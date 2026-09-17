// Direct OpenAI adapter: the Responses API implementation this backend started with, unchanged in
// behaviour and now behind the same normalized event shape as the OpenRouter adapter.
//
// Verified against OpenAI documentation on 2026-09-16: `POST /v1/responses`, `stream: true` with
// `response.output_text.delta` / `response.completed`, `text.format` = `json_schema` with
// `strict: true`, `reasoning.effort`, `store: false`, `safety_identifier`, `prompt_cache_key`.

import { reasoningParameter } from "../config.mjs";

export const OPENAI_BASE = "https://api.openai.com/v1";

function headers(apiKey) {
  return { "content-type": "application/json", authorization: `Bearer ${apiKey}` };
}

export async function* streamAnswer({ apiKey, base = OPENAI_BASE, config, input, safetyIdentifier, cacheKey, signal }) {
  const response = await fetch(`${base}/responses`, {
    method: "POST",
    headers: headers(apiKey),
    body: JSON.stringify({
      model: config.answer_model_id,
      input,
      stream: true,
      store: false,
      reasoning: reasoningParameter(config, config.answer_model_id),
      max_output_tokens: config.max_output_tokens,
      safety_identifier: safetyIdentifier,
      prompt_cache_key: cacheKey,
    }),
    signal,
  });

  if (!response.ok || !response.body) {
    const detail = await response.text().catch(() => "");
    yield { type: "error", status: response.status, message: detail.slice(0, 300) || `HTTP ${response.status}`, committed: false };
    return;
  }

  yield* parseResponsesStream(response.body, { requestedModel: config.answer_model_id });
}

export async function* parseResponsesStream(source, { requestedModel } = {}) {
  const decoder = new TextDecoder("utf-8");
  let buffer = "";
  let sawContent = false;
  const meta = { generationID: null, resolvedModel: requestedModel ?? null, servingProvider: "openai", usage: null, finishReason: null };

  for await (const chunk of source) {
    buffer += typeof chunk === "string" ? chunk : decoder.decode(chunk, { stream: true });
    let newlineIndex;
    while ((newlineIndex = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newlineIndex).replace(/\r$/, "").trim();
      buffer = buffer.slice(newlineIndex + 1);
      if (!line || line.startsWith(":") || !line.startsWith("data:")) continue;
      const payload = line.slice(5).trim();
      if (!payload || payload === "[DONE]") continue;

      let event;
      try {
        event = JSON.parse(payload);
      } catch {
        continue;
      }

      if (event.type === "response.output_text.delta" && typeof event.delta === "string" && event.delta.length) {
        sawContent = true;
        yield { type: "delta", text: event.delta };
      } else if (event.type === "response.completed") {
        meta.generationID = event.response?.id ?? meta.generationID;
        meta.resolvedModel = event.response?.model ?? meta.resolvedModel;
        meta.usage = event.response?.usage ?? null;
        meta.finishReason = "stop";
        yield { type: "done", meta };
        return;
      } else if (event.type === "error" || event.type === "response.failed") {
        yield { type: "error", message: String(event.error?.message ?? "provider error").slice(0, 300), committed: sawContent, meta };
        return;
      }
    }
  }

  yield { type: "error", message: "stream ended before completion", committed: sawContent, meta, truncated: true };
}

export async function classify({ apiKey, base = OPENAI_BASE, config, input, schema, safetyIdentifier, signal }) {
  const response = await fetch(`${base}/responses`, {
    method: "POST",
    headers: headers(apiKey),
    body: JSON.stringify({
      model: config.detection_model_id,
      input,
      store: false,
      reasoning: reasoningParameter(config, config.detection_model_id),
      max_output_tokens: config.detection_max_output_tokens,
      safety_identifier: safetyIdentifier,
      text: { format: { type: "json_schema", name: "question_detection", strict: true, schema } },
    }),
    signal,
  });

  const text = await response.text();
  if (!response.ok) {
    return { ok: false, status: response.status, message: text.slice(0, 300) || `HTTP ${response.status}` };
  }
  let payload;
  try {
    payload = JSON.parse(text);
  } catch {
    return { ok: false, status: 502, message: "provider returned a non-JSON body" };
  }
  const content = payload.output_text ?? extractOutputText(payload);
  try {
    return {
      ok: true,
      result: JSON.parse(content),
      meta: {
        generationID: payload.id ?? null,
        resolvedModel: payload.model ?? config.detection_model_id,
        servingProvider: "openai",
        usage: payload.usage ?? null,
      },
    };
  } catch {
    return { ok: false, status: 502, message: "detector output was not valid JSON despite an enforced schema" };
  }
}

function extractOutputText(payload) {
  const parts = [];
  for (const item of payload.output ?? []) {
    for (const content of item.content ?? []) {
      if (typeof content.text === "string") parts.push(content.text);
    }
  }
  return parts.join("");
}
