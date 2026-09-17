// OpenRouter adapter tests: stream parsing edge cases, route metadata, and fallback rules.
//
// A local stub stands in for OpenRouter, speaking the documented Chat Completions stream shapes.
// **No credential is needed and none is used** — which is also why these are contract tests, not
// evidence about latency or answer quality.

import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";
import { parseChatCompletionsStream } from "../providers/openrouter.mjs";

let failures = 0;
const check = (label, condition, detail = "") => {
  if (condition) console.log(`  ok   ${label}`);
  else { failures += 1; console.log(`  FAIL ${label} ${detail}`); }
};

/** Feeds arbitrary byte chunks through the parser and collects normalized events. */
async function parse(chunks) {
  async function* source() {
    for (const chunk of chunks) yield typeof chunk === "string" ? Buffer.from(chunk, "utf8") : chunk;
  }
  const events = [];
  for await (const event of parseChatCompletionsStream(source(), { requestedModel: "test/model" })) events.push(event);
  return events;
}

const frame = (payload) => `data: ${JSON.stringify(payload)}\n\n`;
const contentChunk = (text, extra = {}) => frame({
  id: "gen-a", model: "test/model", provider: "Together",
  choices: [{ index: 0, delta: { content: text }, finish_reason: null }], ...extra,
});

console.log("stream parsing");
{
  const events = await parse([
    ": OPENROUTER PROCESSING\n\n",
    contentChunk("Hello "),
    contentChunk("world."),
    frame({ id: "gen-a", model: "test/model", provider: "Together", choices: [{ index: 0, delta: { content: "" }, finish_reason: "stop", native_finish_reason: "stop" }] }),
    frame({ id: "gen-a", model: "test/model", choices: [{ index: 0, delta: { content: "" }, finish_reason: "stop" }], usage: { completion_tokens: 12 } }),
    "data: [DONE]\n\n",
  ]);
  const text = events.filter((e) => e.type === "delta").map((e) => e.text).join("");
  const done = events.find((e) => e.type === "done");
  check("keep-alive comments do not break the stream", text === "Hello world.", JSON.stringify(text));
  check("the usage frame is accounting, not a second terminal event", events.filter((e) => e.type === "done").length === 1);
  check("usage is captured", done?.meta.usage?.completion_tokens === 12);
  check("resolved model is recorded", done?.meta.resolvedModel === "test/model");
  check("serving provider is recorded as reported", done?.meta.servingProvider === "Together");
}

{
  // One SSE frame split across three network chunks, mid-token.
  const whole = contentChunk("Split across chunks.");
  const events = await parse([whole.slice(0, 10), whole.slice(10, 40), whole.slice(40), "data: [DONE]\n\n"]);
  check("frames split across network chunks reassemble",
    events.filter((e) => e.type === "delta").map((e) => e.text).join("") === "Split across chunks.");
}

{
  // A multi-byte character split across a chunk boundary must not become a replacement character.
  const payload = Buffer.from(contentChunk("réorganisation — délai"), "utf8");
  const cut = 60;
  const events = await parse([payload.subarray(0, cut), payload.subarray(cut), "data: [DONE]\n\n"]);
  const text = events.filter((e) => e.type === "delta").map((e) => e.text).join("");
  check("UTF-8 split across chunks survives", text === "réorganisation — délai", JSON.stringify(text));
}

{
  const events = await parse([contentChunk("Partial answer. "), frame({ error: { message: "upstream exploded" } })]);
  const error = events.find((e) => e.type === "error");
  check("an error after a 200 is surfaced", error?.message.includes("upstream exploded"));
  check("the error records that text was already committed", error?.committed === true);
  check("no done event follows a mid-stream error", !events.some((e) => e.type === "done"));
}

{
  const events = await parse([contentChunk("Some text. "), frame({ choices: [{ index: 0, delta: {}, finish_reason: "error", native_finish_reason: "error" }] })]);
  check("finish_reason=error is treated as a failure", events.some((e) => e.type === "error"));
}

{
  const events = await parse([contentChunk("Truncated")]);
  const error = events.find((e) => e.type === "error");
  check("a stream that stops without [DONE] is incomplete, not complete", error?.truncated === true);
}

{
  const events = await parse([
    frame({ id: "gen-a", model: "test/model", choices: [{ index: 0, delta: { content: "", reasoning: "internal thoughts" } }] }),
    contentChunk("Visible."),
    "data: [DONE]\n\n",
  ]);
  const text = events.filter((e) => e.type === "delta").map((e) => e.text).join("");
  check("reasoning text never reaches the answer", text === "Visible.", JSON.stringify(text));
  check("empty content deltas emit nothing", !events.some((e) => e.type === "delta" && e.text === ""));
}

{
  const events = await parse([contentChunk("No provider reported.", { provider: undefined }), "data: [DONE]\n\n"]);
  const done = events.find((e) => e.type === "done");
  check("an unreported serving provider stays null rather than being guessed", done?.meta.servingProvider === null);
}

// ---------------------------------------------------------------------------------------------
// Integration against a stub gateway
// ---------------------------------------------------------------------------------------------

