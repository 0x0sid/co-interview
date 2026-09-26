// Access control: installations, the free preview, and the `pro` entitlement (access.mjs).
//
// Part 1 exercises the rules directly with a controllable clock and a scripted RevenueCat.
// Part 2 runs the real server twice on the same database file — the restart is the point — with a
// local stub standing in for RevenueCat, and checks the HTTP contract the app relies on.
//
// Run:  node test/access-test.mjs

import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { DatabaseSync } from "node:sqlite";
import { AccessStore, AccessControl, accessLimitsFromEnv, makeRevenueCatVerifier, sanitizeEvent, appUserIDFor } from "../access.mjs";

let failures = 0;
function check(label, condition, detail = "") {
  if (condition) console.log(`  ok   ${label}`);
  else { failures += 1; console.log(`  FAIL ${label} ${detail}`); }
}


const limits = { ...accessLimitsFromEnv({}), freeMaxUncounted: 4, freeRedeliveries: 2 };

// The deployed defaults, which the app's wording states ("2 free AI answers").
{
  const defaults = accessLimitsFromEnv({});
  check("default: 2 free answers, 300 free detections, 10 unsuccessful free attempts",
    defaults.freeAnswers === 2 && defaults.freeDetections === 300 && defaults.freeMaxUncounted === 10);
}

// --- Part 1: rules --------------------------------------------------------------------------------

