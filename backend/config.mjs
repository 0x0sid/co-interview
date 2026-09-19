// Backend configuration for the copilot's text provider: profiles, precedence and validation.
//
// **Configuration is authoritative on the backend.** The iOS app never chooses a model, a provider
// route or an upstream URL; it asks for an answer and is told, in the response metadata, what
// actually served it.
//
// Precedence, lowest to highest (docs/CO_INTERVIEW_AI_PIPELINE.md §4):
//   1. built-in defaults
//   2. the selected profile
//   3. explicit operator overrides (environment variables)
//   4. development-only request overrides — refused unless COINTERVIEW_ALLOW_REQUEST_OVERRIDES=1,
//      and then still validated exactly like operator configuration. They exist for the benchmark
//      harness, which must pin one route per run.

import { OPENAI_MODELS, acceptsImages, knownRoutes, openRouterModel, routeCapability } from "./capabilities.mjs";

export class ConfigurationError extends Error {
  constructor(message) {
    super(message);
    this.name = "ConfigurationError";
    this.statusCode = 400;
  }
}

const GEMINI = "google/gemini-2.5-flash-lite";
const GEMINI_ROUTE = ["google-ai-studio"];

/**
 * Initial presets. **Profile names are product labels, not claims of measured superiority** — no
 * live benchmark has run yet, so "speed" and "smart" describe intent, not evidence.
 */
export const PROFILES = {
  speed: {
    answer_model_id: "nvidia/nemotron-3.5-lightning",
    answer_provider_order: ["coreweave/bf16"],
    detection_model_id: GEMINI,
    detection_provider_order: GEMINI_ROUTE,
    reasoning_enabled: false,
  },
  balanced: {
    answer_model_id: GEMINI,
    answer_provider_order: GEMINI_ROUTE,
    detection_model_id: GEMINI,
    detection_provider_order: GEMINI_ROUTE,
    reasoning_enabled: false,
  },
  smart: {
    answer_model_id: "deepseek/deepseek-v4.1-flash",
    // Wafer was the first preference until the catalogue stopped offering it for this model on
    // 2026-09-17 (see capabilities.mjs). The model is unchanged; only the route list is shorter.
    answer_provider_order: ["together"],
    detection_model_id: GEMINI,
    detection_provider_order: GEMINI_ROUTE,
    // DeepSeek reasons by default at "high" effort. Live answers must not, so this is switched off
    // explicitly with the parameter the model actually supports.
    reasoning_enabled: false,
  },
  custom: {},
};

const BUILT_IN_DEFAULTS = {
  text_provider: "openai",
  profile: "balanced",
  // Direct-OpenAI defaults, unchanged from the existing implementation.
  detection_model_id: "gpt-5.4-nano",
  detection_provider_order: [],
  answer_model_id: "gpt-5.4-mini",
  answer_provider_order: [],
  // Gateway-specific: filled in by `resolveConfig` once the gateway is known, because a Gemini id is
  // not a valid direct-OpenAI model and must never be sent to it.
  fallback_model_id: null,
  fallback_provider_order: [],
  allow_fallbacks: true,
  require_parameters: true,
  reasoning_enabled: false,
  reasoning_effort: null,
  max_output_tokens: 700,
  temperature: 0.3,
  // Detection-specific overrides, so changing answer length or temperature cannot quietly change how
  // the detector behaves.
  detection_max_output_tokens: 300,
  detection_temperature: 0,
  combined_detect_and_answer: false,
  pin_provider_during_benchmark: true,
  data_collection: "deny",
  zdr: false,
};

const BOOLEAN_KEYS = new Set([
  "allow_fallbacks", "require_parameters", "reasoning_enabled", "combined_detect_and_answer",
  "pin_provider_during_benchmark", "zdr",
]);
const NUMBER_KEYS = new Set(["max_output_tokens", "temperature", "detection_max_output_tokens", "detection_temperature"]);
const LIST_KEYS = new Set(["detection_provider_order", "answer_provider_order", "fallback_provider_order"]);

