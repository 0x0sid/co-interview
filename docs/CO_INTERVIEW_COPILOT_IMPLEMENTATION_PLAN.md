# Co-Interview copilot — implementation plan

**Status: proposed order for review, 2026-09-16. No increment has been approved or started.**

This document owns **sequencing**: ordered increments, dependencies, acceptance criteria, verification
and stopping points. Product intent is in [`CO_INTERVIEW_COPILOT_BRIEF.md`](CO_INTERVIEW_COPILOT_BRIEF.md),
design in [`CO_INTERVIEW_COPILOT_ARCHITECTURE.md`](CO_INTERVIEW_COPILOT_ARCHITECTURE.md) (cited as
"arch §n"), and decisions in [`CO_INTERVIEW_COPILOT_OPEN_QUESTIONS.md`](CO_INTERVIEW_COPILOT_OPEN_QUESTIONS.md).

---

## Ground rules for every increment

These carry forward the repository's hard-won safeguards and are **not relaxed** by any increment:

1. **Test counts come from `xcresulttool`**, never from log greps. Always pass `-resultBundlePath`.
2. **`xcodebuild clean` before load-bearing verification**; confirm the log actually recompiled.
3. Every claim is labelled **implemented**, **automated-verified** or **device-verified**.
4. **Baseline:** the public snapshot reportedly passes **113 tests** (113 `@Test` declarations counted in
   `prompterTests/` at `32a583c`; not re-run in the planning round). Each increment re-establishes the
   baseline with a clean run before changing code, and reports new totals from the result bundle.
5. **Known gaps stay listed** in every increment report: LOST 3 unresolved and uncovered, removed
   capture-derived suites, intermittent `restartClearsTheSpokenSet`, and the other inherited defects
   (arch §10). No increment may delete, skip or weaken an existing test to pass.
6. **Script reading must not regress** (C1, C2). Any increment touching `Prompt/`, `Speech/` or
   `Matching/` runs the full suite and the `-promptReplay` visual check.
7. `Matching/` and `Speech/` were marked "do not edit without written approval" in Prompter's handoff.
   Increments that need edits there say so, and that approval is part of approving the increment.
8. **No secrets** in the repository or in chat. No personal speech in fixtures, logs or evidence —
   scripted, non-personal content only.
9. **No push** unless the owner asks. No dependency additions without an explicit line in the increment.
10. One increment at a time; each ends at a safe stopping point with a written report.

---

## Order and dependencies

> **Amended 2026-09-16.** The owner directed an earlier, bounded **pipeline prototype** (Increment 0
> below) to measure continuous listening and low-latency, document-grounded generation, using the
> selected API pipeline in architecture §8.2.1. It runs ahead of Increments 1–8, which are unchanged.
> Increment 0 does not include file import, persistence, billing, deployment or submission, and its
> results are recorded in [`CO_INTERVIEW_AI_PIPELINE.md`](CO_INTERVIEW_AI_PIPELINE.md).

| # | Increment | Depends on increments | Blocked by decisions |
|---|---|---|---|
| 0 | **Continuous-listening / generation pipeline prototype** (owner-directed) | — | none to build; real-API measurement needs Q3 credentials |
| 1 | Audio and alignment feasibility spike | — | Q1, Q7 |
| 2 | Reader extraction, no behaviour change | — | — |
| 3 | Question cards and navigation, synthetic events | 2 | — |
| 4 | Persistence foundation and project workspace | 3 (card/version types) | Q5, Q8 |
| 5 | Document import and processing | 4 | Q6 |
| 6 | Provider backend (development) and grounding evaluation | 5 | Q3 |
| 7 | Live question detection and answer generation | 1, 3, 6 | Q2; Q4 before use beyond the owner |
| 8 | Failure recovery, deletion, disclosure, device validation | 7 | Q4, Q5 |
| 9 | Later: OCR, more formats, retrieval, languages | 8 | Q6, Q7 |