console.log("rules");
{
  let clock = 1_000_000;
  const now = () => clock;
  const store = new AccessStore(":memory:", { now });
  store.migrate(limits);
  let rc = { active: false, expiresAt: null };
  let rcFails = false;
  let rcCalls = 0;
  const verify = async () => { rcCalls += 1; if (rcFails) throw new Error("down"); return rc; };
  const control = new AccessControl({ store, verify, limits, now });
  const auth = (id, secret) => control.authenticate({ headers: { authorization: `Installation ${id}.${secret}` } });
  const fresh = (ip = "1.1.1.1") => { const c = control.register(ip); return auth(c.installation_id, c.secret); };

  const created = control.register("1.2.3.4");
  check("an installation is created with a secret and a server-chosen app user id",
    created && created.secret.length >= 40 && created.app_user_id === appUserIDFor(created.installation_id));
  const me = auth(created.installation_id, created.secret);
  check("the credential authenticates", me?.id === created.installation_id);
  check("a wrong secret does not", auth(created.installation_id, "x".repeat(43)) === null);
  check("another installation's id with my secret does not", auth("00000000-0000-0000-0000-000000000000", created.secret) === null);
  check("a bearer header is not an installation", control.authenticate({ headers: { authorization: `Bearer ${created.secret}` } }) === null);

  const answer = async (who, key) => control.authorize(who, "answer", { generationKey: key });
  const delivered = { textDelivered: true };

  // Two answers, then nothing.
  const a1 = await answer(me, "g1"); control.settle(a1.reservation, delivered);
  const a2 = await answer(me, "g2"); control.settle(a2.reservation, delivered);
  const a3 = await answer(me, "g3");
  check("the first and second answers are free", a1.allowed && a2.allowed && a1.via === "free");
  check("the third is refused before any model call", !a3.allowed && a3.reason === "exhausted");
  check("the allowance reads 0 left", (await control.describe(me)).free_answers.remaining === 0);

  // Rapid taps: ten reservations at once take exactly two.
  const burstUser = fresh();
  const burst = await Promise.all(Array.from({ length: 10 }, (_, n) => answer(burstUser, `b${n}`)));
  check("ten simultaneous taps reserve exactly two", burst.filter((r) => r.allowed).length === 2, JSON.stringify(burst.map((r) => r.allowed)));

  // What does not count.
  const u = fresh();
  for (const ending of [{ textDelivered: false }, { textDelivered: true, needs: "clarification" }, { textDelivered: true, needs: "context" }]) {
    const r = await answer(u, `x${Math.random()}`);
    control.settle(r.reservation, ending);
  }
  check("failures, empty and clarification-only results do not consume", (await control.describe(u)).free_answers.used === 0);
  const code = await answer(u, "code"); control.settle(code.reservation, delivered);
  check("a code-only answer consumes one", (await control.describe(u)).free_answers.used === 1);

  // Retry: the same generation key is not charged twice, and not forever.
  const r = fresh();
  const first = await answer(r, "same"); control.settle(first.reservation, delivered);
  const again = await answer(r, "same"); control.settle(again.reservation, delivered);
  check("a retried generation is not charged twice", (await control.describe(r)).free_answers.used === 1 && again.reservation.redelivery);
  const other = await answer(r, "new"); control.settle(other.reservation, delivered);
  check("a new generation (regenerate, follow-up) uses the allowance", (await control.describe(r)).free_answers.used === 2);
  const third = await answer(r, "same"); control.settle(third.reservation, delivered); // third delivery: the limit
  const pastLimit = await answer(r, "same");
  check("re-sending one key is bounded", !pastLimit.allowed);

  // Disconnect: text already sent counts; nothing sent does not.
  const d = fresh();
  const cut = await answer(d, "d1"); control.settle(cut.reservation, { textDelivered: true });
  const early = await answer(d, "d2"); control.settle(early.reservation, { textDelivered: false });
  check("a disconnect after text was sent consumes; before any text it does not", (await control.describe(d)).free_answers.used === 1);

  // Abuse bound: unsuccessful free attempts are capped.
  const abuser = fresh();
  for (let n = 0; n < limits.freeMaxUncounted; n += 1) {
    const x = await answer(abuser, `f${n}`); control.settle(x.reservation, { textDelivered: false });
  }
  const blocked = await answer(abuser, "after");
  check("repeated unsuccessful free attempts are bounded", !blocked.allowed && blocked.reason === "too_many_unsuccessful");

  // A reservation left by a crash stops holding capacity after its lifetime.
  const crash = fresh();
  await answer(crash, "c1"); await answer(crash, "c2");
  check("two open reservations hold both answers", !(await answer(crash, "c3")).allowed);
  clock += limits.reservationTtlMs + 1;
  check("stale reservations are not held forever", (await answer(crash, "c4")).allowed);

  // Detection: only while answers remain.
  const det = fresh();
  check("detection is served while free answers remain", (await control.authorize(det, "detection")).allowed);
  for (const k of ["k1", "k2"]) { const x = await answer(det, k); control.settle(x.reservation, delivered); }
  check("detection stops when the free answers are used", !(await control.authorize(det, "detection")).allowed);

  // Pro: verified, never limited, never consumes.
  rc = { active: true, expiresAt: clock + 7 * 86_400_000 };
  check("an active RevenueCat entitlement is Pro", (await control.describe(me, { refresh: true })).pro.active);
  const proBurst = await Promise.all(Array.from({ length: 20 }, (_, n) => answer(me, `p${n}`)));
  check("Pro is never limited by the used allowance", proBurst.every((x) => x.allowed && x.via === "pro" && !x.reservation));
  check("Pro requests consume no free credit", (await control.describe(me)).free_answers.used === 2);
  const callsBefore = rcCalls;
  await control.authorize(me, "detection");
  check("Pro is served from the cache inside its lifetime", rcCalls === callsBefore);
  rcFails = true;
  clock += limits.proCacheMs + 1;
  check("a verification failure keeps a verified, unexpired entitlement", (await answer(me, "q")).allowed);
  clock += 8 * 86_400_000;
  check("…but never past its expiry", !(await answer(me, "q2")).allowed);
  const newcomer = fresh();
  const failed = await control.describe(newcomer, { refresh: true });
  check("a verification failure with no history is not Pro", !failed.pro.active && !failed.pro.verified);
  rcFails = false;

  const bare = new AccessControl({ store, verify: null, limits, now });
  check("without a RevenueCat key nobody is Pro", !(await bare.describe(newcomer)).pro.active);

  const throttled = new AccessControl({ store, verify, limits: { ...limits, installsPerHourPerIP: 2 }, now });
  throttled.register("7.7.7.7"); throttled.register("7.7.7.7");
  check("installations are throttled per address", throttled.register("7.7.7.7") === null);
  check("…and other addresses are unaffected", throttled.register("8.8.8.8") !== null);

  check("unknown events are refused", sanitizeEvent({ name: "transcript", text: "hello" }) === null);
  check("free-form fields are dropped from events",
    JSON.stringify(sanitizeEvent({ name: "purchase_failed", reason: "cancelled", plan: "monthly", text: "my CV" })) === JSON.stringify({ name: "purchase_failed", plan: "monthly", reason: "cancelled" }));
  check("the exhaustion event is accepted", sanitizeEvent({ name: "free_answers_exhausted" })?.name === "free_answers_exhausted");
  store.close();
}

