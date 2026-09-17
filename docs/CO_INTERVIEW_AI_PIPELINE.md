# Co-Interview — AI pipeline

**Status: development prototype, 2026-09-17. Not a shipping feature.**

This document owns the **live pipeline**: how speech becomes a detected question, how a question
becomes a grounded answer, which providers serve it, and what has actually been verified. Product
intent lives in [`CO_INTERVIEW_COPILOT_BRIEF.md`](CO_INTERVIEW_COPILOT_BRIEF.md), design in
[`CO_INTERVIEW_COPILOT_ARCHITECTURE.md`](CO_INTERVIEW_COPILOT_ARCHITECTURE.md), sequencing in
[`CO_INTERVIEW_COPILOT_IMPLEMENTATION_PLAN.md`](CO_INTERVIEW_COPILOT_IMPLEMENTATION_PLAN.md).

Four kinds of evidence appear here and are never mixed:

| Label | Means |
|---|---|
| **Verified (catalogue)** | Read from a provider's live API on the stated date |
| **Verified (stub)** | Proven against a local stub speaking the documented protocol — contract, not availability or quality |
| **Verified (simulator)** | Observed in the iOS Simulator with synthetic speech |
| **Not measured** | No number exists yet. Nothing here is estimated into one |

---

## 1. Shape of the pipeline

```
microphone ─▶ SpeechAnalyzer/SpeechTranscriber (on device, Apple)
                └─▶ TranscriptDelta (volatile → final)
                      └─▶ ConversationLog        application-owned ids, dedupe, bounded window
                            └─▶ pendingTurns     turn segmentation by silence gap
                                  └─▶ DetectionPolicy    when to spend a classification
                                        └─▶ detector  (gpt-5.4-nano | gemini-2.5-flash-lite)
                                              └─▶ QuestionCard
                                                    ├─▶ PassageRetriever (on device, lexical)
                                                    └─▶ answer model (streaming)
                                                          └─▶ StreamingAnswerAssembler
                                                                └─▶ ReadingAlignment → the reader
```

**Apple's on-device transcription is the listening layer and stays that way.** OpenRouter is an
alternative gateway for *text generation only*. GPT-Live and cloud audio streaming are deferred
(architecture §8.2). Changing the text provider grants no new access to audio: capturing a call
running in another app on the same iPhone remains unproven and unsupported (architecture §4).

Listening is independent of everything downstream — classification, generation, cancellation,
provider failure, card navigation and reading pause. `InterviewAudioInput` owns one session for the
whole interview; nothing in the answer path can reach it.

---

## 2. Models and gateways

Both gateways are supported. The backend decides which is used; the app never chooses.

### Direct OpenAI (default) — verified (catalogue) 2026-09-16

| Role | Model | Notes |
|---|---|---|
| Detection | `gpt-5.4-nano` | snapshot `gpt-5.4-nano-2026-03-17`; Responses API; streaming; structured outputs; `reasoning.effort` includes `none` (its default) |
| Answers | `gpt-5.4-mini` | snapshot `gpt-5.4-mini-2026-03-17`; same surface |

Requests use `store: false`, `max_output_tokens`, `text.format` = `json_schema` with `strict: true`,
`safety_identifier` (a hash, never an account identifier) and `prompt_cache_key`.
`prompt_cache_options` is documented as GPT-5.6-and-later, so it is not sent.

### OpenRouter — verified (catalogue) 2026-09-16, re-checkable

Routing slugs are **not** display names. These were read from
`GET /api/v1/models/:author/:slug/endpoints` and `GET /api/v1/providers`:

| Display name | Routing slug | Status |
|---|---|---|
| CoreWeave | `coreweave/bf16` | offered for Nemotron 3.5 Lightning |
| Google AI Studio | `google-ai-studio` (also `/flex`, `/priority`) | offered for Gemini 2.5 Flash-Lite |
| Together | `together` | offered for DeepSeek V4.1 Flash |
| Wafer | `wafer` | **withdrawn for DeepSeek V4.1 Flash between 2026-09-16 and 2026-09-17** |

