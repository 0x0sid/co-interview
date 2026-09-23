// Deterministic tests for the Jev decision layer (decisions.mjs, providers/typesafe.mjs).
//
// A local stub stands in for TypeSafe, speaking the documented System One shapes (verified against
// docs.typesafe.ai on 2026-09-24). **Nothing here is a Jev result**: the stub supplies the answers,
// so these tests prove request construction, mapping, queueing, staleness, fallback and isolation from
// the answer path — never decision quality.
//
// Run:  node test/decisions-test.mjs

import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";
import {
  decisionConfigFromEnv, decisionApiKey, validateAnswers, decide, publicDecisionConfig, snapshotFromClassifyBody, buildJevQuestions, buildJevState,
  interpretJev, baselineDecision, compareDecisions, DecisionRecorder, DecisionShadow, applyActiveDecision, logLine,
} from "../decisions.mjs";
import { evaluate, costUSD } from "../providers/typesafe.mjs";
import { score } from "../eval/decisions/metrics.mjs";
import { loadCases, runAnswerCompleteness } from "../eval/decisions/run-decision-eval.mjs";

let failures = 0;
function check(label, condition, detail = "") {
  if (condition) console.log(`  ok   ${label}`);
  else {
    failures += 1;
    console.log(`  FAIL ${label} ${detail}`);
  }
}

const jevAnswers = (overrides = {}) => ({
  role: { type: "choice", choice: "continuation", probabilities: { continuation: 0.9, new_request: 0.1 }, confidence: 0.86 },
  answer_need: { type: "choice", choice: "general", probabilities: { general: 0.95 }, confidence: 0.93 },
  transcription_ambiguity: { type: "noul", noul: 0.1 },
  parent: { type: "choice", choice: "q1", probabilities: { q1: 0.8, none: 0.2 }, confidence: 0.7 },
  ...overrides,
});

// --- Stub TypeSafe --------------------------------------------------------------------------------

const stub = { requests: [], mode: "ok", delayMs: 0, sequence: [] };
const typesafeStub = createServer(async (request, response) => {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  const body = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
  stub.requests.push({ url: request.url, auth: request.headers.authorization, body });
  const mode = stub.sequence.length ? stub.sequence.shift() : stub.mode;
  if (stub.delayMs) await delay(stub.delayMs);
  if (mode === "429") {
    response.writeHead(429, { "content-type": "application/json", "retry-after": "0" });
    return response.end(JSON.stringify({ error: { message: "slow down" } }));
  }
  if (mode === "401") {
    response.writeHead(401, { "content-type": "application/json" });
    return response.end(JSON.stringify({ detail: "bad key" }));
  }
  if (mode === "garbage") {
    response.writeHead(200, { "content-type": "application/json" });
    return response.end("not json");
  }
  if (["402", "404", "524"].includes(mode)) {
    response.writeHead(Number(mode), { "content-type": "application/json" });
    return response.end(JSON.stringify({ error: { code: Number(mode), message: "stub error" } }));
  }
  if (mode === "openrouter") {
    response.writeHead(200, { "content-type": "application/json" });
    return response.end(JSON.stringify({ id: "gen-dec-test", model: "typesafe/jev-1.13-20260917", provider: "TypeSafe", answers: jevAnswers(), usage: { input_tokens: 488, output_tokens: 60, cost: 0.0000205 } }));
  }
  if (mode === "badrole") {
    response.writeHead(200, { "content-type": "application/json" });
    return response.end(JSON.stringify({ model: "typesafe/jev-1.13-20260917", answers: jevAnswers({ role: { type: "choice", choice: "banana", probabilities: { banana: 1 }, confidence: 1 } }), usage: {} }));
  }
  if (mode === "filler") {
    response.writeHead(200, { "content-type": "application/json" });
    return response.end(JSON.stringify({ model: "stub-not-jev", answers: jevAnswers({ role: { type: "choice", choice: "filler", probabilities: { filler: 1 }, confidence: 1 } }), usage: { input_tokens: 500, output_tokens: 20 } }));
  }
  response.writeHead(200, { "content-type": "application/json" });
  response.end(JSON.stringify({ model: "jev-1.13.0", answers: jevAnswers(), usage: { input_tokens: 500, output_tokens: 20 } }));
});
await new Promise((resolve) => typesafeStub.listen(9921, "127.0.0.1", resolve));
const STUB = "http://127.0.0.1:9921";

// --- Stub detector provider (OpenAI Responses shape, as in contract-test) ------------------------