const ENV_KEYS = [
  "text_provider", "profile", "detection_model_id", "detection_provider_order", "answer_model_id",
  "answer_provider_order", "fallback_model_id", "fallback_provider_order", "allow_fallbacks",
  "require_parameters", "reasoning_enabled", "reasoning_effort", "max_output_tokens", "temperature",
  "detection_max_output_tokens", "detection_temperature", "combined_detect_and_answer",
  "pin_provider_during_benchmark", "data_collection", "zdr",
];

function coerce(key, raw) {
  if (raw === undefined || raw === null || raw === "") return undefined;
  if (BOOLEAN_KEYS.has(key)) {
    const value = String(raw).toLowerCase();
    if (["1", "true", "yes", "on"].includes(value)) return true;
    if (["0", "false", "no", "off"].includes(value)) return false;
    throw new ConfigurationError(`${key} must be a boolean (got "${raw}")`);
  }
  if (NUMBER_KEYS.has(key)) {
    const value = Number(raw);
    if (!Number.isFinite(value)) throw new ConfigurationError(`${key} must be a number (got "${raw}")`);
    return value;
  }
  if (LIST_KEYS.has(key)) {
    return Array.isArray(raw) ? raw.map(String) : String(raw).split(",").map((v) => v.trim()).filter(Boolean);
  }
  return raw;
}

/** Reads operator overrides from the environment (`COPILOT_` + upper-cased key). */
export function operatorOverridesFromEnv(env = process.env) {
  const overrides = {};
  for (const key of ENV_KEYS) {
    const value = env[`COPILOT_${key.toUpperCase()}`];
    const coerced = coerce(key, value);
    if (coerced !== undefined) overrides[key] = coerced;
  }
  return overrides;
}

/**
 * Resolves the effective configuration and validates it.
 * @throws {ConfigurationError} with an actionable message; never silently drops a requested capability.
 */
export function resolveConfig({ operator = {}, request = {}, allowRequestOverrides = false } = {}) {
  if (Object.keys(request).length && !allowRequestOverrides) {
    throw new ConfigurationError(
      "per-request configuration overrides are disabled; set COINTERVIEW_ALLOW_REQUEST_OVERRIDES=1 for local benchmarking"
    );
  }

  const profileName = request.profile ?? operator.profile ?? BUILT_IN_DEFAULTS.profile;
  if (!(profileName in PROFILES)) {
    throw new ConfigurationError(`unknown profile "${profileName}"; expected one of ${Object.keys(PROFILES).join(", ")}`);
  }

  const provider = request.text_provider ?? operator.text_provider ?? BUILT_IN_DEFAULTS.text_provider;
  if (!["openai", "openrouter"].includes(provider)) {
    throw new ConfigurationError(`text_provider must be "openai" or "openrouter" (got "${provider}")`);
  }

  // A profile's models are OpenRouter model ids. Applying them to direct OpenAI would send an
  // invalid identifier upstream, so profiles only contribute when the gateway is OpenRouter.
  const profile = provider === "openrouter" ? PROFILES[profileName] : {};
  // The fallback route defaults per gateway. On direct OpenAI there is no second model configured,
  // so `fallback_model_id` equals the answer model and no application-level fallback attempt is made
  // — the existing direct-OpenAI behaviour, unchanged.
  const gatewayDefaults = provider === "openrouter"
    ? { fallback_model_id: GEMINI, fallback_provider_order: GEMINI_ROUTE }
    : { fallback_model_id: BUILT_IN_DEFAULTS.answer_model_id, fallback_provider_order: [] };
  const config = {
    ...BUILT_IN_DEFAULTS, ...gatewayDefaults, ...profile, ...operator, ...request,
    profile: profileName, text_provider: provider,
  };
  if (!config.fallback_model_id) config.fallback_model_id = config.answer_model_id;

  for (const [key, value] of Object.entries(config)) {
    if (LIST_KEYS.has(key) && !Array.isArray(value)) config[key] = coerce(key, value) ?? [];
  }

  validate(config);
  return config;
}