**Why this order.** The largest unknowns are (a) whether acoustic capture hears the interviewer well
enough and how badly speech contaminates reading — cheap to measure, fatal if wrong, so it goes first;
and (b) whether the reader can host many independent answers without regressing script reading — the
core of the confirmed UX, testable with no AI at all. Grounding quality is measured on synthetic
projects (6) before live wiring (7), so live failures can be attributed to detection or audio rather than
to generation. Increments 1 and 2 are independent and could be reordered if the owner prefers; 2 does
not depend on Q1.

---

## Increment 0 — Continuous-listening and generation pipeline prototype *(owner-directed)*

**Objective.** Build and measure the end-to-end pipeline — continuous on-device transcription →
question detection (`gpt-5.4-nano`) → parallel document retrieval over a synthetic project →
streamed answer (`gpt-5.4-mini`) → stable reading text in cards — behind a development-only entry
point, with a minimal authenticated backend.

| | |
|---|---|
| **Included** | `Copilot/` module: continuous `InterviewAudioInput` independent of generation; `ConversationLog` with application-owned utterance and question IDs, dedupe and revisions; `DetectionPolicy` + `QuestionDetector` (structured: none / incomplete / new / continuation); `PassageRetriever` over a synthetic project fixture behind a `ProjectContextProviding` interface; `AnswerGenerator` with streaming, bounded concurrency, a queue, cancellation and stale-event rejection; `StreamingAnswerAssembler` committing whole sentences to an immutable readable prefix; `ReadingAlignment` extracted from `PromptViewModel`; a card UI with reading, navigation and manual "Answer this"; a zero-dependency backend (`backend/`) with bearer auth, limits, timeouts, cancellation, a development-only fake provider and an honest unavailable state; a scenario evaluation harness (English and French) |
| **Excluded** | File import and document processing, persistence of sessions, a second transcription provider, deployment, billing, camera, App Store work, any change to script reading behaviour |
| **Likely modules** | New `prompter/Copilot/`, new `prompter/Prompt/ReadingAlignment.swift`, `Prompt/PromptViewModel.swift` (delegation only), `DebugTools/DebugMenuScreen.swift`, new `backend/` |
| **Owner decisions** | None to build. Real-API measurement and the mini-vs-nano comparison need provider credentials (Q3), supplied by the owner outside chat |
| **Acceptance** | Capture continues through classification, generation, reading, navigation, cancellation and provider failure; listening pause and reading pause are distinct; no fake answers when configuration is missing; committed readable text never changes while streaming; late responses attach to the correct version; session end rejects later events; new cards never steal focus; evaluation harness produces median/p95 per stage with sample size and failures |
| **Automated verification** | New `prompterTests/Copilot/` suite plus the full inherited suite, read from the result bundle |
| **Device verification** | Not performed in this increment — deferred to Increment 1, which owns the device audio protocol |
| **Safe stopping point** | Development-only entry point; production surface unchanged; no credentials committed |

**Delivered (2026-09-17).** Everything above, plus a configurable provider layer: direct OpenAI and
OpenRouter behind one contract, verified route/capability registry, profiles, bounded fallback, route
metadata, and a **tapable entry point** — Home → *Interview Copilot* → *Start demo* / *Start live* —
because the copilot was previously reachable only through a launch argument, so a normal launch showed
only the teleprompter. Results and verification status: [`CO_INTERVIEW_AI_PIPELINE.md`](CO_INTERVIEW_AI_PIPELINE.md).
**Still not measured:** real provider latency and answer quality (no credential), and device audio
(Increment 1).

---

## Increment 1 — Audio and alignment feasibility spike

**Objective.** Measure, on a real iPhone, the risks in arch §4.5 for the owner's confirmed scenario.