let detectorDelayMs = 0;
const upstreamBodies = [];
const detector = createServer(async (request, response) => {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  upstreamBodies.push(body);
  if (detectorDelayMs) await delay(detectorDelayMs);
  if (!body.stream) {
    response.writeHead(200, { "content-type": "application/json" });
    return response.end(JSON.stringify({ output_text: JSON.stringify({ kind: "new_question", is_question: true, question_text: "Compare Java 7, 8 and 9", related_question_id: "", confidence: 0.9, language: "en" }) }));
  }
  response.writeHead(200, { "content-type": "text/event-stream" });
  response.write(`data: ${JSON.stringify({ type: "response.output_text.delta", delta: "TITLE: t\nAn answer." })}\n\n`);
  response.write(`data: ${JSON.stringify({ type: "response.completed", response: { usage: { output_tokens: 3 } } })}\n\n`);
  response.end();
});
await new Promise((resolve) => detector.listen(9922, "127.0.0.1", resolve));

function startServer(port, env) {
  const logs = [];
  const child = spawn(process.execPath, ["server.mjs"], {
    cwd: new URL("..", import.meta.url).pathname,
    env: {
      ...process.env,
      COINTERVIEW_NO_ENV_FILE: "1", PORT: String(port), COINTERVIEW_TOKENS: "test-token",
      OPENAI_API_KEY: "test-key-not-real", OPENAI_BASE: "http://127.0.0.1:9922", COPILOT_TEXT_PROVIDER: "openai",
      COINTERVIEW_FAKE: "", COPILOT_DECISION_TRANSPORT: "typesafe", TYPESAFE_BASE: STUB, TYPESAFE_API_KEY: "", COPILOT_DECISION_MODE: "", COPILOT_DIAGNOSTICS: "",
      ...env,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout.on("data", (data) => logs.push(String(data)));
  child.stderr.on("data", (data) => process.stderr.write(data));
  return { child, logs };
}

const auth = { "content-type": "application/json", authorization: "Bearer test-token" };
const SECRET_SPEECH = "Compare Java 8 with the secret-marker-7731 release";
const classifyBody = (overrides = {}) => ({
  newSpeech: SECRET_SPEECH,
  recentConversation: ["Earlier line.", SECRET_SPEECH],
  knownQuestions: [{ id: "card-1", text: "Earlier question", answered: true }],
  language: "en",
  sessionID: "session-A",
  snapshotID: "snap-1",
  diagnosticsSessionID: "diag-A",
  utterances: [{ id: "u1", revision: 2, isFinal: true }],
  generationEpoch: 0,
  ...overrides,
});

try {
  console.log("configuration");
  {
    const off = decisionConfigFromEnv({});
    check("no key means off", off.mode === "off" && off.keyPresent === false);
    check("OpenRouter is the default transport", off.transport === "openrouter" && off.base === "https://openrouter.ai/api");
    const requested = decisionConfigFromEnv({ COPILOT_DECISION_MODE: "shadow" });
    check("shadow without a key stays off, and says why", requested.mode === "off" && /no OpenRouter key/.test(requested.modeReason));
    const withKey = decisionConfigFromEnv({ OPENROUTER_API_KEY: "k-123456789" });
    check("the existing OpenRouter key turns shadow on, no TypeSafe key needed", withKey.mode === "shadow" && decisionApiKey(withKey, { OPENROUTER_API_KEY: "k-123456789" }) === "k-123456789");
    check("a TypeSafe key alone does not enable the OpenRouter transport", decisionConfigFromEnv({ TYPESAFE_API_KEY: "t" }).mode === "off");
    check("the OpenRouter model is pinned to the dated snapshot", withKey.model === "typesafe/jev-1.13-20260917");
    check("the Decisions base follows a stubbed OpenRouter base", decisionConfigFromEnv({ OPENROUTER_BASE: "http://127.0.0.1:1/api/v1" }).base === "http://127.0.0.1:1/api");
    const direct = decisionConfigFromEnv({ COPILOT_DECISION_TRANSPORT: "typesafe", TYPESAFE_API_KEY: "t", OPENROUTER_API_KEY: "o" });
    check("TypeSafe direct uses its own key and model", direct.mode === "shadow" && decisionApiKey(direct, { TYPESAFE_API_KEY: "t", OPENROUTER_API_KEY: "o" }) === "t" && direct.model === "jev-1.13.0");
    check("nothing is active unless named", withKey.activeDecisions.length === 0);
    const active = decisionConfigFromEnv({ OPENROUTER_API_KEY: "k", COPILOT_DECISION_MODE: "active", COPILOT_DECISION_ACTIVE: "role,bogus" });
    check("active accepts only known decision types", active.activeDecisions.join() === "role");
    check("an unknown mode is refused, not guessed", decisionConfigFromEnv({ OPENROUTER_API_KEY: "k", COPILOT_DECISION_MODE: "yes" }).mode === "off");
    const view = JSON.stringify(publicDecisionConfig(decisionConfigFromEnv({ OPENROUTER_API_KEY: "k-secret-value-99" })));
    check("the public view never contains the key", !view.includes("k-secret-value-99") && !/api_key/i.test(view));
  }

  console.log("snapshot and questions");
  {
    const snapshot = snapshotFromClassifyBody({
      newSpeech: "And Java 7.",
      recentConversation: ["Could you compare Java 8.", "And Java 9.", "And Java 7."],
      knownQuestions: [{ id: "Q1", text: "Compare Java 8 and 9", answered: false }],
    });
    check("the newest speech is separated from what came before", snapshot.conversationBefore.join("|") === "Could you compare Java 8.|And Java 9.");
    check("an older app's body (no ids) still makes a snapshot", snapshot.sessionID === null && snapshot.utterances.length === 0);
    const { questions, parentKeys } = buildJevQuestions(snapshot);
    check("role, need, ambiguity and parent are asked", ["role", "answer_need", "transcription_ambiguity", "parent"].every((k) => questions[k]));
    check("parent options are the known questions plus none and unclear", Object.keys(questions.parent.criteria).join() === "q1,none,unclear" && parentKeys.q1 === "Q1");
    check("question types match the documented primitives", questions.role.type === "choice" && questions.transcription_ambiguity.type === "noul");
    check("choice option counts stay within the documented 255", Object.keys(questions.role.criteria).length <= 255);
    const noKnown = buildJevQuestions(snapshotFromClassifyBody({ newSpeech: "Hi there" }));
    check("with nothing to point at, the parent is not asked", !noKnown.questions.parent);
    const state = buildJevState(snapshot);
    check("the state names its parts", state.newest_speech === "And Java 7." && state.earlier_questions[0].key === "q1");
    const long = snapshotFromClassifyBody({ newSpeech: "x y z w", recentConversation: Array.from({ length: 30 }, (_, i) => `line ${i}`) });
    check("Jev sees a bounded window of the conversation", buildJevState(long).conversation_before.length === 12);

    // The prompt must not contain the evaluation's own held-out wording.
    const heldout = loadCases().filter((c) => c.split === "heldout");
    const prompt = JSON.stringify(buildJevQuestions(snapshotFromClassifyBody({ newSpeech: "x", knownQuestions: [] })).questions);
    const leaked = heldout.filter((c) => c.newSpeech.length > 12 && prompt.includes(c.newSpeech));
    check("no held-out case appears in the questions or criteria", leaked.length === 0, leaked.map((c) => c.id).join());
  }

  console.log("interpretation and comparison");
  {
    const decision = interpretJev(jevAnswers(), { q1: "card-1" });
    check("a parent key maps back to the real question id", decision.parent === "card-1");
    check("probabilities and confidence are kept", decision.roleConfidence === 0.86 && decision.roleProbabilities.continuation === 0.9);
    check("an unknown role choice is not accepted", interpretJev(jevAnswers({ role: { type: "choice", choice: "banana", confidence: 1 } }), {}).role === null);
    const baseline = baselineDecision({ kind: "continuation", related_question_id: "card-1", confidence: 0.8 }, { knownQuestions: [{ id: "card-1" }] });
    check("the detector's continuation maps to attach with its parent", baseline.role === "continuation" && baseline.parent === "card-1");
    check("a correction and a continuation agree once collapsed", compareDecisions(baseline, { ...decision, role: "correction" }).roleAgrees);
    check("filler and a new question disagree", !compareDecisions({ role: "new_request", parent: "none" }, { role: "filler", parent: "none" }).roleAgrees);
    check("cost uses the published input price", Math.abs(costUSD("jev-1.13.0", { input_tokens: 1_000_000 }) - 0.042) < 1e-12);
    check("cost is not invented for an unknown model", costUSD("stub-not-jev", { input_tokens: 10 }) === null);
  }

  console.log("adapter");
  {
    stub.requests.length = 0;
    const ok = await evaluate({ apiKey: "test-typesafe-key", base: STUB, model: "jev-1.13.0", state: { a: 1 }, questions: { role: { type: "choice", instructions: "x", criteria: { a: null } } } });
    const sent = stub.requests[0];
    check("calls POST /v1/systemone", sent.url === "/v1/systemone");
    check("sends the key as a bearer token", sent.auth === "Bearer test-typesafe-key");
    check("sends state, model and questions", sent.body.model === "jev-1.13.0" && sent.body.state.a === 1 && sent.body.questions.role);
    check("returns answers, the answering model and usage", ok.ok && ok.model === "jev-1.13.0" && ok.usage.input_tokens === 500);

    stub.requests.length = 0;
    stub.sequence = ["429"];
    const retried = await evaluate({ apiKey: "k", base: STUB, model: "m", state: "s", questions: {}, retryDelayMs: 10 });
    check("a 429 is retried once and then succeeds", retried.ok && retried.attempts === 2 && stub.requests.length === 2);

    stub.requests.length = 0;
    stub.sequence = ["401", "ok"];
    const refused = await evaluate({ apiKey: "k", base: STUB, model: "m", state: "s", questions: {} });
    check("a 401 is not retried", !refused.ok && refused.reason === "unauthorized" && stub.requests.length === 1);
    stub.sequence = [];

    stub.mode = "garbage";
    const garbage = await evaluate({ apiKey: "k", base: STUB, model: "m", state: "s", questions: {} });
    check("a non-JSON body is a failure, not a crash", !garbage.ok && garbage.reason === "invalid_response");
    stub.mode = "ok";

    stub.delayMs = 400;
    const slow = await evaluate({ apiKey: "k", base: STUB, model: "m", state: "s", questions: {}, timeoutMs: 150 });
    check("a slow call ends at its deadline", !slow.ok && slow.reason === "timeout" && slow.latencyMs < 350, `latency=${slow.latencyMs}`);
    stub.delayMs = 0;

    const down = await evaluate({ apiKey: "k", base: "http://127.0.0.1:9", model: "m", state: "s", questions: {}, timeoutMs: 500 });
    check("an unreachable service is a failure, not a throw", !down.ok && ["network", "timeout"].includes(down.reason));
  }

  console.log("OpenRouter transport and answer validation");
  {
    stub.requests.length = 0;
    stub.mode = "openrouter";
    const ok = await evaluate({ apiKey: "or-key", transport: "openrouter", base: `${STUB}/api`, model: "typesafe/jev-1.13-20260917", state: "s", questions: {} });
    const sent = stub.requests[0];
    check("calls POST /api/alpha/decisions", sent.url === "/api/alpha/decisions");
    check("sends the OpenRouter key as the bearer token", sent.auth === "Bearer or-key");
    check("records the generation id, serving provider and dated model", ok.generationID === "gen-dec-test" && ok.servingProvider === "TypeSafe" && ok.model === "typesafe/jev-1.13-20260917");
    check("reported usage.cost is used as the cost", costUSD(ok.model, ok.usage) === 0.0000205);
    for (const [mode, reason] of [["402", "payment_required"], ["404", "model_unavailable"], ["524", "timeout"]]) {
      stub.mode = mode;
      const failed = await evaluate({ apiKey: "k", transport: "openrouter", base: `${STUB}/api`, model: "m", state: "s", questions: {}, retryDelayMs: 5 });
      check(`HTTP ${mode} is an explicit ${reason} fallback`, !failed.ok && failed.reason === reason, JSON.stringify(failed));
    }
    stub.mode = "ok";

    const questions = buildJevQuestions(snapshotFromClassifyBody({ newSpeech: "And Go.", knownQuestions: [{ id: "c1", text: "Compare Rust and C" }] })).questions;
    check("well-formed answers pass validation", validateAnswers(questions, jevAnswers()).length === 0);
    const bad = validateAnswers(questions, jevAnswers({
      role: { type: "choice", choice: "banana", probabilities: { banana: 1 }, confidence: 1 },
      answer_need: { type: "noul", noul: 0.5 },
      transcription_ambiguity: { type: "noul", noul: 7 },
    }));
    check("an unoffered choice, a wrong type and an out-of-range noul are all caught", ["role", "answer_need", "transcription_ambiguity"].every((id) => bad.some((p) => p.startsWith(`${id}:`))), bad.join(" | "));
    const missing = validateAnswers(questions, { role: jevAnswers().role });
    check("a missing answer is caught", missing.some((p) => p.startsWith("parent: missing")));

    stub.mode = "badrole";
    const config = { ...decisionConfigFromEnv({ OPENROUTER_API_KEY: "k" }), base: `${STUB}/api` };
    const refused = await decide({ snapshot: snapshotFromClassifyBody({ newSpeech: "x y z" }), config, apiKey: "k", timeoutMs: 500 });
    check("an invalid role answer is an explicit invalid_response fallback", !refused.ok && refused.reason === "invalid_response" && /not an offered option/.test(refused.message));
    stub.mode = "ok";
  }

  console.log("shadow queue");
  {
    let inFlight = 0;
    let peak = 0;
    const gates = [];
    const slowEvaluate = async () => {
      inFlight += 1;
      peak = Math.max(peak, inFlight);
      await new Promise((resolve) => gates.push(resolve));
      inFlight -= 1;
      return { ok: true, model: "jev-1.13.0", answers: jevAnswers(), usage: { input_tokens: 10 }, attempts: 1, latencyMs: 5 };
    };
    const recorder = new DecisionRecorder();
    const config = { ...decisionConfigFromEnv({ OPENROUTER_API_KEY: "k" }), maxConcurrency: 1, maxQueuedSessions: 2 };
    const shadow = new DecisionShadow({ config, apiKey: "k", recorder, evaluate: slowEvaluate });
    const snap = (session, id, revision = 0, epoch = 0) => snapshotFromClassifyBody({
      newSpeech: "What is a monad", sessionID: session, snapshotID: id, diagnosticsSessionID: session,
      utterances: [{ id: `${session}-u1`, revision, isFinal: true }], generationEpoch: epoch,
    });
    const base = { role: "new_request", parent: "none", kind: "new_question", confidence: 0.9 };

    shadow.submit(snap("s1", "a"), base);
    shadow.submit(snap("s1", "b"), base);
    shadow.submit(snap("s1", "c"), base);
    const s2 = shadow.submit(snap("s2", "d"), base);
    const s3 = shadow.submit(snap("s3", "e"), base);
    check("a full queue drops rather than grows", s3.status === "dropped", s3.status);
    check("concurrency is bounded", peak === 1);
    const s1 = recorder.list("s1");
    check("a replaced waiting snapshot is recorded as obsolete", s1.find((r) => r.snapshot_id === "b")?.jev.status === "obsolete");
    check("the latest waiting snapshot is kept", s1.find((r) => r.snapshot_id === "c")?.jev.status === "queued");

    // A revision of the first snapshot's utterance arrives while it is still running.
    shadow.observe(snap("s1", "rev", 1));
    while (gates.length || shadow.running || shadow.waiting.size) {
      gates.splice(0).forEach((open) => open());
      await delay(5);
    }
    await shadow.idle();
    check("a result about revised speech is marked stale", recorder.list("s1").find((r) => r.snapshot_id === "a")?.stale === true);
    check("a current result is ok and compared", recorder.list("s2").find((r) => r.snapshot_id === "d")?.jev.status === "ok" && s2.status === "queued");

    const epochRecorder = new DecisionRecorder();
    let release;
    const epochShadow = new DecisionShadow({ config, apiKey: "k", recorder: epochRecorder, evaluate: async () => { await new Promise((r) => { release = r; }); return { ok: true, model: "jev-1.13.0", answers: jevAnswers(), usage: null, attempts: 1, latencyMs: 1 }; } });
    epochShadow.submit(snap("e1", "x", 0, 0), base);
    epochShadow.observe(snap("e1", "later", 0, 1));
    await delay(5);
    release();
    await epochShadow.idle();
    check("a result from before a generation is marked stale", epochRecorder.list("e1")[0].stale_reason === "a generation was accepted after the snapshot");

    const line = logLine(recorder.list("s2")[0]);
    check("the log line carries no conversation text", !line.includes("monad"));
  }

  console.log("active mode");
  {
    const config = { ...decisionConfigFromEnv({ OPENROUTER_API_KEY: "k", COPILOT_DECISION_MODE: "active", COPILOT_DECISION_ACTIVE: "role,parent" }) };
    const snapshot = snapshotFromClassifyBody({ newSpeech: "And Go.", knownQuestions: [{ id: "card-1", text: "Compare Rust and C" }] });
    const baselineResult = { kind: "new_question", is_question: true, question_text: "And Go.", related_question_id: "", confidence: 0.7 };
    const jev = { ok: true, decision: interpretJev(jevAnswers(), { q1: "card-1" }) };
    const applied = applyActiveDecision(baselineResult, snapshot, jev, config);
    check("a trusted, confident decision replaces the detector's", applied.result.kind === "continuation" && applied.result.related_question_id === "card-1" && applied.controlledBy === "jev:role+parent");
    const failed = applyActiveDecision(baselineResult, snapshot, { ok: false, reason: "timeout" }, config);
    check("a failed call falls back to the detector, with the reason", failed.result === baselineResult && failed.fallbackReason === "timeout");
    const unsure = { ok: true, decision: { ...jev.decision, roleConfidence: 0.2, parentConfidence: 0.2 } };
    check("an unsure decision falls back to the detector", applyActiveDecision(baselineResult, snapshot, unsure, config).controlledBy === "baseline");
  }

  console.log("server: shadow never delays the detector");
  {
    const { child, logs } = startServer(9923, { TYPESAFE_API_KEY: "test-typesafe-key", COPILOT_DECISION_MODE: "shadow" });
    await delay(600);
    try {
      const health = await (await fetch("http://127.0.0.1:9923/health")).json();
      check("health reports shadow mode without the key", health.decisions?.mode === "shadow" && !JSON.stringify(health).includes("test-typesafe-key"));

      stub.delayMs = 1200;
      stub.requests.length = 0;
      const started = Date.now();
      const response = await fetch("http://127.0.0.1:9923/v1/copilot/classify", { method: "POST", headers: auth, body: JSON.stringify(classifyBody()) });
      const payload = await response.json();
      const elapsed = Date.now() - started;
      check("the detector's verdict is returned unchanged", response.status === 200 && payload.kind === "new_question");
      check("the response does not wait for Jev", elapsed < 900, `elapsed=${elapsed}ms`);

      const pending = await (await fetch("http://127.0.0.1:9923/v1/copilot/diagnostics/decisions?session=diag-A", { headers: auth })).json();
      check("the record exists at once, queued", pending.records?.[0]?.jev.status === "queued");

      // Generate is a separate route and never touches the decision queue.
      const answerStarted = Date.now();
      const answer = await fetch("http://127.0.0.1:9923/v1/copilot/answer", { method: "POST", headers: auth, body: JSON.stringify({ question: "q", recentConversation: ["q"], newInput: ["q"], passages: [], language: "en", targetWordRange: [40, 80], projectID: "p" }) });
      await answer.text();
      check("an answer streams while a shadow call is in flight", answer.status === 200 && Date.now() - answerStarted < 900);

      await delay(1500);
      stub.delayMs = 0;
      const done = await (await fetch("http://127.0.0.1:9923/v1/copilot/diagnostics/decisions?session=diag-A", { headers: auth })).json();
      const record = done.records[0];
      check("the comparison completes afterwards", record.jev.status === "ok" && record.comparison && record.jev.role === "continuation");
      check("ids, revisions, model and config version are recorded", record.snapshot_id === "snap-1" && record.utterances[0].revision === 2 && record.jev.answered_model === "jev-1.13.0" && record.config_version);
      check("usage and published cost are recorded", record.jev.usage.input_tokens === 500 && record.jev.cost_usd > 0);
      check("the context boundary is recorded", record.context.conversation_lines_sent_to_jev === 1 && /unaffected/.test(record.context.answer_request));
      check("no conversation text without content capture", !JSON.stringify(done).includes("secret-marker-7731"));
      check("the backend log carries no conversation text", !logs.join("").includes("secret-marker-7731") && logs.join("").includes("[decision] shadow"));
      check("Jev received the newest speech as the thing to judge", stub.requests.at(-1).body.state.newest_speech === SECRET_SPEECH);

      const unauthorized = await fetch("http://127.0.0.1:9923/v1/copilot/diagnostics/decisions?session=diag-A");
      check("decision records need the client token", unauthorized.status === 401);
    } finally {
      child.kill();
      stub.delayMs = 0;
    }
  }

  console.log("server: content capture needs both switches");
  {
    const { child } = startServer(9924, { TYPESAFE_API_KEY: "test-typesafe-key", COPILOT_DECISION_MODE: "shadow", COPILOT_DIAGNOSTICS: "1" });
    await delay(600);
    try {
      await fetch("http://127.0.0.1:9924/v1/copilot/classify", { method: "POST", headers: auth, body: JSON.stringify(classifyBody({ diagnosticsSessionID: "diag-B", captureContent: true })) });
      await fetch("http://127.0.0.1:9924/v1/copilot/classify", { method: "POST", headers: auth, body: JSON.stringify(classifyBody({ diagnosticsSessionID: "diag-C", sessionID: "session-C" })) });
      await delay(300);
      const captured = await (await fetch("http://127.0.0.1:9924/v1/copilot/diagnostics/decisions?session=diag-B", { headers: auth })).json();
      const uncaptured = await (await fetch("http://127.0.0.1:9924/v1/copilot/diagnostics/decisions?session=diag-C", { headers: auth })).json();
      check("an opted-in request keeps its text", captured.records[0].content?.new_speech === SECRET_SPEECH);
      check("a request that did not opt in keeps none", !JSON.stringify(uncaptured).includes("secret-marker-7731"));
    } finally {
      child.kill();
    }
  }

  console.log("server: an unavailable decision service changes nothing");
  {
    const { child } = startServer(9925, { TYPESAFE_API_KEY: "test-typesafe-key", COPILOT_DECISION_MODE: "shadow", TYPESAFE_BASE: "http://127.0.0.1:9" });
    await delay(600);
    try {
      const response = await fetch("http://127.0.0.1:9925/v1/copilot/classify", { method: "POST", headers: auth, body: JSON.stringify(classifyBody({ diagnosticsSessionID: "diag-D" })) });
      check("classification still answers", response.status === 200 && (await response.json()).kind === "new_question");
      await delay(800);
      const records = await (await fetch("http://127.0.0.1:9925/v1/copilot/diagnostics/decisions?session=diag-D", { headers: auth })).json();
      check("the failure is recorded with its reason", records.records[0].jev.status === "failed" && records.records[0].jev.failure.reason);
    } finally {
      child.kill();
    }
  }

  console.log("server: off without a key");
  {
    const { child } = startServer(9926, {});
    await delay(600);
    try {
      const health = await (await fetch("http://127.0.0.1:9926/health")).json();
      check("health says off, and why", health.decisions.mode === "off" && health.decisions.key_configured === false);
      const response = await fetch("http://127.0.0.1:9926/v1/copilot/classify", { method: "POST", headers: auth, body: JSON.stringify(classifyBody()) });
      const payload = await response.json();
      check("classification is exactly as before", response.status === 200 && payload.kind === "new_question" && !("decision" in payload));
      const records = await fetch("http://127.0.0.1:9926/v1/copilot/diagnostics/decisions?session=diag-A", { headers: auth });
      check("no decision records exist", records.status === 404);
      check("no TypeSafe request was made", !stub.requests.some((r) => r.body?.state?.newest_speech === SECRET_SPEECH && r.auth === "Bearer "));
    } finally {
      child.kill();
    }
  }

  console.log("server: active mode falls back in time");
  {
    const { child } = startServer(9927, { TYPESAFE_API_KEY: "test-typesafe-key", COPILOT_DECISION_MODE: "active", COPILOT_DECISION_ACTIVE: "role", COPILOT_DECISION_ACTIVE_TIMEOUT_MS: "300" });
    await delay(600);
    try {
      stub.mode = "filler";
      const overridden = await (await fetch("http://127.0.0.1:9927/v1/copilot/classify", { method: "POST", headers: auth, body: JSON.stringify(classifyBody()) })).json();
      check("a trusted decision controls the verdict", overridden.kind === "none" && overridden.decision.controlled_by === "jev:role");
      stub.delayMs = 1000;
      const started = Date.now();
      const fallback = await (await fetch("http://127.0.0.1:9927/v1/copilot/classify", { method: "POST", headers: auth, body: JSON.stringify(classifyBody({ snapshotID: "snap-2" })) })).json();
      check("a late decision falls back to the detector within its deadline", fallback.kind === "new_question" && fallback.decision.controlled_by === "baseline" && Date.now() - started < 900);
    } finally {
      child.kill();
      stub.mode = "ok";
      stub.delayMs = 0;
    }
  }

  console.log("shadow changes nothing the app receives or the model is sent");
  {
    // Identical inputs through a server with decisions off and one in shadow: the classify responses
    // and the provider inputs must be byte-identical. Only then can shadow not move a question, a
    // coverage boundary, a snapshot or a page.
    const answerBody = {
      question: "q", passages: [], language: "en", targetWordRange: [40, 80], projectID: "p",
      recentConversation: ["Could you compare Java 8 and Java 9?", "No, we're not talking about Java anymore.", "What's new in Angular?"],
      newInput: ["No, we're not talking about Java anymore.", "What's new in Angular?"],
    };
    const outcome = {};
    for (const [mode, port] of [["off", 9928], ["shadow", 9929]]) {
      const { child } = startServer(port, { TYPESAFE_API_KEY: "test-typesafe-key", COPILOT_DECISION_MODE: mode });
      await delay(600);
      try {
        upstreamBodies.length = 0;
        const classify = await (await fetch(`http://127.0.0.1:${port}/v1/copilot/classify`, { method: "POST", headers: auth, body: JSON.stringify(classifyBody()) })).text();
        const answer = await (await fetch(`http://127.0.0.1:${port}/v1/copilot/answer`, { method: "POST", headers: auth, body: JSON.stringify(answerBody) })).text();
        outcome[mode] = { classify, answer, upstream: JSON.stringify(upstreamBodies) };
      } finally {
        child.kill();
      }
    }
    check("classify responses are byte-identical", outcome.off.classify === outcome.shadow.classify);
    check("answer streams are byte-identical", outcome.off.answer === outcome.shadow.answer);
    check("what the detector and answer model were sent is byte-identical", outcome.off.upstream === outcome.shadow.upstream);
    const sent = outcome.off.upstream;
    check("new input is numbered with the most recent marked", sent.includes("[1] No, we're not talking about Java anymore.") && sent.includes("[2, most recent] What's new in Angular?"));
  }

  console.log("a tapped action is the whole request");
  {
    const { child } = startServer(9930, {});
    await delay(600);
    try {
      upstreamBodies.length = 0;
      await (await fetch("http://127.0.0.1:9930/v1/copilot/answer", { method: "POST", headers: auth, body: JSON.stringify({
        question: "", newInput: [], passages: [], language: "en", targetWordRange: [40, 80], projectID: "p",
        recentConversation: ["Could you compare Java 8 and Java 9?", "How does routing work in Angular?"],
        requestedAction: "Give one concrete example of what you just explained.",
        actionParentQuestion: "Compare Java 8 and 9", actionParentAnswer: "Java 8 brought lambdas.", actionParentAnswerVersion: 1,
      }) })).text();
      const sent = JSON.stringify(upstreamBodies);
      check("TO ANSWER NOW says the action is the request, not the end of the conversation",
        sent.includes("this request is only the REQUESTED ACTION below") && !sent.includes("answer the end of CONVERSATION"));
    } finally {
      child.kill();
    }
  }

  console.log("answer requests are complete whatever the decision");
  {
    const results = await runAnswerCompleteness(loadCases());
    const incomplete = results.filter((r) => !r.complete);
    check(`all ${results.length} answer requests carry every required part`, incomplete.length === 0, JSON.stringify(incomplete));
    check("checked with decisions off and with a wrong shadow decision", new Set(results.map((r) => r.mode)).size === 2);
  }

  console.log("metrics");
  {
    const cases = [
      { id: "a", knownQuestions: [{ id: "Q1" }], expected: { role: "continuation", parent: "Q1", answerNeed: "general" } },
      { id: "b", knownQuestions: [], expected: { role: "filler", parent: "none", answerNeed: "nothing_asked" } },
      { id: "c", knownQuestions: [{ id: "Q1" }], expected: { role: "correction", parent: "Q1", answerNeed: "general" } },
      { id: "d", knownQuestions: [], expected: { role: "new_request", parent: "none", answerNeed: "general" } },
    ];
    const s = score(cases, {
      a: { ok: true, role: "new_request", parent: "none", latencyMs: 10 },
      b: { ok: true, role: "new_request", parent: "none", latencyMs: 20 },
      c: { ok: true, role: "continuation", parent: "Q1", latencyMs: 30 },
      d: { ok: false, reason: "timeout", timeout: true },
    });
    check("a new question where one should attach is a duplicate", s.duplicateEvents === 1);
    check("a question found in filler is incorrectly consumed", s.incorrectlyConsumed === 1);
    check("a failed call loses the request it was about", s.lostUtterances === 1 && s.fallbackRate === 0.25 && s.timeoutRate === 0.25);
    check("an attach to the right parent counts as a correct correction", s.correctionAccuracy === 1);
    check("precision and recall", s.questionPrecision === 2 / 3 && s.questionRecall === 2 / 3);
  }

  console.log("cases");
  {
    const cases = loadCases();
    const ids = new Set(cases.map((c) => c.id));
    check(`at least 60 cases (${cases.length})`, cases.length >= 60);
    check("ids are unique", ids.size === cases.length);
    check("English and French both present", cases.some((c) => c.language === "en") && cases.some((c) => c.language === "fr"));
    check("tuning and held-out are separate", cases.some((c) => c.split === "tune") && cases.filter((c) => c.split === "heldout").length >= 40);
    const required = ["fragmented", "multiple_questions", "correction", "filler", "partial_revision", "misheard_term", "topic_change", "repeated_wording", "older_page_followup", "speech_during_generation", "imperative"];
    const missing = required.filter((category) => !cases.some((c) => c.category === category && c.split === "heldout"));
    check("every required category has held-out cases", missing.length === 0, missing.join());
    const badParent = cases.filter((c) => [c.expected.parent].flat().some((p) => p !== "none" && p !== "unclear" && !c.knownQuestions.some((q) => q.id === p)));
    check("every expected parent is a real known question", badParent.length === 0, badParent.map((c) => c.id).join());
  }

  console.log(failures === 0 ? "\nAll decision checks passed." : `\n${failures} decision check(s) FAILED.`);
} finally {
  typesafeStub.close();
  detector.close();
}
process.exitCode = failures ? 1 : 0;
