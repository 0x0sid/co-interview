// Jev (TypeSafe System One) — typed decisions, never generated text. Two transports, one contract.
//
// **OpenRouter (default).** Verified against openrouter.ai/docs on 2026-09-24 (guides/community/jev,
// jev-tutorial, api-reference/alphadecisions): `POST https://openrouter.ai/api/alpha/decisions` with
// the existing `OPENROUTER_API_KEY` as a bearer token — no TypeSafe account. Same `{ model, state,
// questions }` body and the same answer shapes as TypeSafe's own API, plus `id`, `provider` and
// `usage.cost` (USD) in the response. Model ids: `typesafe/jev-1.13`, alias `~typesafe/jev-latest`; the
// response names the dated snapshot that answered (`typesafe/jev-1.13-20260917` on 2026-09-24), and that
// dated id is itself accepted as a model — verified with a real call — so it is the pinned default.
// 32k-token context. Errors: 400, 401, 402 (credits), 403, 404, 408, 429, 500, 502, 503, 524 (edge
// timeout), 529 (overloaded), with `{ error: { code, message } }` bodies.
//
// **TypeSafe direct (optional).** Verified against the official documentation on 2026-09-24 (docs.typesafe.ai: /api, /models,
// /confidence, /model-jaggedness/jev-1.13, /sdk/javascript):
//
// - One endpoint: `POST https://api.typesafe.ai/v1/systemone`, `Authorization: Bearer <key>`.
// - Body: `{ state, model, questions }`. `questions` is a map of id → `{ type, instructions, criteria }`
//   where type is "choice" (criteria: option → description, ≤255 options), "noul" (yes/no) or
//   "score". Every question sees the same state and is evaluated **independently** — one answer
//   cannot read another's, so dependent decisions must not share a call.
// - Response: `{ model, answers: { id: {type, choice, probabilities, confidence} | {type, noul} },
//   usage: { input_tokens, output_tokens } }`. `model` names the versioned model that answered.
// - `jev-latest` → `jev-1.13.0` on the verification date. Pricing is per input token ($0.042 / Mtok
//   for jev-1.13.0); output tokens are free. Context: 64k tokens per request, 32k for the state plus
//   the longest question.
// - Errors: 401 bad key, 422 validation, 429 rate limit, 529 overloaded (retry with backoff).
// - `confidence` on a Choice is derived from how peaked the distribution is. It is **not** a
//   calibrated accuracy percentage, and the documentation says thresholds must be tuned per use.
// - No server-side timeout is documented; every call here carries its own deadline.
//
// The official JavaScript SDK (`@typesafe-ai/sdk`, v0.6.0) wraps this same endpoint. It is not used:
// the backend has no third-party dependencies (see server.mjs), and the HTTP contract is four fields.

export const TYPESAFE_BASE = "https://api.typesafe.ai";
export const OPENROUTER_DECISIONS_BASE = "https://openrouter.ai/api";

/** Where each transport's decision endpoint lives, relative to its base. */
export const TRANSPORTS = {
  openrouter: { path: "/alpha/decisions", defaultBase: OPENROUTER_DECISIONS_BASE, defaultModel: "typesafe/jev-1.13-20260917" },
  typesafe: { path: "/v1/systemone", defaultBase: TYPESAFE_BASE, defaultModel: "jev-1.13.0" },
};

/** Published input price for jev-1.13.0, USD per input token. Output tokens are free. */
export const PRICE_PER_INPUT_TOKEN_USD = {
  "jev-1.13.0": 0.042 / 1_000_000,
};

const RETRYABLE = new Set([408, 429, 500, 502, 503, 504, 524, 529]);

/**
 * Evaluates typed questions against one state, with a hard deadline and bounded retries.
 *
 * Never throws for an upstream or network failure: the caller is a shadow comparison or a fallback
 * path, and both need a result object describing what happened rather than an exception.
 *
 * @returns {{ ok: true, model, answers, usage, attempts, latencyMs }
 *         | { ok: false, reason, status, message, attempts, latencyMs }}
 */
