// Answer-quality evaluation harness.
//
// Sends the *exact* body shape the iOS app sends to /answer, against the real provider through the
// running local backend, and records what comes back. Synthetic content only.
//
// Usage: node answer-eval.mjs <cases.json> <out.md>

import { readFileSync, writeFileSync, existsSync } from "node:fs";

// The client token is read from the git-ignored backend/.env, or from the environment. It is never
// printed, never written into a result file, and never passed on a command line.
const envPath = new URL("../../../backend/.env", import.meta.url);
const fromFile = existsSync(envPath)
  ? readFileSync(envPath, "utf8").match(/^COINTERVIEW_TOKENS=(.+)$/m)?.[1]
  : undefined;
const token = (process.env.COINTERVIEW_TOKENS ?? fromFile ?? "").split(",")[0].trim();
if (!token) {
  console.error("no client token: set COINTERVIEW_TOKENS, or put it in backend/.env");
  process.exit(1);
}

const BASE = process.env.EVAL_BASE ?? "http://127.0.0.1:8787";
const cases = JSON.parse(readFileSync(process.argv[2], "utf8"));
const outPath = process.argv[3];

async function runCase(testCase) {
  const started = Date.now();
  let firstTextMs = null;
  let text = "";
  const events = [];

  const response = await fetch(`${BASE}/v1/copilot/answer`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify(testCase.body),
  });

  if (!response.ok) {
    return { ...testCase, httpStatus: response.status, text: await response.text(), firstTextMs: null };
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let index;
    while ((index = buffer.indexOf("\n\n")) >= 0) {
      const line = buffer.slice(0, index).trim();
      buffer = buffer.slice(index + 2);
      if (!line.startsWith("data: ")) continue;
      const event = JSON.parse(line.slice(6));
      if (event.type === "delta") {
        if (firstTextMs === null) firstTextMs = Date.now() - started;
        text += event.text;
      } else {
        events.push(event);
      }
    }
  }
  return { ...testCase, httpStatus: 200, text, firstTextMs, events, totalMs: Date.now() - started };
}

const results = [];
for (const testCase of cases) {
  process.stderr.write(`running ${testCase.id}…\n`);
  try {
    results.push(await runCase(testCase));
  } catch (error) {
    results.push({ ...testCase, error: String(error) });
  }
}

const words = (value) => value.trim().split(/\s+/).filter(Boolean).length;
const lines = [`# Answer evaluation — ${new Date().toISOString()}`, ""];
for (const result of results) {
  lines.push(`## ${result.id} — ${result.title}`);
  lines.push("");
  lines.push(`**Question sent:** \`${result.body.question.replace(/\n/g, " / ")}\``);
  lines.push(`**Passages sent:** ${result.body.passages?.length ?? 0} · **Instructions sent:** ${result.body.projectInstructions ? `${words(result.body.projectInstructions)} words` : "(none)"}`);
  lines.push(`**Conversation sent:** ${(result.body.recentConversation ?? []).map((l) => `"${l}"`).join(" → ") || "(none)"}`);
  lines.push("");
  if (result.error || result.httpStatus !== 200) {
    lines.push("```");
    lines.push(`FAILED: ${result.error ?? `HTTP ${result.httpStatus}`}`);
    lines.push(String(result.text ?? "").slice(0, 500));
    lines.push("```");
  } else {
    lines.push(`**First visible text:** ${result.firstTextMs} ms · **Complete:** ${result.totalMs} ms · **Length:** ${words(result.text)} words`);
    const sources = result.events.find((e) => e.type === "sources");
    if (sources) lines.push(`**Sources claimed:** ${sources.ids?.join(", ") || "none"}`);
    lines.push("");
    lines.push("```");
    lines.push(result.text.trim());
    lines.push("```");
  }
  lines.push("");
}
writeFileSync(outPath, lines.join("\n"));
process.stderr.write(`wrote ${outPath}\n`);
