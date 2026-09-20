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
  // A model that opens with the interpreted title, as the rules ask it to. Split across deltas on
  // purpose: the stripper has to hold the line until its newline arrives, not just match one chunk.
  const pieces = upstreamMode === "titled" ? [
    "TITLE: Compare Ja",
    "va 7, 8 and 9\n",
    "We bound the queue rather than the producer. ",
    "\nSOURCES: none",
  ] : [
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

  // The knowledge policy, asserted on the prompt that actually goes upstream.
  //
  // These are the rules that produced the device failures when they said the opposite: answers that
  // refused to explain a HashMap because no document mentioned one, and an invented first-person
  // introduction with `<add a specific example>` left in it for the speaker to read aloud.
  console.log("answer policy");
  {
    let lastAnswerEvents = [];
    const send = async (extra) => (lastAnswerEvents = await sendRaw(extra));
    const sendRaw = (extra) =>
      fetch(`${BASE}/v1/copilot/answer`, {
        method: "POST",
        headers: auth,
        body: JSON.stringify({
          question: "What is a HashMap in Java?",
          recentConversation: ["What is a HashMap in Java?"],
          language: "en",
          targetWordRange: [40, 100],
          projectID: "p2",
          ...extra,
        }),
      }).then(readStream);

    await send({});
    const rules = lastUpstreamRequest.input.find((part) => part.role === "developer").content;
    const body = JSON.stringify(lastUpstreamRequest.input);

    check("never instructs the model to write a placeholder", !/<add a specific example>/.test(rules));
    check("bans placeholders outright", /Never write a placeholder/i.test(rules));
    // The phrase still appears — as a prohibition. What must be gone is the *instruction* to say it,
    // so this asserts on the direction of the sentence, not on the words alone.
    check("does not tell the model to say things are not covered by the documents",
          !/say (plainly )?that this is not covered by the documents/i.test(rules));
    check("forbids mentioning documents for a general question",
          /Never say something is "not covered by the documents"/i.test(rules));
    check("allows general questions from the model's own knowledge",
          /answer from your own knowledge/i.test(rules));
    check("still requires evidence for claims about the speaker",
          /comes only from PASSAGES/i.test(rules));
    check("asks for a fenced code block when code is wanted", /fenced code block/i.test(rules));
    check("excludes code from the spoken target length", /not counting any code block/i.test(body));
    check("describes an empty document set as ordinary, not as a deficiency",
          /no imported documents/i.test(body));
    check("says the request may be a fragment or a correction",
          /fragment of a longer question, or a correction to/i.test(rules));
    check("tells the model to group related fragments into one request",
          /extends the comparison or list already under way/i.test(rules));
    check("tells the model a later explicit narrowing wins",
          /later explicit narrowing wins/i.test(rules));
    check("tells the model a follow-up keeps its subject",
          /follow-up keeps its subject/i.test(rules));
    // The three parts are labelled separately, so "what was said", "what is being asked now" and
    // "what I suggested earlier" cannot be confused for one another.
    check("separates the conversation from the request", /CONVERSATION so far/i.test(body));
    check("labels what is to be answered now", /TO ANSWER NOW/i.test(body));
    check("labels earlier answers as the assistant's own suggestions",
          /YOUR EARLIER SUGGESTIONS/i.test(body));
    check("says earlier suggestions are not things the speaker said",
          /NOT things the speaker said/i.test(body));

    // --- What actually reaches the provider ------------------------------------------------------
    //
    // The device can send a complete conversation and still have it cut here: there used to be a
    // second twelve-line slice on this side, so these assert on the outgoing upstream body.

    const longConversation = [
      "My most recent project was the Mill Street rollout.",
      ...Array.from({ length: 40 }, (_, i) => `Filler line number ${i + 1}.`),
      "Which project did I just mention?",
    ];
    await send({ question: "Which project did I just mention?", recentConversation: longConversation });
    const longBody = JSON.stringify(lastUpstreamRequest.input);
    check("a fact 40 lines back still reaches the provider", /Mill Street rollout/.test(longBody));
    check("no line of a long conversation is dropped",
          longConversation.every((line) => longBody.includes(line.replace(/"/g, '\\"'))));

    await send({
      question: "And Java 9. And Java 7.",
      recentConversation: [
        "Could you explain the difference between Java and Java 8?",
        "And Java 9.",
        "And Java 7.",
      ],
      newInput: ["And Java 9.", "And Java 7."],
      priorSuggestions: ["Java 8 added lambdas and the stream API."],
    });
    const javaBody = JSON.stringify(lastUpstreamRequest.input);
    check("every fragment of the comparison reaches the provider",
          /Java 8/.test(javaBody) && /Java 9/.test(javaBody) && /Java 7/.test(javaBody));
    check("the new input is sent as the request", /TO ANSWER NOW[\s\S]*And Java 9/.test(javaBody));
    check("an earlier suggestion is sent, labelled as a suggestion",
          /YOUR EARLIER SUGGESTIONS[\s\S]*stream API/.test(javaBody));

    await send({
      question: "What would you use for caching",
      recentConversation: ["So, about persistence.", "What would you use for caching"],
      newInput: ["What would you use for caching"],
      lastNewInputIsProvisional: true,
    });
    const partialBody = JSON.stringify(lastUpstreamRequest.input);
    check("the in-progress utterance is marked as still being spoken",
          /still being spoken/.test(partialBody));
    check("the in-progress utterance is not duplicated in the request block",
          (partialBody.match(/What would you use for caching/g) ?? []).length === 2);

    // --- Too long is refused, never silently shortened -------------------------------------------

    const hugeConversation = Array.from({ length: 4000 }, (_, i) =>
      `Line ${i}: ${"a somewhat long sentence about the ingestion pipeline. ".repeat(6)}`);
    const overflow = await fetch(`${BASE}/v1/copilot/answer`, {
      method: "POST",
      headers: auth,
      body: JSON.stringify({
        question: "What did I say at the start?",
        recentConversation: hugeConversation,
        language: "en",
        targetWordRange: [40, 100],
        projectID: "p2",
      }),
    });
    check("an over-budget conversation is refused explicitly", overflow.status === 413);
    const overflowBody = await overflow.json();
    check("the refusal names the context limit", overflowBody.error === "context_limit");
    check("the refusal reports the estimate and the budget",
          typeof overflowBody.estimated_input_tokens === "number" &&
          typeof overflowBody.input_budget_tokens === "number" &&
          overflowBody.estimated_input_tokens > overflowBody.input_budget_tokens);
    check("the refusal says nothing was dropped", /Nothing has been shortened or dropped/i.test(overflowBody.detail));
    check("the refusal does not claim the count was measured", /estimated/i.test(overflowBody.detail));

    // --- The interpreted title ---------------------------------------------------------------------

    upstreamMode = "titled";
    const titled = await send({ question: "And Java 7.", newInput: ["And Java 7."] });
    upstreamMode = "ok";
    const titleEvent = titled.find((event) => event.type === "title");
    check("the model's interpreted title is reported", titleEvent?.text === "Compare Java 7, 8 and 9");
    const titledText = titled.filter((e) => e.type === "delta").map((e) => e.text).join("");
    check("the title line is never shown to the reader", !/TITLE:/.test(titledText));
    check("the answer text survives the title line", /bound the queue/i.test(titledText));

    // --- Development diagnostics -----------------------------------------------------------------
    //
    // This server was started without COPILOT_DIAGNOSTICS, so the capture must be entirely inert:
    // the flag on a request changes nothing and the endpoint does not exist.

    await send({
      question: "What is a HashMap?",
      diagnosticsSessionID: "session-1",
      diagnosticsRequestID: "request-1",
      captureProviderMessages: true,
    });
    const offProbe = await fetch(`${BASE}/v1/copilot/diagnostics/request-1`, { headers: auth });
    check("diagnostics are off unless the operator enables them", offProbe.status === 404);
    const offBody = await offProbe.json();
    check("and say so rather than pretending the request is unknown",
          offBody.error === "diagnostics_disabled");
    check("the attempt event still reports the backend version",
          lastAnswerEvents.some((event) => event.type === "attempt" && typeof event.backend_version === "string"));
    check("the attempt event echoes the correlation id",
          lastAnswerEvents.some((event) => event.diagnostics_request_id === "request-1"));

    // Document-only answering still exists — it is just no longer the default.
    await send({ answerMode: "documents" });
    const strictRules = lastUpstreamRequest.input.find((part) => part.role === "developer").content;
    check("document-only mode is reachable and explicit", /DOCUMENT-ONLY MODE IS ON/i.test(strictRules));
    check("document-only mode keeps the placeholder ban", /Never write a placeholder/i.test(strictRules));
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