export async function evaluate({
  apiKey,
  transport = "typesafe",
  base,
  model,
  state,
  questions,
  timeoutMs = 2500,
  maxAttempts = 2,
  retryDelayMs = 200,
  signal,
  fetchImpl = fetch,
  now = () => Date.now(),
}) {
  const route = TRANSPORTS[transport] ?? TRANSPORTS.typesafe;
  const url = `${base ?? route.defaultBase}${route.path}`;
  const started = now();
  const deadline = started + timeoutMs;
  let attempts = 0;
  let last = { reason: "not_attempted", status: null, message: "" };

  while (attempts < maxAttempts) {
    const remaining = deadline - now();
    if (remaining <= 0) {
      last = { reason: "timeout", status: null, message: `no answer within ${timeoutMs}ms` };
      break;
    }
    attempts += 1;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), remaining);
    const onOuterAbort = () => controller.abort();
    signal?.addEventListener("abort", onOuterAbort, { once: true });
    try {
      const response = await fetchImpl(url, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${apiKey}` },
        body: JSON.stringify({ state, model, questions }),
        signal: controller.signal,
      });
      const text = await response.text();
      if (response.ok) {
        let payload;
        try {
          payload = JSON.parse(text);
        } catch {
          return { ok: false, reason: "invalid_response", status: response.status, message: "non-JSON body", attempts, latencyMs: now() - started };
        }
        if (!payload || typeof payload.answers !== "object" || payload.answers === null) {
          return { ok: false, reason: "invalid_response", status: response.status, message: "no answers", attempts, latencyMs: now() - started };
        }
        return {
          ok: true,
          model: typeof payload.model === "string" ? payload.model : null,
          answers: payload.answers,
          usage: payload.usage ?? null,
          generationID: typeof payload.id === "string" ? payload.id : null,
          servingProvider: typeof payload.provider === "string" ? payload.provider : null,
          attempts,
          latencyMs: now() - started,
        };
      }
      last = { reason: reasonFor(response.status), status: response.status, message: errorMessage(text, response.status) };
      if (!RETRYABLE.has(response.status)) break;
      // Honour a short `retry-after`; a long one means "not now", and a shadow call has no "later".
      const retryAfter = Number(response.headers.get?.("retry-after"));
      const wait = Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter * 1000 : retryDelayMs * attempts;
      if (now() + wait >= deadline) break;
      await new Promise((resolve) => setTimeout(resolve, wait));
    } catch (error) {
      if (signal?.aborted) {
        last = { reason: "cancelled", status: null, message: "cancelled by caller" };
        break;
      }
      if (controller.signal.aborted) {
        last = { reason: "timeout", status: null, message: `no answer within ${timeoutMs}ms` };
        break;
      }
      last = { reason: "network", status: null, message: String(error?.message ?? error).slice(0, 200) };
      if (now() + retryDelayMs >= deadline) break;
      await new Promise((resolve) => setTimeout(resolve, retryDelayMs));
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener("abort", onOuterAbort);
    }
  }
  return { ok: false, ...last, attempts, latencyMs: now() - started };
}

function reasonFor(status) {
  if (status === 401 || status === 403) return "unauthorized";
  if (status === 402) return "payment_required";
  if (status === 404) return "model_unavailable";
  if (status === 400 || status === 422) return "invalid_request";
  if (status === 408 || status === 524) return "timeout";
  if (status === 429) return "rate_limited";
  if (status === 529 || status === 503) return "overloaded";
  return "upstream_error";
}

/** The upstream's error text, clipped — never the request, which may hold the key in a header. */
function errorMessage(text, status) {
  try {
    const parsed = JSON.parse(text);
    const detail = parsed?.error?.message ?? parsed?.detail ?? parsed?.message;
    if (detail && parsed?.error?.metadata?.provider_name) return `${detail} (${parsed.error.metadata.provider_name})`.slice(0, 200);
    if (detail) return String(typeof detail === "string" ? detail : JSON.stringify(detail)).slice(0, 200);
  } catch {
    // fall through
  }
  return `HTTP ${status}`;
}

/**
 * Cost in USD. OpenRouter reports it (`usage.cost`), and that is used as is; otherwise the published
 * input price, or null when the model's price is not known here. Never estimated beyond that.
 */
export function costUSD(model, usage) {
  if (typeof usage?.cost === "number") return usage.cost;
  const price = PRICE_PER_INPUT_TOKEN_USD[model];
  const input = Number(usage?.input_tokens);
  if (!price || !Number.isFinite(input)) return null;
  return input * price;
}
