// Replays requests captured from the app's real request builder (prompterTests/…/RequestReplayCaptureTests)
// against a backend, so the same bytes can be compared across prompt revisions with the same model.
//
// Usage:
//   node eval/topic-replay.mjs --dir <captured json dir> --base <url> --token <t> [--repeat 3] [--label x] [--out dir]
//
// Each check names what a correct answer to that request must and must not contain. Wording varies
// run to run, so the report counts how often each was met.

import { readFileSync, readdirSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

const JAVA_TOPIC = /\bJava\b(?!Script)(?:\s+(?:\d+|SE|versions?))?/;
const CHECKS = {
  "A-topic-change": { 1: { what: "Angular after an explicit topic change", must: [/Angular/i], mustNot: [JAVA_TOPIC], titleMust: /Angular/i } },
  "A-phone-intermediate-taps": {
    1: { what: "Tap while Angular (garbled) is being asked, 'And Java 10.' still unanswered before it", must: [/Angular/i], mustNot: [/Java versions/i, /which Java/i], titleMust: /Angular/i },
    2: { what: "Tap after the explicit 'not Java anymore'", must: [/Angular/i], mustNot: [JAVA_TOPIC], titleMust: /Angular/i },
  },
  "A-phone-transcript": { 1: { what: "Angular after the phone's topic change (garbled names, a late Java fragment)", must: [/Angular/i], mustNot: [JAVA_TOPIC], titleMust: /Angular/i } },
  "BCD-garbled-followup-newtopic": {
    0: { what: "Garbled names resolve to AngularJS vs Angular 2+", must: [/Angular ?JS|AngularJS|Angular 1/i, /Angular 2|Angular \(?2|Angular 2\+|version two|version 2/i],
         mustNot: [/not (?:a )?(?:recogni[sz]ed|standard|real|known)/i, /(?:question|request) (?:seems|appears) to be/i, /Iura/i] },
    1: { what: "'And the latest version?' stays on Angular and invents no release number", must: [/Angular/i], mustNot: [/Angular\s*v?(?:1[4-9]|2\d)\b/i, JAVA_TOPIC] },
    2: { what: "A genuinely new topic switches again", must: [/Kubernetes|rolling/i], mustNot: [/Angular/i] },
  },
  "E-old-page-and-chip": {
    2: { what: "Ordinary Generate on an old page answers the newest speech", must: [/rout/i, /Angular/i], mustNot: [JAVA_TOPIC] },
    3: { what: "A chip on the old Java page still targets Java", must: [/Java|lambda/i], mustNot: [/Angular/i] },
  },
};

function parseArguments(argv) {
  const options = { dir: "", base: "http://127.0.0.1:8787", token: "", repeat: "1", label: "run", out: "" };
  for (let index = 2; index < argv.length; index += 2) {
    const key = argv[index].replace(/^--/, "");
    if (key in options) options[key] = argv[index + 1];
  }
  return options;
}

async function send(body, { base, token }) {
  const requestID = randomUUID();
  const started = Date.now();
  const response = await fetch(`${base}/v1/copilot/answer`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ ...body, diagnosticsSessionID: "topic-replay", diagnosticsRequestID: requestID, captureProviderMessages: true }),
  });
  const raw = await response.text();
  const events = raw.split("\n").filter((l) => l.startsWith("data:")).map((l) => JSON.parse(l.slice(5)));
  const diagnostics = await fetch(`${base}/v1/copilot/diagnostics/${requestID}`, { headers: { authorization: `Bearer ${token}` } });
  return {
    status: response.status,
    ms: Date.now() - started,
    title: events.find((e) => e.type === "title")?.text ?? null,
    needs: events.find((e) => e.type === "needs")?.value ?? null,
    answer: events.filter((e) => e.type === "delta").map((e) => e.text).join("").trim(),
    providerMessages: diagnostics.ok ? (await diagnostics.json()).provider_messages : null,
  };
}

async function main() {
  const options = parseArguments(process.argv);
  const results = [];
  for (const file of readdirSync(options.dir).filter((f) => f.endsWith(".json")).sort()) {
    const { scenario, requests } = JSON.parse(readFileSync(join(options.dir, file), "utf8"));
    for (const [index, check] of Object.entries(CHECKS[scenario] ?? {})) {
      const body = requests[Number(index)].body;
      for (let round = 0; round < Number(options.repeat); round += 1) {
        const r = await send(body, options);
        const text = `${r.title ?? ""}\n${r.answer}`;
        const missing = check.must.filter((p) => !p.test(text)).map(String);
        const forbidden = check.mustNot.filter((p) => p.test(r.answer) || p.test(r.title ?? "")).map(String);
        if (check.titleMust && !check.titleMust.test(r.title ?? "")) missing.push(`title ${check.titleMust}`);
        results.push({ scenario, index: Number(index), round, what: check.what, met: !missing.length && !forbidden.length, missing, forbidden, ...r,
          newInput: body.newInput, requestedAction: body.requestedAction ?? null });
        console.log(`${!missing.length && !forbidden.length ? "met    " : "NOT MET"} ${scenario}#${index}  ${r.ms}ms  [${r.title}]  ${[...missing, ...forbidden].join(" ")}`);
      }
    }
  }
  if (options.out) {
    mkdirSync(options.out, { recursive: true });
    writeFileSync(join(options.out, `topic-replay-${options.label}.json`), JSON.stringify(results, null, 2));
    const lines = [`# Topic replay — ${options.label}`, "", `${new Date().toISOString()} · ${options.base} · ${results.filter((r) => r.met).length}/${results.length} met`, ""];
    for (const r of results) {
      lines.push(`## ${r.scenario} #${r.index} (round ${r.round}) — ${r.met ? "met" : "NOT met"}`, "", r.what, "",
        `- New input: ${JSON.stringify(r.newInput)}${r.requestedAction ? ` · tapped: ${r.requestedAction}` : ""}`,
        `- Title: ${r.title} · needs: ${r.needs ?? "-"} · ${r.ms} ms`,
        ...(r.missing.length || r.forbidden.length ? [`- Failed on: ${[...r.missing, ...r.forbidden].join(", ")}`] : []),
        "", "> " + r.answer.replace(/\n/g, "\n> "), "");
    }
    writeFileSync(join(options.out, `topic-replay-${options.label}.md`), lines.join("\n"));
  }
}

await main();