// Migration from the 30-second preview.
{
  const dir = mkdtempSync(join(tmpdir(), "neverblank-migrate-"));
  const path = join(dir, "old.sqlite");
  const old = new DatabaseSync(path);
  old.exec(`CREATE TABLE installations (id TEXT PRIMARY KEY, secret_hash BLOB NOT NULL, app_user_id TEXT NOT NULL UNIQUE, created_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL);
    CREATE TABLE previews (installation_id TEXT PRIMARY KEY, started_at INTEGER, ended_at INTEGER, answers_used INTEGER NOT NULL DEFAULT 0, detections_used INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE entitlements (installation_id TEXT PRIMARY KEY, active INTEGER NOT NULL, expires_at INTEGER, verified_at INTEGER NOT NULL);`);
  const add = old.prepare("INSERT INTO installations VALUES (?, x'00', ?, 0, 0)");
  const prev = old.prepare("INSERT INTO previews VALUES (?, ?, ?, ?, 0)");
  add.run("ended", "nb_ended"); prev.run("ended", 1, 2, 0);          // 30 s used, no answers
  add.run("one", "nb_one"); prev.run("one", 1, null, 1);             // one answer, still running
  add.run("many", "nb_many"); prev.run("many", 1, null, 4);          // more than two answers
  add.run("unused", "nb_unused"); prev.run("unused", null, null, 0); // never used
  old.prepare("INSERT INTO entitlements VALUES ('many', 1, NULL, 0)").run();
  old.close();
  const store = new AccessStore(path);
  const migrated = store.migrate(limits);
  const used = Object.fromEntries(store.db.prepare("SELECT installation_id, free_used, migrated_from FROM previews").all().map((r) => [r.installation_id, r]));
  check("migration: an ended preview counts as the allowance used", used.ended.free_used === 2);
  check("migration: answers already received are not given back", used.one.free_used === 1 && used.many.free_used === 2);
  check("migration: an unused preview keeps both answers", used.unused.free_used === 0);
  check("migration: each migrated row is marked, once", migrated === 4 && used.one.migrated_from === "preview-30s" && store.migrate(limits) === 0);
  check("migration: paid access is untouched", store.cachedEntitlement("many")?.active === 1);
  store.close();
  rmSync(dir, { recursive: true, force: true });
}

// RevenueCat response parsing.
{
  const at = Date.parse("2026-10-01T00:00:00Z");
  const reply = (status, body) => async () => ({ ok: status === 200, status, json: async () => body });
  const make = (fetchImpl) => makeRevenueCatVerifier({ secretKey: "sk_test", fetchImpl, now: () => at });
  const active = await make(reply(200, { subscriber: { entitlements: { neverblank_pro: { expires_date: "2026-10-05T00:00:00Z" } } } }))("nb_x");
  check("RevenueCat: a future expiry is active", active.active && active.expiresAt === Date.parse("2026-10-05T00:00:00Z"));
  const lapsed = await make(reply(200, { subscriber: { entitlements: { neverblank_pro: { expires_date: "2026-09-01T00:00:00Z" } } } }))("nb_x");
  check("RevenueCat: a past expiry is inactive", !lapsed.active);
  const other = await make(reply(200, { subscriber: { entitlements: { pro: { expires_date: null } } } }))("nb_x");
  check("RevenueCat: another entitlement (the old `pro`) does not unlock", !other.active);
  const lifetime = await make(reply(200, { subscriber: { entitlements: { neverblank_pro: { expires_date: null } } } }))("nb_x");
  check("RevenueCat: a lifetime purchase (no expiry) is active", lifetime.active && lifetime.expiresAt === null);
  let threw = false;
  try { await make(reply(500, {}))("nb_x"); } catch { threw = true; }
  check("RevenueCat: an HTTP error throws rather than answering", threw);
  let path = "";
  await make(async (url) => { path = url; return { ok: true, status: 200, json: async () => ({ subscriber: { entitlements: {} } }) }; })("nb_a/b");
  check("RevenueCat: the app user id is path-encoded", path.endsWith("/v1/subscribers/nb_a%2Fb"));
  check("RevenueCat: no key means no verifier", makeRevenueCatVerifier({ secretKey: "" }) === null);
}

// --- Part 2: the server, restarted on the same database -----------------------------------------------

