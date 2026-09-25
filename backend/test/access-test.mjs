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
import { AccessStore, AccessControl, accessLimitsFromEnv, makeRevenueCatVerifier, sanitizeEvent, appUserIDFor } from "../access.mjs";

let failures = 0;
function check(label, condition, detail = "") {
  if (condition) console.log(`  ok   ${label}`);
  else { failures += 1; console.log(`  FAIL ${label} ${detail}`); }
}

const limits = { ...accessLimitsFromEnv({}), previewAnswers: 3, previewDetections: 4, previewAnswerGraceMs: 60_000 };

// --- Part 1: rules --------------------------------------------------------------------------------

console.log("rules");
{
  let clock = 1_000_000;
  const now = () => clock;
  const store = new AccessStore(":memory:", { now });
  let rc = { active: false, expiresAt: null };
  let rcFails = false;
  let rcCalls = 0;
  const verify = async () => { rcCalls += 1; if (rcFails) throw new Error("down"); return rc; };
  const control = new AccessControl({ store, verify, limits, now });

  const created = control.register("1.2.3.4");
  check("an installation is created with a secret and a server-chosen app user id",
    created && created.secret.length >= 40 && created.app_user_id === appUserIDFor(created.installation_id));
  const auth = (id, secret) => control.authenticate({ headers: { authorization: `Installation ${id}.${secret}` } });
  const me = auth(created.installation_id, created.secret);
  check("the credential authenticates", me?.id === created.installation_id);
  check("a wrong secret does not", auth(created.installation_id, "x".repeat(43)) === null);
  check("another installation's id with my secret does not", auth("00000000-0000-0000-0000-000000000000", created.secret) === null);
  check("a bearer header is not an installation", control.authenticate({ headers: { authorization: `Bearer ${created.secret}` } }) === null);

  // Free preview: answers capped, atomically.
  const results = await Promise.all(Array.from({ length: 10 }, () => control.authorize(me, "answer")));
  check("ten simultaneous answers take exactly the three preview answers",
    results.filter((r) => r.allowed).length === 3, JSON.stringify(results.map((r) => r.allowed)));
  check("…and every grant was the preview", results.filter((r) => r.allowed).every((r) => r.via === "preview"));

  // Detection has its own counter and stops the moment the preview is ended.
  const second = auth(control.register("1.2.3.4").installation_id, "nope");
  check("(a wrong credential for a second installation is refused)", second === null);
  const fresh = control.register("5.6.7.8");
  const other = auth(fresh.installation_id, fresh.secret);
  check("a detection is admitted during the preview", (await control.authorize(other, "detection")).allowed);
  store.endPreview(other.id);
  check("detection stops as soon as the preview is ended", !(await control.authorize(other, "detection")).allowed);
  check("an answer already asked for may still start inside the grace window", (await control.authorize(other, "answer")).allowed);
  clock += 61_000;
  check("…but not after it", !(await control.authorize(other, "answer")).allowed);
  store.endPreview(other.id);
  check("ending twice never reopens the preview", (await control.describe(other)).preview.state === "ended");

  // Pro: verified, never limited by the preview, cached, and honest when verification fails.
  rc = { active: true, expiresAt: clock + 7 * 86_400_000 };
  const pro = await control.describe(other, { refresh: true });
  check("an active RevenueCat entitlement is Pro", pro.pro.active && pro.pro.verified);
  const burst = await Promise.all(Array.from({ length: 20 }, () => control.authorize(other, "answer")));
  check("Pro is never limited by the exhausted preview", burst.every((r) => r.allowed && r.via === "pro"));
  const callsBefore = rcCalls;
  await control.authorize(other, "detection");
  check("Pro is served from the cache inside its lifetime", rcCalls === callsBefore);

  // Cancelled auto-renew keeps the same expiry, so access continues until it passes.
  rcFails = true;
  clock += limits.proCacheMs + 1;
  check("a verification failure keeps a verified, unexpired entitlement", (await control.authorize(other, "answer")).allowed);
  clock += 8 * 86_400_000;
  check("…but never past its expiry", !(await control.authorize(other, "answer")).allowed);

  rcFails = false;
  rc = { active: false, expiresAt: clock - 1000 };
  const expired = await control.describe(other, { refresh: true });
  check("an expired entitlement is not Pro", !expired.pro.active);

  // Never Pro from a failure with nothing verified before.
  const newcomer = control.register("9.9.9.9");
  const n = auth(newcomer.installation_id, newcomer.secret);
  rcFails = true;
  const failed = await control.describe(n, { refresh: true });
  check("a verification failure with no history is not Pro", !failed.pro.active && !failed.pro.verified);
  rcFails = false;

  // No verifier configured: nobody is Pro, the preview still works.
  const bare = new AccessControl({ store, verify: null, limits, now });
  check("without a RevenueCat key nobody is Pro", !(await bare.describe(n)).pro.active);
  check("…and the preview still works", (await bare.authorize(n, "answer")).allowed);

  // Installation throttle per address.
  const throttled = new AccessControl({ store, verify, limits: { ...limits, installsPerHourPerIP: 2 }, now });
  throttled.register("7.7.7.7"); throttled.register("7.7.7.7");
  check("installations are throttled per address", throttled.register("7.7.7.7") === null);
  check("…and other addresses are unaffected", throttled.register("8.8.8.8") !== null);

  check("unknown events are refused", sanitizeEvent({ name: "transcript", text: "hello" }) === null);
  check("free-form fields are dropped from events",
    JSON.stringify(sanitizeEvent({ name: "purchase_failed", reason: "cancelled", plan: "monthly", text: "my CV" })) === JSON.stringify({ name: "purchase_failed", plan: "monthly", reason: "cancelled" }));
  store.close();
}

