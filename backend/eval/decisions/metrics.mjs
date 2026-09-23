// Scoring for decision replay cases. Pure functions: the same code scores the existing detector and
// Jev, from predictions in one shared vocabulary (decisions.mjs).

import { collapsedRole } from "../../decisions.mjs";

const accepts = (expected, actual) => (Array.isArray(expected) ? expected.includes(actual) : expected === actual);
const acceptedList = (expected) => (Array.isArray(expected) ? expected : [expected]);

/** True when every acceptable label for this case falls in the given collapsed class. */
const expectsCollapsed = (expected, cls) => acceptedList(expected).some((role) => collapsedRole(role) === cls);
const requestBearing = (expected) => acceptedList(expected).every((role) => ["new", "attach"].includes(collapsedRole(role)));

function percentile(values, p) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return sorted[Math.max(0, index)];
}

const ratio = (numerator, denominator) => (denominator ? numerator / denominator : null);

/**
 * @param cases       the labelled cases
 * @param predictions map id → { ok, role, parent, answerNeed?, ambiguity?, latencyMs, fallback?, timeout?, costUSD? }
 *                    `ok: false` is a failed call; it is counted, and scored as the caller's
 *                    fallback would behave — **no decision**, which is what an unavailable provider gives.
 */
export function score(cases, predictions, { fineRoles = true } = {}) {
  const m = {
    cases: cases.length, scored: 0, failed: 0, timeouts: 0,
    question: { tp: 0, fp: 0, fn: 0 },
    roleCollapsedCorrect: 0,
    roleFineCorrect: 0, roleFineScored: 0,
    parentCorrect: 0, parentScored: 0,
    correctionCorrect: 0, correctionScored: 0,
    answerNeedCorrect: 0, answerNeedScored: 0,
    ambiguityCorrect: 0, ambiguityScored: 0,
    lostUtterances: 0, incorrectlyConsumed: 0, duplicateEvents: 0,
    latencies: [], costUSD: 0, costKnown: 0,
    perCase: [],
  };

  for (const testCase of cases) {
    const p = predictions[testCase.id];
    const e = testCase.expected;
    const row = { id: testCase.id, category: testCase.category, language: testCase.language, expected: e };
    if (!p || !p.ok) {
      m.failed += 1;
      if (p?.timeout) m.timeouts += 1;
      // With no decision the speech is neither turned into a question nor attached: a request-bearing
      // case is therefore lost, exactly as it would be live.
      if (requestBearing(e.role)) { m.question.fn += 1; m.lostUtterances += 1; }
      row.failed = p?.reason ?? "no prediction";
      m.perCase.push(row);
      continue;
    }
    m.scored += 1;
    if (typeof p.latencyMs === "number") m.latencies.push(p.latencyMs);
    if (typeof p.costUSD === "number") { m.costUSD += p.costUSD; m.costKnown += 1; }

    const predicted = collapsedRole(p.role);
    const expectedClasses = acceptedList(e.role).map(collapsedRole);
    const collapsedOK = expectedClasses.includes(predicted);
    if (collapsedOK) m.roleCollapsedCorrect += 1;

    // Question detection: "is there something to answer here" — a new request or an attachment.
    const predictedQuestion = predicted === "new" || predicted === "attach";
    const expectedQuestion = requestBearing(e.role);
    const expectedNoQuestion = acceptedList(e.role).every((role) => collapsedRole(role) === "no_request");
    if (predictedQuestion && expectedQuestion) m.question.tp += 1;
    if (predictedQuestion && expectedNoQuestion) m.question.fp += 1;
    if (!predictedQuestion && expectedQuestion) m.question.fn += 1;

    // What the live pipeline would do wrong.
    if (expectedQuestion && predicted === "no_request") m.lostUtterances += 1;
    if (expectedNoQuestion && predictedQuestion) m.incorrectlyConsumed += 1;
    if (acceptedList(e.role).every((role) => collapsedRole(role) === "attach") && predicted === "new") m.duplicateEvents += 1;

    if (fineRoles) {
      m.roleFineScored += 1;
      if (accepts(e.role, p.role)) m.roleFineCorrect += 1;
    }

    // Parent: scored where the case attaches to an earlier question, and for the known-question cases
    // where it must not.
    if (e.parent !== undefined && testCase.knownQuestions.length) {
      m.parentScored += 1;
      if (accepts(e.parent, p.parent)) m.parentCorrect += 1;
    }

    if (acceptedList(e.role).includes("correction")) {
      m.correctionScored += 1;
      // The detector cannot say "correction"; attaching to the right question is the most it can do,
      // and that is what the live pipeline needs. Both are held to the same test.
      if (predicted === "attach" && accepts(e.parent, p.parent)) m.correctionCorrect += 1;
    }

    if (e.answerNeed !== null && e.answerNeed !== undefined && p.answerNeed !== undefined) {
      m.answerNeedScored += 1;
      if (accepts(e.answerNeed, p.answerNeed)) m.answerNeedCorrect += 1;
    }
    if (typeof e.ambiguous === "boolean" && typeof p.ambiguity === "number") {
      m.ambiguityScored += 1;
      if ((p.ambiguity >= 0.5) === e.ambiguous) m.ambiguityCorrect += 1;
    }

    Object.assign(row, { predicted: { role: p.role, parent: p.parent, answerNeed: p.answerNeed ?? null, ambiguity: p.ambiguity ?? null, confidence: p.confidence ?? null }, collapsedOK });
    m.perCase.push(row);
  }

  const q = m.question;
  return {
    cases: m.cases,
    scored: m.scored,
    failed: m.failed,
    fallbackRate: ratio(m.failed, m.cases),
    timeoutRate: ratio(m.timeouts, m.cases),
    questionPrecision: ratio(q.tp, q.tp + q.fp),
    questionRecall: ratio(q.tp, q.tp + q.fn),
    roleAccuracyCollapsed: ratio(m.roleCollapsedCorrect, m.scored),
    roleAccuracyFine: fineRoles ? ratio(m.roleFineCorrect, m.roleFineScored) : null,
    parentAccuracy: ratio(m.parentCorrect, m.parentScored),
    parentScored: m.parentScored,
    correctionAccuracy: ratio(m.correctionCorrect, m.correctionScored),
    correctionScored: m.correctionScored,
    answerNeedAccuracy: ratio(m.answerNeedCorrect, m.answerNeedScored),
    answerNeedScored: m.answerNeedScored,
    ambiguityAccuracy: ratio(m.ambiguityCorrect, m.ambiguityScored),
    ambiguityScored: m.ambiguityScored,
    lostUtterances: m.lostUtterances,
    incorrectlyConsumed: m.incorrectlyConsumed,
    duplicateEvents: m.duplicateEvents,
    latencyMedianMs: percentile(m.latencies, 50),
    latencyP95Ms: percentile(m.latencies, 95),
    costUSD: m.costKnown ? m.costUSD : null,
    perCase: m.perCase,
  };
}

export { expectsCollapsed };
