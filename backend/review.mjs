// Interview summary & feedback: an explicit, Pro-only AI review of a frozen transcript snapshot.
//
// Principles, enforced here rather than trusted to the model:
// - **Only the candidate's own words are judged.** The app sends which lines the candidate marked as
//   theirs. Without enough of them the report is an unscored conversation summary, and strengths and
//   improvements are left empty.
// - **Evidence is real.** Each strength must quote the candidate's marked lines; a quote that is not
//   found in them is dropped.
// - **A score only when the evidence supports it**, on a transparent 0–4 rubric (relevance, clarity,
//   structure, supporting examples). Too little evidence → "Not enough evidence to score."
// - It is AI coaching feedback, not a hiring prediction, and nothing is inferred about voice,
//   confidence or body language from text.

export const REVIEW_VERSION = "review-2026-09-27.1";

/** Below this, the candidate's marked speech is too little to score. */
export const MIN_SCORED_LINES = 3;
export const MIN_SCORED_WORDS = 60;

export const REVIEW_SCHEMA = {
  type: "object",
  properties: {
    topics: { type: "array", items: { type: "string" } },
    questions: { type: "array", items: { type: "string" } },
    key_points: { type: "array", items: { type: "string" } },
    strengths: {
      type: "array",
      items: {
        type: "object",
        properties: { point: { type: "string" }, evidence: { type: "string" } },
        required: ["point", "evidence"],
        additionalProperties: false,
      },
    },
    improvements: {
      type: "array",
      items: {
        type: "object",
        properties: { point: { type: "string" }, example: { type: "string" } },
        required: ["point", "example"],
        additionalProperties: false,
      },
    },
    practice_questions: { type: "array", items: { type: "string" } },
    scores: {
      type: "object",
      properties: {
        relevance: { type: "integer" },
        clarity: { type: "integer" },
        structure: { type: "integer" },
        examples: { type: "integer" },
      },
      required: ["relevance", "clarity", "structure", "examples"],
      additionalProperties: false,
    },
  },
  required: ["topics", "questions", "key_points", "strengths", "improvements", "practice_questions", "scores"],
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
  const attributed = lines.some((line) => line.candidate);
  const canScore = scorable(lines);
  const transcript = lines.map((line, n) => `${n + 1}. ${attributed ? (line.candidate ? "[CANDIDATE] " : "[OTHER] ") : ""}${line.text}`).join("\n");
  const system = [
    "You write interview coaching feedback for the candidate, from a transcript.",
    `Write every string in the language with code ${language}.`,
    "It is AI coaching feedback, not a hiring prediction. Never guess the outcome.",
    "Work from the text only: never comment on voice, tone, pace, confidence, nerves or body language.",
    "The app may also have shown suggested answers on screen; those are not in this transcript and must not be judged.",
    attributed
      ? "Lines marked [CANDIDATE] are the candidate's own words; [OTHER] lines are the interviewer or others. Judge only [CANDIDATE] lines."
      : "Speakers are not identified. Summarise the conversation only: leave strengths, improvements empty, because you cannot know which words are the candidate's.",
    "topics: the subjects discussed. questions: the questions that were asked, as asked (short).",
    "key_points: the main points the candidate made (empty if speakers are not identified).",
    "strengths: each with `evidence` = an exact quote of a few words copied from a [CANDIDATE] line.",
    "improvements: each specific, with `example` = a concrete better way to say or structure it.",
    "practice_questions: 3 to 5 questions worth practising next, based on the topics.",
    canScore
      ? "scores: rate the [CANDIDATE] answers 0–4 on relevance (answers what was asked), clarity (easy to follow), structure (logical order, e.g. situation–action–result), examples (concrete supporting examples). 0 = absent, 4 = strong."
      : "scores: set all four to 0; there is not enough of the candidate's speech to score, and the app will say so.",
    "Be specific and brief. Do not invent anything that is not in the transcript.",
  ].join("\n");
  const user = `INTERVIEW: ${title || "(untitled)"}\nTRANSCRIPT (in order):\n${transcript}`;
  return [
    { role: "system", content: system },
    { role: "user", content: user },
  ];
}

/**
 * Enforces the rules on the model's output: drops strengths whose evidence is not found in the
 * candidate's marked lines, clears judgement without attribution, and removes scores without
 * enough evidence.
 */
export function finalizeReview(result, { lines }) {
  const attributed = lines.some((line) => line.candidate);
  const candidateText = normalize(lines.filter((line) => line.candidate).map((line) => line.text).join(" "));
  const canScore = scorable(lines);
  const list = (value, max = 12) => (Array.isArray(value) ? value.map((v) => clip(v, 400)).filter(Boolean).slice(0, max) : []);
  const strengths = attributed
    ? (Array.isArray(result?.strengths) ? result.strengths : [])
        .map((s) => ({ point: clip(s?.point, 400), evidence: clip(s?.evidence, 300) }))
        .filter((s) => s.point && s.evidence && candidateText.includes(normalize(s.evidence)))
        .slice(0, 6)
    : [];
  const improvements = attributed
    ? (Array.isArray(result?.improvements) ? result.improvements : [])
        .map((s) => ({ point: clip(s?.point, 400), example: clip(s?.example, 500) }))
        .filter((s) => s.point)
        .slice(0, 6)
    : [];
  const bound = (n) => Math.max(0, Math.min(4, Number.isInteger(n) ? n : 0));
  const scores = canScore && result?.scores
    ? { relevance: bound(result.scores.relevance), clarity: bound(result.scores.clarity), structure: bound(result.scores.structure), examples: bound(result.scores.examples) }
    : null;
  return {
    version: REVIEW_VERSION,
    attributed,
    topics: list(result?.topics),
    questions: list(result?.questions, 20),
    key_points: attributed ? list(result?.key_points) : [],
    strengths,
    improvements,
    practice_questions: list(result?.practice_questions, 6),
    scores,
    score_note: scores
      ? "Scored 0–4 on relevance, clarity, structure and supporting examples, from your marked answers only."
      : attributed
        ? "Not enough evidence to score."
        : "Unscored conversation summary: mark the lines you said to get feedback and a score.",
    disclaimer: "AI coaching feedback, not a hiring prediction. Based on the transcript text only.",
  };
}
