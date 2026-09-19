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

---

## 12. Live mode behind the v2.5 interface (2026-09-19)

The approved interview screen now runs against real microphone transcription and the real provider
path. **No component was duplicated**: `LiveInterviewFeed` is an adapter that translates the existing
`CopilotSessionCoordinator` into the `InterviewFeed` the screen already consumed.

| Concern | Who does it | Changed? |
|---|---|---|
| Capture, permissions, interruptions | `InterviewAudioInput` | no |
| Transcript reconciliation | `ConversationLog` | no |
| Question detection | `DetectionPolicy` + backend `/v1/copilot/classify` | no |
| Retrieval | `ProjectContext` | no |
| Provider routing, streaming, fallback | backend `/v1/copilot/answer` | one field added |
| Reading | `ReadingAlignment`, `ScriptStyling` | no |
| Interface | `InterviewScreen` (v2.5) | wired, not redesigned |

### Detection and generation are separate, in code

`CopilotSessionCoordinator.generationMode` is `.manual` for the interview screen. Detection still
runs on finalized, reconciled turns exactly as before; the automatic `startGeneration` call that the
diagnostic screen still uses is suppressed. An answer exists only after `requestAnswer`, which only
`generate()` calls, which only a tap calls.

### One microphone

`LiveInterviewFeed` chains onto the coordinator's existing `audio.onDelta` rather than starting a
second transcription: the pipeline sees every delta first (detection unaffected), then the screen
sees the same delta for answer-following. There is exactly one `AVAudioEngine` session.

### Live never simulates

`isSimulatedReadingEnabled` is false in `.live` and `stepSimulatedReading()` refuses to run there.
Fading is driven only by `ingestLiveDelta`, i.e. by words the transcriber actually heard. The header
waveform reflects `InterviewAudioInput.state`, so "listening" on screen means the microphone is open.

### Readiness is checked, not assumed

`LiveReadiness` distinguishes microphone denied, speech-recognition denied, no on-device model for
the locale, backend not configured, backend unreachable, **client** token rejected, provider not
configured, and development fake enabled. Listening and generation are independent: with no provider
credential the session still transcribes and detects, and says so, rather than refusing to start.

### Honest limits, stated in the UI rather than worked around

- **Attached images are not sent.** The route is text-only, so the Context panel says the images are
  not sent *before* anything is generated. The typed note **is** sent, as `extraContext`, framed in
  the prompt as reference material and not as instructions.
- **Document import does not exist.** Grounding still comes from the sample project fixture, which
  the start screen names as a sample.
- **No speaker identification.** Nothing distinguishes the interviewer's voice from the candidate's.
  The existing `overlapsReading` signal is *text* evidence — whether recognised words matched the
  answer on screen — and it is used only to suppress false questions, never presented as knowing who
  spoke. Ordinary interviewer speech can still advance reading if it happens to match the answer
  text; this is a real remaining limitation and has not been measured on device.
- **Same-device call audio remains impossible.** Unchanged from §1: no iOS API gives a third-party
  app another app's call audio.

### Device check actually performed (2026-09-19)

Installed to the owner's iPhone 15 (iOS 26.6.2) as `talk.cointerview` — that app only, nothing
uninstalled or erased — and launched pointed at a backend on the Mac's LAN address, running with
`COINTERVIEW_FAKE=1` because no provider credential exists on this machine.

What the backend's own request log shows from that session:

```
   2 GET  /health              -> 200
   6 POST /v1/copilot/classify -> 200
   0      /v1/copilot/answer
```

Read plainly, that is:

- the readiness probe reached the backend from the phone over plain HTTP on the LAN, so
  `NSAllowsLocalNetworking` and the bearer token both work on a real device;
- the microphone opened, on-device transcription produced turns, and **detection ran six times** on
  real speech;
- **no answer was ever requested**, because nobody tapped Generate. Manual generation is not just a
  unit-test claim — it held on device.

The log contains no transcript text (the only line matching interview vocabulary is the server's own
startup banner), confirming the no-content-logging rule under real use.

**Not checked on device:** a real provider answer, answer latency, reading-follow accuracy while
someone reads aloud, and whether ordinary interviewer speech causes false reading progress. Those
need a provider credential and a person speaking, and are listed in the owner protocol below.

### Not yet measured

No live provider run has been made from this build: no `OPENROUTER_API_KEY` or `OPENAI_API_KEY` is
configured on this machine, so every verification here used stubs and the labelled development fake.
Time-to-first-token, time-to-first-sentence and completion time for the live path are therefore
**unmeasured**, and the harness in `eval/` remains the way to measure them once a key is set.

### Owner protocol for a real live test