| | |
|---|---|
| **Included** | A `#if DEBUG` screen reachable from `DebugMenuScreen`, modelled on `DebugTranscriptScreen`; audio-mode toggle (`.measurement` / `.default` / voice-processing) for the spike only; exposure of `.audioTimeRange` per result; an optional `finalize(through:)` trigger after N ms of silence; a fixed non-personal answer text driving a `SlidingWindowMatcher`; on-screen aggregate counters (recognised question words, final latency, cursor moves and greyed tokens during interviewer-only speech, naive question-candidate flags during reading) |
| **Excluded** | Networking, models, persistence, production UI, any change to shipping behaviour, recording audio or storing transcripts |
| **Likely modules** | `DebugTools/`; `Speech/AudioCaptureService.swift` and `Speech/TranscriptionService.swift` only if the mode/time-range seams cannot be added from `DebugTools/` (requires approval, ground rule 7) |
| **Owner decisions** | **Q1** (scenario to test); **Q7** (test language — English proposed) |
| **Acceptance** | A report with, per mode and distance: interviewer-word recognition rate, median/max question-end→final latency with and without `finalize(through:)`, greyed-token count and cursor advance during interviewer-only speech, false question-candidate rate during reading. A clear go / change-mode / no-go recommendation for acoustic capture. If Q1 is A or B: a recorded result of whether the app can capture anything during a call, stated without extrapolation |
| **Automated verification** | Clean build; full suite equals baseline (no production change); `#if DEBUG` nesting scan shows no new ungated `print` |
| **Device verification** | The arch §4.5 protocol, scripted content, at least two distances and three modes |
| **Safe stopping point** | Debug-only code merged or discarded; no production behaviour changed. If no-go, stop and return to Q1 with numbers |

---

## Increment 2 — Reader extraction, no behaviour change

**Objective.** Separate audio lifetime from reading alignment and the reading surface, so an answer can
be read without a `Script` and without owning audio (arch §2.1).

| | |
|---|---|
| **Included** | Extract `ReadingAlignment` from `PromptViewModel` (index, matcher, cursor, spoken set, `applyCursor`, volatile feeding, silence tick input); extract the reading surface from `PromptScreen` into `AnswerReaderView` (text column, prefix/block measurement, `readingOffset`, `applyScroll`, `ScrollOwnership` wiring); `PromptViewModel` and `PromptScreen` re-composed from them. New synthetic, non-personal tests for `ReadingAlignment` (volatile revision, final catch-up, recovery not greying, interviewer-style off-text speech not greying) |
| **Excluded** | Cards, paging, any copilot UI, matcher or threshold changes, speech changes |
| **Likely modules** | `Prompt/PromptViewModel.swift`, `Prompt/PromptScreen.swift`, new `Prompt/ReadingAlignment.swift`, `Prompt/AnswerReaderView.swift`; tests in `prompterTests/Prompt/` |
| **Owner decisions** | None beyond approving the increment |
| **Acceptance** | All baseline tests pass unchanged (`VolatileReconciliationTests`, `SpokenTokenMarkingTests`, `ContextualMarkingTests`, `ScrollOwnershipTests`, `ScrollAnchorTests`, `ResumeGlideOwnershipTests`, `RealDeviceReadReplayTests`, …); new tests pass; `-promptReplay` renders the same fading and scroll sequence; `restartClearsTheSpokenSet` flakiness rate not worse than before (run ≥ 10 times before and after, both reported) |
| **Automated verification** | Clean full suite via `xcresulttool`; repeated-run flakiness report; `-promptReplay` screenshots before/after |
| **Device verification** | One script read of the demo script: follow, fade, manual scroll detach, automatic resume, Resume following, Restart, pause/resume, interruption — compared with pre-extraction behaviour |
| **Safe stopping point** | Pure refactor with parity evidence. If parity cannot be shown, revert; the copilot then embeds `PromptScreen` per card as a fallback design (heavier, noted) |

---

## Increment 3 — Question cards and navigation with synthetic events

**Objective.** Build the card model and live reading experience end-to-end with **scripted** questions
and answers — no AI, no network, no persistence.

