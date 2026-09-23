// Replays labelled conversation snapshots through the existing detector and Jev, on identical input,
// and checks that complete answer requests survive whatever the decision says.
//
// Usage:
//   node eval/decisions/run-decision-eval.mjs [--split heldout|tune|all] [--providers baseline,jev,answers]
//        [--base http://127.0.0.1:8787 --token <client token>]   # a running backend, for the baseline
//        [--out docs/evidence/decisions]
//
// - baseline: POST /v1/copilot/classify on the given backend — the real detector, real provider.
// - jev:      Jev through the configured transport (OpenRouter's Decisions API by default, with
//             OPENROUTER_API_KEY from the environment or backend/.env). **Without a key this step
//             reports NOT RUN.** It never substitutes a stub and never reports a stub as Jev.
// - answers:  deterministic. Starts this backend against a local stub provider and asserts that the
//             assembled answer prompt contains every required part of each case's request, with
//             decisions off and with a deliberately wrong shadow decision in play.
//
// No dependencies. Node 22+.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";
import { score } from "./metrics.mjs";
import { baselineDecision, decide, decisionApiKey, decisionConfigFromEnv, snapshotFromClassifyBody, DECISION_CONFIG_VERSION } from "../../decisions.mjs";
import { costUSD } from "../../providers/typesafe.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const BACKEND = join(HERE, "..", "..");

