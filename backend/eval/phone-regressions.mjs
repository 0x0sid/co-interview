// Replays the requests from the 2026-09-24 phone test against a running backend with the real
// provider, and records what the answer model was actually sent, what it wrote, and how long it took.
//
// The bodies are shaped exactly as the app builds them (`AnswerRequest`): the whole conversation in
// `recentConversation`, the uncovered part in `newInput`, earlier answers in `priorSuggestions`, the
// typed note in `extraContext`. The provider messages come from the backend's own diagnostics store,
// so the backend must run with COPILOT_DIAGNOSTICS=1.
//
// Usage:
//   node eval/phone-regressions.mjs --base http://127.0.0.1:8787 --token <token> [--out <dir>] [--label before]
//
// Not a pass/fail suite: the model's wording varies. Each case lists what a correct answer must and
// must not contain, and the report shows whether this run met it — evidence for a person to read.

import { writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

const JAVA = ["Could you compare Java 8 and Java 9?", "And Java 7.", "Could you compare Java 9 and Java 8 and Java 7?", "Java 10."];
const EARLIER_JAVA_ANSWER = "Java 7 added try-with-resources and the diamond operator. Java 8 brought lambdas and streams. Java 9 introduced the module system and JShell.";

export const CASES = [
  {
    id: "note-pizza",
    what: "A personal question answered from the typed note, and only from it",
    body: { recentConversation: ["Could you tell me your secret, in fact?"], newInput: ["Could you tell me your secret, in fact?"], extraContext: "Secret: I love pizza" },
    must: [/pizza/i],
    mustNot: [/cannot|can't|don't have|no information|not (?:able|contain)|as an ai/i],
    needs: null,
  },
  {
    id: "note-pizza-screenshot-wording",
    what: "The wording from the screenshot, after an unrelated earlier answer",
    body: {
      recentConversation: [...JAVA, "TS", "And could you tell me more your secret?"],
      newInput: ["TS", "And could you tell me more your secret?"],
      priorSuggestions: [EARLIER_JAVA_ANSWER],
      extraContext: "Secret: I love pizza",
    },
    must: [/pizza/i],
    mustNot: [/cannot|can't|don't have|no information|not (?:able|contain)|as an ai/i],
    needs: null,
  },
  {
    id: "note-absent",
    what: "The same question with no note: ask for the detail, invent nothing",
    body: { recentConversation: ["Could you tell me your secret, in fact?"], newInput: ["Could you tell me your secret, in fact?"], extraContext: "" },
    must: [],
    mustNot: [/pizza/i, /as an ai|i am an ai|language model/i, /\bI (?:do not|don't) have\b|\bI have no\b|\bI've never\b/i],
    needs: "context",
  },
  {
    id: "compare-one-tap",
    what: "All four lines before one Generate: every version stays in scope",
    body: { recentConversation: JAVA, newInput: JAVA },
    must: [/Java 7|\b7\b/, /Java 8|\b8\b/, /Java 9|\b9\b/, /Java 10|\b10\b/],
    mustNot: [],
  },
  {
    id: "compare-tap-after-line-2",
    what: "Tap after 'And Java 7.', then lines 3–4 as the next request",
    body: {
      recentConversation: JAVA,
      newInput: JAVA.slice(2),
      priorSuggestions: [EARLIER_JAVA_ANSWER],
    },
    must: [/Java 7|\b7\b/, /Java 8|\b8\b/, /Java 9|\b9\b/, /Java 10|\b10\b/],
    mustNot: [],
  },
  {
    id: "compare-provisional-10",
    what: "Tap while 'Java 10.' was still being recognised (sent as the provisional last line)",
    body: { recentConversation: JAVA, newInput: JAVA.slice(2), lastNewInputIsProvisional: true, priorSuggestions: [EARLIER_JAVA_ANSWER] },
    must: [/Java 7|\b7\b/, /Java 8|\b8\b/, /Java 9|\b9\b/, /Java 10|\b10\b/],
    mustNot: [],
  },
  {
    id: "compare-fragment-after-tap",
    what: "Bare 'Java 10.' arriving after the previous Generate",
    body: { recentConversation: JAVA, newInput: ["Java 10."], priorSuggestions: [EARLIER_JAVA_ANSWER] },
    must: [/Java 10|\b10\b/, /Java 9|\b9\b/],
    mustNot: [],
  },
  {
    id: "compare-and-10-after-tap",
    what: "'And Java 10.' after the previous Generate: an addition to 7, 8 and 9",
    body: { recentConversation: [...JAVA.slice(0, 3), "And Java 10."], newInput: ["And Java 10."], priorSuggestions: [EARLIER_JAVA_ANSWER] },
    must: [/Java 7|\b7\b/, /Java 8|\b8\b/, /Java 9|\b9\b/, /Java 10|\b10\b/],
    mustNot: [],
  },
  {
    id: "compare-explicit-narrowing",
    what: "'Actually, only Java 8 and Java 10.' replaces the wider scope",
    body: { recentConversation: [...JAVA.slice(0, 3), "Actually, only Java 8 and Java 10."], newInput: ["Actually, only Java 8 and Java 10."], priorSuggestions: [EARLIER_JAVA_ANSWER] },
    must: [/Java 8|\b8\b/, /Java 10|\b10\b/],
    mustNot: [/Java 7\b/, /Java 9\b/],
  },
];

function parseArguments(argv) {
  const options = { base: "http://127.0.0.1:8787", token: "", out: "", label: "run", repeat: "1", filter: "" };
  for (let index = 2; index < argv.length; index += 2) {
    const key = argv[index].replace(/^--/, "");
    if (key in options) options[key] = argv[index + 1];
  }
  return options;
}

async function runCase(testCase, { base, token }) {
  const requestID = randomUUID();
  const body = {
    question: testCase.body.newInput.join(" "),
    recentConversation: testCase.body.recentConversation,
    newInput: testCase.body.newInput,
    lastNewInputIsProvisional: testCase.body.lastNewInputIsProvisional ?? false,
    priorSuggestions: testCase.body.priorSuggestions ?? [],
    extraContext: testCase.body.extraContext ?? "",
    projectInstructions: "",
    passages: [],
    language: "en",
    targetWordRange: [40, 100],
    projectID: "phone-regressions",
    diagnosticsSessionID: "phone-regressions",
    diagnosticsRequestID: requestID,
    captureProviderMessages: true,
  };
  const started = Date.now();
  const response = await fetch(`${base}/v1/copilot/answer`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });
  let text = "";
  let title = null;
  let needs = null;
  let firstText = null;
  let attempt = null;
  const decoder = new TextDecoder();
  let buffer = "";
  for await (const chunk of response.body) {
    buffer += decoder.decode(chunk, { stream: true });
    let at;
    while ((at = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, at).trim();
      buffer = buffer.slice(at + 1);
      if (!line.startsWith("data:")) continue;
      const event = JSON.parse(line.slice(5));
      if (event.type === "delta") { text += event.text; firstText ??= Date.now() - started; }
      if (event.type === "title") title = event.text;
      if (event.type === "needs") needs = event.value;
      if (event.type === "attempt") attempt = event;
    }
  }
  const total = Date.now() - started;
  const diagnostics = await fetch(`${base}/v1/copilot/diagnostics/${requestID}`, { headers: { authorization: `Bearer ${token}` } });
  const providerMessages = diagnostics.ok ? (await diagnostics.json()).provider_messages : "(diagnostics unavailable)";
  const missing = testCase.must.filter((pattern) => !pattern.test(text)).map(String);
  if (testCase.needs !== undefined && testCase.needs !== needs) missing.push(`needs=${testCase.needs}`);
  const forbidden = testCase.mustNot.filter((pattern) => pattern.test(text)).map(String);
  return {
    id: testCase.id, what: testCase.what, status: response.status, title, needs, answer: text.trim(), firstTextMs: firstText, totalMs: total,
    model: attempt?.resolved_model ?? attempt?.requested_model ?? null, met: !missing.length && !forbidden.length, missing, forbidden, providerMessages,
  };
}

async function main() {
  const options = parseArguments(process.argv);
  const results = [];
  // Repeats measure variance: one passing run of a sampled model proves little.
  const cases = CASES.filter((c) => !options.filter || c.id.includes(options.filter));
  for (let round = 0; round < Number(options.repeat); round += 1) {
    for (const testCase of cases) results.push({ ...(await runCase(testCase, options)), round });
  }
  const lines = [`# Phone regressions — ${options.label}`, "", `Generated ${new Date().toISOString()} against ${options.base}.`, ""];
  for (const r of results) {
    lines.push(`## ${r.id} — ${r.met ? "met" : "NOT met"}`, "", r.what, "",
      `- HTTP ${r.status} · model \`${r.model}\` · first text ${r.firstTextMs} ms · complete ${r.totalMs} ms`,
      `- Title: ${r.title ?? "(none)"} · needs: ${r.needs ?? "(none)"}`,
      ...(r.missing.length ? [`- Missing: ${r.missing.join(", ")}`] : []),
      ...(r.forbidden.length ? [`- Forbidden present: ${r.forbidden.join(", ")}`] : []),
      "", "Answer:", "", "> " + r.answer.replace(/\n/g, "\n> "), "",
      "<details><summary>Provider messages (effective input)</summary>", "", "```", r.providerMessages, "```", "", "</details>", "");
    console.log(`${r.met ? "met    " : "NOT MET"} ${r.id}  ${r.totalMs}ms  ${r.title ?? ""}${r.needs ? ` [needs ${r.needs}]` : ""}  ${r.missing.concat(r.forbidden).join(" ")}`);
  }
  if (options.out) {
    mkdirSync(options.out, { recursive: true });
    writeFileSync(join(options.out, `phone-regressions-${options.label}.md`), lines.join("\n"));
    writeFileSync(join(options.out, `phone-regressions-${options.label}.json`), JSON.stringify(results, null, 2));
  }
}

await main();