let mode = "ok";
let requests = [];

const upstream = createServer(async (request, response) => {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  requests.push(body);

  if (mode === "primary-fails" && body.model === "nvidia/nemotron-3.5-lightning") {
    response.writeHead(500, { "content-type": "application/json" });
    return response.end(JSON.stringify({ error: { message: "primary route unavailable" } }));
  }
  if (mode === "primary-fails-after-text" && body.model === "nvidia/nemotron-3.5-lightning") {
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.write(contentChunk("Visible text already. "));
    await delay(30);
    response.write(frame({ error: { message: "died mid-stream" } }));
    return response.end();
  }
  if (mode === "auth-fails") {
    response.writeHead(401, { "content-type": "application/json" });
    return response.end(JSON.stringify({ error: { message: "invalid api key" } }));
  }

  if (!body.stream) {
    response.writeHead(200, { "content-type": "application/json" });
    return response.end(JSON.stringify({
      id: "gen-cls", model: body.model, provider: "Google AI Studio",
      choices: [{ message: { content: JSON.stringify({
        kind: "new_question", is_question: true, question_text: "What worries you about Mill Street?",
        related_question_id: "", confidence: 0.9, language: "en",
      }) } }],
    }));
  }

  response.writeHead(200, { "content-type": "text/event-stream" });
  response.write(contentChunk("The main risks are utility diversions. ", { model: body.model }));
  response.write(contentChunk("\nSOURCES: brief#2", { model: body.model }));
  response.write(frame({ id: "gen-a", model: body.model, provider: "Google AI Studio", choices: [{ index: 0, delta: { content: "" }, finish_reason: "stop" }], usage: { completion_tokens: 42 } }));
  response.write("data: [DONE]\n\n");
  response.end();
});

await new Promise((resolve) => upstream.listen(9921, "127.0.0.1", resolve));

const server = spawn(process.execPath, ["server.mjs"], {
  cwd: new URL("..", import.meta.url).pathname,
  env: {
    ...process.env,
    PORT: "9922",
    COINTERVIEW_TOKENS: "test-token",
    OPENROUTER_API_KEY: "test-key-not-real",
    OPENROUTER_BASE: "http://127.0.0.1:9921",
    OPENAI_API_KEY: "",
    COINTERVIEW_FAKE: "",
    COPILOT_TEXT_PROVIDER: "openrouter",
    COPILOT_PROFILE: "speed",
    COINTERVIEW_ALLOW_REQUEST_OVERRIDES: "1",
    REQUEST_TIMEOUT_MS: "3000",
  },
  stdio: ["ignore", "pipe", "pipe"],
});
server.stdout.on("data", () => {});
server.stderr.on("data", (data) => process.stderr.write(data));
await delay(700);

const BASE = "http://127.0.0.1:9922";
const auth = { "content-type": "application/json", authorization: "Bearer test-token" };

async function answer(body) {
  const response = await fetch(`${BASE}/v1/copilot/answer`, { method: "POST", headers: auth, body: JSON.stringify(body) });
  if (!response.ok) return { status: response.status, events: [], json: await response.json().catch(() => ({})) };
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
  return { status: response.status, events };
}

const question = { question: "What worries you about Mill Street?", passages: [{ id: "brief#2", documentTitle: "Brief", documentVersion: "v1", locator: "p. 4", text: "Known risks…" }], language: "en", projectID: "p1" };

