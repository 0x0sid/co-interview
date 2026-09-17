// Measures the copilot pipeline against synthetic scenarios (docs/CO_INTERVIEW_AI_PIPELINE.md §9).
//
// What it measures, per scenario: detection latency, retrieval latency, time to first streamed text,
// time to the first complete readable sentence, and completion time — plus detection correctness,
// citation validity, and whether an unsupported question was answered honestly.
//
// What it does NOT measure: anything before the transcript exists. Speech-to-stable-transcript is an
// on-device number that needs a real microphone and a real room (plan Increment 1). It is reported as
// "not measured" rather than estimated.
//
// Usage:
//   node eval/run-eval.mjs --base http://127.0.0.1:8787 --token dev-token [--model gpt-5.4-mini]
//                          [--runs 3] [--filter en-] [--out results.json]
//
// No dependencies. Node 18+.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));

function parseArguments(argv) {
  const options = {
    base: "http://127.0.0.1:8787", token: "", runs: 1, filter: "", out: "", model: "", label: "",
    // Route pinning for an answer-model comparison. `--profile smart --route wafer` benchmarks
    // DeepSeek through Wafer specifically; each route is a separate run, because pinning requires
    // exactly one.
    profile: "", route: "", provider: "", benchmark: "",
  };
  for (let index = 2; index < argv.length; index += 2) {
    const key = argv[index].replace(/^--/, "");
    const value = argv[index + 1];
    if (key in options) options[key] = key === "runs" ? Number(value) : value;
  }
  return options;
}

const options = parseArguments(process.argv);
const suite = JSON.parse(readFileSync(join(HERE, "scenarios.json"), "utf8"));

/** The same lexical retrieval the app runs on device, reimplemented here so the measured retrieval
 *  step reflects the real one. Kept deliberately small — see PassageRetriever.swift. */
const STOP_WORDS = new Set(
  ("the a an and or of to in on for with you your me my is are was were do did does can could would about tell what how why who when that this it as at be by from " +
   "le la les un une des du de et ou que qui quoi comment pourquoi vous votre vos moi mon ma mes est sont etait avez pouvez parlez dites dans sur pour avec au aux ce cette il elle")
    .split(" ")
);

const normalize = (text) =>
  text
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .split(/[^a-z0-9àâäéèêëîïôöùûüç]+/i)
    .filter(Boolean);

function retrieve(project, question, limit = 3) {
  const passages = project.passages;
  const frequency = new Map();
  for (const passage of passages) {
    for (const word of new Set(normalize(passage.text))) frequency.set(word, (frequency.get(word) ?? 0) + 1);
  }
  const queryWords = new Set(normalize(question).filter((word) => !STOP_WORDS.has(word)));
  const scored = passages.map((passage) => {
    const words = new Set(normalize(passage.text));
    let score = 0;
    for (const word of queryWords) {
      if (words.has(word)) score += Math.log(1 + passages.length / (frequency.get(word) ?? 1));
    }
    return { passage, score };
  });
  return scored
    .filter((entry) => entry.score > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, limit)
    .map((entry) => entry.passage);
}

/** Development-only configuration overrides; the backend refuses them unless it opted in. */
function routeOverrides() {
  const overrides = {};
  if (options.profile) overrides.profile = options.profile;
  if (options.provider) overrides.text_provider = options.provider;
  if (options.route) overrides.answer_provider_order = [options.route];
  if (options.model) overrides.answer_model_id = options.model;
  return Object.keys(overrides).length ? overrides : null;
}

