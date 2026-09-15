# Architecture

Prompter (product name; bundle identifier `talk.prompter`) is a fully on-device iOS app.
There is no backend. This document tracks the real structure of the codebase and is
updated as milestones land — see AGENT_PROGRESS.md for the session-by-session log.

## System map

See ScriptWatch_WhitePaper_BuildSpec.md §7 for the full data-flow diagram. Summary:

```
Mic -> AVAudioEngine -> SpeechAnalyzer/SpeechTranscriber -> TranscriptStream
    -> Matching Engine (pure Swift, Foundation-only) -> PromptViewModel (@MainActor)
    -> ScrollAnimator -> PromptTextRenderer (SwiftUI)
```

SwiftData persists Script / PromptSession / UsageLedger / AppSettings locally.
RevenueCat (StoreKit 2) is the only third-party dependency and the only network traffic
besides Apple's one-time speech-model asset download.

## Folder structure (§14)

```
prompter/
├── App/            PrompterApp.swift (@main) · AppEnvironment.swift (ModelContainer) · RootView.swift (placeholder pending M5)
├── Models/         Script · PromptSession · UsageLedger · AppSettings (SwiftData @Model)
├── Speech/         AudioCaptureService · TranscriptionService (+ FakeTranscriptionService) · TranscriptStream · SpeechAssetManager
├── Matching/        Tokenizer · ScriptIndex · SlidingWindowMatcher · RecoverySearch · ConfidenceModel · PromptCursor · MatcherConfig · ReplayFixture (debug demo content)
├── DebugTools/     (not in original §14 tree — see docs/DECISIONS.md) ReplayPlayer/ReplayDebugScreen (§10.5) · DebugTranscriptScreen (§16 M2)
├── Prompt/         (M3) PromptScreen · PromptViewModel · ScrollAnimator · PromptTextRenderer
├── Editor/         (M5) ScriptListScreen · ScriptEditorScreen · AIRewriteService
├── Demo/           (M5) DemoScreen · DemoScript
├── Paywall/        (M6) EntitlementService (RevenueCat) · UsageMeter · PaywallScreen
├── DesignSystem/   Theme.swift · Typography.swift · Components/ · Mascot/
├── Accessibility/  (M7) OutdoorMode.swift
└── Resources/      Fonts/ (Space Grotesk, Inter, IBM Plex Mono, OFL-licensed) · Assets.xcassets · Info.plist
```

## Build configuration

- Swift 6 language mode (`SWIFT_VERSION = 6.0`), which enables complete strict
  concurrency checking by default (no separate `SWIFT_STRICT_CONCURRENCY` setting
  exists once a target is in Swift 6 mode).
- `IPHONEOS_DEPLOYMENT_TARGET = 26.0` (SpeechAnalyzer requires iOS 26+).
- No module-wide default actor isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION` is unset).
  The Xcode template originally set this to `MainActor`; removed in M1 because it
  implicitly isolated `Matching/`'s `Token` to the main actor, breaking the module's
  off-main-actor requirement (see docs/DECISIONS.md). Types that genuinely need main
  actor isolation (`ReplayPlayer`, `DebugTranscriptViewModel`) declare it explicitly.
- App target's Info.plist is a physical file at `prompter/Resources/Info.plist`
  (`INFOPLIST_FILE`, with `GENERATE_INFOPLIST_FILE = YES` still merging the
  build-setting-driven boilerplate keys) instead of pure auto-generation, because
  `UIAppFonts` is an array value that has no `INFOPLIST_KEY_*` build-setting
  equivalent. It is excluded from the target's Copy Bundle Resources phase via a
  `PBXFileSystemSynchronizedBuildFileExceptionSet` membership exception (otherwise
  the synchronized group tries to both copy it verbatim and process it as the
  Info.plist, producing a "Multiple commands produce" build error).
- RevenueCat is added via SPM (`https://github.com/RevenueCat/purchases-ios-spm.git`,
  up to next major from 5.0.0; resolved 5.83.1 as of M0). It is declared as a
  `packageProductDependencies` entry AND must also have a corresponding
  `PBXBuildFile` in the target's `PBXFrameworksBuildPhase` — declaring the package
  dependency alone compiles the package but does not link it into the app binary.
  Verified by inspecting the linked `prompter.debug.dylib` for `RevenueCat` Swift
  symbols after a clean build.

## Matching engine (M1)

See docs/MATCHING_ENGINE.md for the algorithm, tuning constants, and fixture-suite
results. `Matching/` imports Foundation only — no SwiftUI, no Speech framework — so it
is pure, deterministic, and independently unit-testable before any speech code exists.

## Speech pipeline (M2)

`Speech/` implements §11 against the real, installed iOS 26.5 SDK (verified via its
Speech.swiftinterface and AVFAudio headers — see AGENT_PROGRESS.md for exact symbols
and line numbers, since the public docs pages didn't return renderable content at
verification time).

