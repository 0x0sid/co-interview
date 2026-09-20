// Development diagnostics, with the operator switch ON.
//
// The off case lives in contract-test.mjs, where it must stay inert. This suite runs a second server
// with COPILOT_DIAGNOSTICS=1 and asserts the bounded, authenticated, expiring behaviour that switch
// buys — and, just as importantly, that it still keeps nothing for a request that did not ask.
//
// Run:  node test/diagnostics-test.mjs

import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";

let failures = 0;
function check(label, condition, detail = "") {
  if (condition) console.log(`  ok   ${label}`);
  else {
    failures += 1;
    console.log(`  FAIL ${label} ${detail}`);
  }
}

const upstream = createServer(async (request, response) => {
  for await (const _ of request) { /* drain */ }
  response.writeHead(200, { "content-type": "text/event-stream" });
  response.write(`data: ${JSON.stringify({ type: "response.output_text.delta", delta: "TITLE: A title\nAn answer. \nSOURCES: none" })}\n\n`);
  response.write(`data: ${JSON.stringify({ type: "response.completed", response: { usage: { output_tokens: 3 } } })}\n\n`);
  response.end();
});
await new Promise((resolve) => upstream.listen(9921, "127.0.0.1", resolve));

const server = spawn(process.execPath, ["server.mjs"], {
  cwd: new URL("..", import.meta.url).pathname,
  env: {
    ...process.env,
    COINTERVIEW_NO_ENV_FILE: "1",
    PORT: "9922",
    COINTERVIEW_TOKENS: "test-token",
    OPENAI_API_KEY: "test-key-not-real",
    OPENAI_BASE: "http://127.0.0.1:9921",
    COINTERVIEW_FAKE: "",
    COPILOT_DIAGNOSTICS: "1",
    COPILOT_BACKEND_VERSION: "test-backend",
    COPILOT_DIAGNOSTICS_TTL_MS: "900",
  },
  stdio: ["ignore", "pipe", "pipe"],
});
server.stdout.on("data", () => {});
server.stderr.on("data", (data) => process.stderr.write(data));
await delay(700);

const BASE = "http://127.0.0.1:9922";
const auth = { "content-type": "application/json", authorization: "Bearer test-token" };

const ask = (extra) =>
  fetch(`${BASE}/v1/copilot/answer`, {
    method: "POST",
    headers: auth,
    body: JSON.stringify({
      question: "And Java 7.",
      recentConversation: ["Compare Java versions.", "And Java 7."],
      newInput: ["And Java 7."],
      language: "en",
      targetWordRange: [40, 100],
      projectID: "p1",
      ...extra,
    }),
  }).then(async (response) => {
    for await (const _ of response.body) { /* drain */ }
  });

try {
  console.log("diagnostics enabled");

  // A request that asks for its messages to be kept.
  await ask({
    diagnosticsSessionID: "session-A",
    diagnosticsRequestID: "req-A",
    captureProviderMessages: true,
    projectInstructions: "Answer in the first person.",
  });
  const kept = await fetch(`${BASE}/v1/copilot/diagnostics/req-A`, { headers: auth });
  check("a captured request is retrievable", kept.status === 200);
  const trace = await kept.json();
  check("it is correlated to its session", trace.session_id === "session-A");
  check("it names the backend version", trace.backend_version === "test-backend");
  check("it names the answer model", typeof trace.answer_model === "string" && trace.answer_model.length > 0);
  check("it holds the assembled provider messages, system instructions included",
        /--- role=system ---/.test(trace.provider_messages) && /--- role=user ---/.test(trace.provider_messages));
  check("the answer rules are in them", /Never write a placeholder/i.test(trace.provider_messages));
  check("the labelled request block is in them", /TO ANSWER NOW/.test(trace.provider_messages));
  check("the conversation is in them", /Compare Java versions/.test(trace.provider_messages));
  check("it reports its own expiry", typeof trace.expires_in_ms === "number" && trace.expires_in_ms > 0);

  // A request that did not ask keeps nothing, even with the switch on.
  await ask({ diagnosticsSessionID: "session-B", diagnosticsRequestID: "req-B" });
  const notAsked = await fetch(`${BASE}/v1/copilot/diagnostics/req-B`, { headers: auth });
  check("a request that did not ask for capture stores nothing", notAsked.status === 404);

  // Reading a trace is authenticated like everything else.
  const noToken = await fetch(`${BASE}/v1/copilot/diagnostics/req-A`);
  check("reading a trace without a token is refused", noToken.status === 401);
  const wrongToken = await fetch(`${BASE}/v1/copilot/diagnostics/req-A`, {
    headers: { authorization: "Bearer wrong" },
  });
  check("reading a trace with the wrong token is refused", wrongToken.status === 401);

  // Credentials never reach the store.
  await ask({
    diagnosticsSessionID: "session-C",
    diagnosticsRequestID: "req-C",
    captureProviderMessages: true,
    extraContext: "my key is sk-abcdef0123456789 and Authorization: Bearer super-secret-value",
  });
  const redacted = await (await fetch(`${BASE}/v1/copilot/diagnostics/req-C`, { headers: auth })).json();
  check("an API-key-shaped string is redacted", !/sk-abcdef0123456789/.test(redacted.provider_messages));
  check("a bearer token is redacted", !/super-secret-value/.test(redacted.provider_messages));
  check("the redaction is visible rather than silent", /REDACTED/.test(redacted.provider_messages));

  // Traces are temporary.
  await delay(1100);
  const expired = await fetch(`${BASE}/v1/copilot/diagnostics/req-A`, { headers: auth });
  check("a trace expires", expired.status === 404);
} finally {
  server.kill();
  upstream.close();
}

console.log(failures ? `\n${failures} diagnostics check(s) FAILED.` : "\nAll diagnostics checks passed.");
process.exit(failures ? 1 : 0);
