// Who may spend AI money: installation credentials, two free AI answers, and the `neverblank_pro`
// entitlement.
//
// **The rule, in one line:** a paid request is served when the installation is authenticated AND
// (its RevenueCat identity has an active `neverblank_pro` entitlement OR it still has free answers).
//
// Properties this module guarantees:
//
// 1. **The client never names its customer.** An installation is created here, with a random secret
//    the app keeps in its Keychain. Its RevenueCat app user id is derived here, and entitlement is
//    always looked up for *that* id.
// 2. **Failure never grants Pro.** A RevenueCat error, timeout or unknown response denies Pro, except
//    that a previously *verified* expiration date is honoured until it passes.
// 3. **Two free answers, counted exactly** (see "Free answers" below): capacity is reserved
//    atomically before a request is sent to the model, and settled once when the stream ends.
//
// Stored: installation id, a hash of its secret, timestamps, free-answer counters, reservation and
// generation-key bookkeeping, and the cached entitlement expiry. **Never interview content.**
//
// ## Free answers
//
// - A free installation gets `FREE_ANSWERS` (2) successful AI answers in total — not per day, not per
//   session, and not an App Store trial.
// - Before an answer is generated, one unit of capacity is **reserved** in a single statement that
//   succeeds only while `used + active reservations < limit`, so simultaneous taps cannot exceed it.
// - When the stream ends the reservation is **settled once**: a delivered, non-empty answer (prose or
//   code) that is not only a request for clarification or context **consumes** a credit; a failure,
//   an empty response or a clarification-only response **releases** it.
// - **Disconnecting does not help:** if answer text had already been sent when the client went away,
//   the credit is consumed; with nothing sent, it is released.
// - **Retries are not charged twice.** Requests carry a generation key (the app keeps it with the
//   request's snapshot, so Retry sends the same key). A key that already consumed a credit is served
//   again without charge, at most `FREE_REDELIVERIES` times. Regenerating or a follow-up action is a
//   new generation with a new key and uses the same allowance.
// - **Bounded abuse control:** free requests that end without consuming (failures, empty or
//   clarification-only results) are counted; after `FREE_MAX_UNCOUNTED` of them no more free answers
//   are served. Reservations older than `FREE_RESERVATION_TTL_MS` (a crashed server mid-stream) stop
//   holding capacity.
// - Question detection and focused decisions are served free **only while free answers remain**,
//   bounded by `FREE_MAX_DETECTIONS`. Pro requests never touch any of these counters.
//
// ## Migration from the 30-second preview (schema of 2026-09-25)
//
// Existing `previews` rows get `free_used` once, when this version first opens the database:
// - a preview that had **ended** (its 30 seconds used) counts as the allowance used: `free_used = 2`;
// - otherwise `free_used = min(answers_used, 2)` — answers it already received are not given back.
// Nothing is reset silently, paid access is untouched (entitlements are a separate table), and each
// migrated row is marked `migrated_from = 'preview-30s'`.

import { DatabaseSync } from "node:sqlite";
import { randomBytes, randomUUID, createHash, timingSafeEqual } from "node:crypto";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

// The RevenueCat entitlement that unlocks Neverblank Pro. The app checks the same identifier
// (`BillingConfiguration.entitlementIdentifier`).
export const ENTITLEMENT = "neverblank_pro";

/** Operator-tunable limits. */
export function accessLimitsFromEnv(env = process.env) {
  const number = (name, fallback) => {
    const value = Number(env[name]);
    return Number.isFinite(value) && value >= 0 ? value : fallback;
  };
  return {
    freeAnswers: number("FREE_ANSWERS", 2),
    freeDetections: number("FREE_MAX_DETECTIONS", 300),
    freeMaxUncounted: number("FREE_MAX_UNCOUNTED", 10),
    freeRedeliveries: number("FREE_REDELIVERIES", 3),
    reservationTtlMs: number("FREE_RESERVATION_TTL_MS", 180_000),
    proCacheMs: number("PRO_CACHE_MS", 60_000),
    negativeCacheMs: number("PRO_NEGATIVE_CACHE_MS", 15_000),
    installsPerHourPerIP: number("INSTALLS_PER_HOUR_PER_IP", 10),
  };
}