Wafer was verified present on the 16th and gone on the 17th — caught by `tools/verify-routes.mjs`,
which is why that tool exists. The `smart` profile now routes DeepSeek through **Together** only; the
model is unchanged and nothing was silently substituted. Configuring `wafer` is rejected with the list
of routes that do exist.

Re-verify with `node tools/verify-routes.mjs` (no credential needed). It compares the registry in
`backend/capabilities.mjs` against the live catalogue and exits non-zero on any difference. Last run
(2026-09-17): **all routes matched**, after removing Wafer (below).

#### Model-level versus endpoint-level capability

The two disagree, and the endpoint is what serves the request, so the endpoint wins:

- `deepseek/deepseek-v4.1-flash` advertises `structured_outputs` at model level, but its `deepseek`
  and `novita/fp8` endpoints do **not** support it. Those routes are therefore refused for detection.
- A base slug (`google-ai-studio`) covers every variant, so the registry treats it as only as capable
  as its weakest variant.

#### Reasoning: disabling is not hiding

| Model | Reasoning defaults | How this backend disables it |
|---|---|---|
| `nvidia/nemotron-3.5-lightning` | off; no effort selection exposed | `reasoning: { enabled: false }` |
| `google/gemini-2.5-flash-lite` | off; no effort selection exposed | `reasoning: { enabled: false }` |
| `deepseek/deepseek-v4.1-flash` | **on by default**, `default_effort: "high"`, supported efforts `max/high/low` | `reasoning: { enabled: false }` |

Two traps this avoids. `exclude: true` only hides the trace — the model still reasons and is still
billed. And `effort: "none"` is documented as disabling reasoning but is **not accepted by DeepSeek**,
whose supported efforts are only `max`, `high` and `low`. `reasoning: { enabled: false }` is the lever
that works for all three, and is what the "smart" profile relies on to keep live answers fast.

If a configured effort is not supported by a configured model, the backend **refuses the
configuration** with an actionable message rather than quietly dropping it or leaving thinking on.

---

## 3. Profiles

Initial presets. **Profile names are product labels, not measured rankings** — no live benchmark has
run (§9).

| Profile | Answer model | Preferred route | Detection | Reasoning |
|---|---|---|---|---|
| `speed` | `nvidia/nemotron-3.5-lightning` | `coreweave/bf16` | Gemini 2.5 Flash-Lite via `google-ai-studio` | disabled |
| `balanced` *(initial OpenRouter default)* | `google/gemini-2.5-flash-lite` | `google-ai-studio` | same | disabled |
| `smart` | `deepseek/deepseek-v4.1-flash` | `together` (Wafer withdrawn 2026-09-17) | same | disabled |
| `custom` | operator-supplied | operator-supplied | operator-supplied | operator-supplied |

Detection is configurable independently of answers, and has its own token budget and temperature, so
changing answer length or temperature cannot quietly change detector behaviour.

Fallback: `google/gemini-2.5-flash-lite` via `google-ai-studio`. On the **direct OpenAI** gateway the
fallback model equals the answer model, so no application-level fallback attempt is made — the
existing OpenAI behaviour, unchanged.

---

## 4. Configuration

Authoritative on the backend. Precedence, lowest to highest:

1. built-in defaults
2. the selected profile (OpenRouter only — profile ids are OpenRouter model ids)
3. operator overrides, from the environment as `COPILOT_<KEY>`
4. development-only request overrides, refused unless `COINTERVIEW_ALLOW_REQUEST_OVERRIDES=1`, and
   then validated exactly like operator configuration