async function classify(scenario, project) {
  const started = performance.now();
  const response = await fetch(`${options.base}/v1/copilot/classify`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${options.token}` },
    body: JSON.stringify({
      newSpeech: scenario.speech,
      recentConversation: scenario.recentConversation ?? [],
      activeAnswerText: scenario.activeAnswerText ?? null,
      knownQuestions: scenario.knownQuestions ?? [],
      language: project.language,
      projectID: scenario.project,
    }),
  });
  const seconds = (performance.now() - started) / 1000;
  if (!response.ok) {
    return { seconds, error: `${response.status} ${(await response.text()).slice(0, 200)}` };
  }
  return { seconds, result: await response.json() };
}

/** Streams an answer, timing first text and first complete sentence as the app's assembler sees them. */
async function generate(scenario, project, passages) {
  const started = performance.now();
  const body = {
    question: scenario.speech,
    projectInstructions: project.instructions,
    recentConversation: scenario.recentConversation ?? [],
    passages,
    language: project.language,
    targetWordRange: [60, 120],
    projectID: scenario.project,
  };
  if (options.model) body.model = options.model;
  const overrides = routeOverrides();
  if (overrides) body.config = overrides;
  // Benchmark mode pins one provider and disables both fallback mechanisms, so a run that cannot use
  // the named route fails loudly instead of quietly measuring a different one.
  if (options.benchmark === "1") body.benchmark = true;

  const response = await fetch(`${options.base}/v1/copilot/answer`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${options.token}` },
    body: JSON.stringify(body),
  });

  if (!response.ok || !response.body) {
    return { error: `${response.status} ${(await response.text()).slice(0, 200)}` };
  }

  let firstText = null;
  let firstSentence = null;
  let text = "";
  let sources = [];
  let attempt = null;
  const attemptFailures = [];
  const decoder = new TextDecoder();
  let buffer = "";

  for await (const chunk of response.body) {
    buffer += decoder.decode(chunk, { stream: true });
    let newlineIndex;
    while ((newlineIndex = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newlineIndex).trim();
      buffer = buffer.slice(newlineIndex + 1);
      if (!line.startsWith("data:")) continue;
      const payload = line.slice(5).trim();
      if (!payload) continue;
      let event;
      try {
        event = JSON.parse(payload);
      } catch {
        continue;
      }
      if (event.type === "attempt") {
        attempt = event;
      } else if (event.type === "attempt_failed") {
        attemptFailures.push(event);
      } else if (event.type === "delta") {
        if (firstText === null) firstText = (performance.now() - started) / 1000;
        text += event.text;
        // First complete sentence: the same rule the app uses to freeze readable text.
        if (firstSentence === null && /[.!?…][\s]/.test(text)) {
          firstSentence = (performance.now() - started) / 1000;
        }
      } else if (event.type === "sources") {
        sources = event.ids ?? [];
      } else if (event.type === "error") {
        return { error: event.message, firstText, firstSentence, text, sources };
      }
    }
  }

  return {
    firstText,
    firstSentence,
    complete: (performance.now() - started) / 1000,
    text: text.trim(),
    sources,
    words: text.trim().split(/\s+/).filter(Boolean).length,
    // Recorded, never inferred: "unknown" when the gateway does not report who served the request.
    servingProvider: attempt?.serving_provider ?? "unknown",
    resolvedModel: attempt?.resolved_model ?? null,
    requestedModel: attempt?.requested_model ?? null,
    generationID: attempt?.generation_id ?? null,
    usage: attempt?.usage ?? null,
    attempts: (attempt?.attempt ?? 0) + attemptFailures.length,
    attemptFailures: attemptFailures.map((failure) => failure.detail),
  };
}

const KIND_MAP = { new_question: "new_question", none: "none", incomplete: "incomplete", continuation: "continuation" };

/** The first sentence, by the same rule the app uses to freeze readable text. */
function firstSentenceOf(text) {
  const match = /^(.*?[.!?…])(\s|$)/s.exec(text ?? "");
  return match ? match[1].trim() : (text ?? "").trim();
}

