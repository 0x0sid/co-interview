// Verified capability registry for the OpenRouter routes this backend is allowed to use.
//
// **Every value here was read from the live OpenRouter catalogue on 2026-09-16** —
// `GET /api/v1/models`, `GET /api/v1/models/:author/:slug/endpoints` and `GET /api/v1/providers` —
// not from display names or documentation prose. Re-verify with `node tools/verify-routes.mjs`
// before trusting it; routes and their parameter support change.
//
// Two facts in here are load-bearing and easy to get wrong:
//
//  1. **Routing slugs are not display names.** "CoreWeave" routes as `coreweave/bf16`, "Google AI
//     Studio" as `google-ai-studio`, "Wafer" as `wafer`, "Together" as `together`. A display name
//     sent as a slug silently fails to pin anything.
//  2. **Disabling reasoning is per model.** `deepseek/deepseek-v4.1-flash` has reasoning *on by
//     default* (`default_enabled: true`) and its supported efforts are `max|high|low` — `"none"` is
//     not among them, so `effort: "none"` cannot be used to switch it off. `reasoning: {enabled:
//     false}` is the lever that works for all three models. `exclude: true` is **not** a way to
//     disable reasoning: the documentation is explicit that the model still reasons and is still
//     billed; it only hides the trace.

export const OPENROUTER_MODELS = {
  "nvidia/nemotron-3.5-lightning": {
    // Input modalities verified against OpenRouter's live catalogue on 2026-09-19
    // (GET /api/v1/models -> architecture.input_modalities). Never assumed: sending an image to a
    // text-only model would be silently ignored upstream while the app implied it had been read.
    inputModalities: ["text"],
    displayName: "NVIDIA: Nemotron 3.5 Lightning",
    contextLength: 262144,
    // No `supported_efforts` in the model's reasoning block → the model exposes no effort selection.
    supportedEfforts: [],
    reasoningDefaultEnabled: false,
    routes: {
      "coreweave/bf16": { providerName: "CoreWeave", structuredOutputs: true, maxCompletionTokens: 235929, cancellationStopsBilling: true },
      "darkbloom/int4": { providerName: "Darkbloom", structuredOutputs: true, maxCompletionTokens: 32768, cancellationStopsBilling: null },
      "phala": { providerName: "Phala", structuredOutputs: true, maxCompletionTokens: 235929, cancellationStopsBilling: null },
      "deepinfra/bf16": { providerName: "DeepInfra", structuredOutputs: true, maxCompletionTokens: 131072, cancellationStopsBilling: true },
    },
  },
  "google/gemini-2.5-flash-lite": {
    // Verified 2026-09-19: text, image, file, audio and video in; text out.
    inputModalities: ["text", "image", "file", "audio", "video"],
    displayName: "Google: Gemini 2.5 Flash Lite",
    contextLength: 1048576,
    supportedEfforts: [],
    reasoningDefaultEnabled: false,
    routes: {
      // Documented under "Stream cancellation": Google and Google AI Studio are listed as **not**
      // supporting cancellation, so aborting mid-stream does not necessarily stop provider
      // computation or billing on this route.
      "google-ai-studio": { providerName: "Google AI Studio", structuredOutputs: true, maxCompletionTokens: 65535, cancellationStopsBilling: false },
      "google-ai-studio/flex": { providerName: "Google AI Studio (flex)", structuredOutputs: true, maxCompletionTokens: 65535, cancellationStopsBilling: false },
      "google-ai-studio/priority": { providerName: "Google AI Studio (priority)", structuredOutputs: true, maxCompletionTokens: 65535, cancellationStopsBilling: false },
      "google-vertex": { providerName: "Google", structuredOutputs: true, maxCompletionTokens: 65535, cancellationStopsBilling: false },
    },
  },
  "deepseek/deepseek-v4.1-flash": {
    // Verified 2026-09-19.
    inputModalities: ["text", "image"],
    displayName: "DeepSeek: DeepSeek V4.1 Flash",
    contextLength: 1048576,
    supportedEfforts: ["max", "high", "low"],
    // Reasoning is ON unless switched off — the reason the "smart" profile must disable it explicitly.
    reasoningDefaultEnabled: true,
    routes: {
      // **Wafer was withdrawn for this model between 2026-09-16 and 2026-09-17.** It was verified
      // present on the 16th and `tools/verify-routes.mjs` caught its disappearance the next day —
      // which is the whole reason that tool exists. Re-add it only if the catalogue offers it again.
      "together": { providerName: "Together", structuredOutputs: true, maxCompletionTokens: 943718, cancellationStopsBilling: true },
      "fireworks": { providerName: "Fireworks", structuredOutputs: true, maxCompletionTokens: 943718, cancellationStopsBilling: true },
      "deepinfra/fp8": { providerName: "DeepInfra", structuredOutputs: true, maxCompletionTokens: 131072, cancellationStopsBilling: true },
      // Present on the model but **without** structured-output support: usable for answers, refused
      // for detection.
      "deepseek": { providerName: "DeepSeek", structuredOutputs: false, maxCompletionTokens: 384000, cancellationStopsBilling: true },
      "novita/fp8": { providerName: "Novita", structuredOutputs: false, maxCompletionTokens: 393216, cancellationStopsBilling: true },
    },
  },
};

/** Direct OpenAI models, verified 2026-09-16 (see docs/CO_INTERVIEW_AI_PIPELINE.md §2). */
export const OPENAI_MODELS = {
  "gpt-5.4-nano": { structuredOutputs: true, supportedEfforts: ["none", "low", "medium", "high", "xhigh"], inputModalities: ["text", "image"] },
  "gpt-5.4-mini": { structuredOutputs: true, supportedEfforts: ["none", "low", "medium", "high", "xhigh"], inputModalities: ["text", "image"] },
};

export function openRouterModel(modelID) {
  return OPENROUTER_MODELS[modelID] ?? null;
}

export function routeCapability(modelID, routeSlug) {
  const model = openRouterModel(modelID);
  if (!model) return null;
  if (model.routes[routeSlug]) return model.routes[routeSlug];
  // A base slug matches every variant of that provider ("google-ai-studio" covers
  // "google-ai-studio/flex"), which the routing documentation states explicitly.
  const variants = Object.entries(model.routes).filter(([slug]) => slug.split("/")[0] === routeSlug);
  if (!variants.length) return null;
  return {
    providerName: variants[0][1].providerName,
    // A base slug is only as capable as its weakest variant, because any of them may serve.
    structuredOutputs: variants.every(([, route]) => route.structuredOutputs),
    maxCompletionTokens: Math.min(...variants.map(([, route]) => route.maxCompletionTokens)),
    cancellationStopsBilling: variants.every(([, route]) => route.cancellationStopsBilling === true)
      ? true
      : variants.some(([, route]) => route.cancellationStopsBilling === false)
        ? false
        : null,
  };
}

/** Human-readable list for error messages, so an operator can fix a typo without reading the source. */
/**
 * Whether a model accepts image input, from the verified registry above.
 *
 * Unknown models answer `false`. That is the safe direction: refusing to send an image the model
 * might have understood is a missing feature, while sending one it cannot read would be silently
 * dropped upstream and reported to the user as understood.
 */
export function acceptsImages(modelID) {
  const entry = OPENROUTER_MODELS[modelID] ?? OPENAI_MODELS[modelID];
  return Boolean(entry?.inputModalities?.includes("image"));
}

export function knownRoutes(modelID) {
  const model = openRouterModel(modelID);
  return model ? Object.keys(model.routes) : [];
}