| | |
|---|---|
| **Included** | `CopilotSessionCoordinator` (in-memory), `QuestionCard`/`AnswerVersion` structs with the arch §3.1 invariants; `CopilotScreen` pager of `AnswerReaderView`; compact question header; streaming preview (muted, following disabled) → stable version → following; horizontal swipe with vertical-only ownership detach (arch §2.2); Previous/Next and Latest controls; "newer question" indicator; version switcher; status indicators; end session; `-copilotReplay` launch argument driving `FakeTranscriptionService` plus a scripted event timeline (question appears, answer streams, follow-up arrives mid-reading, regeneration, late event for an ended session) |
| **Excluded** | Real detection, generation, documents, projects, persistence, networking |
| **Likely modules** | New `Copilot/` folder; `Prompt/AnswerReaderView.swift`; `App/RootView.swift` (debug harness entry only); `DebugTools/` |
| **Owner decisions** | None blocking; the brief §4.4 defaults are implemented as proposed and are easy to change |
| **Acceptance** | Unit tests: new card never changes selection; late event for another version/ended session is dropped; completed version text immutable; regeneration keeps prior version; returning restores cursor and spoken set; card creation idempotent per turn. UI tests (simulator, `-copilotReplay`): swipe changes card without detaching following on the destination; vertical drag detaches; Previous/Next/Latest reachable by VoiceOver labels with position ("Question 2 of 4"); script reading tests still pass |
| **Automated verification** | Clean full suite; new UI tests; accessibility identifiers asserted |
| **Device verification** | Read a scripted answer aloud while the harness appends a follow-up card: following continues, no focus change; swipe back and forth mid-read; light/dark; largest Dynamic Type; Reduce Motion |
| **Safe stopping point** | Feature hidden behind the debug harness; production UI unchanged |

---

## Increment 4 — Persistence foundation and project workspace

**Objective.** Introduce versioned SwiftData and the project workspace without document processing.

| | |
|---|---|
| **Included** | `VersionedSchema` V1 = current schema, V2 adds `InterviewProject`, `InterviewSession`, `QuestionCard`, `AnswerVersion`, `SourceReference` (and `ProjectDocument`/`DocumentVersion`/`DocumentChunk` shells) with a `SchemaMigrationPlan`; project list, create/rename/delete with confirmation and rollback (pattern: `ScriptListScreen.delete(_:)`); instructions editor (pattern: `ScriptEditorScreen`); session list per project; Increment 3 coordinator writes cards/versions when sessions are saved (per Q5) |
| **Excluded** | File import, extraction, AI, live capture from the project screen |
| **Likely modules** | `App/AppEnvironment.swift`, `App/RootView.swift`, `Models/`, new `Projects/`, `Editor/` patterns |
| **Owner decisions** | **Q5** (what a saved session contains); **Q8** (navigation placement) |
| **Acceptance** | Migration test: a store created by the current schema with scripts and settings opens under V2 with data intact; project deletion cascades (no orphan rows); scripts remain reachable and unchanged; session save/delete follows Q5 |
| **Automated verification** | Clean suite; migration test against a fixture store generated from V1 models in-test; cascade tests |
| **Device verification** | Install over a build of `32a583c` with existing scripts; confirm scripts, settings and appearance survive |
| **Safe stopping point** | Workspace usable for instructions and sessions; no document or AI behaviour |

---

## Increment 5 — Document import and processing

**Objective.** Import supported documents, extract and chunk them, show honest status, and support
replacement and removal (arch §6).