function gradeAnswer(scenario, answer, passages) {
  const problems = [];
  const text = (answer.text ?? "").toLowerCase();

  // "Ends with punctuation" is not usefulness. The opening sentence has to carry substance: enough
  // words to say something, and either a figure from the documents or a direct claim.
  const opening = firstSentenceOf(answer.text);
  const openingWords = opening.split(/\s+/).filter(Boolean).length;
  if (openingWords < 6) problems.push(`first sentence is too thin to be useful (${openingWords} words)`);
  if (/^(well|so|okay|um|hmm|alors|eh bien)\b/i.test(opening)) problems.push("first sentence opens with a hesitation");

  // Citations must point at passages the model was actually given.
  const allowed = new Set(passages.map((passage) => passage.id));
  const invalid = (answer.sources ?? []).filter((id) => !allowed.has(id));
  if (invalid.length) problems.push(`cited unknown source(s): ${invalid.join(", ")}`);

  // Where the scenario expects a specific source, it should be used.
  for (const expected of scenario.expectSources ?? []) {
    if (!(answer.sources ?? []).includes(expected)) problems.push(`missing expected source ${expected}`);
  }

  // A question with no supporting material must be answered honestly, not invented.
  if (scenario.expectHonestGap) {
    if ((answer.sources ?? []).length) problems.push("cited sources for a question the documents do not cover");
    const honest = /(not|pas|n'est pas|ne figure|do not|don't|couldn't find|<)/.test(text);
    if (!honest) problems.push("did not flag the missing information");
  }

  if (scenario.mustMention?.length) {
    const mentioned = scenario.mustMention.some((value) => text.includes(value.toLowerCase()));
    if (!mentioned) problems.push(`did not use the document figure (${scenario.mustMention.join(" / ")})`);
  }

  if (/^(here is|here's|sure|certainly|great question|voici|bien sûr)/.test(text)) {
    problems.push("opened with filler");
  }

  return problems;
}

function percentile(values, fraction) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil(fraction * sorted.length) - 1));
  return sorted[index];
}

const median = (values) => percentile(values, 0.5);
const round = (value) => (value === null || value === undefined ? null : Math.round(value * 1000) / 1000);

