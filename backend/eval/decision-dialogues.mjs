// Evaluates request-relationship decisions on whole dialogues captured from the app's real pipeline
// (prompterTests/…/DialogueCaptureTests): the decision snapshot the tracker would send at each tap,
// and the answer request the screen actually built.
//
//   A  corrected baseline, decisions off   — answers from the captured request as is
//   B  the earlier Jev strategy ("legacy") — decisions only; it never shaped a request
//   C  the focused strategy                — decisions, and answers with the accepted interpretation
//
// Usage:
//   node eval/decision-dialogues.mjs --captured <dir> --split dev|heldout|regression [--answers <answer backend url> --token <t>]
//        [--decisionRepeat 3] [--answerRepeat 2] [--relation 0.5 --parent 0.5] [--tune] [--out <dir>] [--label x]
//
// The decision calls go to Jev through OpenRouter with OPENROUTER_API_KEY (env or backend/.env).
// Nothing here tunes on held-out data: --tune is refused for that split.

import { readFileSync, readdirSync, writeFileSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import {
  decisionConfigFromEnv, decisionApiKey, focusedSnapshotFromBody, buildFocusedQuestions, buildFocusedState, combineFocused,
  snapshotFromClassifyBody, decide as legacyDecide,
} from "../decisions.mjs";
import { evaluate, costUSD } from "../providers/typesafe.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));

function args(argv) {
  const o = { captured: "", split: "heldout", answers: "", token: "", decisionRepeat: "3", answerRepeat: "2", relation: "", parent: "", withdraws: "", only: "", tune: false, out: "", label: "" };
  for (let i = 2; i < argv.length; i += 1) {
    const key = argv[i].replace(/^--/, "");
    if (key === "tune") { o.tune = true; continue; }
    if (key in o) { o[key] = argv[i + 1]; i += 1; }
  }
  return o;
}

function localEnv() {
  try {
    return Object.fromEntries(readFileSync(join(HERE, "..", ".env"), "utf8").split("\n")
      .map((l) => l.trim()).filter((l) => l && !l.startsWith("#") && l.includes("="))
      .map((l) => { const at = l.indexOf("="); return [l.slice(0, at).trim(), l.slice(at + 1).trim().replace(/^["']|["']$/g, "")]; }));
  } catch { return {}; }
}

const toRegex = (s) => { const m = /^\/(.*)\/([a-z]*)$/s.exec(s); return m ? new RegExp(m[1], m[2]) : new RegExp(s); };
const accepts = (expected, actual) => [expected].flat().includes(actual);
const pct = (n, d) => (d ? `${((100 * n) / d).toFixed(1)}% (${n}/${d})` : "—");
const quantile = (values, q) => { if (!values.length) return null; const s = [...values].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.ceil(q * s.length) - 1)]; };

/** Labels in dialogues name requests "req1", "req2"… in the order they were accepted. */
function labelOf(id, labels) { return id === "none" || id === "unclear" || id === null ? id : labels[id] ?? `?${id}`; }

// --- Decisions -------------------------------------------------------------------------------------

async function focusedDecision(snapshotBody, config, apiKey) {
  const snapshot = focusedSnapshotFromBody(snapshotBody);
  const { questions, parentKeys } = buildFocusedQuestions(snapshot);
  const result = await evaluate({ apiKey, transport: config.transport, base: config.base, model: config.model,
    state: buildFocusedState(snapshot), questions, timeoutMs: config.shadowTimeoutMs, maxAttempts: 1 });
  return { result, snapshot, parentKeys };
}

/** The earlier strategy, given the same speech — and, to be fair to it, requests' own words rather than titles. */
async function legacyDecision(snapshotBody, config, apiKey) {
  const body = {
    newSpeech: snapshotBody.newSpeech.map((u) => u.text).join(" "),
    recentConversation: [...snapshotBody.preceding, ...snapshotBody.newSpeech.map((u) => u.text)],
    knownQuestions: snapshotBody.candidates.map((c) => ({ id: c.id, text: c.sourceText, answered: c.status !== "pending" })),
    language: snapshotBody.language,
  };
  const outcome = await legacyDecide({ snapshot: snapshotFromClassifyBody(body), config, apiKey, timeoutMs: config.shadowTimeoutMs });
  if (!outcome.ok) return { ok: false, reason: outcome.reason, latencyMs: outcome.latencyMs };
  const role = { new_request: "new_request", continuation: "continuation", correction: "correction", answer_or_explanation: "non_request", filler: "non_request", unclear: "unclear" }[outcome.decision.role];
  return { ok: true, relation: role, parent: outcome.decision.parent, latencyMs: outcome.latencyMs, usage: outcome.usage, model: outcome.model };
}

// --- Answers ---------------------------------------------------------------------------------------

/** The dev backend token from the app's local config, so it never has to be typed or printed. */
function devToken() {
  try {
    const line = readFileSync(join(HERE, "..", "..", "prompter", "Config", "Local-Debug.xcconfig"), "utf8")
      .split("\n").find((l) => /^\s*COPILOT_DEV_BACKEND_TOKEN\s*=/.test(l));
    return line ? line.slice(line.indexOf("=") + 1).trim() : "";
  } catch { return ""; }
}

async function answer(body, { answers, token }) {
  token ||= devToken();
  const started = Date.now();
  const response = await fetch(`${answers}/v1/copilot/answer`, {
    method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ ...body, diagnosticsRequestID: randomUUID() }),
  });
  const events = (await response.text()).split("\n").filter((l) => l.startsWith("data:")).map((l) => JSON.parse(l.slice(5)));
  return { status: response.status, ms: Date.now() - started, title: events.find((e) => e.type === "title")?.text ?? "",
    text: events.filter((e) => e.type === "delta").map((e) => e.text).join("").trim() };
}

function judgeAnswer(expect, a) {
  if (!expect) return { met: true, failures: [] };
  const all = `${a.title}\n${a.text}`;
  const failures = [];
  for (const m of expect.must ?? []) if (!toRegex(m).test(all)) failures.push(`missing ${m}`);
  for (const m of expect.mustNot ?? []) if (toRegex(m).test(a.text) || toRegex(m).test(a.title)) failures.push(`has ${m}`);
  if (expect.firstMust) {
    const first = a.text.split(/(?<=[.!?])\s+/)[0] ?? "";
    if (!toRegex(expect.firstMust).test(first)) failures.push(`first sentence lacks ${expect.firstMust}`);
  }
  return { met: failures.length === 0, failures };
}

// --- Main ------------------------------------------------------------------------------------------

async function main() {
  const o = args(process.argv);
  if (o.tune && o.split === "heldout") throw new Error("refusing to tune on the held-out split");
  const env = { ...localEnv(), ...process.env, COPILOT_DECISION_MODE: "shadow" };
  const config = decisionConfigFromEnv(env);
  const apiKey = decisionApiKey(config, env);
  if (!apiKey) throw new Error(`no ${config.transport} key: decisions cannot be evaluated, and nothing will be reported as if they were`);
  const thresholds = { relation: Number(o.relation || 0.5), parent: Number(o.parent || 0.5), withdraws: Number(o.withdraws || 0.7) };

  const dir = join(o.captured, o.split);
  const dialogues = readdirSync(dir).filter((f) => f.endsWith(".json")).sort().map((f) => JSON.parse(readFileSync(join(dir, f), "utf8")))
    .filter((d) => !o.only || o.only.split(",").includes(d.id));
  const rows = [];
  for (const dialogue of dialogues) {
    for (const [index, tap] of dialogue.taps.entries()) {
      const row = { dialogue: dialogue.id, language: dialogue.language, index, kind: tap.kind, expect: tap.expect ?? null,
        newInput: tap.request.newInput, lostSpeech: null, focused: [], legacy: [], answersA: [], answersC: [] };
      if (tap.kind === "tap" && tap.decisionSnapshot) {
        // Speech is never lost or consumed by building the request: every new line is in it.
        const sent = [...tap.request.newInput];
        row.lostSpeech = tap.decisionSnapshot.newSpeech.map((u) => u.text).filter((t) => !sent.includes(t));
        for (let r = 0; r < Number(o.decisionRepeat); r += 1) {
          const { result, snapshot, parentKeys } = await focusedDecision(tap.decisionSnapshot, config, apiKey);
          const combined = result.ok ? combineFocused(result.answers, parentKeys, snapshot, thresholds) : null;
          row.focused.push({ ok: result.ok, reason: result.reason ?? null, latencyMs: result.latencyMs,
            cost: result.ok ? costUSD(result.model, result.usage) : null, model: result.model ?? null,
            relation: result.answers?.relation?.choice ?? null, relationConfidence: result.answers?.relation?.confidence ?? null,
            parent: result.ok ? labelOf(result.answers?.parent?.choice ? (parentKeys[result.answers.parent.choice] ?? result.answers.parent.choice) : "none", tap.candidateLabels) : null,
            parentConfidence: result.answers?.parent?.confidence ?? (snapshot.candidates.length ? null : 1),
            raw: result.answers ?? null, snapshot, parentKeys, labels: tap.candidateLabels, combined });
          const l = await legacyDecision(tap.decisionSnapshot, config, apiKey);
          row.legacy.push({ ...l, parent: l.ok ? labelOf(l.parent, tap.candidateLabels) : null });
        }
      }
      if (o.answers) {
        for (let r = 0; r < Number(o.answerRepeat); r += 1) {
          const a = await answer(tap.request, o);
          row.answersA.push({ ...a, ...judgeAnswer(tap.expect, a) });
          // C differs from A only when an accepted interpretation exists for that decision round.
          const decision = row.focused[r % Math.max(1, row.focused.length)];
          const interpretation = decision?.combined?.accepted ? decision.combined.interpretation : null;
          if (tap.kind === "tap" && interpretation) {
            const c = await answer({ ...tap.request, interpretation }, o);
            row.answersC.push({ ...c, ...judgeAnswer(tap.expect, c), interpretation });
          } else {
            row.answersC.push({ ...row.answersA.at(-1), interpretation: null, reusedA: true });
          }
        }
      }
      rows.push(row);
      process.stdout.write(".");
    }
  }
  process.stdout.write("\n");

  // --- Tuning (development data only) ------------------------------------------------------------
  const score = (t) => {
    let accepted = 0, right = 0, n = 0;
    for (const row of rows) for (const d of row.focused) {
      if (!d.ok || !row.expect) continue;
      n += 1;
      const c = combineFocused(d.raw, d.parentKeys, d.snapshot, t);
      if (!c.accepted) continue;
      accepted += 1;
      const parentLabel = labelOf(c.parent, d.labels);
      const wrongDirection = c.relation === "new_request" && c.interpretation.parentWords && typeof row.expect.withdrawn === "boolean" && c.interpretation.withdrawn !== row.expect.withdrawn;
      if (!wrongDirection && accepts(row.expect.relation, c.relation) && (c.relation === "new_request" && !c.interpretation.parentWords ? true : accepts(row.expect.parent, parentLabel))) right += 1;
    }
    return { accepted, right, n };
  };
  const grid = [];
  if (o.tune) {
    for (const relation of [0.35, 0.5, 0.65, 0.8]) for (const parent of [0.35, 0.5, 0.65, 0.8]) for (const withdraws of [0.6, 0.7, 0.8]) grid.push({ relation, parent, withdraws, ...score({ relation, parent, withdraws }) });
  }

  // --- Summary -----------------------------------------------------------------------------------
  const taps = rows.filter((r) => r.kind === "tap" && r.expect);
  const decisions = taps.flatMap((r) => r.focused.map((d) => ({ r, d })));
  const legacy = taps.flatMap((r) => r.legacy.map((d) => ({ r, d })));
  const ok = (list) => list.filter(({ d }) => d.ok);
  const relOK = (list) => ok(list).filter(({ r, d }) => accepts(r.expect.relation, d.relation)).length;
  const parOK = (list) => ok(list).filter(({ r, d }) => accepts(r.expect.parent, d.parent)).length;
  const withParent = (list) => ok(list).filter(({ r }) => [r.expect.parent].flat().some((p) => p !== "none"));
  const accepted = ok(decisions).filter(({ d }) => d.combined?.accepted);
  const acceptedRight = accepted.filter(({ r, d }) => accepts(r.expect.relation, d.combined.relation)
    && (d.combined.relation === "new_request" && !d.combined.interpretation.parentWords ? true : accepts(r.expect.parent, labelOf(d.combined.parent, d.labels))));
  const lat = (list) => ok(list).map(({ d }) => d.latencyMs);
  const ready = (gapMs) => decisions.filter(({ d }) => d.ok && d.latencyMs + 700 <= gapMs).length;
  const cost = ok(decisions).reduce((sum, { d }) => sum + (d.cost ?? 0), 0);
  const answerRows = rows.filter((r) => r.expect);
  const metA = answerRows.flatMap((r) => r.answersA).filter((a) => a.met).length;
  const metC = answerRows.flatMap((r) => r.answersC).filter((a) => a.met).length;
  const nAnswers = answerRows.flatMap((r) => r.answersA).length;
  const byClass = (cls, key) => answerRows.filter((r) => cls(r)).flatMap((r) => r[key]);
  const isSwitch = (r) => r.kind === "tap" && [r.expect.relation].flat().includes("new_request") && r.index > 0;
  const isAttach = (r) => r.kind === "tap" && [r.expect.relation].flat().every((x) => ["continuation", "correction"].includes(x));

  const summary = {
    split: o.split, label: o.label || null, thresholds, generatedAt: new Date().toISOString(),
    conversations: dialogues.length, taps: taps.length, chips: rows.filter((r) => r.kind === "chip").length,
    decisionRepeat: Number(o.decisionRepeat), answerRepeat: o.answers ? Number(o.answerRepeat) : 0,
    lostSpeechTaps: taps.filter((r) => r.lostSpeech?.length).map((r) => `${r.dialogue}#${r.index}`),
    focused: {
      calls: decisions.length, failed: decisions.length - ok(decisions).length,
      timeouts: decisions.filter(({ d }) => d.reason === "timeout").length,
      relationAccuracy: pct(relOK(decisions), ok(decisions).length),
      parentAccuracy: pct(parOK(decisions), ok(decisions).length),
      parentAccuracyWhereAParentExists: pct(parOK(withParent(decisions)), withParent(decisions).length),
      accepted: pct(accepted.length, ok(decisions).length), acceptedCorrect: pct(acceptedRight.length, accepted.length),
      latencyP50: quantile(lat(decisions), 0.5), latencyP95: quantile(lat(decisions), 0.95),
      readyAtTapIfTapComes1500msAfterSpeech: pct(ready(1500), decisions.length),
      readyAtTapIfTapComes3000msAfterSpeech: pct(ready(3000), decisions.length),
      costUSD: Number(cost.toFixed(6)),
    },
    legacy: {
      calls: legacy.length, failed: legacy.length - ok(legacy).length,
      relationAccuracy: pct(relOK(legacy), ok(legacy).length),
      parentAccuracy: pct(parOK(legacy), ok(legacy).length),
      parentAccuracyWhereAParentExists: pct(parOK(withParent(legacy)), withParent(legacy).length),
      latencyP50: quantile(lat(legacy), 0.5), latencyP95: quantile(lat(legacy), 0.95),
    },
    answers: o.answers ? {
      A_correctCurrentRequest: pct(metA, nAnswers), C_correctCurrentRequest: pct(metC, nAnswers),
      C_answersActuallyShapedByADecision: byClass(() => true, "answersC").filter((a) => a.interpretation).length,
      topicSwitchTaps: { A: pct(byClass(isSwitch, "answersA").filter((a) => a.met).length, byClass(isSwitch, "answersA").length), C: pct(byClass(isSwitch, "answersC").filter((a) => a.met).length, byClass(isSwitch, "answersC").length) },
      attachTaps: { A: pct(byClass(isAttach, "answersA").filter((a) => a.met).length, byClass(isAttach, "answersA").length), C: pct(byClass(isAttach, "answersC").filter((a) => a.met).length, byClass(isAttach, "answersC").length) },
      chips: pct(byClass((r) => r.kind === "chip", "answersA").filter((a) => a.met).length, byClass((r) => r.kind === "chip", "answersA").length),
      firstSentenceRelevantTaps: pct(answerRows.filter((r) => r.expect.firstMust).flatMap((r) => r.answersC).filter((a) => !a.failures.some((f) => f.startsWith("first"))).length, answerRows.filter((r) => r.expect.firstMust).flatMap((r) => r.answersC).length),
    } : null,
    tuning: grid.length ? grid.sort((a, b) => b.right / Math.max(1, b.accepted) - a.right / Math.max(1, a.accepted) || b.accepted - a.accepted) : null,
  };
  console.log(JSON.stringify(summary, (k, v) => (k === "tuning" && v ? v.slice(0, 12) : v), 2));
  if (o.out) {
    mkdirSync(o.out, { recursive: true });
    const name = `dialogues-${o.split}${o.label ? `-${o.label}` : ""}`;
    writeFileSync(join(o.out, `${name}.json`), JSON.stringify({ summary, rows: rows.map((r) => ({ ...r, focused: r.focused.map(({ snapshot, parentKeys, raw, ...rest }) => rest) })) }, null, 1));
  }
}

await main();