| | |
|---|---|
| **Included** | `fileImporter` + paste text; validation (type, magic bytes, size, pages, duplicates by hash); extraction for TXT, MD, PDF text layer (per page, scanned-page detection); DOCX **only if** a dependency-free extractor passes fixtures (else `unsupported` with a clear message); chunking with locators; states `ready` / `partiallyProcessed` / `unsupported` / `failed`; retry; replacement; removal and project deletion with file cleanup; project context-budget accounting and "too large" state |
| **Excluded** | OCR, images, spreadsheets, presentations, embeddings, any upload |
| **Likely modules** | New `Documents/`; `Projects/` UI |
| **Owner decisions** | **Q6** (formats and limits) |
| **Acceptance** | Fixture documents (synthetic, committed): each format → expected state and chunk count; a scanned-style PDF → `unsupported` or `partiallyProcessed`, never `ready`; malformed files → `failed` without crash; replacement leaves exactly one current version; removal leaves no file in the container and no chunk rows; a project never lists a document as Ready unless extracted text exists |
| **Automated verification** | Clean suite; fixture-driven extraction tests; filesystem cleanup assertions |
| **Device verification** | Import from Files and iCloud Drive; a 300-page PDF within limits; memory and time observed on the oldest available iPhone |
| **Safe stopping point** | Documents processed and inspectable locally; nothing leaves the device |

---

## Increment 6 — Provider backend (development) and grounding evaluation

**Objective.** Prove answer quality and honesty on synthetic projects **before** live wiring.

| | |
|---|---|
| **Included** | A minimal backend in its own directory (or repository, per Q3) implementing `POST /copilot/classify` and `POST /copilot/answer` (streaming) per arch §8.4, run locally by the owner with their own key; `ProviderClient` + `ProviderConfiguration` (base URL, enabled flag); `ContextBuilder`; citation validation; a grounding evaluation set of synthetic projects across subjects (not only job interviews) with expected-grounding labels; typed-question path in `CopilotScreen` against the dev backend |
| **Excluded** | Live audio-driven detection; deployment; production auth; any real personal documents in evaluation |
| **Likely modules** | New `Copilot/Provider/`, `Copilot/Context/`; backend directory; `Settings/` (debug-only backend URL) |
| **Owner decisions** | **Q3** (provider, backend hosting and auth); the owner performs account/key setup outside chat |
| **Acceptance** | On the evaluation set: 0 answers attributing a fact to a document that does not contain it (citation ids validated and spot-checked); 0 invented personal facts where documents lack them (placeholder present instead); prompt-injection fixtures in documents and transcript do not change output format or rules; removed-document fixtures never cited; answers from different projects never cite each other's chunks; measured time-to-first-token and complete-version time recorded (sets the latency target for Increment 7) |
| **Automated verification** | Unit tests for context building (ordering, budget, project isolation, removed versions excluded), citation parsing, late-event rejection with a fake provider; evaluation run is a scripted, repeatable job with stored aggregate results only |
| **Device verification** | Typed questions on device against the dev backend on Wi-Fi and cellular; offline shows an error state, not a hang |
| **Safe stopping point** | Grounding measured; no live audio; nothing deployed |

---

## Increment 7 — Live question detection and answer generation

**Objective.** Connect acoustic capture to detection and generation in the card experience.

| | |
|---|---|
| **Included** | `InterviewAudioInput` session lifetime (one `Transcribing` per interview session, interruption status, idle timer); `ConversationLog` with audio ranges and reading overlap; `TurnSegmenter`; `QuestionDetector` (local prefilter + remote classification); reading-overlap and open-turn feeding pause (arch §5.3); "Answer that", "Type a question", edit-and-regenerate; documents-still-processing banner; Option C, or C′ if Increment 1 decided so |
| **Excluded** | Background capture, speaker identification, synthesized speech, OCR, retrieval beyond small context |
| **Likely modules** | `Copilot/`, `Speech/` (time ranges, possibly `finalize(through:)` — approval per ground rule 7), `Prompt/ReadingAlignment.swift` |
| **Owner decisions** | **Q2** (speech source, informed by Increment 1); **Q4** must be decided before this is enabled beyond the owner's own testing |
| **Acceptance** | With a scripted interview (non-personal) played at the Increment 1 distance: detected questions ≥ an agreed recall on the script, false cards during reading ≤ an agreed rate, no reading-induced cards on the fixed-answer run, no greyed answer tokens during interviewer-only turns beyond an agreed count, latency within the target set in Increment 6; ending the session discards all later events; network loss keeps listening and reading working |
| **Automated verification** | Replay tests through `FakeTranscriptionService` with scripted interviews covering repeated finals, revised volatile text, overlapping reading, follow-ups mid-read, and end-session races; fake provider with delayed/out-of-order streams |
| **Device verification** | Full scripted interview in scenario C and D (per Q1), light and dark, with thresholds reported against the acceptance numbers |
| **Safe stopping point** | Copilot works for the owner's own testing behind a flag; not presented to others |

