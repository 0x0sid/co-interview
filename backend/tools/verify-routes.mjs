// Re-verifies `capabilities.mjs` against the live OpenRouter catalogue.
//
// The registry is a snapshot taken on 2026-09-16; models, routes and parameter support change, and a
// stale slug fails silently (a request that was meant to be pinned is simply served elsewhere). Run
// this before trusting a profile, and after changing one.
//
// No credential required: the catalogue endpoints are public.
//   node tools/verify-routes.mjs

import { OPENROUTER_MODELS } from "../capabilities.mjs";

const BASE = process.env.OPENROUTER_BASE ?? "https://openrouter.ai/api/v1";
let problems = 0;

const note = (ok, message) => {
  if (!ok) problems += 1;
  console.log(`  ${ok ? "ok  " : "DIFF"} ${message}`);
};

for (const [modelID, expected] of Object.entries(OPENROUTER_MODELS)) {
  console.log(`\n${modelID}`);
  const response = await fetch(`${BASE}/models/${modelID}/endpoints`);
  if (!response.ok) {
    note(false, `catalogue lookup failed: HTTP ${response.status} — the model may have been withdrawn`);
    continue;
  }
  const data = (await response.json()).data ?? {};
  const live = new Map((data.endpoints ?? []).map((endpoint) => [endpoint.tag, endpoint]));

  for (const [slug, route] of Object.entries(expected.routes)) {
    const endpoint = live.get(slug);
    if (!endpoint) {
      note(false, `route "${slug}" (${route.providerName}) is no longer offered for this model`);
      continue;
    }
    const supported = endpoint.supported_parameters ?? [];
    note(
      supported.includes("structured_outputs") === route.structuredOutputs,
      `route "${slug}" structured outputs: registry=${route.structuredOutputs} live=${supported.includes("structured_outputs")}`
    );
    note(
      (endpoint.max_completion_tokens ?? 0) >= route.maxCompletionTokens,
      `route "${slug}" max completion tokens: registry=${route.maxCompletionTokens} live=${endpoint.max_completion_tokens}`
    );
  }

  const model = (await (await fetch(`${BASE}/models`)).json()).data.find((entry) => entry.id === modelID);
  const efforts = model?.reasoning?.supported_efforts ?? [];
  note(
    JSON.stringify(efforts) === JSON.stringify(expected.supportedEfforts),
    `reasoning efforts: registry=${JSON.stringify(expected.supportedEfforts)} live=${JSON.stringify(efforts)}`
  );
  note(
    Boolean(model?.reasoning?.default_enabled) === expected.reasoningDefaultEnabled,
    `reasoning on by default: registry=${expected.reasoningDefaultEnabled} live=${Boolean(model?.reasoning?.default_enabled)}`
  );
}

console.log(
  problems === 0
    ? "\nRegistry matches the live catalogue."
    : `\n${problems} difference(s) — update capabilities.mjs before relying on these routes.`
);
process.exit(problems === 0 ? 0 : 1);