async function main() {
  const health = await fetch(`${options.base}/health`).then((response) => response.json());
  console.log(`backend: provider=${health.provider} detection=${health.detectionModel} answer=${health.answerModel}`);
  if (health.provider === "fake") {
    console.log("WARNING: development fake provider — latency and answer quality here mean nothing.");
  }

  const scenarios = suite.scenarios.filter((scenario) => !options.filter || scenario.id.includes(options.filter));
  const rows = [];

  for (let run = 1; run <= options.runs; run += 1) {
    for (const scenario of scenarios) {
      const project = suite.projects[scenario.project];
      const detection = await classify(scenario, project);

      const retrievalStart = performance.now();
      const passages = retrieve(project, scenario.speech);
      const retrievalSeconds = (performance.now() - retrievalStart) / 1000;

      const kind = detection.result?.kind;
      const detectionCorrect = kind === KIND_MAP[scenario.expect];
      let answer = null;
      let problems = [];

      // Only generate where a question was expected; that is what the app does.
      if (scenario.expect === "new_question") {
        answer = await generate(scenario, project, passages);
        problems = answer.error ? [`generation error: ${answer.error}`] : gradeAnswer(scenario, answer, passages);
      }

      rows.push({
        run,
        id: scenario.id,
        kind: scenario.kind,
        language: project.language,
        expected: scenario.expect,
        detected: kind ?? `ERROR ${detection.error ?? ""}`,
        detectionCorrect,
        detectionSeconds: round(detection.seconds),
        retrievalSeconds: round(retrievalSeconds),
        retrieved: passages.map((passage) => passage.id),
        firstTextSeconds: round(answer?.firstText ?? null),
        firstSentenceSeconds: round(answer?.firstSentence ?? null),
        completeSeconds: round(answer?.complete ?? null),
        words: answer?.words ?? null,
        sources: answer?.sources ?? null,
        servingProvider: answer?.servingProvider ?? null,
        resolvedModel: answer?.resolvedModel ?? null,
        requestedModel: answer?.requestedModel ?? null,
        generationID: answer?.generationID ?? null,
        usage: answer?.usage ?? null,
        attempts: answer?.attempts ?? null,
        problems,
        answer: answer?.text ?? null,
      });

      const status = detectionCorrect ? "ok " : "MISS";
      console.log(
        `[run ${run}] ${status} ${scenario.id.padEnd(30)} detect=${String(round(detection.seconds)).padEnd(6)} ` +
          `first=${String(round(answer?.firstText ?? "-")).padEnd(6)} sentence=${String(round(answer?.firstSentence ?? "-")).padEnd(6)} ` +
          `done=${String(round(answer?.complete ?? "-")).padEnd(6)} ${problems.length ? "problems: " + problems.join("; ") : ""}`
      );
    }
  }

  const withAnswers = rows.filter((row) => row.firstTextSeconds !== null);
  const summary = {
    generatedAt: new Date().toISOString(),
    backend: health,
    answerModelOverride: options.model || null,
    route: { profile: options.profile || null, provider: options.provider || null, pinned_route: options.route || null, benchmark: options.benchmark === "1" },
    servingProviders: [...new Set(rows.map((row) => row.servingProvider).filter(Boolean))],
    label: options.label || null,
    sampleSize: { scenarios: scenarios.length, runs: options.runs, rows: rows.length, generated: withAnswers.length },
    detection: {
      correct: rows.filter((row) => row.detectionCorrect).length,
      total: rows.length,
      missed: rows.filter((row) => !row.detectionCorrect).map((row) => ({ id: row.id, expected: row.expected, got: row.detected })),
      medianSeconds: round(median(rows.map((row) => row.detectionSeconds).filter((value) => value !== null))),
      p95Seconds: round(percentile(rows.map((row) => row.detectionSeconds).filter((value) => value !== null), 0.95)),
    },
    retrieval: {
      medianSeconds: round(median(rows.map((row) => row.retrievalSeconds))),
      p95Seconds: round(percentile(rows.map((row) => row.retrievalSeconds), 0.95)),
    },
    generation: {
      firstTextMedian: round(median(withAnswers.map((row) => row.firstTextSeconds))),
      firstTextP95: round(percentile(withAnswers.map((row) => row.firstTextSeconds), 0.95)),
      firstSentenceMedian: round(median(withAnswers.map((row) => row.firstSentenceSeconds).filter((value) => value !== null))),
      firstSentenceP95: round(percentile(withAnswers.map((row) => row.firstSentenceSeconds).filter((value) => value !== null), 0.95)),
      completeMedian: round(median(withAnswers.map((row) => row.completeSeconds).filter((value) => value !== null))),
      completeP95: round(percentile(withAnswers.map((row) => row.completeSeconds).filter((value) => value !== null), 0.95)),
      medianWords: round(median(withAnswers.map((row) => row.words).filter((value) => value !== null))),
    },
    quality: {
      answersWithProblems: rows.filter((row) => row.problems.length).map((row) => ({ id: row.id, problems: row.problems })),
    },
    notMeasuredHere: [
      "end of spoken question to stable transcript (needs a device and a real room — plan Increment 1)",
      "end of question to first readable sentence (the sum of the above and the numbers here)",
    ],
    rows,
  };

  console.log("\n--- summary ---");
  console.log(`detection correct: ${summary.detection.correct}/${summary.detection.total}`);
  console.log(`detection  median ${summary.detection.medianSeconds}s  p95 ${summary.detection.p95Seconds}s`);
  console.log(`first text median ${summary.generation.firstTextMedian}s  p95 ${summary.generation.firstTextP95}s`);
  console.log(`first sentence median ${summary.generation.firstSentenceMedian}s  p95 ${summary.generation.firstSentenceP95}s`);
  console.log(`complete   median ${summary.generation.completeMedian}s  p95 ${summary.generation.completeP95}s`);
  console.log(`answers with problems: ${summary.quality.answersWithProblems.length}`);

  if (options.out) {
    writeFileSync(options.out, JSON.stringify(summary, null, 2));
    console.log(`\nwrote ${options.out}`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
