// OpenRouter adapter: Chat Completions in, the application's normalized events out.
//
// OpenRouter and OpenAI speak different protocols — Chat Completions chunks versus Responses events —
// so they get separate adapters and meet only at the normalized event shape the iOS app already
// consumes (`delta` / `sources` / `done` / `error`).
//
// The stream handling here is deliberately defensive, because a 200 is not evidence of a successful
// generation. It handles SSE comments (`: OPENROUTER PROCESSING`), arbitrarily split network chunks,
// UTF-8 characters split across chunk boundaries, the final usage frame that repeats `finish_reason`,
// `[DONE]`, empty content deltas, errors delivered *after* a 200 either as an `error` field or as
// `finish_reason: "error"`, and truncated streams.

import { reasoningParameter, providerRouting } from "../config.mjs";
import { routeCapability } from "../capabilities.mjs";

export const OPENROUTER_BASE = "https://openrouter.ai/api/v1";

function headers(apiKey) {
  return {
    "content-type": "application/json",
    authorization: `Bearer ${apiKey}`,
    // Optional attribution headers, documented by OpenRouter. No user data.
    "HTTP-Referer": "https://github.com/0x0sid/co-interview",
    "X-Title": "Co-Interview",
  };
}

/** Streaming answer. Returns an async generator of normalized events. */
export async function* streamAnswer({ apiKey, base = OPENROUTER_BASE, config, messages, order, benchmark, signal }) {
  const body = {
    model: config.answer_model_id,
    messages,
    stream: true,
    max_tokens: config.max_output_tokens,
    temperature: config.temperature,
    reasoning: reasoningParameter(config, config.answer_model_id),
    provider: providerRouting(config, order, { benchmark }),
    usage: { include: true },
  };

  const response = await fetch(`${base}/chat/completions`, {
    method: "POST",
    headers: headers(apiKey),
    body: JSON.stringify(body),
    signal,
  });

  // Errors before the stream is committed arrive as plain JSON, not SSE.
  if (!response.ok || !response.body) {
    const detail = await response.text().catch(() => "");
    yield { type: "error", status: response.status, message: errorMessage(detail, response.status), committed: false };
    return;
  }

  yield* parseChatCompletionsStream(response.body, { requestedModel: config.answer_model_id });
}

function errorMessage(detail, status) {
  try {
    const parsed = JSON.parse(detail);
    return parsed?.error?.message ?? `HTTP ${status}`;
  } catch {
    return detail ? detail.slice(0, 300) : `HTTP ${status}`;
  }
}

/**
 * Parses an OpenRouter Chat Completions SSE stream into normalized events.
 *
 * Exported separately from the network call so every awkward stream shape can be tested without a
 * provider — which is how the edge cases above are covered.
 */