const hashSecret = (secret) => createHash("sha256").update(`neverblank-installation:${secret}`).digest();

export function appUserIDFor(installationID) {
  return `nb_${installationID}`;
}

export class AccessStore {
  /** `path` is a file (durable) or ":memory:" (tests only). */
  constructor(path, { now = () => Date.now() } = {}) {
    if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true });
    this.path = path;
    this.now = now;
    this.db = new DatabaseSync(path);
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = FULL;
      CREATE TABLE IF NOT EXISTS installations (
        id TEXT PRIMARY KEY,
        secret_hash BLOB NOT NULL,
        app_user_id TEXT NOT NULL UNIQUE,
        created_at INTEGER NOT NULL,
        last_seen_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS previews (
        installation_id TEXT PRIMARY KEY REFERENCES installations(id),
        started_at INTEGER,
        ended_at INTEGER,
        answers_used INTEGER NOT NULL DEFAULT 0,
        detections_used INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS entitlements (
        installation_id TEXT PRIMARY KEY REFERENCES installations(id),
        active INTEGER NOT NULL,
        expires_at INTEGER,
        verified_at INTEGER NOT NULL
      );
          CREATE TABLE IF NOT EXISTS reservations (
        id TEXT PRIMARY KEY,
        installation_id TEXT NOT NULL REFERENCES installations(id),
        generation_key TEXT,
        created_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS generations (
        installation_id TEXT NOT NULL REFERENCES installations(id),
        generation_key TEXT NOT NULL,
        consumed_at INTEGER NOT NULL,
        deliveries INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (installation_id, generation_key)
      );
    `);
  }

  /** Adds the free-answer columns and migrates preview rows once (see "Migration" above). */
  migrate(limits = accessLimitsFromEnv()) {
    const columns = new Set(this.db.prepare("PRAGMA table_info(previews)").all().map((c) => c.name));
    if (!columns.has("free_used")) this.db.exec("ALTER TABLE previews ADD COLUMN free_used INTEGER");
    if (!columns.has("uncounted")) this.db.exec("ALTER TABLE previews ADD COLUMN uncounted INTEGER NOT NULL DEFAULT 0");
    if (!columns.has("migrated_from")) this.db.exec("ALTER TABLE previews ADD COLUMN migrated_from TEXT");
    return this.db.prepare(
      `UPDATE previews SET
         free_used = CASE WHEN ended_at IS NOT NULL THEN ? ELSE MIN(answers_used, ?) END,
         migrated_from = 'preview-30s'
       WHERE free_used IS NULL`
    ).run(limits.freeAnswers, limits.freeAnswers).changes;
  }

  close() { this.db.close(); }

  createInstallation() {
    const id = randomUUID();
    const secret = randomBytes(32).toString("base64url");
    const at = this.now();
    const appUserID = appUserIDFor(id);
    this.db.prepare("INSERT INTO installations (id, secret_hash, app_user_id, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?)")
      .run(id, hashSecret(secret), appUserID, at, at);
    this.db.prepare("INSERT INTO previews (installation_id, free_used) VALUES (?, 0)").run(id);
    return { installation_id: id, secret, app_user_id: appUserID };
  }

  /** The installation for a presented credential, or null. Constant-time on the secret. */
  authenticate(installationID, secret) {
    if (typeof installationID !== "string" || typeof secret !== "string" || !installationID || !secret) return null;
    const row = this.db.prepare("SELECT id, secret_hash, app_user_id FROM installations WHERE id = ?").get(installationID);
    if (!row) return null;
    const expected = Buffer.from(row.secret_hash);
    const presented = hashSecret(secret);
    if (expected.length !== presented.length || !timingSafeEqual(expected, presented)) return null;
    this.db.prepare("UPDATE installations SET last_seen_at = ? WHERE id = ?").run(this.now(), row.id);
    return { id: row.id, appUserID: row.app_user_id };
  }

  freeState(installationID, limits) {
    const row = this.db.prepare("SELECT free_used, uncounted, detections_used FROM previews WHERE installation_id = ?").get(installationID) ?? {};
    const reserved = this.db.prepare("SELECT COUNT(*) AS n FROM reservations WHERE installation_id = ? AND created_at > ?")
      .get(installationID, this.now() - limits.reservationTtlMs).n;
    return { used: row.free_used ?? 0, uncounted: row.uncounted ?? 0, detections: row.detections_used ?? 0, reserved };
  }

  /**
   * Reserves one free answer, atomically. Returns `{ reservation }` (with `redelivery: true` when the
   * generation key already consumed a credit and is served again without charge), or `{ refused }`.
   */
  reserveFreeAnswer(installationID, generationKey, limits) {
    const at = this.now();
    const state = this.freeState(installationID, limits);
    if (state.uncounted >= limits.freeMaxUncounted) return { refused: "too_many_unsuccessful" };
    if (generationKey) {
      const done = this.db.prepare("SELECT deliveries FROM generations WHERE installation_id = ? AND generation_key = ?").get(installationID, generationKey);
      if (done && done.deliveries <= limits.freeRedeliveries) {
        return { reservation: { id: null, installationID, generationKey, redelivery: true } };
      }
    }
    const id = randomUUID();
    const inserted = this.db.prepare(
      `INSERT INTO reservations (id, installation_id, generation_key, created_at)
       SELECT ?, ?, ?, ?
       WHERE (SELECT free_used FROM previews WHERE installation_id = ?)
           + (SELECT COUNT(*) FROM reservations WHERE installation_id = ? AND created_at > ?) < ?`
    ).run(id, installationID, generationKey ?? null, at, installationID, installationID, at - limits.reservationTtlMs, limits.freeAnswers);
    return inserted.changes === 1 ? { reservation: { id, installationID, generationKey, redelivery: false } } : { refused: "exhausted" };
  }

  /** Settles a reservation exactly once: `consumed` or `released`. */
  settleFreeAnswer(reservation, outcome) {
    const { id, installationID, generationKey, redelivery } = reservation;
    const at = this.now();
    this.db.exec("BEGIN IMMEDIATE");
    try {
      if (id) this.db.prepare("DELETE FROM reservations WHERE id = ?").run(id);
      if (outcome === "consumed") {
        const known = generationKey
          ? this.db.prepare("SELECT deliveries FROM generations WHERE installation_id = ? AND generation_key = ?").get(installationID, generationKey)
          : null;
        if (known) {
          this.db.prepare("UPDATE generations SET deliveries = deliveries + 1 WHERE installation_id = ? AND generation_key = ?").run(installationID, generationKey);
        } else if (!redelivery) {
          if (generationKey) this.db.prepare("INSERT INTO generations (installation_id, generation_key, consumed_at) VALUES (?, ?, ?)").run(installationID, generationKey, at);
          this.db.prepare("UPDATE previews SET free_used = free_used + 1, started_at = COALESCE(started_at, ?) WHERE installation_id = ?").run(at, installationID);
        }
      } else {
        this.db.prepare("UPDATE previews SET uncounted = uncounted + 1 WHERE installation_id = ?").run(installationID);
      }
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }

  /** Detection while free answers remain, bounded; atomic. */
  takeFreeDetection(installationID, limits) {
    return this.db.prepare(
      `UPDATE previews SET detections_used = detections_used + 1
       WHERE installation_id = ? AND free_used < ? AND detections_used < ? AND uncounted < ?`
    ).run(installationID, limits.freeAnswers, limits.freeDetections, limits.freeMaxUncounted).changes === 1;
  }

  cachedEntitlement(installationID) {
    return this.db.prepare("SELECT active, expires_at, verified_at FROM entitlements WHERE installation_id = ?").get(installationID) ?? null;
  }

  storeEntitlement(installationID, { active, expiresAt }) {
    this.db.prepare(
      `INSERT INTO entitlements (installation_id, active, expires_at, verified_at) VALUES (?, ?, ?, ?)
       ON CONFLICT(installation_id) DO UPDATE SET active = excluded.active, expires_at = excluded.expires_at, verified_at = excluded.verified_at`
    ).run(installationID, active ? 1 : 0, expiresAt ?? null, this.now());
  }
}

/**
 * Asks RevenueCat whether an app user currently has `pro`.
 *
 * Returns `{ active, expiresAt }` (expiresAt in ms, null for a non-expiring grant), or throws on any
 * failure — the caller decides what a failure means, and it never means Pro.
 *
 * Uses the v1 subscriber endpoint, which reports each entitlement's `expires_date`. Cancelling
 * auto-renew does not change that date, so access continues until the paid period ends.
 */
export function makeRevenueCatVerifier({ secretKey, fetchImpl = fetch, baseURL = "https://api.revenuecat.com", timeoutMs = 5000, now = () => Date.now() }) {
  if (!secretKey) return null;
  return async function verify(appUserID) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetchImpl(`${baseURL}/v1/subscribers/${encodeURIComponent(appUserID)}`, {
        headers: { authorization: `Bearer ${secretKey}`, accept: "application/json" },
        signal: controller.signal,
      });
      if (!response.ok) throw new Error(`revenuecat_http_${response.status}`);
      const payload = await response.json();
      const entitlement = payload?.subscriber?.entitlements?.[ENTITLEMENT];
      if (!entitlement) return { active: false, expiresAt: null };
      const expires = entitlement.expires_date ? Date.parse(entitlement.expires_date) : null;
      if (expires !== null && !Number.isFinite(expires)) throw new Error("revenuecat_bad_expiry");
      return { active: expires === null || expires > now(), expiresAt: expires };
    } finally {
      clearTimeout(timer);
    }
  };
}

/** Everything the server needs: authenticate, decide, and describe access. */
export class AccessControl {
  constructor({ store, verify, limits = accessLimitsFromEnv(), now = () => Date.now() }) {
    this.store = store;
    this.verify = verify;
    this.limits = limits;
    this.now = now;
    this.installsByIP = new Map();
  }

  /** `Authorization: Installation <id>.<secret>` → the installation, or null. */
  authenticate(request) {
    const header = request.headers?.authorization ?? "";
    if (!header.startsWith("Installation ")) return null;
    const credential = header.slice("Installation ".length).trim();
    const dot = credential.indexOf(".");
    if (dot <= 0) return null;
    return this.store.authenticate(credential.slice(0, dot), credential.slice(dot + 1));
  }

  /** Rate-limited per client address, in memory: a restart only forgets the throttle, not access. */
  register(clientIP) {
    const hour = 3_600_000;
    const at = this.now();
    const recent = (this.installsByIP.get(clientIP) ?? []).filter((t) => at - t < hour);
    if (recent.length >= this.limits.installsPerHourPerIP) return null;
    recent.push(at);
    this.installsByIP.set(clientIP, recent);
    if (this.installsByIP.size > 10_000) this.installsByIP.clear();
    return this.store.createInstallation();
  }

  /**
   * Pro status for an installation. Fresh verification when the cache is stale (or `refresh`);
   * on a failed verification only a still-valid verified expiry keeps access.
   */
  async pro(installation, { refresh = false } = {}) {
    const at = this.now();
    const cached = this.store.cachedEntitlement(installation.id);
    const stillValid = (row) => Boolean(row?.active) && (row.expires_at === null || row.expires_at > at);
    if (cached && !refresh) {
      const ttl = cached.active ? this.limits.proCacheMs : this.limits.negativeCacheMs;
      if (at - cached.verified_at < ttl) return { active: stillValid(cached), expiresAt: cached.expires_at, source: "cache" };
    }
    if (!this.verify) return { active: stillValid(cached), expiresAt: cached?.expires_at ?? null, source: "unconfigured" };
    try {
      const result = await this.verify(installation.appUserID);
      this.store.storeEntitlement(installation.id, result);
      return { ...result, source: "revenuecat" };
    } catch {
      return { active: stillValid(cached), expiresAt: cached?.expires_at ?? null, source: "verification_failed" };
    }
  }

  /**
   * The gate every paid route passes. `kind` is "answer" or "detection".
   * Pro is checked first, so Pro users never touch — and are never limited by — the preview.
   */
  async authorize(installation, kind, { generationKey } = {}) {
    const pro = await this.pro(installation);
    if (pro.active) return { allowed: true, via: "pro" };
    if (kind === "answer") {
      const result = this.store.reserveFreeAnswer(installation.id, generationKey, this.limits);
      return result.reservation
        ? { allowed: true, via: "free", reservation: result.reservation }
        : { allowed: false, via: null, reason: result.refused };
    }
    return this.store.takeFreeDetection(installation.id, this.limits)
      ? { allowed: true, via: "free" }
      : { allowed: false, via: null, reason: "exhausted" };
  }

  /**
   * How a free answer's stream ended decides its credit: consumed only when answer text reached the
   * client and the response was not only a request for clarification or context.
   */
  settle(reservation, { textDelivered, needs }) {
    if (!reservation) return null;
    // Delivered text counts even when the client then disconnected; nothing delivered never does.
    const consumed = Boolean(textDelivered) && !needs;
    this.store.settleFreeAnswer(reservation, consumed ? "consumed" : "released");
    return consumed ? "consumed" : "released";
  }

  async describe(installation, { refresh = false } = {}) {
    const pro = await this.pro(installation, { refresh });
    const free = this.store.freeState(installation.id, this.limits);
    const remaining = free.uncounted >= this.limits.freeMaxUncounted ? 0 : Math.max(0, this.limits.freeAnswers - free.used);
    return {
      entitlement: ENTITLEMENT,
      app_user_id: installation.appUserID,
      pro: { active: pro.active, expires_at: pro.expiresAt ? new Date(pro.expiresAt).toISOString() : null, verified: pro.source !== "verification_failed" && pro.source !== "unconfigured" },
      free_answers: { limit: this.limits.freeAnswers, used: free.used, remaining },
      // Kept for app builds from before the two-answer allowance; derived from the same ledger.
      preview: { state: remaining === 0 ? "ended" : free.used > 0 ? "started" : "available", answers_left: remaining },
    };
  }
}

/** The product events the app may send. Anything else is refused, so nothing free-form is logged. */
export const PRODUCT_EVENTS = new Set([
  "trial_started", "trial_30s_consumed", "free_answers_exhausted", "paywall_viewed", "weekly_selected", "monthly_selected",
  "purchase_started", "purchase_completed", "purchase_failed", "purchase_restored", "paywall_dismissed",
]);
const EVENT_FIELDS = { plan: new Set(["weekly", "monthly"]), trigger: new Set(["preview_end", "free_answers_exhausted", "generate", "settings", "retry"]), reason: new Set(["cancelled", "store_error", "network", "pending", "not_entitled", "unavailable"]) };

/** Validates an event body into a log-safe object, or null. Only enumerated values survive. */
export function sanitizeEvent(body) {
  if (!body || typeof body !== "object" || !PRODUCT_EVENTS.has(body.name)) return null;
  const event = { name: body.name };
  for (const [field, allowed] of Object.entries(EVENT_FIELDS)) {
    if (allowed.has(body[field])) event[field] = body[field];
  }
  return event;
}