| Key | Default | Notes |
|---|---|---|
| `text_provider` | `openai` | `openai` or `openrouter` |
| `profile` | `balanced` | `speed`, `balanced`, `smart`, `custom` |
| `detection_model_id` / `detection_provider_order` | `gpt-5.4-nano` / — | must support enforced structured output |
| `answer_model_id` / `answer_provider_order` | `gpt-5.4-mini` / — | |
| `fallback_model_id` / `fallback_provider_order` | gateway-specific | Gemini via `google-ai-studio` on OpenRouter |
| `allow_fallbacks` | `true` | `false` disables **both** upstream provider fallback and application-level model fallback |
| `require_parameters` | `true` | required for detection routes |
| `reasoning_enabled` / `reasoning_effort` | `false` / — | see §2 |
| `max_output_tokens` / `temperature` | `700` / `0.3` | validated against the route's own limit |
| `detection_max_output_tokens` / `detection_temperature` | `300` / `0` | independent of the answer settings |
| `combined_detect_and_answer` | `false` | **unimplemented**; enabling it is refused with an explicit error |
| `pin_provider_during_benchmark` | `true` | |
| `data_collection` / `zdr` | `deny` / `false` | routing restrictions |

Rejected, with actionable messages: an OpenRouter model id on the OpenAI gateway, a provider order on
the OpenAI gateway, a display name used as a slug, an unknown model, a detection route without
structured output, an unsupported reasoning effort, output tokens beyond the route limit, an unknown
profile, and `combined_detect_and_answer`.

### Credentials

`OPENAI_API_KEY` and `OPENROUTER_API_KEY` live **only** in the backend's environment. They are never
compiled into the iOS app, returned by any endpoint (including `/v1/copilot/config`), written to a log
line, or committed. The app carries a backend URL and a development bearer token that the developer
sets themselves. `GET /v1/copilot/config` returns the non-secret view, and a contract test asserts no
credential appears in it.

---

## 5. Routing and failover

`order` is a **preference, not an allowlist**. Restricting a request requires `only`, or
`allow_fallbacks: false` (which this backend turns into `only`).

| Mode | Routing sent |
|---|---|
| Production, ordered | `order`, `allow_fallbacks: true`, `require_parameters`, `data_collection` |
| Production, exclusive (`allow_fallbacks=false`) | `only` = the ordered list, `allow_fallbacks: false` |
| Benchmark (`benchmark: true`) | `only` = exactly one route, `allow_fallbacks: false`; more than one configured route is **refused** |

Application-level fallback is separate from upstream provider failover, and is bounded:

- at most **one** fallback attempt, and only **before any visible answer text**;
- never in benchmark mode;
- never when the fallback resolves to the same route as the primary (no retry loop);
- never for cancellation, invalid input, authentication or configuration errors — those are not
  transient, and retrying them hides the real fault.

**After visible text has appeared** the text and the reading position are preserved, the version is
marked incomplete, listening continues, and Retry creates a **new** version rather than replacing the
one being read. The reader is never moved to a new version automatically.

### Attempt and route metadata

Each attempt records: requested gateway, requested model and routing, resolved model, serving provider
*as reported*, upstream generation id, usage, finish reason, and the application's session, card and
answer-version ids. When the gateway does not report who served the request, the value is
**`unknown`** — it is never inferred from the first requested preference. The app surfaces this on the
card and in **Debug: Copilot**.

---

## 6. Detection

A bounded rolling window of conversation, segmented into turns by silence, with one classification per
turn. The structured result carries `kind` (`none` / `incomplete` / `new_question` / `continuation`),
`is_question`, `question_text`, `confidence` and `language`. Confidence is the model's own estimate, a
heuristic — not a calibrated probability.

Four defects found by tracing a replay, each fixed at its cause and covered by tests:

1. **Batched turns merged questions.** Everything unconsumed was classified as one block, so two
   questions finalized together became one card. Detection now classifies **one turn at a time**.
2. **The backlog never drained.** After a classification completed, queued speech had no trigger of
   its own. A closed turn is now a trigger, and a drained turn of finalized utterances is closed by
   definition.
3. **A short backchannel blocked the queue forever.** "Right. Understood." never reached the word
   minimum, so the cut-off never moved past it and every later question was ignored.
4. **Speech identified as the user reading blocked it the same way.**

Short speech cuts both ways, so length is a **noise filter, not a definition of a question**: a short
turn that is shaped like one ("Why?", "Et ensuite ?") still gets a classification, while a short
backchannel is skipped. Skipped speech stays in the conversation log as context.

Manual paths remain: **Answer this** for speech detection missed, and **Type** for a question with no
audio at all.

---

## 7. Answers

