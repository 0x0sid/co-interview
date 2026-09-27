// Interview score: an explicit, Pro-only AI score of a frozen transcript snapshot.
//
// Owner decision (2026-09-27): **a score, not a report.** No summary, topics, key points, practice
// questions or coaching prose are generated. Principles, enforced here rather than trusted to the model:
// - **Only the candidate's own words are scored.** The app sends which lines the candidate marked as
//   theirs; nothing else — including suggested answers the app showed — is judged.
// - **A score only when the evidence supports it**, on a transparent 0–4 rubric (relevance, clarity,
//   structure, supporting examples). Too little marked speech → no score, and no model call.
// - **Each criterion carries a short quote** from the candidate's marked lines; a quote not found there
//   is dropped, so the evidence shown is always real.
// - It is AI coaching feedback, not a hiring prediction, and nothing is inferred about voice,
//   confidence or body language from text.

export const REVIEW_VERSION = "score-2026-09-27.1";

/** Below this, the candidate's marked speech is too little to score. */
export const MIN_SCORED_LINES = 3;
export const MIN_SCORED_WORDS = 60;

export const CRITERIA = ["relevance", "clarity", "structure", "examples"];

const criterionObject = (itemType) => ({
  type: "object",
  properties: Object.fromEntries(CRITERIA.map((name) => [name, { type: itemType }])),
  required: CRITERIA,
  additionalProperties: false,
});

export const REVIEW_SCHEMA = {
  type: "object",
  properties: { scores: criterionObject("integer"), evidence: criterionObject("string") },
  required: ["scores", "evidence"],
  additionalProperties: false,
};

const clip = (value, max) => (typeof value === "string" ? value.slice(0, max) : "");
const normalize = (text) => text.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();

/** Validates and bounds the app's request. Returns `{ lines, language, title }` or throws a 400. */
export function reviewInput(body) {
  const raw = Array.isArray(body?.lines) ? body.lines.slice(0, 600) : [];
  const lines = raw
    .map((line) => ({ text: clip(line?.text, 800).trim(), candidate: line?.candidate === true }))
    .filter((line) => line.text);
  if (!lines.length) throw Object.assign(new Error("the transcript is empty"), { statusCode: 400 });
  return { lines, language: clip(body?.language, 16) || "en", title: clip(body?.title, 120) };
}

/** Whether the candidate's marked lines are enough to score. */
export function scorable(lines) {
  const mine = lines.filter((line) => line.candidate);
  const words = mine.reduce((n, line) => n + line.text.split(/\s+/).filter(Boolean).length, 0);
  return mine.length >= MIN_SCORED_LINES && words >= MIN_SCORED_WORDS;
}

export function buildReviewMessages({ lines, language, title }) {
  const transcript = lines.map((line, n) => `${n + 1}. ${line.candidate ? "[CANDIDATE] " : "[OTHER] "}${line.text}`).join("\n");
  const system = [
    "You score a candidate's interview answers from a transcript. You return scores and short quotes only — no summary, no advice.",
    `Write every quote exactly as it appears in the transcript (language ${language}); never translate it.`,
    "It is AI coaching feedback, not a hiring prediction. Never guess the outcome.",
    "Work from the text only: never judge voice, tone, pace, confidence, nerves or body language.",
    "Lines marked [CANDIDATE] are the candidate's own words; [OTHER] lines are the interviewer or others. Score only [CANDIDATE] lines. Suggested answers the app displayed are not in this transcript and are not judged.",
    "scores: rate the [CANDIDATE] answers 0–4 on relevance (answers what was asked), clarity (easy to follow), structure (logical order, e.g. situation–action–result), examples (concrete supporting examples). 0 = absent, 4 = strong.",
    "evidence: for each criterion, an exact quote of a few words copied from one [CANDIDATE] line that best shows the score.",
  ].join("\n");
  const user = `INTERVIEW: ${title || "(untitled)"}\nTRANSCRIPT (in order):\n${transcript}`;
  return [
    { role: "system", content: system },
    { role: "user", content: user },
  ];
}

/**
 * Enforces the rules on the model's output: scores bounded to the rubric, only with enough marked
 * speech; quotes kept only when found in the candidate's marked lines. `result` is null when the
 * model was not called because there was nothing to score.
 */
export function finalizeReview(result, { lines }) {
  const attributed = lines.some((line) => line.candidate);
  const candidateText = normalize(lines.filter((line) => line.candidate).map((line) => line.text).join(" "));
  const canScore = scorable(lines);
  const bound = (n) => Math.max(0, Math.min(4, Number.isInteger(n) ? n : 0));
  const scores = canScore && result?.scores
    ? Object.fromEntries(CRITERIA.map((name) => [name, bound(result.scores[name])]))
    : null;
  const evidence = scores
    ? Object.fromEntries(CRITERIA.map((name) => {
        const quote = clip(result?.evidence?.[name], 300).trim();
        return [name, quote && candidateText.includes(normalize(quote)) ? quote : ""];
      }))
    : null;
  const overall = scores ? Math.round((CRITERIA.reduce((sum, name) => sum + scores[name], 0) / CRITERIA.length) * 10) / 10 : null;
  return {
    version: REVIEW_VERSION,
    attributed,
    scores,
    overall,
    evidence,
    score_note: scores
      ? "Scored 0–4 on relevance, clarity, structure and supporting examples, from your marked answers only."
      : attributed
        ? "Not enough evidence to score: mark at least three of your answers."
        : "Mark the lines you said to get a score.",
    disclaimer: "AI coaching feedback, not a hiring prediction. Based on the transcript text only.",
  };
}
