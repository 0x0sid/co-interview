// Contract tests for the **real** provider path — the code that runs when an API key is present.
//
// A local stub stands in for OpenAI, speaking the documented Responses shapes (verified 2026-09-16):
// `text.format` json_schema output for classification, and `response.output_text.delta` /
// `response.completed` SSE events for streaming. This exercises request construction, SSE parsing,
// the SOURCES-line stripper, error mapping and cancellation **without any credential**.
//
// It is not a substitute for a real run against OpenAI — it cannot be, since it supplies the answers.
// Run:  node test/contract-test.mjs

import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";

let failures = 0;
function check(label, condition, detail = "") {
  if (condition) {
    console.log(`  ok   ${label}`);
  } else {
    failures += 1;
    console.log(`  FAIL ${label} ${detail}`);
  }
}

// --- Stub upstream ------------------------------------------------------------------------------

let lastUpstreamRequest = null;
let upstreamAborted = false;
let upstreamMode = "ok";

const upstream = createServer(async (request, response) => {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  lastUpstreamRequest = body;

  if (upstreamMode === "rate-limited") {
    response.writeHead(429, { "content-type": "application/json" });
    return response.end(JSON.stringify({ error: { message: "slow down" } }));
  }

  if (!body.stream) {
    // Classification: a structured-output response.
    response.writeHead(200, { "content-type": "application/json" });
    return response.end(
      JSON.stringify({
        output_text: JSON.stringify({
          kind: "new_question",
          question_text: "What worries you about Mill Street?",
          related_question_id: "",
          confidence: 0.91,
        }),
      })
    );
  }

  // Streaming answer, in the documented event format.
  response.writeHead(200, { "content-type": "text/event-stream" });
  // The client here is the server under test. If it goes away mid-stream, this response closes before
  // it finished writing — that is what "the upstream request was cancelled" looks like from here.
  response.on("close", () => {
    if (!response.writableFinished) upstreamAborted = true;
  });
  const pieces = [
    "The main risks are utility diversions under Mill Street. ",
    "The depot power upgrade is not yet scheduled. ",
    "\nSOU",
    "RCES: brief#2, notes#1",
  ];
  for (const piece of pieces) {
    if (response.writableEnded) return;
    response.write(`data: ${JSON.stringify({ type: "response.output_text.delta", delta: piece })}\n\n`);
    await delay(upstreamMode === "slow" ? 400 : 20);
  }
  response.write(
    `data: ${JSON.stringify({ type: "response.completed", response: { usage: { output_tokens: 42 } } })}\n\n`
  );
  response.end();
});

await new Promise((resolve) => upstream.listen(9911, "127.0.0.1", resolve));

// --- Server under test --------------------------------------------------------------------------

const server = spawn(process.execPath, ["server.mjs"], {
  cwd: new URL("..", import.meta.url).pathname,
  env: {
    ...process.env,
    // Never read the developer's backend/.env: these suites define their own world.
    COINTERVIEW_NO_ENV_FILE: "1",
    PORT: "9912",
    COINTERVIEW_TOKENS: "test-token",
    OPENAI_API_KEY: "test-key-not-real",
    OPENAI_BASE: "http://127.0.0.1:9911",
    COINTERVIEW_FAKE: "",
    REQUEST_TIMEOUT_MS: "1500",
  },
  stdio: ["ignore", "pipe", "pipe"],
});
server.stdout.on("data", () => {});
server.stderr.on("data", (data) => process.stderr.write(data));
await delay(600);

const BASE = "http://127.0.0.1:9912";
const auth = { "content-type": "application/json", authorization: "Bearer test-token" };

async function readStream(response) {
  const events = [];
  const decoder = new TextDecoder();
  let buffer = "";
  for await (const chunk of response.body) {
    buffer += decoder.decode(chunk, { stream: true });
    let index;
    while ((index = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, index).trim();
      buffer = buffer.slice(index + 1);
      if (line.startsWith("data:")) events.push(JSON.parse(line.slice(5).trim()));
    }
  }
  return events;
}