Streamed immediately. The first sentence must be direct and useful; filler openings are graded as a
defect in the harness. Default target is **40–80 words** (a tunable prototype setting). Facts about the
speaker must come from retrieved passages, cited by id; the backend validates every cited id against
the passages it actually sent and drops unknown ones. Where the passages lack a detail, the model
writes a visible placeholder rather than inventing experience. Citations and control metadata are
stripped from the spoken text: the `SOURCES:` line never reaches the reader, and reasoning traces are
never appended.

**Reader stability.** Text becomes readable only in whole sentences, and committed text is
append-only, because `SlidingWindowMatcher` captures its token sequence at initialisation — text that
changed underneath the cursor would invalidate token indices, spoken markers and the cursor itself.
The continuation is frozen as a further segment (architecture §7 fallback).

---

## 8. Streaming

Two protocols, two adapters, one normalized event stream (`delta` / `attempt` / `sources` / `done` /
`error`).

OpenRouter Chat Completions handling — each **verified (stub)**:

| Case | Behaviour |
|---|---|
| `: OPENROUTER PROCESSING` comments | skipped before any parsing (passing one to `JSON.parse` would kill the loop) |
| Frames split across network chunks | reassembled |
| UTF-8 split across chunks | decoded incrementally; no replacement characters |
| Final usage frame repeating `finish_reason` | treated as an accounting frame, not a second terminal event |
| `[DONE]` | terminal |
| Empty content deltas | emit nothing |
| Error before streaming | plain JSON, mapped to a status |
| Error after HTTP 200 (`error` field or `finish_reason: "error"`) | surfaced, with whether text was already committed |
| Truncated stream (no `[DONE]`, no terminal reason) | reported as incomplete, never as success |
| Reasoning fields | never appended to answer text |
| Cancellation | client disconnect aborts upstream |

**A 200 is not evidence of a successful generation**, and cancellation is not universally honoured:
OpenRouter documents Google and Google AI Studio as **not** supporting stream cancellation, so
aborting a Gemini request does not necessarily stop provider computation or billing. That affects the
current default profile and is recorded in `capabilities.mjs`.

---

## 9. Benchmarking

`backend/eval/run-eval.mjs` runs the synthetic English and French scenarios, one pinned route per run,
with fallbacks disabled and the detector held fixed. It measures first visible text, first complete
sentence, completion time, median and p95, failures, citation validity, honest handling of unsupported
questions, and usage when reported. It records the **actual** serving provider when the gateway
reports one.

```bash
cd backend
COINTERVIEW_TOKENS=dev-token OPENROUTER_API_KEY=… COPILOT_TEXT_PROVIDER=openrouter \
  COINTERVIEW_ALLOW_REQUEST_OVERRIDES=1 node server.mjs

# One pinned route per run — these are four separate measurements, not one.
node eval/run-eval.mjs --base http://127.0.0.1:8787 --token dev-token --runs 5 --benchmark 1 \
  --provider openrouter --profile speed    --route coreweave/bf16   --out speed-coreweave.json
node eval/run-eval.mjs --base http://127.0.0.1:8787 --token dev-token --runs 5 --benchmark 1 \
  --provider openrouter --profile balanced --route google-ai-studio --out balanced-gemini.json
node eval/run-eval.mjs --base http://127.0.0.1:8787 --token dev-token --runs 5 --benchmark 1 \
  --provider openrouter --profile smart    --route together         --out smart-together.json
# Wafer was withdrawn for DeepSeek V4.1 Flash on 2026-09-17. If the catalogue offers it again
# (`npm run verify-routes`), add it to capabilities.mjs and benchmark it as its own run:
#   … --profile smart --route wafer --out smart-wafer.json
```

### Results

**Not measured.** No provider credential was available in this environment, so no request has reached
OpenAI or OpenRouter. The harness has only been exercised against the development fake, whose delays
are synthetic — **those numbers are not provider performance and are not reported here.** Until a live
run exists, `balanced` (Gemini 2.5 Flash-Lite via Google AI Studio) stays the initial OpenRouter
default as a starting point, not as a measured winner.

