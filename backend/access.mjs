// Who may spend AI money: installation credentials, the free preview, and the `pro` entitlement.
//
// **The rule, in one line:** a paid request is served when the installation is authenticated AND
// (its RevenueCat identity has an active `pro` entitlement OR its free preview still has allowance).
//
// Three properties this module exists to guarantee:
//
// 1. **The client never names its customer.** An installation is created here, with a random secret
//    the app keeps in its Keychain. Its RevenueCat app user id is derived here, from the installation
//    id, and returned to the app. Entitlement is always looked up for *that* id — nothing in a request
//    can point the check at another customer.
// 2. **Failure never grants Pro.** A RevenueCat error, timeout or unknown response denies Pro, except
//    that a previously *verified* expiration date is honoured until it passes. That is continuity for
//    a network blip, never permanent access.
// 3. **Preview counters are atomic.** Each allowance is taken with one conditional UPDATE, so two
//    simultaneous requests can never both take the last unit.
//
// Stored: installation id, a hash of its secret, timestamps, preview counters and the cached
// entitlement expiry. **Never interview content** — no transcript, answer, file or note reaches this
// database.

import { DatabaseSync } from "node:sqlite";
import { randomBytes, randomUUID, createHash, timingSafeEqual } from "node:crypto";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

// The RevenueCat entitlement that unlocks Neverblank Pro. The app checks the same identifier
// (`BillingConfiguration.entitlementIdentifier`).
export const ENTITLEMENT = "neverblank_pro";

/** Operator-tunable limits. The client's 30-second meter is the experience; these bound the cost. */
export function accessLimitsFromEnv(env = process.env) {
  const number = (name, fallback) => {
    const value = Number(env[name]);
    return Number.isFinite(value) && value >= 0 ? value : fallback;
  };
  return {
    previewAnswers: number("PREVIEW_MAX_ANSWERS", 5),
    previewDetections: number("PREVIEW_MAX_DETECTIONS", 60),
    // After the app reports the preview ended, an answer the user had already asked for may still
    // start (it can be queued behind another). Detection stops at once.
    previewAnswerGraceMs: number("PREVIEW_ANSWER_GRACE_MS", 60_000),
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
    `);
  }

  close() { this.db.close(); }

  createInstallation() {
    const id = randomUUID();
    const secret = randomBytes(32).toString("base64url");
    const at = this.now();
    const appUserID = appUserIDFor(id);
    this.db.prepare("INSERT INTO installations (id, secret_hash, app_user_id, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?)")
      .run(id, hashSecret(secret), appUserID, at, at);
    this.db.prepare("INSERT INTO previews (installation_id) VALUES (?)").run(id);
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

  preview(installationID) {
    return this.db.prepare("SELECT started_at, ended_at, answers_used, detections_used FROM previews WHERE installation_id = ?").get(installationID) ?? null;
  }

  /**
   * Takes one unit of preview allowance, atomically. `kind` is "answer" or "detection".
   * Returns true when the unit was granted.
   */
  takePreview(installationID, kind, limits) {
    const at = this.now();
    // Ended previews still admit answers inside the grace window; detections stop immediately.
    const result = kind === "answer"
      ? this.db.prepare(
          `UPDATE previews SET answers_used = answers_used + 1, started_at = COALESCE(started_at, ?)
           WHERE installation_id = ? AND answers_used < ? AND (ended_at IS NULL OR ended_at + ? >= ?)`
        ).run(at, installationID, limits.previewAnswers, limits.previewAnswerGraceMs, at)
      : this.db.prepare(
          `UPDATE previews SET detections_used = detections_used + 1, started_at = COALESCE(started_at, ?)
           WHERE installation_id = ? AND detections_used < ? AND ended_at IS NULL`
        ).run(at, installationID, limits.previewDetections);
    return result.changes === 1;
  }

  /** The app's report that its 30 seconds of listening are used. Idempotent; never reopens. */
  endPreview(installationID) {
    const at = this.now();
    this.db.prepare("UPDATE previews SET ended_at = COALESCE(ended_at, ?), started_at = COALESCE(started_at, ?) WHERE installation_id = ?")
      .run(at, at, installationID);
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
  async authorize(installation, kind) {
    const pro = await this.pro(installation);
    if (pro.active) return { allowed: true, via: "pro" };
    if (this.store.takePreview(installation.id, kind, this.limits)) return { allowed: true, via: "preview" };
    return { allowed: false, via: null };
  }

  async describe(installation, { refresh = false } = {}) {
    const pro = await this.pro(installation, { refresh });
    const preview = this.store.preview(installation.id) ?? {};
    const answersLeft = Math.max(0, this.limits.previewAnswers - (preview.answers_used ?? 0));
    const ended = preview.ended_at != null || answersLeft === 0;
    return {
      entitlement: ENTITLEMENT,
      app_user_id: installation.appUserID,
      pro: { active: pro.active, expires_at: pro.expiresAt ? new Date(pro.expiresAt).toISOString() : null, verified: pro.source !== "verification_failed" && pro.source !== "unconfigured" },
      preview: { state: ended ? "ended" : preview.started_at ? "started" : "available", answers_left: answersLeft },
    };
  }
}

/** The product events the app may send. Anything else is refused, so nothing free-form is logged. */
export const PRODUCT_EVENTS = new Set([
  "trial_started", "trial_30s_consumed", "paywall_viewed", "weekly_selected", "monthly_selected",
  "purchase_started", "purchase_completed", "purchase_failed", "purchase_restored", "paywall_dismissed",
]);
const EVENT_FIELDS = { plan: new Set(["weekly", "monthly"]), trigger: new Set(["preview_end", "generate", "settings", "retry"]), reason: new Set(["cancelled", "store_error", "network", "pending", "not_entitled", "unavailable"]) };

/** Validates an event body into a log-safe object, or null. Only enumerated values survive. */
export function sanitizeEvent(body) {
  if (!body || typeof body !== "object" || !PRODUCT_EVENTS.has(body.name)) return null;
  const event = { name: body.name };
  for (const [field, allowed] of Object.entries(EVENT_FIELDS)) {
    if (allowed.has(body[field])) event[field] = body[field];
  }
  return event;
}