try {
  console.log("routing and metadata");
  {
    requests = [];
    const { events } = await answer(question);
    const sent = requests.at(-1);
    const attempt = events.find((e) => e.type === "attempt");
    const text = events.filter((e) => e.type === "delta").map((e) => e.text).join("");
    check("uses the profile's answer model", sent.model === "nvidia/nemotron-3.5-lightning", sent.model);
    check("pins the verified routing slug", String(sent.provider.order) === "coreweave/bf16", JSON.stringify(sent.provider));
    check("disables reasoning with enabled:false", sent.reasoning.enabled === false, JSON.stringify(sent.reasoning));
    check("requires parameter support", sent.provider.require_parameters === true);
    check("denies data-collecting providers", sent.provider.data_collection === "deny");
    check("asks for usage accounting", sent.usage?.include === true);
    check("reports the serving provider it was told", attempt?.serving_provider === "Google AI Studio");
    check("reports the upstream generation id", attempt?.generation_id === "gen-a");
    check("strips the SOURCES line from readable text", !text.includes("SOURCES"), JSON.stringify(text));
    check("still extracts the cited ids", String(events.find((e) => e.type === "sources")?.ids) === "brief#2");
  }

  console.log("benchmark pinning");
  {
    // The smart profile lists two routes (Wafer, then Together). Benchmarking must compare them
    // separately, so a benchmark run has to name exactly one — asking for both is refused.
    const refused = await fetch(`${BASE}/v1/copilot/answer`, {
      method: "POST", headers: auth,
      body: JSON.stringify({ ...question, benchmark: true, config: { profile: "smart", answer_provider_order: ["together", "fireworks"] } }),
    });
    check("benchmarking more than one route at once is refused", refused.status === 400, String(refused.status));

    requests = [];
    await answer({ ...question, benchmark: true, config: { profile: "smart", answer_provider_order: ["together"] } });
    const sent = requests.at(-1);
    check("benchmark pins exactly one route with only", String(sent.provider.only) === "together", JSON.stringify(sent.provider));
    check("benchmark disables upstream fallback", sent.provider.allow_fallbacks === false);
    check("benchmark sends no ordered list", sent.provider.order === undefined);
  }

  console.log("fallback");
  {
    mode = "primary-fails";
    requests = [];
    const { events } = await answer(question);
    const models = requests.map((r) => r.model);
    const failed = events.find((e) => e.type === "attempt_failed");
    const attempt = events.find((e) => e.type === "attempt");
    check("falls back to Gemini before any visible text", models.includes("google/gemini-2.5-flash-lite"), JSON.stringify(models));
    check("the failed attempt is reported", failed?.attempt === 1);
    check("exactly two attempts are made", models.length === 2, JSON.stringify(models));
    check("the successful attempt is numbered 2", attempt?.attempt === 2);
    mode = "ok";
  }

  {
    mode = "primary-fails-after-text";
    requests = [];
    const { events } = await answer(question);
    const text = events.filter((e) => e.type === "delta").map((e) => e.text).join("");
    const error = events.find((e) => e.type === "error");
    check("after visible text there is no fallback attempt", requests.length === 1, JSON.stringify(requests.map((r) => r.model)));
    check("the text already shown is preserved", text.includes("Visible text already"));
    check("the answer is marked incomplete", error?.incomplete === true);
    check("and is offered as retryable", error?.retryable === true);
    mode = "ok";
  }

  {
    // Primary and fallback resolving to the same route must not produce a retry loop.
    mode = "primary-fails";
    requests = [];
    await answer({ ...question, config: { profile: "balanced" } });
    check("no recursive fallback when primary and fallback match", requests.length === 1, JSON.stringify(requests.map((r) => r.model)));
    mode = "ok";
  }

  {
    mode = "primary-fails";
    requests = [];
    await answer({ ...question, benchmark: true, config: { profile: "speed" } });
    check("benchmark mode never falls back", requests.length === 1, JSON.stringify(requests.map((r) => r.model)));
    mode = "ok";
  }

  {
    mode = "auth-fails";
    requests = [];
    const { events } = await answer(question);
    check("an authentication failure is not retried as transient", requests.length === 1, JSON.stringify(requests.length));
    check("and is reported as not retryable", events.find((e) => e.type === "error")?.retryable === false);
    mode = "ok";
  }

  console.log("detection");
  {
    requests = [];
    const response = await fetch(`${BASE}/v1/copilot/classify`, {
      method: "POST", headers: auth,
      body: JSON.stringify({ newSpeech: "What worries you most about Mill Street?", language: "en", projectID: "p1" }),
    });
    const payload = await response.json();
    const sent = requests.at(-1);
    check("detection uses the configured detector model", sent.model === "google/gemini-2.5-flash-lite", sent.model);
    check("detection enforces a strict JSON schema",
      sent.response_format?.type === "json_schema" && sent.response_format.json_schema.strict === true);
    check("detection returns the validated decision", payload.kind === "new_question" && payload.is_question === true);
    check("detection reports its language", payload.language === "en");
    check("detection reports the serving route", payload.route?.serving_provider === "Google AI Studio");
    check("detection uses its own token budget, not the answer budget", sent.max_tokens === 300, String(sent.max_tokens));
    check("detection uses its own temperature", sent.temperature === 0, String(sent.temperature));
  }

  console.log("configuration errors");
  {
    const response = await fetch(`${BASE}/v1/copilot/answer`, {
      method: "POST", headers: auth,
      body: JSON.stringify({ ...question, config: { answer_provider_order: ["CoreWeave"] } }),
    });
    const payload = await response.json();
    check("a display-name slug is refused with an actionable message",
      response.status === 400 && payload.detail?.includes("not a route"), JSON.stringify(payload).slice(0, 160));
  }
  {
    const response = await fetch(`${BASE}/v1/copilot/answer`, {
      method: "POST", headers: auth,
      body: JSON.stringify({ ...question, config: { combined_detect_and_answer: true } }),
    });
    check("combined detect+answer is refused as unsupported", response.status === 400);
  }
  {
    const response = await fetch(`${BASE}/v1/copilot/config`, { headers: auth });
    const payload = await response.json();
    const serialized = JSON.stringify(payload);
    check("the config endpoint reports the active route", payload.answer_model_id === "nvidia/nemotron-3.5-lightning");
    // The whole point of the backend boundary.
    check("the config endpoint leaks no credential",
      !serialized.includes("test-key-not-real") && !/api_key|apiKey|authorization/i.test(serialized));
  }

  console.log(failures === 0 ? "\nAll OpenRouter checks passed." : `\n${failures} OpenRouter check(s) FAILED.`);
} finally {
  server.kill();
  upstream.close();
}

process.exit(failures === 0 ? 0 : 1);