try {
  console.log("classification");
  {
    const response = await fetch(`${BASE}/v1/copilot/classify`, {
      method: "POST",
      headers: auth,
      body: JSON.stringify({ newSpeech: "What worries you most about Mill Street?", language: "en", projectID: "p1" }),
    });
    const payload = await response.json();
    check("returns the parsed structured result", payload.kind === "new_question" && payload.confidence === 0.91);
    check("marks real provider output as not fake", payload.is_fake === false);
    check("requests the documented detection model", lastUpstreamRequest.model === "gpt-5.4-nano", lastUpstreamRequest.model);
    check("sends reasoning effort none", lastUpstreamRequest.reasoning?.effort === "none");
    check("sends store:false", lastUpstreamRequest.store === false);
    check(
      "asks for a strict json_schema",
      lastUpstreamRequest.text?.format?.type === "json_schema" && lastUpstreamRequest.text?.format?.strict === true
    );
    check("sends a hashed safety identifier", /^[0-9a-f]{32}$/.test(lastUpstreamRequest.safety_identifier ?? ""));
    check("developer rules come before user content", lastUpstreamRequest.input[0].role === "developer");
  }

  console.log("streaming answer");
  {
    const response = await fetch(`${BASE}/v1/copilot/answer`, {
      method: "POST",
      headers: auth,
      body: JSON.stringify({
        question: "What worries you about Mill Street?",
        projectInstructions: "Answer in the first person.",
        passages: [{ id: "brief#2", documentTitle: "Brief", documentVersion: "v1", locator: "p. 4", text: "Known risks…" }],
        recentConversation: ["Shall we start?"],
        extraContext: "Focus on Java 17",
        language: "en",
        targetWordRange: [60, 120],
        projectID: "p1",
      }),
    });
    const events = await readStream(response);
    const text = events.filter((event) => event.type === "delta").map((event) => event.text).join("");
    const sources = events.find((event) => event.type === "sources");
    const done = events.find((event) => event.type === "done");

    check("streams text deltas", text.includes("utility diversions"));
    check("never leaks the SOURCES line into readable text", !text.includes("SOURCES"), JSON.stringify(text.slice(-60)));
    check("extracts cited ids, even when split across deltas", JSON.stringify(sources?.ids) === JSON.stringify(["brief#2", "notes#1"]));
    check("reports completion with usage", done?.output_tokens === 42);
    check("requests the documented answer model", lastUpstreamRequest.model === "gpt-5.4-mini", lastUpstreamRequest.model);
    check("streams upstream", lastUpstreamRequest.stream === true);
    check("sets a prompt cache key per project", lastUpstreamRequest.prompt_cache_key === "co-interview:p1");
    check("does not send gpt-5.6-only cache options", lastUpstreamRequest.prompt_cache_options === undefined);
    check("sends only the supplied passages, not whole documents", JSON.stringify(lastUpstreamRequest.input).includes("brief#2"));
    // The session note travels to the model, framed as reference material rather than as
    // instructions — uploaded or typed content must not be able to override the answer rules.
    const answerPrompt = JSON.stringify(lastUpstreamRequest.input);
    check("includes the session note", answerPrompt.includes("Focus on Java 17"));
    check("frames the note as reference, not instructions", answerPrompt.includes("SESSION NOTE"));
  }

  console.log("cancellation");
  {
    upstreamAborted = false;
    upstreamMode = "slow";
    const controller = new AbortController();
    const request = fetch(`${BASE}/v1/copilot/answer`, {
      method: "POST",
      headers: auth,
      body: JSON.stringify({ question: "A question that will be cancelled", passages: [], language: "en", projectID: "p1" }),
      signal: controller.signal,
    });
    await delay(500);
    controller.abort();
    await request.catch(() => {});
    await delay(500);
    check("client disconnect aborts the upstream request", upstreamAborted);
    upstreamMode = "ok";
  }

  console.log("provider errors");
  {
    upstreamMode = "rate-limited";
    const response = await fetch(`${BASE}/v1/copilot/classify`, {
      method: "POST",
      headers: auth,
      body: JSON.stringify({ newSpeech: "Anything at all here", language: "en" }),
    });
    check("maps upstream 429 to 429", response.status === 429, String(response.status));
    upstreamMode = "ok";
  }

  console.log(failures === 0 ? "\nAll contract checks passed." : `\n${failures} contract check(s) FAILED.`);
} finally {
  server.kill();
  upstream.close();
}

process.exit(failures === 0 ? 0 : 1);