// RevenueCat response parsing.
{
  const at = Date.parse("2026-10-01T00:00:00Z");
  const reply = (status, body) => async () => ({ ok: status === 200, status, json: async () => body });
  const make = (fetchImpl) => makeRevenueCatVerifier({ secretKey: "sk_test", fetchImpl, now: () => at });
  const active = await make(reply(200, { subscriber: { entitlements: { pro: { expires_date: "2026-10-05T00:00:00Z" } } } }))("nb_x");
  check("RevenueCat: a future expiry is active", active.active && active.expiresAt === Date.parse("2026-10-05T00:00:00Z"));
  const lapsed = await make(reply(200, { subscriber: { entitlements: { pro: { expires_date: "2026-09-01T00:00:00Z" } } } }))("nb_x");
  check("RevenueCat: a past expiry is inactive", !lapsed.active);
  const other = await make(reply(200, { subscriber: { entitlements: { premium: { expires_date: null } } } }))("nb_x");
  check("RevenueCat: another entitlement is not pro", !other.active);
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
  response.end(JSON.stringify(ok ? { subscriber: { entitlements: proUsers.has(id) ? { pro: { expires_date: new Date(Date.now() + 86_400_000).toISOString() } } : {} } } : {}));
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
      PREVIEW_MAX_ANSWERS: "2",
      PREVIEW_MAX_DETECTIONS: "3",
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
  check("POST /v1/installations issues a credential", created.installation_id && created.secret && created.app_user_id);
  check("no credential → 401", (await answer({ "content-type": "application/json" })).status === 401);
  check("a made-up installation → 401", (await answer(auth({ installation_id: created.installation_id, secret: "guess" }))).status === 401);
  check("a malformed request is refused before the preview is spent",
    (await post("/v1/copilot/answer", auth(created), {})).status === 400);
  check("preview answer 1 is served", (await answer(auth(created))).status === 200);
  check("preview answer 2 is served", (await answer(auth(created))).status === 200);
  const refused = await answer(auth(created));
  check("the third answer needs Pro (402 pro_required)", refused.status === 402 && (await refused.json()).error === "pro_required");
  check("detection is still in its own allowance", (await classify(auth(created))).status === 200);
  const described = await (await fetch(`${base}/v1/access`, { headers: auth(created) })).json();
  check("GET /v1/access reports the preview ended and no Pro", described.preview.state === "ended" && !described.pro.active && described.app_user_id === created.app_user_id);
  check("installations cannot read operator diagnostics", (await fetch(`${base}/v1/copilot/diagnostics/decisions?session=x`, { headers: auth(created) })).status === 403);
  check("the operator token still works (development and evaluation)",
    (await answer({ authorization: "Bearer operator-token", "content-type": "application/json" })).status === 200);

  const event = await post("/v1/events", auth(created), { name: "paywall_viewed", trigger: "generate", text: "secret interview content" });
  check("an allowed event is accepted", event.status === 204);
  await delay(100);
  check("the event log line carries only enumerated values",
    server.output.includes("[event] name=paywall_viewed trigger=generate") && !server.output.includes("secret interview content") && !server.output.includes(created.installation_id));
  check("an unknown event is refused", (await post("/v1/events", auth(created), { name: "transcript_line" })).status === 400);

  // Restart: the credential and the counters must survive.
  await stop(server);
  server = startServer();
  await waitForHealth();
  check("after a restart the same credential still authenticates", (await fetch(`${base}/v1/access`, { headers: auth(created) })).status === 200);
  check("after a restart the used preview is still used", (await answer(auth(created))).status === 402);

  // Purchase: the server finds Pro for the id it issued, and nothing the client says changes that.
  proUsers.add(created.app_user_id);
  const afterPurchase = await (await fetch(`${base}/v1/access?refresh=1`, { headers: auth(created) })).json();
  check("after purchase /v1/access?refresh=1 reports Pro", afterPurchase.pro.active && afterPurchase.pro.verified);
  check("Pro answers are served beyond the preview", (await answer(auth(created))).status === 200);
  const stranger = await (await post("/v1/installations", {}, {})).json();
  check("a second installation is not Pro because another customer is", (await answer({ ...auth(stranger), "x-revenuecat-app-user-id": created.app_user_id })).status === 200
    && (await answer(auth(stranger))).status === 200 && (await answer(auth(stranger))).status === 402);
  proUsers.delete(created.app_user_id);
  check("when the entitlement lapses Pro stops", (await answer(auth(created))).status === 402);
} catch (error) {
  failures += 1;
  console.log(`  FAIL ${error.stack}\n${server.output}`);
} finally {
  await stop(server);
  revenueCat.close();
  rmSync(dir, { recursive: true, force: true });
}

console.log(failures ? `\n${failures} failure(s)` : "\nall access checks passed");
process.exit(failures ? 1 : 0);
