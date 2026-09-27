// Interview review rules (review.mjs) and the Pro-only route, against the fake provider.
// Run:  node test/review-test.mjs
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { finalizeReview, reviewInput, scorable, buildReviewMessages } from "../review.mjs";

let failures = 0;
const check = (label, ok, detail = "") => { if (ok) console.log(`  ok   ${label}`); else { failures += 1; console.log(`  FAIL ${label} ${detail}`); } };

const mine = (text) => ({ text, candidate: true });
const theirs = (text) => ({ text, candidate: false });
const long = "I led the migration of forty services to Kafka and cut delivery latency by sixty percent over two quarters";
const model = { scores: { relevance: 4, clarity: 3, structure: 9, examples: -1 },
  evidence: { relevance: "cut delivery latency by sixty percent", clarity: "I won an award", structure: "", examples: "forty services to Kafka" } };

{
  const lines = [theirs("Tell me about a migration."), mine(long), mine(long), mine(long), mine(long)];
  const report = finalizeReview(model, { lines });
  check("scores are bounded to the 0–4 rubric", report.scores.structure === 4 && report.scores.examples === 0);
  check("the overall score is the mean of the four, to one decimal", report.overall === 2.8);
  check("evidence keeps only quotes found in the candidate's own lines",
    report.evidence.relevance === "cut delivery latency by sixty percent" && report.evidence.clarity === "" && report.evidence.examples === "forty services to Kafka");
  check("no narrative is produced: no summary, topics, strengths, improvements or practice questions",
    ["topics", "questions", "key_points", "strengths", "improvements", "practice_questions", "summary"].every((key) => !(key in report)));
  check("it is labelled coaching feedback, not a hiring prediction", report.disclaimer.includes("not a hiring prediction"));
}
{
  const lines = [theirs("Tell me about a migration."), mine("Kafka, mostly.")];
  const report = finalizeReview(model, { lines });
  check("too little of the candidate's speech: no score", report.scores === null && report.overall === null && report.score_note.startsWith("Not enough evidence to score"));
}
{
  const lines = [{ text: "Tell me about a migration.", candidate: false }, { text: long, candidate: false }];
  const report = finalizeReview(model, { lines });
  check("without marked lines: no score, and it says to mark them", report.scores === null && report.score_note.startsWith("Mark the lines you said"));
}
{
  const prompt = buildReviewMessages({ lines: [theirs("Why Kafka?"), mine(long)], language: "fr", title: "" })[0].content;
  check("the prompt asks for scores and quotes only, never a summary", /scores and short quotes only/.test(prompt) && !/topics|practice|improvements|key_points/.test(prompt));
  check("the prompt scores only the candidate's lines and never suggested answers", /Score only \[CANDIDATE\] lines/.test(prompt) && /Suggested answers the app displayed are not in this transcript/.test(prompt));
}
check("an empty transcript is refused", (() => { try { reviewInput({ lines: [] }); return false; } catch (e) { return e.statusCode === 400; } })());
check("enough substantial marked lines are scorable; 57 words are not", scorable([mine(long), mine(long), mine(long), mine(long)]) && !scorable([mine(long), mine(long), mine(long)]));

// The route: Pro only for installations; operator allowed.
const dir = mkdtempSync(join(tmpdir(), "neverblank-review-"));
const PORT = 9941;
const server = spawn(process.execPath, ["server.mjs"], {
  cwd: new URL("..", import.meta.url).pathname,
  env: { ...process.env, COINTERVIEW_NO_ENV_FILE: "1", PORT: String(PORT), COINTERVIEW_TOKENS: "operator-token", COINTERVIEW_FAKE: "1", ACCESS_DB_PATH: join(dir, "a.sqlite") },
  stdio: ["ignore", "pipe", "pipe"],
});
let output = ""; server.stdout.on("data", (d) => { output += d; }); server.stderr.on("data", (d) => { output += d; });
try {
  const base = `http://127.0.0.1:${PORT}`;
  for (let i = 0; i < 50; i += 1) { try { if ((await fetch(`${base}/health`)).ok) break; } catch {} await delay(100); }
  const body = JSON.stringify({ title: "T", language: "en", lines: [theirs("Why Kafka?"), mine(long), mine(long), mine(long), mine(long)] });
  const created = await (await fetch(`${base}/v1/installations`, { method: "POST", body: "{}" })).json();
  const free = await fetch(`${base}/v1/copilot/review`, { method: "POST", headers: { authorization: `Installation ${created.installation_id}.${created.secret}` }, body });
  const freeBody = await free.json();
  check("a free installation is refused: review is a Pro feature", free.status === 402 && freeBody.reason === "pro_feature");
  const access = await (await fetch(`${base}/v1/access`, { headers: { authorization: `Installation ${created.installation_id}.${created.secret}` } })).json();
  check("a refused review uses no free answer", access.free_answers.used === 0 && access.free_answers.remaining === 2);
  const op = await fetch(`${base}/v1/copilot/review`, { method: "POST", headers: { authorization: "Bearer operator-token" }, body });
  const report = await op.json();
  check("the operator gets a score", op.status === 200 && report.scores && report.overall !== null && report.version.startsWith("score-"));
  const thin = await fetch(`${base}/v1/copilot/review`, { method: "POST", headers: { authorization: "Bearer operator-token" },
    body: JSON.stringify({ title: "T", language: "en", lines: [theirs("Why Kafka?"), mine("Kafka, mostly.")] }) });
  const thinReport = await thin.json();
  check("too little marked speech: answered without a score", thin.status === 200 && thinReport.scores === null);
} finally {
  server.kill("SIGTERM");
  rmSync(dir, { recursive: true, force: true });
}
console.log(failures ? `\n${failures} failure(s)` : "\nall review checks passed");
process.exit(failures ? 1 : 0);