Everything below needs a provider credential, which this machine does not have.

1. **Set the credential and start the backend** (the key never leaves your shell and never enters the app):
   ```bash
   cd ~/Desktop/co-interview-public/backend
   COINTERVIEW_TOKENS=$(openssl rand -hex 24) \
     OPENROUTER_API_KEY=sk-or-...   \
     COPILOT_TEXT_PROVIDER=openrouter COPILOT_PROFILE=balanced \
     HOST=0.0.0.0 node server.mjs
   ```
   Note the printed token; `ipconfig getifaddr en0` gives the Mac's address.
2. **Point the phone at it**: Co-Interview → Debug → Debug: Copilot → backend URL
   `http://<mac-address>:8787`, access token = the `COINTERVIEW_TOKENS` value. Not the provider key.
3. **Open Live**: Interview Copilot → Start live. The footnote should read `Ready · openrouter · …`.
   Allow microphone and speech recognition when asked; allow local network.
4. **Speak a question** as the interviewer would. It should appear in the transcript, underlined, and
   become a page — with **no answer**.
5. **Select it and tap Generate.** Time from tap to first visible text, and to a complete first
   sentence.
6. **Read the answer aloud.** Words you have said should fade; words you have not should not.
7. **Ask another question while reading.** The page must not change; a "Qn ready →" chip should offer
   the new one only after you generate it.
8. **Add a note in Context** and generate again — the answer should reflect it. Attach an image and
   confirm the panel says it is not sent.
9. **Pause and resume listening**, then close the interview. The microphone indicator must go out.

Report what actually happened, including anything that did not work.

---

## 13. Generate is independent of detection (2026-09-20)

Device feedback was blunt: transcription worked, questions were not reliably detected, and Generate
was therefore useless. Two separate faults, fixed separately.

### The detection bug: verdicts discarded, then the queue blocked

The backend was never at fault. Its log showed 22 successful `POST /v1/copilot/classify -> 200` from
the phone, and the classifier answers `new_question` with high confidence for unpunctuated speech
("how do you handle backpressure"), short questions ("Why?") and imperatives ("Tell me about your
last project"). The losses were both app-side:

1. **A verdict about still-volatile speech was thrown away.** On-device transcription publishes
   volatile text long before it finalizes, so the policy's `stablePause` trigger classifies the
   in-flight tail — that is what the trigger is for. But that path had no finalized utterances, so
   `apply` received an empty consumed-utterance group and its `guard !consumed.isEmpty` dropped the
   `new_question`. `lastClassifiedText` was recorded anyway, so when the same words finalized the
   policy refused to look again ("nothing new since the last call"). The question was not delayed —
   it was lost. The open utterance is now the classification group, so the verdict lands and the
   utterance's stable identity still prevents a duplicate when it finalizes.

2. **The finalized copy then blocked everything behind it.** Detection is a queue, and
   `skipUnclassifiableHeadTurns` only skipped turns that were too short or entirely the user reading.
   An already-classified turn sat at the head forever, so no later question was examined. Turns whose
   utterances have all been consumed are now skipped too: they have had their decision, and `apply`
   would reject a second card for them regardless.

Detection still matters — it underlines questions in the transcript and powers explicit selection —
but **it no longer gates anything the user can ask for.**

### The Generate contract

`canGenerate` is now unconditionally true. Tapping Generate:

- takes an **immutable snapshot** of the transcript (bounded to the last 12 lines, enough for a
  follow-up like "and why?" to make sense), the note and the prepared attachments;
- creates a history entry immediately, with a visible generating state;
- asks the feed through `requestAnswerForDiscussion` — **one request**, which derives the question or
  topic and streams the answer. There is no separate classification call to fail first;
- labels the entry with what was actually answered, reported back as `answerTopicResolved`.

With nothing to answer the button stays tappable and says "Speak or add context first" rather than
going grey; no empty request is sent. The explicit per-page "answer this question" action is
unchanged, and ordinary Generate always uses the **latest discussion**, so browsing history does not
change what the next tap asks about.

### Repeated taps

Every accepted tap is its own entry, including repeated taps about the same discussion. A 0.4 s
debounce absorbs an accidental double-tap without refusing a deliberate second request. One request
runs at a time and the rest wait in a FIFO queue bounded at three; a full queue says so rather than
discarding an accepted request. Each queued request keeps the snapshot it was created with, so later
speech belongs to the next request, not to one already accepted.

### What a failure leaves behind

Streamed text stays on screen and the version is marked incomplete. The transcript, every previous
answer and its reading position are untouched, and the queue slot is released so the next request
still runs. Ending the session clears the queue and late events are rejected by request id.
