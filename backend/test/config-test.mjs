// Configuration precedence, profile resolution, validation, and the reasoning/routing translation.
// Pure unit tests: no servers, no network, no credentials.

import { resolveConfig, reasoningParameter, providerRouting, PROFILES, ConfigurationError } from "../config.mjs";

let failures = 0;
const check = (label, condition, detail = "") => {
  if (condition) console.log(`  ok   ${label}`);
  else { failures += 1; console.log(`  FAIL ${label} ${detail}`); }
};
const throws = (label, fn, expected) => {
  try {
    fn();
    failures += 1;
    console.log(`  FAIL ${label} (no error thrown)`);
  } catch (error) {
    const ok = error instanceof ConfigurationError && (!expected || error.message.includes(expected));
    if (ok) console.log(`  ok   ${label}`);
    else { failures += 1; console.log(`  FAIL ${label} — ${error.message}`); }
  }
};

console.log("defaults and precedence");
{
  const config = resolveConfig({});
  check("defaults to direct OpenAI", config.text_provider === "openai");
  check("keeps the existing OpenAI models", config.answer_model_id === "gpt-5.4-mini" && config.detection_model_id === "gpt-5.4-nano");
  check("reasoning is off for live answers", config.reasoning_enabled === false);
  check("combined detect+answer is off by default", config.combined_detect_and_answer === false);
  check("benchmark pinning is on by default", config.pin_provider_during_benchmark === true);

  // Profile beats built-in defaults; operator beats profile.
  const balanced = resolveConfig({ operator: { text_provider: "openrouter", profile: "balanced" } });
  check("profile supplies the answer model", balanced.answer_model_id === "google/gemini-2.5-flash-lite");
  const overridden = resolveConfig({
    operator: { text_provider: "openrouter", profile: "balanced", answer_model_id: "nvidia/nemotron-3.5-lightning", answer_provider_order: ["coreweave/bf16"] },
  });
  check("operator override beats the profile", overridden.answer_model_id === "nvidia/nemotron-3.5-lightning");

  // Request overrides are refused unless explicitly enabled, then still validated.
  throws("request overrides refused by default", () => resolveConfig({ request: { profile: "speed" } }), "overrides are disabled");
  const dev = resolveConfig({
    operator: { text_provider: "openrouter" },
    request: { profile: "speed" },
    allowRequestOverrides: true,
  });
  check("request override beats operator when enabled", dev.answer_model_id === "nvidia/nemotron-3.5-lightning");
}

console.log("profiles");
{
  for (const [name, expectedModel] of [["speed", "nvidia/nemotron-3.5-lightning"], ["balanced", "google/gemini-2.5-flash-lite"], ["smart", "deepseek/deepseek-v4.1-flash"]]) {
    const config = resolveConfig({ operator: { text_provider: "openrouter", profile: name } });
    check(`${name} resolves ${expectedModel}`, config.answer_model_id === expectedModel, config.answer_model_id);
    check(`${name} disables reasoning`, config.reasoning_enabled === false);
    check(`${name} detects with Gemini Flash-Lite`, config.detection_model_id === "google/gemini-2.5-flash-lite");
  }
  check("speed pins CoreWeave by its routing slug, not its display name",
    PROFILES.speed.answer_provider_order[0] === "coreweave/bf16");
  // Wafer was withdrawn for this model on 2026-09-17; Together was always the next preference.
  check("smart routes DeepSeek through Together", String(PROFILES.smart.answer_provider_order) === "together");
  check("a withdrawn route is no longer accepted", (() => {
    try {
      resolveConfig({ operator: { text_provider: "openrouter", profile: "smart", answer_provider_order: ["wafer"] } });
      return false;
    } catch (error) { return error instanceof ConfigurationError && error.message.includes("not a route"); }
  })());
  check("fallback is Gemini via Google AI Studio",
    resolveConfig({ operator: { text_provider: "openrouter" } }).fallback_provider_order[0] === "google-ai-studio");
}