function validate(config) {
  const isOpenRouter = config.text_provider === "openrouter";

  if (config.combined_detect_and_answer) {
    throw new ConfigurationError(
      "combined_detect_and_answer is not implemented; detection and answering are separate calls in this build"
    );
  }

  if (config.max_output_tokens <= 0 || config.detection_max_output_tokens <= 0) {
    throw new ConfigurationError("max_output_tokens and detection_max_output_tokens must be positive");
  }
  for (const key of ["temperature", "detection_temperature"]) {
    if (config[key] < 0 || config[key] > 2) throw new ConfigurationError(`${key} must be between 0 and 2`);
  }
  if (!["allow", "deny"].includes(config.data_collection)) {
    throw new ConfigurationError('data_collection must be "allow" or "deny"');
  }

  for (const role of ["detection", "answer", "fallback"]) {
    const modelID = config[`${role}_model_id`];
    const order = config[`${role}_provider_order`] ?? [];
    if (!modelID) throw new ConfigurationError(`${role}_model_id is required`);

    if (!isOpenRouter) {
      // Direct OpenAI: reject OpenRouter-style ids rather than passing them upstream.
      if (modelID.includes("/")) {
        throw new ConfigurationError(
          `${role}_model_id "${modelID}" looks like an OpenRouter model id, but text_provider is "openai". ` +
          `Set text_provider=openrouter, or use one of: ${Object.keys(OPENAI_MODELS).join(", ")}`
        );
      }
      if (order.length) {
        throw new ConfigurationError(`${role}_provider_order is only meaningful when text_provider is "openrouter"`);
      }
      if (!OPENAI_MODELS[modelID]) {
        throw new ConfigurationError(
          `${role}_model_id "${modelID}" is not a verified direct-OpenAI model; expected ${Object.keys(OPENAI_MODELS).join(", ")}`
        );
      }
      continue;
    }

    const model = openRouterModel(modelID);
    if (!model) {
      throw new ConfigurationError(
        `${role}_model_id "${modelID}" is not in the verified OpenRouter registry. ` +
        "Add it to capabilities.mjs after checking it with tools/verify-routes.mjs."
      );
    }
    for (const slug of order) {
      if (!routeCapability(modelID, slug)) {
        throw new ConfigurationError(
          `${role}_provider_order contains "${slug}", which is not a route for ${modelID}. ` +
          `Known routes: ${knownRoutes(modelID).join(", ")}. ` +
          "Display names such as \"CoreWeave\" or \"Google AI Studio\" are not routing slugs."
        );
      }
    }
    // Detection needs enforced JSON: a route that cannot do it is incompatible, not something to
    // paper over with a lenient parser.
    if (role === "detection") {
      const routes = order.length ? order : Object.keys(model.routes);
      const incapable = routes.filter((slug) => routeCapability(modelID, slug)?.structuredOutputs !== true);
      if (incapable.length) {
        throw new ConfigurationError(
          `detection requires enforced structured output, but ${incapable.join(", ")} ` +
          `${incapable.length === 1 ? "does" : "do"} not support it for ${modelID}. ` +
          "Pin a route that does, or choose a different detection model."
        );
      }
      if (!config.require_parameters) {
        throw new ConfigurationError(
          "detection requires require_parameters=true so a route without structured-output support cannot serve it"
        );
      }
    }
    if (config.reasoning_enabled && config.reasoning_effort) {
      if (!model.supportedEfforts.includes(config.reasoning_effort)) {
        throw new ConfigurationError(
          `reasoning_effort "${config.reasoning_effort}" is not supported by ${modelID}` +
          (model.supportedEfforts.length
            ? `; supported: ${model.supportedEfforts.join(", ")}`
            : "; this model exposes no effort selection, so only reasoning_enabled applies")
        );
      }
    }
    const maxOut = Math.min(...(order.length ? order : Object.keys(model.routes))
      .map((slug) => routeCapability(modelID, slug)?.maxCompletionTokens ?? Infinity));
    const requested = role === "detection" ? config.detection_max_output_tokens : config.max_output_tokens;
    if (Number.isFinite(maxOut) && requested > maxOut) {
      throw new ConfigurationError(`${role} max output tokens ${requested} exceeds the route limit of ${maxOut} for ${modelID}`);
    }
  }
}