- `AudioCaptureService` (`AudioCapturing` protocol): `AVAudioEngine` tap → raw
  `AVAudioPCMBuffer`s via `AsyncStream`. Deliberately **not** main-actor isolated —
  `AVAudioEngine` doesn't require the main thread, and keeping capture off the main
  actor matches §11.5's intent for the whole pipeline, not just the transcriber
  results loop. Handles `.playAndRecord`/`.measurement` session setup and
  interruption notifications (§11.8) — on interruption, it stops itself cleanly and
  leaves resuming to the caller (no session coordinator exists yet; that's M3/M4).
- `TranscriptionService` (`Transcribing` protocol): owns `SpeechAnalyzer` +
  `SpeechTranscriber`, converts mic buffers to the transcriber's best format via
  `AVAudioConverter`, and consumes `transcriber.results` in a plain (non-main-actor)
  `Task` — this is the specific thing §11.5 warns must stay off the main actor.
  Calls `SpeechAssetManager` itself before starting, so it works standalone without
  depending on an onboarding/pre-warm flow that doesn't exist yet (M5).
- `FakeTranscriptionService`: replays a scripted `[ScriptedResult]` with timing —
  same protocol, no microphone, usable in the Simulator and in the debug transcript
  screen's "Play Demo" button.
- `TranscriptStream`: pure Foundation state machine (§11.4) — on a final result,
  clears carried-over volatile text and emits normalized `[Token]` exactly once, so
  the matcher (once wired in M3) never sees duplicate tokens from revised volatile
  text.
- `SpeechAssetManager`: resolves/installs the on-device model
  (`AssetInventory.assetInstallationRequest` + `downloadAndInstall()`).

**Swift 6 concurrency notes** (the concrete traps hit while building this, not
hypothetical ones): `AVAudioPCMBuffer`/`AVAudioConverter` aren't marked `Sendable` by
Apple, so `TranscriptionService.swift` and `AudioCaptureService.swift` use
`@preconcurrency import AVFoundation` to treat those specific Sendable-boundary
mismatches as warnings rather than errors (the standard, Apple-recommended bridge for
not-yet-audited framework types) — the file otherwise still gets full Swift 6 checking
for the app's own code. `TranscriptionService.start()` deliberately runs the
mic-buffer-consuming loop directly in its own `Task` body rather than inside a nested
`async let` child task, because `AsyncStream<AVAudioPCMBuffer>` (non-Sendable element)
cannot be "sent" across a child-task boundary — only the `Sendable`-safe pieces
(`AnalyzerInput` stream, `transcriber.results`) are split into concurrent `async let`
children.

## Volatile reconciliation (M4, 2026-08-18)

`PromptViewModel` feeds `.volatile` deltas to the matcher incrementally (see the
deviation note on the class), which means it has to decide, on every volatile update,
which of the newly-revealed words are safe to commit versus still liable to be revised
by the *next* volatile update for the same utterance — `Matching/` itself stays
append-only and deterministic on principle (§10.5, replay-testability), so this
reconciliation has to happen here, in the ViewModel, before anything reaches
`SlidingWindowMatcher.advance()`. The real-device bug this fixes (build 0be5fb8, M4
retest): the very first `.volatile` for a session was a single truncated letter ("W"
before "Welcome" resolved), which the old logic fed immediately as a whole word since
it was a strict extension of nothing — but the *next* volatile revised it into a
completely different word ("Welcome"), and the matcher's ring buffer has no way to
retract an already-fed token, permanently poisoning the alignment window until enough
later words aged it out (13 seconds of stuck-at-cursor-0 in the observed trace). The
fix withholds only the **trailing word** of each volatile update — the one word still
in a position to be revised by whatever comes next — and feeds it only once it's
either (a) no longer trailing (a later word has appeared after it in the same
utterance, proving it settled) or (b) confirmed by the eventual `.final`, which already
walks word-by-word to catch up on anything volatile never got a chance to feed. This
costs at most one word of latency per utterance and eliminates the whole class of
revision-after-feed bugs, rather than attempting true retraction (rebuilding whatever
the matcher already ingested) — which would mean `SlidingWindowMatcher` accepting an
"undo" operation, a much bigger change to a component whose entire value is being a
simple, append-only, replay-verified state machine.

## Debug tooling (`DebugTools/`)

Not part of the original §14 tree (see docs/DECISIONS.md) — added in M1/M2 for two
debug-only, `#if DEBUG`-gated screens reachable from the placeholder root view:

- **Matcher Replay** (§10.5): plays a small self-contained fixture (`ReplayFixture` /
  `DemoReplayFixtures`, in `Matching/` since it's pure Foundation content) through a
  real `SlidingWindowMatcher` on a timer, rendering the §12.4 spoken/current
  sentence/future text styling. No Speech code involved — works in the Simulator.
- **Live Transcript** (§16 M2): drives either the real `TranscriptionService` (device
  only) or `FakeTranscriptionService` (Simulator-safe demo), showing volatile (gray)
  vs. finalized (black) text and measuring/logging time-to-first-volatile-result —
  the number DEVICE_TEST.md asks for to close the M2 gate.