console.log("validation");
{
  throws("rejects an OpenRouter model id on the OpenAI gateway",
    () => resolveConfig({ operator: { text_provider: "openai", answer_model_id: "google/gemini-2.5-flash-lite" } }),
    "looks like an OpenRouter model id");
  throws("rejects provider order on the OpenAI gateway",
    () => resolveConfig({ operator: { text_provider: "openai", answer_provider_order: ["coreweave/bf16"] } }),
    "only meaningful when text_provider");
  throws("rejects a display name used as a routing slug",
    () => resolveConfig({ operator: {
      text_provider: "openrouter", profile: "balanced",
      answer_model_id: "nvidia/nemotron-3.5-lightning",
      // "CoreWeave" is the display name; the routing slug is "coreweave/bf16".
      answer_provider_order: ["CoreWeave"],
    } }),
    "not a route");
  throws("rejects an unknown model",
    () => resolveConfig({ operator: { text_provider: "openrouter", profile: "custom", answer_model_id: "acme/not-a-model" } }),
    "not in the verified OpenRouter registry");
  throws("rejects a detection route that cannot enforce structured output",
    () => resolveConfig({ operator: { text_provider: "openrouter", profile: "custom", detection_model_id: "deepseek/deepseek-v4.1-flash", detection_provider_order: ["deepseek"], answer_model_id: "deepseek/deepseek-v4.1-flash", answer_provider_order: ["wafer"], fallback_model_id: "google/gemini-2.5-flash-lite", fallback_provider_order: ["google-ai-studio"] } }),
    "requires enforced structured output");
  // Effort applies to every configured model, so a model that cannot take it is refused rather than
  // having the setting silently dropped for that role.
  throws("rejects an effort the model does not support",
    () => resolveConfig({ operator: { text_provider: "openrouter", profile: "smart", reasoning_enabled: true, reasoning_effort: "none" } }),
    "not supported by");
  throws("rejects an effort on a model with no effort selection",
    () => resolveConfig({ operator: { text_provider: "openrouter", profile: "balanced", reasoning_enabled: true, reasoning_effort: "low" } }),
    "exposes no effort selection");
  throws("rejects combined detect+answer as unimplemented",
    () => resolveConfig({ operator: { combined_detect_and_answer: true } }),
    "not implemented");
  throws("rejects an unknown profile", () => resolveConfig({ operator: { profile: "turbo" } }), "unknown profile");
  throws("rejects output tokens beyond the route limit",
    () => resolveConfig({ operator: { text_provider: "openrouter", profile: "balanced", max_output_tokens: 99999 } }),
    "exceeds the route limit");
}

console.log("reasoning translation");
{
  const smart = resolveConfig({ operator: { text_provider: "openrouter", profile: "smart" } });
  const parameter = reasoningParameter(smart, smart.answer_model_id);
  // DeepSeek reasons by default and does not accept effort "none", so `enabled: false` is the lever.
  check("disables DeepSeek reasoning with enabled:false", parameter.enabled === false, JSON.stringify(parameter));
  check("never uses exclude, which hides reasoning but still bills it", parameter.exclude === undefined);

  const speed = resolveConfig({ operator: { text_provider: "openrouter", profile: "speed" } });
  check("disables Nemotron reasoning the same way", reasoningParameter(speed, speed.answer_model_id).enabled === false);

  const withEffort = resolveConfig({ operator: {
    text_provider: "openrouter", profile: "custom",
    detection_model_id: "deepseek/deepseek-v4.1-flash", detection_provider_order: ["together"],
    answer_model_id: "deepseek/deepseek-v4.1-flash", answer_provider_order: ["together"],
    fallback_model_id: "deepseek/deepseek-v4.1-flash", fallback_provider_order: ["together"],
    reasoning_enabled: true, reasoning_effort: "low", max_output_tokens: 700,
  } });
  check("passes a supported effort through", reasoningParameter(withEffort, withEffort.answer_model_id).effort === "low");

  const openaiConfig = resolveConfig({});
  check("maps to effort none on direct OpenAI", reasoningParameter(openaiConfig, openaiConfig.answer_model_id).effort === "none");
}

console.log("routing");
{
  const config = resolveConfig({ operator: { text_provider: "openrouter", profile: "smart" } });
  const production = providerRouting(config, config.answer_provider_order);
  check("ordered routing keeps the configured order", String(production.order) === "together");
  check("production allows provider fallback by default", production.allow_fallbacks === true);
  check("requires parameter support", production.require_parameters === true);
  check("denies data-collecting providers", production.data_collection === "deny");

  const pinned = providerRouting(config, ["together"], { benchmark: true });
  check("benchmark pins with only", String(pinned.only) === "together");
  check("benchmark disables provider fallback", pinned.allow_fallbacks === false);
  check("benchmark does not send an order list", pinned.order === undefined);

  try {
    providerRouting(config, ["together", "fireworks"], { benchmark: true });
    failures += 1;
    console.log("  FAIL benchmark refuses more than one pinned route (no error)");
  } catch (error) {
    check("benchmark refuses more than one pinned route", error instanceof ConfigurationError);
  }

  const exclusive = resolveConfig({ operator: { text_provider: "openrouter", profile: "smart", allow_fallbacks: false } });
  const restricted = providerRouting(exclusive, exclusive.answer_provider_order);
  // An ordered list alone is a preference, not an allowlist: with fallbacks off it must also be `only`.
  check("fallbacks off turns the order into an allowlist", String(restricted.only) === "together");
  check("fallbacks off disables upstream fallback", restricted.allow_fallbacks === false);
}

console.log(failures === 0 ? "\nAll configuration checks passed." : `\n${failures} configuration check(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);