/**
 * Translates the application's reasoning intent into the provider's documented parameters.
 *
 * **Disabling reasoning is not the same as hiding it.** `exclude: true` still reasons and still
 * bills; `effort: "none"` disables it but is not accepted by every model (DeepSeek V4.1 Flash
 * supports only max/high/low and reasons by default). `reasoning: {enabled: false}` is what works
 * across all three profile models, so that is what this sends.
 */
export function reasoningParameter(config, modelID) {
  if (config.text_provider === "openai") {
    return { effort: config.reasoning_enabled ? (config.reasoning_effort ?? "low") : "none" };
  }
  if (!config.reasoning_enabled) return { enabled: false };
  const model = openRouterModel(modelID);
  if (config.reasoning_effort && model?.supportedEfforts.includes(config.reasoning_effort)) {
    return { effort: config.reasoning_effort };
  }
  return { enabled: true };
}

/**
 * Builds OpenRouter's `provider` routing object.
 *
 * **An ordered list is not an allowlist.** `order` expresses preference; without `only` (or
 * `allow_fallbacks: false`) OpenRouter may still serve the request from a provider that is not in
 * the list. Benchmarks therefore pin with `only` *and* disable fallbacks, so a run that cannot use
 * the pinned route fails loudly instead of quietly measuring something else.
 */
export function providerRouting(config, order, { benchmark = false } = {}) {
  const routing = {
    require_parameters: config.require_parameters,
    data_collection: config.data_collection,
  };
  if (config.zdr) routing.zdr = true;

  if (benchmark && config.pin_provider_during_benchmark) {
    if (order.length !== 1) {
      throw new ConfigurationError(
        `benchmark mode pins exactly one route, but ${order.length} were configured (${order.join(", ") || "none"})`
      );
    }
    routing.only = [order[0]];
    routing.allow_fallbacks = false;
    return routing;
  }

  if (order.length) routing.order = order;
  routing.allow_fallbacks = config.allow_fallbacks;
  // With fallbacks disabled, the ordered list becomes the exclusive permitted set.
  if (!config.allow_fallbacks && order.length) routing.only = order;
  return routing;
}

/** The non-secret view of configuration, safe to return to an authenticated client. */
export function publicConfig(config) {
  return {
    text_provider: config.text_provider,
    profile: config.profile,
    detection_model_id: config.detection_model_id,
    detection_provider_order: config.detection_provider_order,
    answer_model_id: config.answer_model_id,
    answer_provider_order: config.answer_provider_order,
    fallback_model_id: config.fallback_model_id,
    fallback_provider_order: config.fallback_provider_order,
    allow_fallbacks: config.allow_fallbacks,
    require_parameters: config.require_parameters,
    reasoning_enabled: config.reasoning_enabled,
    reasoning_effort: config.reasoning_effort,
    max_output_tokens: config.max_output_tokens,
    temperature: config.temperature,
    combined_detect_and_answer: config.combined_detect_and_answer,
    pin_provider_during_benchmark: config.pin_provider_during_benchmark,
    // So the app can ask rather than assume. The answer model decides: attachments travel with the
    // answer request, not the detector's.
    answer_accepts_images: acceptsImages(config.answer_model_id),
  };
}