/** backend/.env, read the same way the server reads it: names only, the real environment wins. */
function localEnv() {
  try {
    const entries = readFileSync(join(BACKEND, ".env"), "utf8").split("\n")
      .map((line) => line.trim()).filter((line) => line && !line.startsWith("#") && line.includes("="))
      .map((line) => { const at = line.indexOf("="); return [line.slice(0, at).trim(), line.slice(at + 1).trim().replace(/^["']|["']$/g, "")]; });
    return Object.fromEntries(entries);
  } catch {
    return {};
  }
}

export function loadCases() {
  const suite = JSON.parse(readFileSync(join(HERE, "cases.json"), "utf8"));
  return suite.cases;
}

/** The request body the app sends to /v1/copilot/classify for this case. */
export function classifyBody(testCase) {
  return {
    newSpeech: testCase.newSpeech,
    recentConversation: testCase.recentConversation,
    activeAnswerText: testCase.activeAnswerText ?? null,
    knownQuestions: testCase.knownQuestions,
    language: testCase.language,
    sessionID: `eval-${testCase.id}`,
    snapshotID: `eval-${testCase.id}`,
  };
}

/** The request body the app sends to /v1/copilot/answer for this case's Generate tap. */
export function answerBody(testCase) {
  const r = testCase.answerRequest;
  return {
    question: r.newInput.join(" "),
    recentConversation: [...r.background, ...r.newInput],
    newInput: r.newInput,
    priorSuggestions: [],
    projectInstructions: "",
    passages: [],
    language: testCase.language,
    targetWordRange: [40, 100],
    projectID: "eval",
  };
}

function parseArguments(argv) {
  const options = { split: "heldout", providers: "baseline,jev,answers", base: "", token: "", out: "" };
  for (let index = 2; index < argv.length; index += 2) {
    const key = argv[index].replace(/^--/, "");
    if (key in options) options[key] = argv[index + 1];
  }
  return options;
}

async function runBaseline(cases, { base, token }) {
  const predictions = {};
  for (const testCase of cases) {
    const started = Date.now();
    try {
      const response = await fetch(`${base}/v1/copilot/classify`, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
        body: JSON.stringify(classifyBody(testCase)),
        signal: AbortSignal.timeout(20000),
      });
      const payload = await response.json();
      if (!response.ok) {
        predictions[testCase.id] = { ok: false, reason: `HTTP ${response.status} ${payload.error ?? ""}`.trim(), latencyMs: Date.now() - started };
        continue;
      }
      const decision = baselineDecision(payload, snapshotFromClassifyBody(classifyBody(testCase)));
      predictions[testCase.id] = {
        ok: true, role: decision.role, parent: decision.parent, confidence: decision.confidence,
        latencyMs: Date.now() - started, model: payload.route?.resolved_model ?? payload.route?.requested_model ?? null,
      };
    } catch (error) {
      predictions[testCase.id] = { ok: false, reason: String(error.message ?? error), timeout: error.name === "TimeoutError", latencyMs: Date.now() - started };
    }
  }
  return predictions;
}

async function runJev(cases, config, apiKey) {
  const predictions = {};
  let answeredModel = null;
  for (const testCase of cases) {
    const snapshot = snapshotFromClassifyBody(classifyBody(testCase));
    const outcome = await decide({ snapshot, config, apiKey, timeoutMs: config.shadowTimeoutMs });
    if (!outcome.ok) {
      predictions[testCase.id] = { ok: false, reason: outcome.reason, timeout: outcome.reason === "timeout", latencyMs: outcome.latencyMs };
      continue;
    }
    answeredModel = outcome.model ?? answeredModel;
    const d = outcome.decision;
    predictions[testCase.id] = {
      ok: true, role: d.role, parent: d.parent, answerNeed: d.answerNeed, ambiguity: d.transcriptionAmbiguity,
      confidence: d.roleConfidence, latencyMs: outcome.latencyMs, costUSD: costUSD(outcome.model, outcome.usage),
      usage: outcome.usage,
    };
  }
  return { predictions, answeredModel };
}

/**
 * Starts this backend against a stub provider (and, for the second pass, a stub TypeSafe that always
 * answers "filler, no parent" — the most destructive decision there is) and checks every required
 * part of each answer request reaches the provider.
 */
export async function runAnswerCompleteness(cases, { port = 9941, upstreamPort = 9940, typesafePort = 9942 } = {}) {
  const captured = [];
  const upstream = createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    if (!body.stream) {
      response.writeHead(200, { "content-type": "application/json" });
      return response.end(JSON.stringify({ output_text: JSON.stringify({ kind: "new_question", is_question: true, question_text: "x", related_question_id: "", confidence: 0.9, language: "en" }) }));
    }
    captured.push(JSON.stringify(body.input));
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.write(`data: ${JSON.stringify({ type: "response.output_text.delta", delta: "TITLE: t\nAn answer." })}\n\n`);
    response.write(`data: ${JSON.stringify({ type: "response.completed", response: { usage: { output_tokens: 3 } } })}\n\n`);
    response.end();
  });
  const typesafeStub = createServer(async (request, response) => {
    for await (const _ of request) { /* drain */ }
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({
      model: "stub-not-jev",
      answers: {
        role: { type: "choice", choice: "filler", probabilities: { filler: 1 }, confidence: 1 },
        parent: { type: "choice", choice: "none", probabilities: { none: 1 }, confidence: 1 },
        answer_need: { type: "choice", choice: "nothing_asked", probabilities: { nothing_asked: 1 }, confidence: 1 },
        transcription_ambiguity: { type: "noul", noul: 0 },
      },
      usage: { input_tokens: 1, output_tokens: 0 },
    }));
  });
  await new Promise((resolve) => upstream.listen(upstreamPort, "127.0.0.1", resolve));
  await new Promise((resolve) => typesafeStub.listen(typesafePort, "127.0.0.1", resolve));

  const results = [];
  try {
    for (const mode of ["off", "shadow"]) {
      const server = spawn(process.execPath, ["server.mjs"], {
        cwd: BACKEND,
        env: {
          ...process.env,
          COINTERVIEW_NO_ENV_FILE: "1", PORT: String(port), COINTERVIEW_TOKENS: "eval-token",
          OPENAI_API_KEY: "stub-key-not-real", OPENAI_BASE: `http://127.0.0.1:${upstreamPort}`,
          COPILOT_TEXT_PROVIDER: "openai", COINTERVIEW_FAKE: "",
          COPILOT_DECISION_TRANSPORT: "typesafe",
          TYPESAFE_API_KEY: mode === "off" ? "" : "stub-key-not-real", TYPESAFE_BASE: `http://127.0.0.1:${typesafePort}`,
          COPILOT_DECISION_MODE: mode === "off" ? "" : "shadow",
        },
        stdio: ["ignore", "ignore", "pipe"],
      });
      server.stderr.on("data", (data) => process.stderr.write(data));
      await delay(500);
      try {
        for (const testCase of cases.filter((c) => c.answerRequest)) {
          const headers = { "content-type": "application/json", authorization: "Bearer eval-token" };
          // The classification happens first, so a (wrong) shadow decision exists before the answer.
          await fetch(`http://127.0.0.1:${port}/v1/copilot/classify`, { method: "POST", headers, body: JSON.stringify(classifyBody(testCase)) });
          captured.length = 0;
          const response = await fetch(`http://127.0.0.1:${port}/v1/copilot/answer`, { method: "POST", headers, body: JSON.stringify(answerBody(testCase)) });
          await response.text();
          const sent = captured.join("\n");
          const missing = testCase.answerRequest.mustInclude.filter((part) => !sent.includes(part) && !sent.includes(JSON.stringify(part).slice(1, -1)));
          results.push({ id: testCase.id, mode, complete: missing.length === 0, missing });
        }
      } finally {
        server.kill();
        await delay(100);
      }
    }
  } finally {
    upstream.close();
    typesafeStub.close();
  }
  return results;
}

const fmt = (value, digits = 2) => (value === null || value === undefined ? "—" : typeof value === "number" ? value.toFixed(digits) : String(value));
const pct = (value) => (value === null || value === undefined ? "—" : `${(value * 100).toFixed(1)}%`);

function markdown({ split, cases, baseline, jev, jevStatus, answers, generatedAt, config }) {
  const rows = [
    ["Cases scored / total", (s) => `${s.scored} / ${s.cases}`],
    ["Question precision", (s) => pct(s.questionPrecision)],
    ["Question recall", (s) => pct(s.questionRecall)],
    ["Role accuracy (collapsed: new / attach / no request / unclear)", (s) => pct(s.roleAccuracyCollapsed)],
    ["Role accuracy (six roles)", (s) => (s.roleAccuracyFine === null ? "cannot express" : pct(s.roleAccuracyFine))],
    ["Parent / grouping accuracy", (s) => `${pct(s.parentAccuracy)} (n=${s.parentScored})`],
    ["Correction and narrowing accuracy", (s) => `${pct(s.correctionAccuracy)} (n=${s.correctionScored})`],
    ["Answer-need accuracy", (s) => (s.answerNeedScored ? `${pct(s.answerNeedAccuracy)} (n=${s.answerNeedScored})` : "not produced")],
    ["Transcription-ambiguity accuracy", (s) => (s.ambiguityScored ? `${pct(s.ambiguityAccuracy)} (n=${s.ambiguityScored})` : "not produced")],
    ["Lost utterances", (s) => String(s.lostUtterances)],
    ["Incorrectly consumed utterances", (s) => String(s.incorrectlyConsumed)],
    ["Duplicate question events", (s) => String(s.duplicateEvents)],
    ["Fallback rate (failed calls)", (s) => pct(s.fallbackRate)],
    ["Timeout rate", (s) => pct(s.timeoutRate)],
    ["Decision latency, median", (s) => `${fmt(s.latencyMedianMs, 0)} ms`],
    ["Decision latency, p95", (s) => `${fmt(s.latencyP95Ms, 0)} ms`],
    ["Inference cost (reported usage × published price)", (s) => (s.costUSD === null ? "not reported" : `$${s.costUSD.toFixed(6)}`)],
  ];
  const out = [
    `# Decision evaluation — ${split} split`,
    "",
    `Generated ${generatedAt}. ${cases.length} cases. Decision config ${config}.`,
    "",
    `**Jev: ${jevStatus}**`,
    "",
    "| Metric | Existing detector | Jev |",
    "| --- | --- | --- |",
    ...rows.map(([label, f]) => `| ${label} | ${baseline ? f(baseline) : "not run"} | ${jev ? f(jev) : "not run"} |`),
    "",
    "Latency for the detector is measured at the client, round trip through the backend; for Jev, the adapter's own call time.",
    "Confidence values are recorded per case in the JSON. They are **not** calibrated accuracies and no threshold is derived from them here.",
    "",
    "## Complete answer requests",
    "",
    "| Case | Decisions off | Shadow with a deliberately wrong decision |",
    "| --- | --- | --- |",
  ];
  const byCase = {};
  for (const r of answers ?? []) (byCase[r.id] ??= {})[r.mode] = r;
  for (const [id, modes] of Object.entries(byCase)) {
    const cell = (r) => (!r ? "—" : r.complete ? "complete" : `missing ${r.missing.join(", ")}`);
    out.push(`| ${id} | ${cell(modes.off)} | ${cell(modes.shadow)} |`);
  }
  return out.join("\n") + "\n";
}

async function main() {
  const options = parseArguments(process.argv);
  const all = loadCases();
  const cases = options.split === "all" ? all : all.filter((c) => c.split === options.split);
  const providers = new Set(options.providers.split(","));
  const generatedAt = new Date().toISOString();

  let baseline = null;
  let baselinePredictions = null;
  if (providers.has("baseline")) {
    if (!options.base || !options.token) {
      console.log("baseline: NOT RUN — pass --base and --token for a running backend");
    } else {
      baselinePredictions = await runBaseline(cases, options);
      baseline = score(cases, baselinePredictions, { fineRoles: false });
      console.log(`baseline: ${baseline.scored}/${baseline.cases} scored`);
    }
  }

  let jev = null;
  let jevPredictions = null;
  let jevStatus = "not requested";
  if (providers.has("jev")) {
    const env = { ...localEnv(), ...process.env, COPILOT_DECISION_MODE: "shadow" };
    const config = decisionConfigFromEnv(env);
    const apiKey = decisionApiKey(config, env);
    if (!apiKey) {
      jevStatus = `NOT RUN — no ${config.transport} key is configured. No Jev result in this report is real, because there is none.`;
    } else {
      const run = await runJev(cases, config, apiKey);
      jevPredictions = run.predictions;
      jev = score(cases, jevPredictions);
      jevStatus = `real calls via ${config.transport} to ${config.model}${run.answeredModel ? ` (answered by ${run.answeredModel})` : ""}`;
    }
    console.log(`jev: ${jevStatus}`);
  }

  let answers = null;
  if (providers.has("answers")) {
    answers = await runAnswerCompleteness(cases);
    const incomplete = answers.filter((r) => !r.complete);
    console.log(`answers: ${answers.length - incomplete.length}/${answers.length} complete${incomplete.length ? ` — INCOMPLETE: ${incomplete.map((r) => `${r.id}/${r.mode}`).join(", ")}` : ""}`);
  }

  const report = { generatedAt, split: options.split, configVersion: DECISION_CONFIG_VERSION, jevStatus, baseline, jev, answers, baselinePredictions, jevPredictions };
  if (options.out) {
    mkdirSync(options.out, { recursive: true });
    writeFileSync(join(options.out, `decision-eval-${options.split}.json`), JSON.stringify(report, null, 2));
    writeFileSync(join(options.out, `decision-eval-${options.split}.md`), markdown({ split: options.split, cases, baseline, jev, jevStatus, answers, generatedAt, config: DECISION_CONFIG_VERSION }));
    console.log(`written to ${options.out}`);
  } else {
    console.log(markdown({ split: options.split, cases, baseline, jev, jevStatus, answers, generatedAt, config: DECISION_CONFIG_VERSION }));
  }
  if (answers?.some((r) => !r.complete)) process.exitCode = 1;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  await main();
}