API-only timing is also not the user-facing number: it excludes everything before the transcript
exists (end of speech → stable transcript on device), which needs a real microphone in a real room and
belongs to plan Increment 1.

---

## 10. Reaching it in the app

Development builds only. The copilot is **not** part of the shipping surface.

| Path | Taps |
|---|---|
| **Demo** | Home (*Scripts*) → **Interview Copilot** → *Start demo* |
| **Live** | Home → **Interview Copilot** → *Start live* (enabled only when the backend and microphone are ready) |
| Provider diagnostics | Home → **Interview Copilot** → *Provider diagnostics*, or the gear → *Debug: Copilot* |
| Automated replay | launch argument `-copilotReplay` (add `-copilotReplayFrench` for French) |

Demo uses a scripted interview and the clearly-marked development fake provider: no microphone, no
network. Live uses the real microphone and the configured backend, and is **never** silently
substituted with canned answers — when it cannot run, the button stays disabled and says why. Both
answer from a **sample project**, labelled as such; document import does not exist yet.

Ending a session (the **End** button, or leaving the screen) cancels detection and generation and
releases the audio session, so ordinary script reading works immediately afterwards.

### Local backend from a physical iPhone

`127.0.0.1` on the phone means *the phone*. Use the Mac's LAN address, and expect a local-network
permission prompt on first connection:

```bash
cd backend
ipconfig getifaddr en0                      # e.g. 192.168.1.42
COINTERVIEW_TOKENS=$(openssl rand -hex 24) OPENROUTER_API_KEY=… \
  COPILOT_TEXT_PROVIDER=openrouter HOST=0.0.0.0 node server.mjs
```

Then in the app: **Debug: Copilot** → backend URL `http://192.168.1.42:8787` and the same token.

Plain HTTP to a LAN address needs an App Transport Security exception. **None is configured**, and one
has deliberately not been added: it would be a change to the shipping `Info.plist` for a development
convenience. The alternatives, in order of preference: run against the Simulator (where
`http://127.0.0.1:8787` works), terminate TLS in front of the backend, or add a **narrowly scoped**
exception for one LAN hostname in a development-only configuration. Production requires HTTPS.

---

## 11. What has been verified

| Area | How | Result |
|---|---|---|
| OpenRouter model ids, routes, parameters, reasoning defaults | Verified (catalogue), 2026-09-16 | All three models exist; registry matches live catalogue |
| OpenAI model ids and parameters | Verified (catalogue), 2026-09-16 | `gpt-5.4-nano`, `gpt-5.4-mini` support everything used |
| Configuration precedence, profiles, validation, reasoning translation, routing | `backend/test/config-test.mjs` | **passing** |
| OpenRouter streaming, metadata, fallback rules, detection contract, credential non-leakage | `backend/test/openrouter-test.mjs` (stub) | **passing** |
| Direct OpenAI Responses path | `backend/test/contract-test.mjs` (stub) | **passing** |
| Pipeline ordering, dedupe, corrections, backlog, short turns, reader stability, route metadata | `prompterTests/Copilot/` | **passing** |
| Owner-facing navigation, demo in both languages, live-unconfigured state | `prompterUITests/CopilotEntryUITests` (simulator) | **passing**; screenshots in `evidence/copilot-prototype/` |
| Real provider latency and answer quality | — | **Not measured** — no credential |
| Device audio (far-field recognition, speech/reading interference) | — | **Not measured** — plan Increment 1 |

**Runtime:** the backend uses built-in `fetch`, `AbortController` and `TextDecoder`, so it runs on
Node 18+. But Node 18 and 20 are past end-of-life (2025-04-30 and 2026-04-30), so the supported
runtime is **Node 22 (Jod) or 24 (Krypton)**, declared in `backend/package.json` as `>=22`.
Everything above was **tested on Node v18.16.0** — the version installed on this machine, which is
end-of-life. Re-run `npm test` in `backend/` on a supported LTS before trusting these results.

Inherited defects and removed coverage are unchanged and still apply: see
`CO_INTERVIEW_SNAPSHOT_NOTICE.md` and architecture §10.