---

## Increment 8 — Failure recovery, deletion, disclosure and device validation

**Objective.** Make the copilot safe to hand to someone other than the owner.

| | |
|---|---|
| **Included** | Error states (microphone denied, locale unavailable, model download, offline, backend errors, rate limits) with recovery; interruption during reading and during generation; disclosure and consent flow per Q4; truthful usage-description strings; session and project deletion per Q5 including verification; privacy inventory for App Store labels; accessibility audit (VoiceOver over cards and controls, Dynamic Type, Reduce Motion) |
| **Excluded** | Pricing, subscriptions, analytics, new formats |
| **Likely modules** | `Copilot/`, `Projects/`, `Settings/`, `Resources/Info.plist` |
| **Owner decisions** | **Q4**, **Q5** final wording and behaviour |
| **Acceptance** | Every error state reachable in a test or a documented device step; deletion leaves no rows, files or cached context; no transcript text in Release logs (binary string scan as in `PROMPTER_CURRENT_STATE.md` §6); disclosure shown before the first cloud request per project; 45-minute device session without crash, with battery and thermal notes |
| **Automated verification** | Clean suite; deletion tests; Release-binary string scan |
| **Device verification** | Long session; call interruption; airplane mode mid-answer; smallest and largest supported iPhones |
| **Safe stopping point** | Candidate for external testing, subject to owner approval |

---

## Increment 9 — Later, each separately approved

- OCR for scanned PDFs and images (`RecognizeDocumentsRequest`), with its own accuracy evaluation.
- Additional formats per Q6 (RTF, spreadsheets as tables, presentations).
- Local lexical retrieval, then embeddings, when arch §7.3 triggers are met.
- Additional languages per Q7, each with its own recognition and answer evaluation.

These are listed so they are not smuggled into earlier increments.

---

## Increment 4 — Live mode behind the approved v2.5 interface (2026-09-19)

Bounded checklist. Each item reuses an existing component; none re-implements detection, retrieval,
provider routing or streaming.

1. **`CopilotSessionCoordinator`: make auto-generation optional.** Add `generationMode`
   (`.automatic` for the existing diagnostic screen, `.manual` for v2.5) and observation callbacks
   in the same idiom `InterviewAudioInput` already uses. Detection still runs; only the automatic
   `startGeneration` call is suppressed.
2. **`LiveInterviewFeed`** implementing the existing `InterviewFeed` over that coordinator:
   transcript lines and detected questions out, `requestAnswer` in. No second pipeline.
3. **Live readiness** — replace the permanently-disabled Live state with real checks that
   distinguish backend unreachable, client auth failure, provider unconfigured, microphone denied
   and speech-recognition unavailable.
4. **Screen wiring** — real capture state drives the waveform; no simulated reading in Live; real
   transcript deltas drive `ReadingAlignment` for the visible answer.
5. **Extra context** — the typed note travels in the answer request and into the backend prompt.
   Image attachments are **not** sent in this increment; the UI says so before generation rather
   than implying they were understood.
6. **Tests** — live feed routing, manual generation, stale events, readiness states, backend
   contract for the note.
7. **Docs** — pipeline doc, backend README, this plan, and the exact owner configuration.

Explicitly **out of scope** for this increment, and stated as such in the UI rather than faked:
document import beyond the existing sample project, image understanding, and speaker identification.