console.log("server");
const dir = mkdtempSync(join(tmpdir(), "neverblank-access-"));
const dbPath = join(dir, "access.sqlite");
const proUsers = new Set();
const revenueCat = createServer((request, response) => {
  const id = decodeURIComponent(request.url.split("/").pop());
  const ok = request.headers.authorization === "Bearer sk_stub";
  response.writeHead(ok ? 200 : 401, { "content-type": "application/json" });
  response.end(JSON.stringify(ok ? { subscriber: { entitlements: proUsers.has(id) ? { neverblank_pro: { expires_date: new Date(Date.now() + 86_400_000).toISOString() } } : {} } } : {}));
});
await new Promise((resolve) => revenueCat.listen(9931, "127.0.0.1", resolve));

const PORT = 9932;
const base = `http://127.0.0.1:${PORT}`;
function startServer() {
  const child = spawn(process.execPath, ["server.mjs"], {
    cwd: new URL("..", import.meta.url).pathname,
    env: {
      ...process.env,
      COINTERVIEW_NO_ENV_FILE: "1",
      PORT: String(PORT),
      COINTERVIEW_TOKENS: "operator-token",
      COINTERVIEW_FAKE: "1",
      ACCESS_DB_PATH: dbPath,
      REVENUECAT_SECRET_KEY: "sk_stub",
      REVENUECAT_API_BASE: "http://127.0.0.1:9931",
      FREE_ANSWERS: "2",
      PRO_CACHE_MS: "0",
      PRO_NEGATIVE_CACHE_MS: "0",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.output = "";
  child.stdout.on("data", (d) => { child.output += d; });
  child.stderr.on("data", (d) => { child.output += d; });
  return child;
}
async function waitForHealth() {
  for (let i = 0; i < 50; i += 1) {
    try { if ((await fetch(`${base}/health`)).ok) return; } catch {}
    await delay(100);
  }
  throw new Error("server did not start");
}
/** Waits for the current server to log a line matching `pattern`, for at most `timeoutMs`. */
async function logged(pattern, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (pattern.test(server.output)) return true;
    await delay(25);
  }
  return false;
}
async function stop(child) {
  child.kill("SIGTERM");
  await new Promise((resolve) => child.once("exit", resolve));
}

let server = startServer();
try {
  await waitForHealth();
  const auth = (c) => ({ authorization: `Installation ${c.installation_id}.${c.secret}`, "content-type": "application/json" });
  const post = (path, headers, body) => fetch(`${base}${path}`, { method: "POST", headers, body: JSON.stringify(body) });
  const answer = (headers) => post("/v1/copilot/answer", headers, { question: "Tell me about yourself." });
  const classify = (headers) => post("/v1/copilot/classify", headers, { newSpeech: "What is Kafka?" });

  const created = await (await post("/v1/installations", {}, {})).json();
  const ask = (headers, extra = {}) => post("/v1/copilot/answer", headers, { question: "Tell me about yourself.", ...extra });
  const drain = async (response) => { await response.text(); return response; };
  check("POST /v1/installations issues a credential", created.installation_id && created.secret && created.app_user_id);
  check("no credential → 401", (await answer({ "content-type": "application/json" })).status === 401);
  check("a made-up installation → 401", (await answer(auth({ installation_id: created.installation_id, secret: "guess" }))).status === 401);
  check("a malformed request is refused before any allowance is reserved", (await post("/v1/copilot/answer", auth(created), {})).status === 400);
  check("an empty response does not use an answer", (await drain(await ask(auth(created), { fakeOutcome: "empty", generationKey: "e" }))).status === 200);
  check("a clarification-only response does not use an answer", (await drain(await ask(auth(created), { fakeOutcome: "clarification", generationKey: "c" }))).status === 200);
  check("a failed stream does not use an answer", (await drain(await ask(auth(created), { fakeOutcome: "error", generationKey: "x" }))).status === 200);
  check("request log: free, settled as released", await logged(/POST \/v1\/copilot\/answer -> 200 \d+ms auth=installation basis=free outcome=done_empty free_credit=released/));
  let described = await (await fetch(`${base}/v1/access`, { headers: auth(created) })).json();
  check("…so both free answers remain", described.free_answers.remaining === 2 && described.free_answers.limit === 2);
  check("free answer 1 is served", (await drain(await ask(auth(created), { generationKey: "g1" }))).status === 200);
  check("free answer 2 is served", (await drain(await ask(auth(created), { generationKey: "g2" }))).status === 200);
  check("request log: installation auth, free basis, completed, credit consumed — no ids or content",
    await logged(/POST \/v1\/copilot\/answer -> 200 \d+ms auth=installation basis=free outcome=done free_credit=consumed/)
      && !server.output.includes(created.installation_id) && !server.output.includes(created.secret));
  const refused = await ask(auth(created), { generationKey: "g3" });
  const refusedBody = await refused.json();
  check("the third answer needs Pro (402, reason exhausted)", refused.status === 402 && refusedBody.error === "pro_required" && refusedBody.reason === "exhausted");
  check("request log: a refusal says so", await logged(/POST \/v1\/copilot\/answer -> 402 \d+ms auth=installation basis=refused/));
  check("detection stops once the free answers are used", (await classify(auth(created))).status === 402);
  described = await (await fetch(`${base}/v1/access`, { headers: auth(created) })).json();
  check("GET /v1/access reports 0 free answers left and no Pro", described.free_answers.remaining === 0 && !described.pro.active && described.app_user_id === created.app_user_id);
  check("an older app's preview-end call changes nothing", (await post("/v1/preview/end", auth(created), {})).status === 200);
  check("installations cannot read operator diagnostics", (await fetch(`${base}/v1/copilot/diagnostics/decisions?session=x`, { headers: auth(created) })).status === 403);
  check("the operator token still works (development and evaluation)",
    (await drain(await answer({ authorization: "Bearer operator-token", "content-type": "application/json" }))).status === 200);

  const event = await post("/v1/events", auth(created), { name: "paywall_viewed", trigger: "generate", text: "secret interview content" });
  check("an allowed event is accepted", event.status === 204);
  check("the event log line carries only enumerated values",
    await logged(/\[event\] name=paywall_viewed trigger=generate/) && !server.output.includes("secret interview content") && !server.output.includes(created.installation_id));
  check("an unknown event is refused", (await post("/v1/events", auth(created), { name: "transcript_line" })).status === 400);

  // A client that disconnects after text started arriving has received an answer.
  const leaver = await (await post("/v1/installations", {}, {})).json();
  const controller = new AbortController();
  const streaming = await fetch(`${base}/v1/copilot/answer`, { method: "POST", headers: auth(leaver), body: JSON.stringify({ question: "Q", generationKey: "L1" }), signal: controller.signal });
  const reader = streaming.body.getReader();
  await reader.read();                        // the first text has arrived
  controller.abort();
  await logged(/outcome=client_closed free_credit=consumed/);
  const leaverState = await (await fetch(`${base}/v1/access`, { headers: auth(leaver) })).json();
  check("a disconnect after text arrived uses the answer", leaverState.free_answers.used === 1);

  // Restart: the credential and the counters must survive.
  await stop(server);
  server = startServer();
  await waitForHealth();
  check("after a restart the same credential still authenticates", (await fetch(`${base}/v1/access`, { headers: auth(created) })).status === 200);
  check("after a restart the used allowance is still used", (await ask(auth(created), { generationKey: "g4" })).status === 402);

  // Purchase: the server finds Pro for the id it issued, and nothing the client says changes that.
  proUsers.add(created.app_user_id);
  const afterPurchase = await (await fetch(`${base}/v1/access?refresh=1`, { headers: auth(created) })).json();
  check("after purchase /v1/access?refresh=1 reports Pro", afterPurchase.pro.active && afterPurchase.pro.verified);
  check("Pro answers are served beyond the allowance", (await drain(await ask(auth(created), { generationKey: "p1" }))).status === 200);
  check("request log: a Pro answer is logged with basis=pro and no credit", await logged(/auth=installation basis=pro outcome=done(?! free_credit)/));
  const stranger = await (await post("/v1/installations", {}, {})).json();
  const claim = await drain(await answer({ ...auth(stranger), "x-revenuecat-app-user-id": created.app_user_id }));
  check("a second installation is not Pro because another customer is",
    claim.status === 200 && (await (await fetch(`${base}/v1/access`, { headers: auth(stranger) })).json()).pro.active === false);
  proUsers.delete(created.app_user_id);
  check("when the entitlement lapses Pro stops", (await ask(auth(created), { generationKey: "p2" })).status === 402);
} catch (error) {
  failures += 1;
  console.log(`  FAIL ${error.stack}\n${server.output}`);
} finally {
  await stop(server);
  revenueCat.close();
  rmSync(dir, { recursive: true, force: true });
}

if (process.env.SHOW_SERVER_LOG) console.log(server.output);
console.log(failures ? `\n${failures} failure(s)` : "\nall access checks passed");
process.exit(failures ? 1 : 0);