export async function* parseChatCompletionsStream(source, { requestedModel } = {}) {
  // `stream: true` on TextDecoder is what keeps a multi-byte character split across two network
  // chunks from being turned into replacement characters.
  const decoder = new TextDecoder("utf-8");
  let buffer = "";
  let sawContent = false;
  let finished = false;
  const meta = { generationID: null, resolvedModel: null, servingProvider: null, usage: null, finishReason: null };

  for await (const chunk of source) {
    buffer += typeof chunk === "string" ? chunk : decoder.decode(chunk, { stream: true });

    let newlineIndex;
    while ((newlineIndex = buffer.indexOf("\n")) >= 0) {
      const rawLine = buffer.slice(0, newlineIndex);
      buffer = buffer.slice(newlineIndex + 1);
      const line = rawLine.replace(/\r$/, "").trim();

      if (!line) continue;
      // SSE comments (": OPENROUTER PROCESSING") are keep-alives. Passing one to JSON.parse throws
      // and, unhandled, kills the stream loop — so they are skipped before any parsing.
      if (line.startsWith(":")) continue;
      if (!line.startsWith("data:")) continue;

      const payload = line.slice(5).trim();
      if (payload === "[DONE]") {
        finished = true;
        continue;
      }

      let event;
      try {
        event = JSON.parse(payload);
      } catch {
        continue; // a partial or malformed frame is not fatal; the stream may still complete
      }

      if (event.id && !meta.generationID) meta.generationID = event.id;
      if (event.model) meta.resolvedModel = event.model;
      // The serving provider is reported by OpenRouter when it knows it. It is never inferred from
      // the first requested preference: a request can be served by any permitted route.
      if (event.provider) meta.servingProvider = event.provider;
      if (event.usage) meta.usage = event.usage;

      // An error can arrive *after* a 200, either as a top-level field or as a finish reason.
      if (event.error) {
        yield { type: "error", message: String(event.error.message ?? event.error).slice(0, 300), committed: sawContent, meta };
        return;
      }

      const choice = event.choices?.[0];
      if (!choice) continue;
      if (choice.finish_reason) meta.finishReason = choice.finish_reason;
      if (choice.finish_reason === "error" || choice.native_finish_reason === "error") {
        yield { type: "error", message: "provider reported finish_reason=error", committed: sawContent, meta };
        return;
      }

      const content = choice.delta?.content;
      if (typeof content === "string" && content.length) {
        sawContent = true;
        yield { type: "delta", text: content };
      }
      // `delta.reasoning` / `reasoning_details` are deliberately ignored: reasoning text, usage and
      // control metadata must never be appended to the answer the user reads aloud.
    }
  }

  const tail = decoder.decode();
  if (tail) buffer += tail;

  if (!finished && !meta.finishReason) {
    // The connection ended without `[DONE]` and without a terminal reason: the answer is incomplete,
    // and saying so is better than presenting a truncated answer as finished.
    yield { type: "error", message: "stream ended before completion", committed: sawContent, meta, truncated: true };
    return;
  }

  yield { type: "done", meta };
}

/** Non-streaming structured classification. */
export async function classify({ apiKey, base = OPENROUTER_BASE, config, messages, schema, order, benchmark, signal }) {
  const modelID = config.detection_model_id;
  const routes = order.length ? order : [];
  for (const slug of routes) {
    if (routeCapability(modelID, slug)?.structuredOutputs !== true) {
      return { ok: false, status: 400, message: `route ${slug} cannot enforce structured output for ${modelID}` };
    }
  }

  const body = {
    model: modelID,
    messages,
    max_tokens: config.detection_max_output_tokens,
    temperature: config.detection_temperature,
    reasoning: reasoningParameter(config, modelID),
    provider: providerRouting(config, routes, { benchmark }),
    response_format: { type: "json_schema", json_schema: { name: "question_detection", strict: true, schema } },
  };

  const response = await fetch(`${base}/chat/completions`, {
    method: "POST",
    headers: headers(apiKey),
    body: JSON.stringify(body),
    signal,
  });

  const text = await response.text();
  if (!response.ok) {
    return { ok: false, status: response.status, message: errorMessage(text, response.status) };
  }

  let payload;
  try {
    payload = JSON.parse(text);
  } catch {
    return { ok: false, status: 502, message: "provider returned a non-JSON body" };
  }
  const content = payload.choices?.[0]?.message?.content;
  if (typeof content !== "string") {
    return { ok: false, status: 502, message: "provider returned no message content" };
  }
  let parsed;
  try {
    parsed = JSON.parse(content);
  } catch {
    // Enforced schemas should make this impossible; if it happens the output is refused rather than
    // guessed at.
    return { ok: false, status: 502, message: "detector output was not valid JSON despite an enforced schema" };
  }
  return {
    ok: true,
    result: parsed,
    meta: {
      generationID: payload.id ?? null,
      resolvedModel: payload.model ?? null,
      servingProvider: payload.provider ?? null,
      usage: payload.usage ?? null,
    },
  };
}
