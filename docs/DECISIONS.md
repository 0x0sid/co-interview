# Decisions

> **INHERITED FROM PROMPTER — historical reference only.** This describes *Prompter*, a separate
> paused project. It is **not** a Co-Interview specification and its roadmap, milestones and release
> criteria do not apply here. Start at [`CO_INTERVIEW_START_HERE.md`](CO_INTERVIEW_START_HERE.md).


> **Status notice.** This remains the authoritative record of **why** each decision was made, with
> its evidence, and still governs that area. For *current* status see
> [`PROMPTER_CURRENT_STATE.md`](PROMPTER_CURRENT_STATE.md).


Dated, non-obvious choices and their justification. Newest first.

## 2026-08-15 — `contextualStrings` biasing wired in (M4 Step 3)

§11.7's limitation note said not to fake `contextualStrings`/`AnalysisContext` if the current
SDK doesn't expose it — checked against the real iOS 26.5 SDK's `Speech.swiftinterface` first,
per that instruction: it does. `AnalysisContext` (a `Sendable` class, `@objc init()`,
`contextualStrings: [ContextualStringsTag: [String]] { get set }`) and
`SpeechAnalyzer.setContext(_:) async throws` both exist exactly as named. Wired in: `Transcribing
.start(locale:contextualStrings:)` (both conformers updated; `FakeTranscriptionService` ignores
the parameter — nothing to bias in scripted playback), `TranscriptionService` builds an
`AnalysisContext`, sets `contextualStrings[.general]`, and calls `setContext` before
`prepareToAnalyze` — skipped entirely (no-op) when the list is empty, so callers with no script
loaded (`DebugTranscriptScreen`, predates the real Prompt screen) don't need special-casing.

`PromptViewModel.distinctiveVocabulary` computes the actual word list fed in: script tokens not
in `MatcherConfig.commonWords` (the same list `RecoverySearch`'s Step 2 eligibility gate uses),
deduplicated, capped at 100. Directly motivated by a real on-device symptom: the owner's own
custom test script had "Mimi" and "Hannah" (character names) consistently mangled by
general-purpose dictation with no vocabulary hint.

**Cannot be validated in the Simulator** (§11.6 — real `Speech` doesn't run there); the M1
fixture suite is unaffected by this change (it's entirely in the Speech layer, not
`Matching/`), confirmed by re-running it and seeing byte-identical numbers. Needs the owner's
own device test to confirm it actually reduces proper-noun misrecognition — no on-device claim
is made here.

## 2026-08-14 — v2 design system recorded in spec, made available, not applied

Owner directed a full palette/type replacement for §13 of `docs/BUILD_SPEC.md` (paper/card/ink/
action tokens replacing the v1 cream/navy/blue set; Hanken Grotesk replacing Inter as the UI
face; Source Serif 4 added as a user-selectable serif reading face) — explicitly as a spec
update to apply at M5/M7, not a restyle of the current `#if DEBUG` scaffolding.

Two things were done now, deliberately scoped to match "spec-only, don't restyle":
1. `docs/BUILD_SPEC.md` §13 replaced with the v2 tokens/typography rules, with a migration note
   stating v1 (`Theme.swift`'s current tokens) is still what `DebugTools/`/`Prompt/` actually
   render as of this date.
2. Hanken Grotesk and Source Serif 4 downloaded (Google Fonts' `google/fonts` GitHub repo,
   `ofl/hankengrotesk` and `ofl/sourceserif4`, confirmed via the real GitHub API rather than a
   guessed URL) and embedded the same way M0 embedded the original three: `.ttf` files under
   `Resources/Fonts/`, `OFL.txt` under `Resources/Fonts/Licenses/`, both registered in
   `UIAppFonts`. Their real PostScript names and variation-axis ranges
   (`HankenGrotesk-Regular`, `wght` 100-900; `SourceSerif4Roman-Regular`, `wght` 200-900,
   `opsz` 8-60) were read directly from the downloaded files via `fontTools`, not assumed.
   `Typography.swift` gained `hankenGrotesk(_:weight:)`, `sourceSerif4(_:weight:)`, and a
   `reading(_:weight:face:)` dispatcher — but `body(_:weight:)` (still Inter) is untouched, and
   nothing in `DebugTools/`/`Prompt/` calls the new functions yet, so no existing screen's
   appearance changes. `Theme.swift`'s v1 color tokens are likewise untouched — v2 colors exist
   only in the spec doc so far, not in code, since no screen was to be restyled this round.

**Deliberately not done**: no Settings screen exists yet (that's M7) to actually list the new
fonts' licenses in-app, so "licenses in Settings" (per the spec's own requirement, matching how
v1's fonts are described) is recorded as an M7 dependency, not stubbed early.

## 2026-08-13 — Replaced the two fixed Prompt Screen debug entries with a paste-a-script screen

M3 originally shipped two separate `RootView` debug entries: "Debug: Prompt Screen (Demo)"
(`FakeTranscriptionService` playing a fixed short script) and "Debug: Prompt Screen (Live Mic)"
(the real mic, but still locked to a fixed longer script). The Demo entry was also the direct
cause of an early confusing bug report ("the screen ignores my voice and scrolls on its own") —
it was never wired to the mic at all, by design, which wasn't obvious from the UI alone. Now
that the live-mic path itself is confirmed working on real hardware, the Demo entry's value
(exercising the UI without a mic) is outweighed by the confusion risk of having two similarly-
named entries, one of which is silently mic-free.

Replaced both with one `PromptTextInputScreen` — a plain `TextEditor` (seeded with the same
longer test script as a starting point, editable/replaceable) feeding into the same live-mic
`PromptScreen`. This is a lightweight stand-in for real script input, not the M5 script
list/editor (§12.1, SwiftData-backed `Script` model) — just enough to test arbitrary text
without waiting for that milestone. `FakeTranscriptionService` itself is untouched and still
used by `DebugTranscriptScreen`'s "Play Demo" button; only `PromptDemoFixture`'s
Demo-entry-specific `scriptText`/`scriptedResults` were removed as dead code, and its remaining
`liveTestScriptText` was renamed to `defaultScriptText` to match its new role as an editable
seed rather than a fixed device-test fixture. The `prompterUITests` test that drove the removed
Demo entry (`testPromptScreenDemoAdvancesAndDoesNotCrash`) was deleted rather than repointed —
its whole premise (asserting on `FakeTranscriptionService`'s fixed timings via
`PromptDemoFixture.scriptText`) no longer has a target once that entry point is gone.

## 2026-08-13 — `PromptViewModel` feeds `.volatile` deltas to the matcher too, not just `.final`

§11.4 says volatile transcript text is display-only, and M2's `TranscriptStream` was built
exactly that way: only `.final` deltas carry tokens, because volatile text gets revised and
re-emitted as more audio arrives, so naively re-feeding it whole each time would mean duplicate/
inconsistent tokens. M3's `PromptViewModel` followed that contract literally at first.

Two rounds of on-device `[PromptDebug]` logging (owner-requested instrumentation, this session)
showed the real cost: `SpeechTranscriber` only finalizes every 2-15 seconds even during
continuous reading, and since the cursor only ever moved on `.final`, it sat frozen for that
whole stretch, then jumped 20-95 tokens at once — this was the dominant cause of a reported
"a lot of delay." Separately, `SlidingWindowMatcher`'s own silence-freeze timer only resets on
`.final` too, so it fired ~1.5s after nearly every sentence regardless of whether the reader had
actually gone quiet — the reported "unstable" advancing-then-frozen cycling. Adding
`SpeechTranscriber.ReportingOption.fastResults` (confirmed to exist via the real SDK's
`Speech.swiftinterface`) shrank the gaps somewhat but far from eliminated them, and did nothing
for the freeze-cycling, since that's driven by the matcher's own `.final`-only reset, not by
finalization cadence.

Fixed by having `PromptViewModel` feed the *newly appended* words from each `.volatile` delta to
`matcher.advance()` too, incrementally, alongside the existing `.final` handling — kept safe
against volatile's revision behavior by only ever feeding a strict prefix-extension of what was
already fed for the current utterance (a mid-utterance revision is silently skipped, not fed
wrong), and having the eventual `.final` feed only whatever tail wasn't already covered, so no
word is double-ingested into the matcher's ring buffer. `SlidingWindowMatcher`/`MatcherConfig`
themselves are untouched — same public `advance(spoken:now:)` API, same fixture-tested internal
logic — so `SlidingWindowMatcherTests`' M1 gate numbers are unaffected. That gate only ever
calls `advance()` with whole finalized tokens, though, so this new live incremental-feed calling
pattern is exercised by nothing but a real device — verification for it is on-device console
logs, not a unit test, at least until it's stable enough to justify writing one.

## 2026-08-10 — `AudioCapturing`/`AudioCaptureService` are not main-actor isolated

Initially wrote `AudioCaptureService` as `@MainActor` (matching a common assumption
that `AVAudioEngine` wants the main thread) — this immediately collided with
`TranscriptionService` (deliberately not main-actor isolated, per §11.5) trying to
`await` its `start()`: the compiler correctly refused to return a non-`Sendable`
`AsyncStream<AVAudioPCMBuffer>` across that actor boundary. Checked the actual
requirement rather than routing around the error: `AVAudioEngine.installTap`/
`start()`/`stop()` don't require the main thread (the tap callback already fires on
an engine-internal audio thread regardless of caller). Removed `@MainActor` from the
protocol and the class — keeping capture off the main actor is more consistent with
§11.5's intent for the whole pipeline, not just the transcriber-results loop.

## 2026-08-10 — `@preconcurrency import AVFoundation` in the Speech pipeline files

`AVAudioPCMBuffer` and `AVAudioConverter` aren't marked `Sendable` by Apple, which
under Swift 6 strict concurrency turned every buffer hand-off (tap callback →
`AsyncStream`, buffer → converter closure) into a hard error, not just a warning.
`@preconcurrency import AVFoundation` in `AudioCaptureService.swift` and
`TranscriptionService.swift` is the standard, Apple-recommended bridge for
not-yet-Sendable-audited framework types — it downgrades those specific
boundary-crossing checks to warnings (then cleaned up to zero warnings by fixing the
underlying capture patterns) without weakening strict concurrency checking for any of
this app's own code. Confirms §11.5's warning was not overstated: this pipeline is
genuinely easy to get wrong under Swift 6 without deliberate attention.

## 2026-08-10 — `AVAudioConverter.convert(to:from:)` instead of the block-based API

First draft used the block-based `convert(to:error:withInputFrom:)` (matching common
online examples), which needs a shared mutable "have I supplied input yet" flag
captured in a `@Sendable` closure — exactly the kind of thing Swift 6 strict
concurrency flags (`captured var in concurrently-executing code`). Since this
pipeline only ever converts one already-complete buffer at a time (no multi-buffer
streaming state to manage), the simpler one-shot `convert(to:from:) throws` (verified
via a minimal compile check against the iOS 26.5 SDK) does the same job with no
shared mutable state and no closure at all.

**Reversed 2026-08-13** — this was wrong for our actual use case. Apple's
`AVAudioConverter.h` documents `convertToBuffer:fromBuffer:error:` explicitly as "a
conversion which does not involve codecs or sample rate conversion... If the
conversion involves a codec or sample rate conversion, you instead must use
convertToBuffer:error:withInputFromBlock:." Our conversion (mic's native rate →
Speech's 16kHz `bestAvailableAudioFormat`) *is* a sample-rate conversion. On-device
testing first hit an `AVAudioConverter.mm` assertion crash (undersized output
buffer), and after fixing that sizing, hit the real issue: `AudioConverterConvertComplexBuffer:
sample rate conversion not allowed` (error -50) on every buffer, silently dropping
all audio. Switched back to the block-based API — the "shared mutable flag" concern
above was real but manageable (a local `var` inside a synchronous, non-escaping-at-
the-call-level closure invoked once per `convert()` call is not a concurrency
problem in practice) and unavoidable, since the one-shot API cannot do sample-rate
conversion at all, not just less elegantly.

## 2026-08-10 — `DebugTools/` folder, not in the original §14 tree

§10.5's matcher replay screen and §16 M2's debug transcript screen are both
`#if DEBUG`-only utility screens with no natural home in the milestone-numbered
folders (`Prompt/` is M3's real prompt screen — putting debug scaffolding there risked
confusing that milestone's scope). Added a `DebugTools/` folder instead. The
fixture *data* each screen plays (`ReplayFixture`/`DemoReplayFixtures`) stays in
`Matching/` since it's pure Foundation content with no UI dependency.

## 2026-08-09 — Removed `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` from the app target

The Xcode template set this project-wide (a Swift 6 "approachable concurrency"
convenience that implicitly isolates every declaration in the module to the main
actor unless marked `nonisolated`). It broke `Matching/`'s hard constraint almost
immediately: `Token`'s initializer became main-actor-isolated, so the (correctly)
`nonisolated` fixture-generation code in the test target couldn't call it from a
synchronous context — a compile error caught this before it became a runtime bug.
Since the spec's own architecture diagram (§7) explicitly calls out
`PromptViewModel (@MainActor)` as a deliberate annotation, the implied default for
everything else (`Matching/`, and `Speech/` in M2) is *not* main-actor-isolated —
§11.5 is explicit that speech results must be consumed off the main actor to avoid
the documented 14s-first-result-latency trap. Removed the blanket default; future
UI-layer types that do need main-actor isolation (like `PromptViewModel`) will
declare it explicitly, matching the spec's own diagram.

## 2026-08-09 — Sentence/paragraph segmentation via Foundation, not NaturalLanguage

§10.1 specifies `NLTokenizer` for sentence segmentation, but the M1 task's hard
constraint requires `Matching/` to import Foundation only (no SwiftUI, no Speech,
implicitly no NaturalLanguage either, given the stated intent is pure/synchronous/
testable code with zero framework surface beyond Foundation). Resolved the tension
by using Foundation's own `String.enumerateSubstrings(in:options:)` with
`.byParagraphs` / `.bySentences` / `.byWords` (ICU-backed, ships in Foundation, no
extra import) instead of `NaturalLanguage.NLTokenizer` — real Unicode-aware sentence/
word segmentation without violating the Foundation-only constraint. See
`ScriptIndex.swift` and docs/MATCHING_ENGINE.md.

## 2026-08-09 — Product name: "Prompter" instead of spec's "ScriptWatch"

The build spec (ScriptWatch_WhitePaper_BuildSpec.md) names the product ScriptWatch
throughout. The owner directed the actual shipping name to be **Prompter**
(website prompter.talk). Xcode project name, target name, and bundle identifier
(`talk.prompter`) all use Prompter/talk.prompter. All *technical* architecture,
folder structure, data model, and matching-engine content in the spec is otherwise
followed verbatim — only the product name changed. Doc/code comments refer to
"Prompter"; the original spec file is kept as-is for reference since it is the
technical source of truth.

## 2026-08-09 — Info.plist: physical file instead of pure auto-generation

`UIAppFonts` (required to embed the three OFL fonts, §13) is an array-valued
Info.plist key with no `INFOPLIST_KEY_*` build-setting equivalent. Kept
`GENERATE_INFOPLIST_FILE = YES` but pointed `INFOPLIST_FILE` at a physical
`prompter/Resources/Info.plist` containing the full key set (Xcode merges the two).
Because the app target is a `PBXFileSystemSynchronizedRootGroup`, the physical
Info.plist file living inside the synchronized folder was *also* being auto-added to
Copy Bundle Resources, colliding with the ProcessInfoPlistFile step on the same
output path ("Multiple commands produce ... Info.plist"). Fixed with a
`PBXFileSystemSynchronizedBuildFileExceptionSet` (`membershipExceptions =
(Resources/Info.plist)`) on the target, which is the modern (Xcode 16+) equivalent of
unchecking "Target Membership" for that one file. Verified by rebuilding clean and
reading back `UIAppFonts` from the built `Info.plist` with `PlistBuddy`.

## 2026-08-09 — Variable font weight selection via CoreText variation axis

Space Grotesk and Inter are shipped by Google Fonts as single variable TTFs (`wght`
axis 300–700 and 100–900+`opsz` respectively). Their `name` table only exposes one
static PostScript name each (`SpaceGrotesk-Light`, `Inter-Regular`), so
`UIFont(name:)` alone cannot address other weights. `Typography.swift` builds a
`UIFontDescriptor` with `kCTFontVariationAttribute` set to
`[axisIdentifier: value]` (axis identifier is the four-char-code integer for
`'wght'`, `0x77676874`) layered on top of the base PostScript name, which is the
Apple-documented mechanism for instantiating a specific point on a variable font's
axis (verified against the on-disk CoreText.framework headers in the iOS 26.5 SDK —
`CTFont.h` lines ~1160–1230 — since the public web docs page did not render
machine-readable content at verification time). IBM Plex Mono ships static weights
(Regular, Medium) so it uses plain `Font.custom(name:size:)`.

## 2026-08-09 — RevenueCat: SDK only, not RevenueCatUI

Added only the `RevenueCat` SPM product (not `RevenueCatUI`) at M0. The paywall
(§12.5) is custom-built per spec ("RC Paywall templates only as time-critical
fallback"), so `RevenueCatUI` is deferred until/unless M6 needs the fallback path —
keeps the dependency surface minimal until it's actually used.

## 2026-08-09 — Deployment target explicitly pinned to iOS 26.0

The template Xcode generated `IPHONEOS_DEPLOYMENT_TARGET = 26.5` (matching the
installed Xcode 26.6 / iOS 26.5 SDK default). Spec §15 requires the minimum, not the
latest, deployment target: 26.0. Repinned explicitly on the project-level and test
target build configurations so the app doesn't silently require a point release
newer than necessary.

## 2026-08-18 — M5: real app structure, v2 design system applied, deviations

M5 replaced the debug-list root with the real Home/Editor/Demo/Prompt screens (§12.1-
§12.4) and applied the v2 design system (§13) everywhere, including the previously-
exempted `#if DEBUG` screens (the 2026-08-14 migration note said v2 wasn't retrofitted
onto debug scaffolding *at that time* — M5 is the point the spec named for that to
happen, since the debug screens now share components — `ReplayButtonStyle`,
`ScriptStyling` — with the real screens and would otherwise look inconsistent next to
them). `Matching/`/`Speech/`'s actual logic is untouched; the M1 fixture suite's
numbers are byte-identical to the last verified M4 run (mean 0.9334353481254782,
1 false jump / 500 words) — confirmed via a real test run, not assumed from the diff
being UI-only.

Deviations, stated plainly rather than silently simplified:

- **Scroll animation** (§12.4: "smooth, interruptible, spring-based... cursor updates
  at 10 Hz interpolated"): implemented as two `Animation` presets
  (`ScrollAnimator.normal`/`.recovery`, an interpolating spring and a slower one for
  recovery-grade jumps) driving SwiftUI's own `scrollTo`, not a hand-rolled 10 Hz
  sampled interpolation loop. This delivers the same *feel* (smooth, interruptible,
  a visibly longer glide on recovery) through SwiftUI's built-in spring physics,
  which already runs well above 10 Hz — a custom sampling loop would duplicate that
  for no visible difference, so it was not built.
- **End-of-session summary** (§12.4: "duration, minutes left today"): shows duration
  only. `UsageMeter` doesn't exist yet (M6) — there is no real "minutes left today"
  number to show, and per §24.6 (no invented numbers) this session will not fabricate
  one. Revisit once M6 lands.
- **"UIColor created with component values far outside the expected range"**
  (owner-reported, appeared on two prior device test logs): investigated this
  session — every color construction in the app was audited (`grep` across the full
  `prompter/` tree for `UIColor(`, out-of-range `.opacity()`, and `Color(hex:)`
  usage); `Color(hex:)` masks each channel to `0...255` before dividing by 255, so it
  is mathematically incapable of producing an out-of-range component regardless of
  input. Attempted to reproduce in Simulator via a console log stream through app
  launch, Home, Editor, and Debug navigation — did not reproduce in this pass. Left
  **open, not resolved** — most likely a system-framework-internal warning (common
  and usually harmless, per general iOS platform behavior) rather than app code, but
  that is not proven either way. Flag if it recurs on the next device test with the
  exact screen/action that preceded it — that's the missing piece to actually
  isolate it, and this session did not have a live device to check against.
- **AI-rewrite diff** (§12.3: "shows a diff"): line-level (classic LCS), not
  word-level — sufficient for paragraph-shaped script text and simple to review;
  word-level would only matter for very long unbroken paragraphs, which the format
  discourages anyway.
- **Outdoor mode's heavy current-sentence underline** (§13: "heavy 3pt underline"):
  drawn as a manual `Rectangle` overlay under the current sentence block, not via
  `AttributedString`'s native underline attribute — `Text.LineStyle` has no width
  parameter, so exact stroke thickness isn't reachable through the attribute alone.

## 2026-09-10 — M5.2: matcher token timestamps are wall-clock, not audio-relative (documented deviation, unfixed)

**Deviation between documented and actual behaviour, found while tracing the matcher's input
contract for the cursor-lost P0. Recorded rather than fixed, because the fix lands in production
`Speech/` and this task was not authorized to change it.**

`TranscriptDelta.timestamp` is documented in `Speech/TranscriptStream.swift` as *"Audio-session-
relative time (seconds since the transcriber started)"*, and `PromptViewModel`'s `[PromptDebug]`
output labels it `audio_ts`. The value actually supplied is:

```swift
let startTime = Date()                                   // TranscriptionService.swift:101
...
let elapsed = Date().timeIntervalSince(startTime)        // :112
transcriptStream.ingest(text: text, isFinal: ..., at: elapsed)   // :114
```

— **wall-clock elapsed at the moment the app observes the result**, which includes ASR
finalization lag and any main-actor scheduling delay. True audio time is available:
`attributeOptions: [.audioTimeRange]` is already requested at `TranscriptionService.swift:63` and
its result is unused for this purpose.

**Why it matters.** Every time-based rule in the matcher consumes this value as `now`:
`silenceFreezeSeconds`, `recoverySustainedSeconds`, `mediocreConfidenceSustainedSeconds`,
`extendedStallSeconds`, `stallCandidateFreshnessSeconds`. Under ASR lag the two clocks diverge, so a
"2.5 s stall" may be less than 2.5 s of speech. It also means the M5.2 conclusion that *elapsed time
is an unstable proxy for window content* is understated, not overstated.

**Not fixed here.** Changing it alters production speech-path behaviour and every time-based
threshold's meaning at once, which needs its own measurement round and the owner's approval. Two
honest options when it is taken up: switch token stamping to the audio time range (correct, but
re-tunes every threshold), or correct the documentation and the `audio_ts` label to say wall clock
(cheap, keeps current behaviour). Recorded in `AGENT_PROGRESS.md` 2026-09-10 as a question for the
owner and in docs/MATCHING_ENGINE.md §M5.2.1.

## 2026-09-10 — M5.2: fixture timing is reconstructed, and replays are labelled by provenance

Replay fixtures previously fed whole utterances at a single timestamp or spaced words 0.001 s apart.
That is not merely imprecise: it made every time-dependent matcher rule untestable, and it caused a
fix (`staleWindowSeconds`, commit `6eece17`) to pass its regression test while being a no-op on
realistic input. The fix was removed and the claim retracted.

Fixtures are now built on `DeviceTiming`, whose inter-event gap distribution is pooled from the
suite's captured traces. **This is a synthetic timing variant, not a captured trace**, and is
labelled as such: the production path gives every word in one delta the *same* timestamp, while
`DeviceTiming` gives each word its own. No captured matcher-input trace exists for the P0 session,
so its per-word grouping cannot be reproduced — only approximated. Every replay in the suite is now
classified captured / reconstructed / synthetic in docs/MATCHING_ENGINE.md §M5.2.3, and conclusions
are stated at the strength its class supports.


## 2026-09-11 — Presentation contract for the Prompt screen (supersedes all earlier styling/scroll instructions)

Recorded as the **current** contract. It supersedes every earlier instruction in this file and in
`AGENT_PROGRESS.md`, in particular the M5.1 seventh-round decision to remove fading entirely and
show only a single travelling grey marker. **Fading is wanted; inferring it from cursor position is
not.** No instruction claiming words should stay dark forever remains in force.

### 1. Fade only words actually pronounced

Individually confirmed spoken words fade; the current word and unread words stay dark. No sentence
or paragraph fades because the cursor entered or passed it. A paragraph may go fully grey only once
each of its words has been confirmed individually. Cursor jumps and recovery never mark skipped
words as spoken, and **"spoken" is never inferred from the interval between the previous and new
cursor positions, even when the state is `.advancing`.**

Implemented as `PromptViewModel.newlySpokenTokens(fedWords:from:to:state:scriptTokens:)` — a pure
function, tested directly in `prompterTests/Prompt/SpokenTokenMarkingTests.swift`. Only the words in
a feed are eligible, paired positionally back from the new cursor, each admitted only if it
resembles the token it landed on (`spokenWordMinSimilarity` = 0.5, the same "is this even the same
word?" bar as `MatcherConfig.freshestTokenMinSimilarity`, so ordinary ASR wobble such as "write" for
"written" still counts).

**What this fixed:** the `155 -> 184 advancing` step at 94.041 s in the 2026-09-10 device session
greyed 29 tokens at once. The screenshots show that result; the cause is the interval rule.

### 2. Smooth scrolling during normal reading

The page moves up as reading progresses, keeping the reading position near a stable line. No abrupt
sentence-by-sentence lurches, no jitter, no restarting the animation on every word. During silence
or off-script speech an in-flight transition settles and then holds. Manual scrolling and its
documented interaction with automatic following are preserved. Driven by reading progress only —
**no fixed-speed or WPM mode** (§25 forbids one).

Implemented as `PromptScreen.scrollTarget`: **two fixed stops per sentence** instead of one. Both
anchors are constants and the mid-sentence one is *smaller* than the resting one, which pulls the
block further up the viewport so the page always moves forward.

**Deliberately not** a continuous sweep of the anchor with reading progress: that was tried and
falsified earlier — for a block shorter than the viewport the scroll offset moves *backwards* as the
fraction grows, producing the "it scrolls up instead of down" report.

### 3. Fast repositioning after a genuine distant skip

On a confirmed reposition the page arrives promptly with one short smooth transition, does not
scroll through the skipped paragraphs, then resumes normal following. Skipped words stay dark.

Implemented by changing `ScrollAnimator.recovery` from
`.interpolatingSpring(stiffness: 60, damping: 16).speed(0.7)` to `.easeOut(duration: 0.45)`. A
spring's settle time grows with distance, so the old value literally crawled through a long skip.
A fixed duration also bounds how long a scroll stays in flight, so a newer matching decision cannot
find an old animation still travelling to a stale destination.

**Presentation only.** No matching threshold changed: `extendedStallJumpThreshold` stays 0.88, the
suffix baseline is untouched, and the matching cursor is not moved by anything here. Faster visual
repositioning must never be obtained by lowering a matching bar.


## 2026-09-11 — M5.3.1: the two proven causes of the reported fading and scrolling failures

The 2026-09-11 device test failed on all three presentation requirements. Both causes are now
established from code and the captured session, not inferred from the screenshots.

### Cause 1 of the grey unread text: a second greying path that has nothing to do with `spokenTokenIndices`

`PromptScreen` dimmed the **entire current sentence block** to 0.55 opacity, pulsing forever:

```swift
.opacity(isListeningPulseTarget(block) && listeningPulseOn ? 0.55 : 1.0)
// isListeningPulseTarget = block.id == currentSentenceIndex && cursor.state == .holding
```

It selected the block **purely by cursor position**, and applied whenever the matcher was
`holding`. In the captured session the cursor held for minutes at a time (tokens 8, 14, 30, 46, 47,
107, 118, 119, 139), and ¶1's second sentence spans tokens **3-35** — so most of an unread paragraph
was faded out. That is exactly what the screenshots show: "Welcome to Prompter." in the darker
*spoken* grey (genuinely read, tokens 0-2) and the rest of the paragraph in a lighter wash.

The previous round's per-word fix to `applyCursor` was correct and is retained, but it addressed
only `spokenTokenIndices`. **It could not have fixed this, because this path never consulted it.**
That is the lesson: one styling input was fixed while a second, independent one kept dimming text.

**Removed outright**, along with its state and its `repeatForever` animation, rather than retuned —
the contract forbids cursor position determining whether text looks spoken, and an "I'm listening"
cue that dims unread script cannot satisfy that. §12.4's ad-lib pulse is withdrawn as specified;
if a listening cue is wanted later it must not touch script text.

Verified exhaustively: the app now contains **three** `opacity(` calls, all button-press feedback,
and **two** `foregroundColor` assignments, both in `ScriptStyling` — `palette.ink` by default and
`palette.spoken` only for members of `spokenTokenIndices`.

### Cause 2: the reading line was anchored to the start of a block, not to the rendered line

Two independent faults:

1. `readingLineFraction` was **0.28** — roughly a quarter of the screen left empty above the reading
   line. Now **0.12**, just below the safe area. A trailing spacer was added so the final lines can
   still reach that position.
2. The scroll target was the **start of a sentence block**. A long sentence is one block — ¶1's
   second sentence is 33 tokens, many rendered lines — so by the end of it the reader had drifted
   far below the anchor.

Fixed by computing the anchor from **measured geometry**. `scrollTo(id:anchor:)` aligns unit point
`a` of the block with unit point `a` of the viewport, so to put a reading position `p` through a
block of height `H` at viewport fraction `F` of viewport height `V`:

```
  blockTop + a·H = a·V        (what scrollTo guarantees)
  blockTop + p·H = F·V        (what we want)
  =>  a = (F·V − p·H) / (V − H)
```

`H` comes from a `BlockHeightPreference`, `V` from a `GeometryReader`. **This is why the earlier
attempt failed and was reverted:** it swept the anchor with `p` alone — the numerator's second term
without the denominator — and for `H < V` that moves the page *backwards*, which is precisely the
"it scrolls up instead of down" report. With `H` and `V` measured the sign falls out of the algebra.
Pinned by `ScrollAnchorTests.theAnchorMovesMonotonicallyAsReadingProgresses`.

The target is quantised to 1/50 so it changes about once per rendered line rather than once per
token, which is what previously restarted the animation and read as jitter.

### Debug diagnostics added (log-only, `#if DEBUG`)

- `[Styling]` — every cursor step that could grey text prints the tokens greyed, the word that
  confirmed each, and the step that produced it; or `greyed=NONE (skipped text stays dark)`.
- `[Scroll]` — target token, sentence, progress, measured block height, viewport height, computed
  anchor, and transition type.

These exist so "which function greyed an unread paragraph?" is answerable from a log. The captured
2026-09-11 session could not answer it, which cost a device round.

### Reported separately, not fixed: the 139 → 248 recovery at 107.051 s

> **Superseded 2026-09-12 — the clamping attribution below was wrong.** See the M5.3.2 entry: the
> candidate is anchor 236 with a 12-token window, so `236 + 12 = 248` exactly. **Nothing is
> clamped.** The paragraph below is kept as the record of the wrong first answer.

`VOLATILE-FED "thats" cursor -> token 248 confidence=0.91 state=recovering`.

The trigger is legitimate — the reader said "That's the word test", and ¶5 begins "That's the whole
test" at token 235. **The destination is inflated by end-of-script clamping.**
`SlidingWindowMatcher.applyAdvance` computes `min(anchor + windowSize, scriptTokens.count)`; with an
anchor around 236 and `recoveryAlignmentWindow` = 12 that is 248 — the script end — while the reader
was at roughly token 235-238.

Consequences: the page jumps to the very end rather than to the line being read, and every
subsequent word reports `advancing` at a cursor that cannot move. **Spoken-token marking is not
affected**: the jump is `recovering`, which marks nothing, and the later `advancing` steps have
`newIndex == previousIndex`, which also marks nothing.

This is an engine behaviour in `Matching/`, outside this round's authorized scope, and the
thresholds and suffix baseline were left unchanged while diagnosing it. **It needs separate
authorization**; the smallest correction is to treat `anchor + windowSize` as an upper bound on the
*matched span* rather than a cursor destination when it reaches the script end.

### Instrumentation gap found while replaying the capture

`[PromptDebug]` logs FINAL catch-ups as `(final, N new of M total)` **without the words**, so a
faithful replay of the catch-up path cannot be reconstructed from a log. The new `[Styling]` line
records `fed=[...]`, which closes the gap going forward.


## 2026-09-12 — M5.3.2: evidence-based recovery marking, block-walking anchor, and the overshoot measured

### 1. Recovery no longer discards positively aligned words — and the "a / longer / test" report

The previous rule returned nothing for a `.recovering` step. That over-corrected: recovery must not
grey the interval it *skipped*, but the words it was *given* are real speech that aligned to real
script tokens. Both properties now come from one mechanism — eligibility is capped at
`fedWords.count` tokens ending at the new cursor, so a jump can never reach back over what it
skipped, whatever its state — so the state test was removed rather than special-cased.

**Verified against the capture, not by reasoning.** `[Styling]` from the replay harness:

```
applyCursor 1->5  advancing fed=["to","prompter","this","is"]        greyed=[1:to 2:prompter 3:this 4:is]
applyCursor 5->9  advancing fed=["a","longer","test","script"]        greyed=[5:a 6:longer 7:test 8:script]
applyCursor 9->15 advancing fed=["written",…,"enough"]                greyed=[9:written … 14:enough]
```

"a", "longer" and "test" grey correctly, and multi-word updates grey **each** aligned word.
`CapturedSessionMarkingTests` replays the captured `VOLATILE-FED` sequence and pins this, including
that "prompter" stays dark in the device capture because ASR heard "Pronto" and never confirmed it.

### 2. The anchor: block-walking solver, rendered-line progress — and a residual limitation

Three separate defects were found and two are fixed.

**(a) Clamping at zero stopped the page.** `scrollTo(id:anchor:)` gives `blockTop = a·(V − H)` with
`a ∈ [0, 1]`, so a block's top can never go above the viewport top. Holding reading position `p` of
a block of height `H` at `F·V` needs `blockTop = F·V − p·H`, which goes negative once `p·H > F·V` —
at `F = 0.12`, `V = 800`, `H = 400` that is **p = 0.25**. `PromptScreen.scrollTarget` now walks
forward to a later block whose top is still reachable. Pinned by
`ScrollAnchorTests.followingContinuesThroughALongSentence`.

**(b) Progress was estimated, not measured.** It used the token fraction. It now uses the rendered
height of the sentence's text *up to the current word*, laid out at the same width and font
(`ScriptStyling.prefixOfCurrentSentence` + `PrefixHeightPreference`) — the real vertical offset of
the line being read.

**(c) A stale prefix measurement made the target oscillate.** `[Scroll]` showed two targets for the
same token — `sentence=3 anchor=0.48` then `sentence=2 anchor=0.22` — because a block change left
the previous block's prefix in place for a frame. The measurement is now tagged with the block it
belongs to and ignored otherwise. The oscillation is gone from the post-fix capture.

**Residual limitation, not fixed, stated precisely.** `[Scroll]` still shows `anchor=0.000` at
`progress=0.20` on a 443 pt block. Between "current block's top at 0" and "next block's top at its
own minimum" there is a **band of scroll positions no `scrollTo(id:anchor:)` call can express**, and
for a ten-line sentence that band is wide. Walking forward closes it only when the next block
happens to fall inside the viewport.

The smallest correction is to stop positioning by block id at all and drive the scroll by **content
offset** — iOS 17+'s `ScrollPosition` binding with `.scrollTargetLayout()` can set an exact offset
and still leaves manual dragging intact. That is a structural change to `textColumn` and is proposed,
not made, in this presentation round.

### 3. Motion measurement — target updates measured separately from animation

Frame sequences were captured from the production `PromptScreen` under `PromptReplayHarness` and the
frame-to-frame vertical displacement measured by row-signature correlation, alongside the `[Scroll]`
log of target updates. Target updates are sparse and correct in ordering; **smoothness of the
animation between them is not established by this method** — a still sequence at 0.35 s intervals
cannot distinguish a smooth glide from a jump. Durations were therefore **not** adjusted: doing so
without separating target cadence from animation lag would be tuning blind, which is what the
instruction warns against.

### 4. The end-of-script jump: measured, and the earlier attribution corrected

Reconstructed at the 107.051 s step (`CapturedSessionMarkingTests.recordTheEndOfScriptOvershootCandidate`,
`docs/evidence/M5.3.2/overshoot-candidate.txt`):

```
  ring buffer (reconstructed) : [okay, lets, jump, thats, the, word, thanks, for, reading, all, the, way, to, the, thats]
  effective recovery window   : [thats, the, word, thanks, for, reading, all, the, way, to, the, thats]  (size 12)
  selected candidate          : anchor 236  score 0.667
  script at anchor            : "the whole test thanks for reading all the way to the end"
  cursor calculation          : anchor(236) + windowSize(12) = 248
  clamped?                    : NO — the candidate itself points here
```

**My earlier "end-of-script clamping" attribution was wrong and is withdrawn.** Nothing is clamped:
`236 + 12 = 248` exactly. The cursor reports the **end of the matched window**, and that window
genuinely matched — the reader had recited "thanks for reading all the way to the end" moments
earlier, so those words were still in the ring buffer. The newest word ("thats") aligns at 236; the
window's end is 247.

So the behaviour is the documented `anchor + windowSize` convention meeting a ring buffer that still
holds an earlier recitation of the ending — **not** an off-by-one at the script boundary. Whether
the cursor should report the window's end or the newest word's position is an engine question in
`Matching/`, outside this presentation round. No threshold was changed. Spoken-token marking is
unaffected: "thats" pairs with token 247 ("end"), which does not match, so nothing greys.


## 2026-09-12 — M5.3.3: offset-driven scrolling, and the jump reconstruction left unresolved

### 1. Scrolling: `scrollTo(id:anchor:)` replaced with a content offset

**The 2026-09-12 device capture proved the saturation, five times.** With the `[Scroll]`
instrumentation in place the failure is unambiguous:

```
[Scroll] token=12  sentence=1 progress=0.27 blockH=365 anchor=0.000   … then silence
[Scroll] token=44  sentence=2 progress=0.27 blockH=324 anchor=0.000   … then silence
[Scroll] token=74  sentence=3 progress=0.42 blockH=203 anchor=0.000   … then silence
[Scroll] token=93  sentence=4 progress=0.24 blockH=365 anchor=0.000   … then silence
[Scroll] token=134 sentence=6 progress=0.30 blockH=324 anchor=0.000   … then silence
```

Every long sentence stalled roughly a quarter of the way in and did not move again until the next
sentence began. That is the structural limit of `scrollTo(id:anchor:)`: it can only produce
`blockTop = a·(V − H)` with `a ∈ [0, 1]`, so a block's top can never rise above the viewport top —
and holding the reading line fixed inside a long sentence requires exactly that.

**API verified against the installed iOS 26.5 SDK before choosing** (§24.1):
`SwiftUICore.ScrollPosition` provides `mutating func scrollTo(y: CGFloat)` and
`var isPositionedByUser: Bool`, and `View.scrollPosition(_:anchor:)` binds it
(`SwiftUI.swiftinterface:21433`, `SwiftUICore.swiftinterface:690-712`). An offset accepts any
content position, so there is no unreachable band and no block to switch to.

`PromptScreen.readingOffset` computes it from measured geometry only — each block's **full** height
including its paragraph padding, the stack spacing, and the rendered height of the current
sentence's text up to the word being read:

```
  readingContentY = Σ(earlier block heights + spacing) + paragraphPadding + prefixHeight
  targetOffset    = max(0, readingContentY − readingLine · viewportHeight)
```

**Measured result** from the replay harness after the change — the target now moves continuously
through the same long sentence that used to stall:

```
  token=5   prefixH=44   targetY=20.1
  token=9   prefixH=89   targetY=64.4
  token=15  prefixH=177  targetY=153.1
  token=23  prefixH=266  targetY=241.8
  token=36  block=2      targetY=439.1
```

`prefixH` climbs one rendered line at a time; `targetY` follows monotonically. No saturation, no
block-switching jump.

Trailing space is now `viewportHeight · (1 − readingLineFraction)`, which is exactly what the final
lines need to reach the reading position.

### 2. Marking: pairing stops at the first misalignment

Requirement: recovery must not discard positively aligned words. The state test is gone — a
`.recovering` step now greys the words it was given, verified against the captured steps
`5->6 fed=["a"]`, `6->7 fed=["longer"]`, `7->8 fed=["test"]`, which the previous build logged as
`greyed=NONE`.

A cap of `fedWords.count` bounds **how many** tokens may be marked; it does not establish **which**.
Testing an insertion found a real hole: "this is erm a longer test" against "this is a longer test"
shifts every earlier pair by one, and `"is"` against `"this"` scores **exactly 0.5** — the floor —
so it would have been greyed. Backward pairing now **stops at the first failed pair**: the newest
word is the best-supported pairing (it is the one the matcher advanced on), everything earlier is
inference, and that inference is only sound while it keeps matching.

The newest word is **not** certain. A matching decision can be wrong, and when the matcher advances
on a wrong alignment the newest-word pairing is wrong with it — the captured stall is exactly such a
case, where the cursor sat at 216/220 while the reader was at 219-230. The anchor's real property is
narrower: those pairs depend on **one** matcher decision instead of a chain, so they fail together
rather than independently. Marking accuracy is therefore bounded by matching accuracy, and no styling
rule can raise it above that.

The cost is that a misheard word in the middle of a multi-word feed leaves the words before it dark
too. That is the safe direction, and small in practice: the volatile path feeds one word at a time,
and multi-word feeds are FINAL catch-ups where the cursor advances by about one anyway.

### 3. Motion: recorded, target trajectory measured, smoothness still not established

A screen recording of the production `PromptScreen` under `PromptReplayHarness` is preserved at
`docs/evidence/M5.3.3/replay-recording.mp4`, together with the timestamped `[Scroll]` target
trajectory above.

**Stated precisely: I cannot inspect video playback.** The target trajectory is measured and
continuous — that is the half of the question the instruction asks to separate out, and it is
answered. Whether the *animation between targets* glides or jumps is not established: frame capture
through `simctl io screenshot` runs at roughly 0.2 s per frame with non-uniform spacing, which
cannot distinguish the two. Durations were therefore **not** tuned.

### 4. The 139 → 248 jump: reconstruction does not match, kept unresolved

The reconstruction selects a candidate scoring **0.667**; the device reported **0.91** (and the
2026-09-12 session shows a comparable jump at **1.00**). **The reconstruction therefore does not
reproduce the original decision, and no root cause is assigned.**

Most likely explanation, not yet confirmed: the device jump was applied from the **retained**
`bestStallCandidate` — snapshotted at an earlier tick, against a different ring buffer — whereas the
reconstruction computes a **fresh** candidate at the moment of the jump. `state=recovering` is
consistent with the retained path (`applyBestStallCandidateIfAboveThreshold`). Two further
differences remain possible and are not excluded: the reconstruction rebuilds the ring buffer from
`VOLATILE-FED` lines only, because FINAL catch-up feeds are not logged with their words; and the
decision time differs from the tick used.

Earlier attributions are both withdrawn: **not** end-of-script clamping (the arithmetic
`236 + 12 = 248` disproves clamping for the reconstructed calculation, but that calculation is not
the device's), and **not** reproduced. It stays open. No engine change was made.


## 2026-09-12 — M5.3.4: the scrolling contract (manual ownership + paced following)

Two device failures, two distinct causes. Both are visible in the 2026-09-11 capture.

### Root cause A — automatic targets overwrote the reader's drag

`.scrollPosition($scrollPosition)` does **not** block dragging. The fault was that
`onChange(of: readingOffset)` applied `scrollTo(y:)` unconditionally, so any new target — and the
capture shows targets re-issued even while merely holding, e.g. `token=155 … targetY=1693.0` then
`1707.0` at 130.4 s — immediately overwrote wherever the reader had dragged to. The page appeared
un-draggable because every drag was undone within a frame.

`isPositionedByUser` alone does not settle ownership: it reports that *a* user gesture happened, not
that following should stay suspended afterwards. Ownership is now explicit state:

- Any touch sets `isManuallyDetached` via a `simultaneousGesture` — observing only, so it never
  competes with the ScrollView's own drag or its deceleration.
- While detached, targets are still computed but **never applied** (`[Scroll] … SUPPRESSED`), so
  nothing fights the drag and nothing snaps back on release.
- An unobtrusive **"Resume following"** control appears only while detached, and returns to the
  current confirmed reading position with the short repositioning transition.
- **Restart** clears detachment, resets the offset to 0 and resumes following.

Manual scrolling changes the viewport only — the matching cursor and spoken-token history are
untouched.

### Root cause B — the motion was stepped because each line settled before the next arrived

The rendered prefix height advances in **whole rendered lines**, so targets arrive as ~40 pt steps.
The capture shows exactly that: `targetY` 14.7 → 55.4 → 136.4 → 177.0 → 217.4 → 298.4 → 339.0, all
multiples of one line. Correct geometry does not imply continuous motion.

The animation was `.easeOut(0.3)`, which **decelerates to a stop** — and at a reading pace of about
one line per second it finished long before the next target. Each line was therefore a separate
settle, which is precisely what reads as stepping.

`ScrollAnimator.following(interval:)` is now a **linear** ramp whose duration is the *observed*
interval between recent targets (an exponential average), so the animation is still travelling when
the next target lands and consecutive line-steps blend into one continuous drift. The interval is
measured, never configured — there is no fixed-speed or WPM mode (§25) — and it is clamped to
`0.25…1.2 s` so neither a burst nor a long silence can run the motion away or leave it trailing.
Confirmed distant repositioning keeps its own separate `easeOut(0.45)` transition.

**Measured after the change** (replay harness): interval tracks 0.50 → 0.90 → 1.03 → 0.96 → 1.15 →
1.20 s and clamps at the maximum, each target labelled `transition=following`.

### Root cause C — stale prefix geometry at block boundaries

`PrefixMeasurement` was tagged with the block id only. At a boundary the overlay re-renders with the
new `block.id` while its `Text` still holds the previous prefix for one layout pass, so a stale
height arrived labelled with the *new* block — the `token=155` reversal (1693 → 1707 → 1693) and the
doubled `token=36` (prefixH 365 then 14).

The measurement now carries the **cursor token** as well, and `readingOffset` returns `nil` unless
both the block and the token match the current reading position. Measured after the change: block 2
produces a **single** target (`token=36 block=2 prefixH=14 targetY=453.1`) where it previously
produced two. The only remaining duplicate is at `token=0` during initial layout, before reading
starts.

### Verification limitation, stated precisely

**I could not perform a real drag.** `simctl` has no drag command, and scripted input via System
Events is refused by macOS (`error -1743`, accessibility not authorised). Ownership (root cause A)
is therefore verified by code inspection and by the `[ScrollOwner]` / `[Scroll] … SUPPRESSED`
diagnostics, which will prove or disprove it on the next device read. Root causes B and C are
verified by measurement from the replay harness, above.

A screen recording is preserved at `docs/evidence/M5.3.4/replay-recording.mp4`. **I cannot inspect
video playback**, so displayed-motion smoothness remains judged by you, not asserted by me.


## 2026-09-12 — M5.4: bounded contextual marking (the rule, written before implementing)

**Capture status, stated first:** `Pasted text(20260912-100902).txt` was **not attached and is not on
disk**. The three screenshots are. Everything below therefore rests on the screenshots, the specific
events quoted in the request (9→15, 151→214, the 120.983–130.571 s stall, the repeated
`targetY=14.7` / `targetY=643.0` targets) and the source — **not** on a replay of that capture. No
claim here is described as capture-verified.

### Why a contextual rule is needed

The screenshot shows "…you automatically. If you pause for a" grey, then "moment, the cursor should
hold steady and wait for you, rather than guessing ahead." **dark** — a sentence the reader
demonstrably read through, because the reading continues past it. Two mechanisms produced that:

1. **Direct marking pairs only the words of the current feed.** A recovery fed `["off","script"]`
   marks two tokens even though the words that *caused* the reacquisition — a whole clause still in
   the ring buffer — also aligned. The newly fed words are not the whole supporting evidence.
2. **Stop-at-first-mismatch discards the rest of a feed.** Introduced to stop an insertion greying
   mispaired tokens, it also throws away correctly aligned words *after* the break, so one
   misrecognised word can leave a clause dark.

### The rule

**Coverage is inferred only between two directly confirmed anchors, and only across a short gap.**

| Element | Value |
|---|---|
| Evidence required | a directly marked token **before** the gap and a directly marked token **after** it |
| Maximum gap bridged | `maximumBridgedTokens` = **6** contiguous tokens — about one clause |
| Continuity breaks (never bridged across) | any `.recovering` landing, any advance larger than `forwardCapWithoutRecovery`, and the start of the script |
| ASR substitution | one dark token between two anchors → bridged |
| ASR insertion | the mispaired tokens stay dark until anchors exist on both sides, then bridged if within the bound |
| Delayed FINAL | bridging re-runs on every update, so gaps close retroactively when the catch-up lands |
| Off-script speech | produces no anchor after the gap, so nothing is bridged |
| Deliberate skip | the skip is a continuity break, so a skipped sentence or paragraph is never bridged |
| Ambiguous | if either anchor is missing, or the gap exceeds the bound, **nothing is marked** |

**What this explicitly does not do:** it never greys everything before the cursor, and speech activity
alone never establishes coverage. The 151→214 interval is a recovery landing — a continuity break —
so it can never be coloured wholesale. What *can* be recovered there is the coverage the reacquiring
words themselves support at the destination, which is handled by widening the direct rule (below),
not by bridging.

### Two supporting changes to direct marking

- **Pair against recent fed-word history, not just this feed.** `PromptViewModel` keeps a bounded
  rolling history of the words it has fed. At a landing, pairing walks backward from the new cursor
  against that history, so a reacquisition supported by a clause still in the buffer marks the
  tokens that clause actually covers — never the interval it jumped.
- **Stop-at-first-mismatch becomes skip-one-and-continue.** A single failed pair is treated as a
  substitution and skipped; two consecutive failures still stop the walk, which is what an insertion
  produces. This recovers the clause-after-a-stumble case without reopening the insertion hole.

### Debug distinguishability

`[Styling]` reports `direct=[…]` and `bridged=[…]` separately, so inferred coverage is never
mistaken for recognition in evidence.

**No matching threshold is changed by any of this.**


## 2026-09-12 — M5.4 findings from the full capture (`Pasted text(20260912-100902).txt`)

**Capture status corrected:** the log *was* supplied — pasted inline in the request. It is from
build `323cb17`, i.e. **before** the M5.4 changes, so it shows the behaviour being fixed rather than
the fix. The three screenshots were on disk and were read.

### The two omissions, verified against the real token layout

Token indices are the app's own (248 tokens), read back from its `[Styling]` output rather than
re-derived.

**`9→15 recovering fed=["enough"] greyed=[14:enough]`.** Script 10-14 is
`specifically so you have enough`, and the reader had just said all five ("…So you have enough
math…"). Only `enough` was in the *newest feed*, so only token 14 was marked. Pairing against the
recent **history** instead marks 10-14 — four correctly aligned words recovered, none inferred.

**`151→214 recovering fed=["off","script"] greyed=[212:off 213:script]`.** The FINAL was
"The cursor should hold its position rather than chasing you off script." — the whole clause was
spoken, and it is what produced the reacquisition, but only the two newest words were marked.
History pairing maps the clause to the tokens it actually covers (≈203-213). The 151→214 interval is
**never** coloured: eligibility reaches back at most `fedHistoryLimit` = 16 words from the landing,
so it cannot span a 63-token jump.

**Where stop-at-first-mismatch discarded evidence.** It treated any single failed pair as the end of
trustworthy alignment, so one misrecognised word ended the walk and left everything before it dark —
visible in the screenshot as a whole sentence the reader read through. A single failure is now
treated as a substitution and skipped; **two consecutive** failures still stop the walk, which is
the signature of an insertion shifting every earlier pair.

### The 120.983 → 130.571 s stall is a TRACKING failure, not presentation

Diagnosed read-only; **no threshold changed, no `Matching/` edit made.**

```
120.983  "somewhere"  cursor -> 216  conf 0.75  advancing
121.049  "as"                    216  conf 0.62  holding
121.925  "in"                    216  conf 0.65  holding
121.965  "the"                   216  conf 0.68  holding
125.830  "i"                     216  conf 0.65  holding
127.722  "smoothly"              216  conf 0.53  holding
128.805  "to"                    216  conf 0.51  holding
129.673  FINAL                   216  conf 0.62  holding
130.571  "whats"      cursor -> 222        advancing
```

The reader was reading ¶4 continuously ("…words somewhere else in the text, and should pick back up
smoothly once you return to reading…"). **Confidence sat in the ambiguous band for ~9.6 s** —
between `recoveryTriggerThreshold` (0.45) and `advanceThreshold` (0.72) — so:

- the ordinary advance never fired, because it needs ≥ 0.72;
- the mediocre-confidence stall path armed after `mediocreConfidenceSustainedSeconds` (4.0 s), but
  `applyBestStallCandidateIfAboveThreshold` then demanded `extendedStallJumpThreshold` = **0.88**,
  because the stall had passed `extendedStallSeconds` (8.0 s).

So the cursor was pinned by 0.72 while the reader was genuinely reading, and the escape hatch was
gated at 0.88, which this ASR quality never reaches. That is the same class as the M5.2 cursor-lost
P0 and it is **outside this presentation round's scope**.

**Proposed change, not made, for separate approval:** the ambiguous band is the problem, not the
recovery bar. A sustained run of *mediocre but monotonically consistent* local anchors — the log's
anchors were tracking the reader's words throughout — is different evidence from a flat low-
confidence stall, and could justify an ordinary advance without touching `advanceThreshold` or
`extendedStallJumpThreshold`. Regression evidence it would need: `MetaCommentaryFalseJumpTests` and
`OffScriptCommentaryHoldTests` unchanged, M1 false jumps still 0.

**Presentation must not paper over this.** Scrolling is driven by the cursor, so while the cursor is
stalled the page correctly stops too. No interpolation is allowed to run ahead of an uncertain
cursor — "microphone active" is not permission to scroll.

### Presentation: identical targets and a mis-fed pacing estimator

The capture shows both, plus SwiftUI's own complaint:

```
tokens 4-8    targetY=14.7   (five identical targets)
tokens 60-64  targetY=643.0  (five identical targets)
onChange(of: Optional<CGFloat>) action tried to update multiple times per frame.
```

`readingOffset` returns `nil` while the prefix is re-measured for a new token, so `onChange` fires
again with the *same* value, and each re-issue restarted the in-flight ramp from rest. The estimator
also treated those no-op callbacks as reading cadence, dragging the interval toward its 0.25 s floor
— visible in the capture as `interval=0.25s` during ordinary reading — which made the ramp shorter
than the reader's real pace, so it finished early and waited. That waiting is the "frequent stops".

Both fixed by refusing to re-issue an unchanged target (`offsetEpsilon` = 1 pt) and by pacing only
from applied, *moving* targets.


## 2026-09-12 — M5.5: tracked-read advance, and the insertion false positive closed

**Tracking stall.** See docs/MATCHING_ENGINE.md §11 for the full diagnosis. Two earlier claims of
mine are withdrawn: confidence does *not* stay in 0.45-0.72 (it reaches 0.42 and 0.39), and 0.88 was
never implicated (the retained candidate peaks at 0.750, below the ordinary 0.80 bar). The block was
the local advance, with the anchor tracking the reader perfectly at 0.62-0.70. The correction is a
`trackedRunLength` = 3 / `trackedAdvanceThreshold` = 0.70 path, swept against the P0, the M5.1 false
jump, the stall and M1 together. **No global threshold changed.**

**Insertion false positive, closed.** The previous round left `"is"` against `"this"` marked at
exactly 0.5 — the admission floor — after an insertion shifted the pairing. "One mismatch =
substitution, two = insertion" was never a proven classification and is replaced by an evidence rule:
pairs **before** any failure are anchored to the newest word, the best-supported pairing available
because it is the one the matcher advanced on (best-supported, not certain — see above); pairs
**after** a failure are inferences through a possibly shifted alignment and
must clear `shiftedPairMinSimilarity` (0.8, `perTokenMatchThreshold`) rather than 0.5.

The ambiguous token now stays dark while independently supported words later in the clause keep their
colour, which is the requested preference. Guarded by the concrete `"is"`/`"this"` case in
`CapturedSessionMarkingTests.anInsertionDoesNotCauseMisalignedWordsToBeGreyed`.

**Limits of the rule, stated:** it is conservative, not correct. It cannot detect an insertion, only
refuse to trust position after alignment has broken once. A substitution followed by clean words
still marks them, and a shifted pair that happens to score ≥ 0.8 would still be marked — that case is
not observed in any capture but is not excluded.

**History provenance checked.** The 16-word history admits tokens by similarity, not recency:
`historyCannotImportUnrelatedCommentaryIntoCoverage` feeds twelve words of pure commentary at a
63-token landing and asserts nothing in the jumped interval is marked.

## 2026-09-12 — M5.5 evidence assessment: the tracked-read gain measured, and my claim cut down

The M5.5 result was reported from **one checkpoint** (216 → 220 at 127.9 s). Measured across the
whole capture on a single clock, the improvement is much smaller than that sample implied, and the
earlier wording is withdrawn.

**Longest incorrect hold: 8.68 s → 7.72 s.** The hold does not break up; it **relocates** from token
216 to token 220. Error first exceeds 3 tokens at 120.167 s before and 124.918 s after — an onset
delay of **0.90 s**. Position error improves by a flat 4 tokens at every row — one shift, not
progressive re-acquisition — and ends at 14 tokens before, 10 after. So: the path delays and shallows
the divergence, it does not fix it, and it does **not** resolve the owner's complaint about stops
during continuous reading. Full trajectory in docs/MATCHING_ENGINE.md §11.

**Correction to my own metric.** I previously reported "time to regain the reader: 120.11 s,
unchanged". That measured the *pre-stall* acquisition, when the cursor was already correct (error 0
at 119.209 s), not recovery from the stall. Measured correctly, **neither configuration regains the
reader within the capture** — error grows monotonically to 14 (before) and 10 (after).

**Widening the anchor-step bound is not the missing lever.** `trackedAnchorStep` ∈ {1, 2, 3} produce
byte-identical results on the P0, the M5.1 false jump, the stall and M1. The run is gated by
freshest-token support. 1 is kept as the stricter setting at no measured cost.

**A claim of mine was falsified mid-assessment and the test now records the truth.** I documented
"`step == 0` counts toward the run" and wrote a test asserting that repeating a word would extend it.
It does the opposite — repetition destroys freshest support and collapses the run to 0. The rule is
**both** things: stationary anchors do count, and commonly (242 of 6395 ticks across the M1 suite),
but literal repetition is not how that happens. The consequence, now stated in the rule table: three
observations evidence a **stable, freshest-supported alignment, not forward progress**.

**The off-script negative is narrowed.** Three traces were tested and none fired the tracked path
(M5.1 meta-commentary, a repeated common word, an off-script echo of nearby script vocabulary). But
all three are blocked by the **freshest-token conjunct**, not by anchor consistency — the run never
exceeded 1. The claim "off-script speech cannot satisfy this rule" is **not** made and is not
supported; off-script audio producing freshest-supported, slowly-advancing anchors would satisfy it.

**Residual gap, bounded.** Replacing "needs better recognition": the current alignment and
eligibility rules **reject this captured ASR sequence** — and "better recognition is required" is
**not established**, because the recorded evidence shows the alignment was *correct the whole time*.
The local anchor advances 207 → 223, one token per fed word, exactly the reader's pace; only the
score (0.39-0.70) never clears the bar. The failure is in eligibility, not recognition.

Over 29 fed words: 23 exact, 5 substitutions, 1 tokenisation mismatch (`backup` scores 0.33 against
`up` but **1.00** against `back`+`up`).

**Correction to my own claim.** I wrote "0 near-misses — nothing sits just under
`perTokenMatchThreshold`". That was an artefact of my classifier, which counted "near" only at or
above the bar. `you`/`your` scores **0.75**, 0.05 *under* it, and contributes 0. Accurate statement:
five of six non-exact words are ≥ 0.25 below the bar; one is 0.05 below it, and that one is outside
the stall window. Two mechanisms are implicated, both in `Matching/` and both needing written
approval: all-or-nothing token credit, and the missing tokenisation join. Neither is a threshold.

**Styling certainty claims removed.** The newest-word pairing is the *best-supported* pairing, not a
certain one: it rests on a matcher decision, and the captured stall is precisely a case where that
decision was wrong (cursor at 216/220 while the reader was at 219-230). Marking accuracy is bounded
by matching accuracy; no styling rule raises it above that. Wording corrected in
`PromptViewModel.newlySpokenTokens` and in the two places above that said "certain".

## 2026-09-12 — M5.6: the split-script-token join, and a hypothesis of mine falsified

**Authorized narrow scope:** alignment only. No global token-scoring semantics, no threshold, no
`Speech/`, no reconciliation, no styling change. Full rule and evidence in
docs/MATCHING_ENGINE.md §12.

**What it does.** One spoken token may align against **two adjacent script tokens** when the
recogniser emits a compound as a single word. Eligibility is narrow by construction: the 1:1 pairing
must already have failed, the concatenation must score ≥ 0.95, it must beat the 1:1 alternative, and
at most one join per window. Score normalization is unchanged — the denominator stays the weight
total over spoken positions — so a join cannot inflate a window. The cursor lands at
`anchor + scriptConsumed`, which is one further per join because the reader really did say both
tokens. Applied to the **local search only**; recovery and suffix paths keep the strict 1:1 walk.

**Result.** On the captured stall the longest incorrect hold falls **7.72 s → 3.86 s** and the
position error **never again exceeds one token** (it previously reached 10). The compound mismatch
had dragged the alignment one token out of phase, and every later window paid for it.

**A hypothesis of mine is falsified.** I had written that global all-or-nothing token credit "is the
one that would actually move stop frequency". That is **withdrawn**. The local alignment fix alone
produced the improvement, with no change to credit, thresholds, or scoring semantics — so the error
I had attributed to substitutions was largely the phase shift the compound word introduced. On this
capture a local correction was sufficient and a global scoring change was not required. No such
proposal is made; §12.6 lists the evidence any future one would owe, including which off-script
windows would also gain score, and two strictly narrower local alternatives to try first.

**Two measurement corrections, both mine.** (1) "Error first exceeds 3 tokens: 120.167 → 124.918,
onset delayed 0.90 s" was internally inconsistent — 120.167 s is where the error *reaches* 3, and
124.918 − 120.167 is 4.751 s. The 0.90 s figure was the `err ≥ 4` crossing reported against the wrong
timestamp. The metric is now defined once and derived across all thresholds (§11). (2) "Neither
configuration regains within the capture" was unscoped: the replay ends at the **escape**, and the
device log quoted above ends at the same event on a clock offset by **+1.768 s** (130.571 log =
128.803 audio_ts). Behaviour after the escape is **unmeasured**, not known.

**Anchor correctness is now validated, not inferred.** An advancing anchor is not the same as a
correct alignment, so the anchor's mapped claim (`anchor + windowSize`) was checked tick by tick
against the labelled reading: **13 of 17 ticks map exactly**, three are one token behind — precisely
the span between the compound mismatch and the `+2` self-correction — and one is the pre-lock
recovery tick.

**Known cost, accepted for this round.** A joined advance moves the cursor two tokens for one fed
word, and `newlySpokenTokens` pairs backward 1:1, so the joined words **stay dark** (measured:
nothing marked for that advance). This is the safe direction and preserves "grey means you actually
said this" — no word the reader did not say is marked, and neither neighbour is touched — but those
words were spoken and do not grey. Styling was out of scope; this is the first candidate for the
next round.

## 2026-09-12 — M5.6 follow-up: three more measurement corrections, all mine

**1. "Longest incorrect hold" was the wrong metric name and conflated two things.** It measured only
how long the cursor *value stayed unchanged*, which says nothing about correctness — a reader pausing,
or reading words the cursor already covers, produces a stationary cursor that is behaving correctly.
Now reported separately:

| Configuration | Longest stationary | Longest out of range (error > 2) | Max error |
|---|---|---|---|
| Both corrections off | 8.68 s | — | 14 |
| M5.5 tracked-read only | 7.72 s | **3.88 s** | 10 |
| **M5.6 join added** | **3.86 s** | **0.00 s** | **2** |

The 3.86 s stationary span coexists with a max error of 2 because the cursor reaches 225 at 124.918 s
and the reader stays within one token of it. It is sitting *where the reader is*, not stalled behind
them. There is no span at all in which the reader is more than two tokens ahead. That remaining
stationary time is **not** a tracking failure and must not be reported as one.

**2. "Position error never again exceeds one token" was unqualified and wrong.** The maximum error
across the stall region (t ≥ 117.0 s) is **2**, at 120.109 s — *before* the join fires. The accurate
claim: after the join fires at 124.918 s, the error never exceeds 1.

**3. "The capture contains no events after the escape" confused two boundaries.** That was true of the
**replay excerpt** (`StallDiagnosisTests.fed`, cut at 128.803 s audio_ts = 130.571 s log), not of the
device capture, which continues past it and includes events at **134.458 s**. Those later events are
not transcribed into any fixture here, so post-escape behaviour is **outside the replayed material** —
neither measured nor contradicted. Claiming anything about it would require extending the fixture
first.

**4. Unchanged M1 is narrower evidence than I implied.** It means **no observed regression on this
28-fixture suite** — not universal non-regression, and not benefit. No fixture contains a compound
mismatch, so the suite cannot detect this class in either direction, and 28 synthetic fixtures over
one script family say nothing about scripts or recognisers they do not contain.

**Fading is NOT complete.** Joined words stay dark: `newlySpokenTokens` pairs backward 1:1, fails on
`backup`/`up`, and marks nothing for that feed. Safe — no unspoken word is marked — but those words
were spoken. docs/MATCHING_ENGINE.md §12.6 records the per-position mapping the join already computes
and discards, and the smallest follow-up that would mark both script words without greying skipped
neighbours (return the walk's mapping, carry it on the candidate, and have marking consult it instead
of re-deriving a 1:1 pairing). Out of scope this round; first candidate for the next.

## 2026-09-12 — M5.6: verifying the log caught a defect in the log

**The protocol claim was unsound and is corrected.** I had written that, in a device capture,
"`[Join]` absent while `[Scroll]` present ⇒ the join did not fire". That does not follow until the
`[Join]` emission path has been *positively* observed: `[Scroll]` working proves the logging
*mechanism* works, not that this particular statement is reachable or correct.

**Verification added.** `SlidingWindowMatcher.emitDebugLog` is now the single point where a matcher
diagnostic is produced; it records the line and then prints the same string.
`TokenJoinTests.theJoinLoggingPathEmitsOnADeterministicCase` replays a case known to join and asserts
on that record — so the test observes exactly what `print` receives. Its converse,
`theJoinLoggingPathIsSilentWhenNoJoinFires`, asserts nothing is emitted with joining disabled. What
this covers: the guard, the string construction, the call. What it does not: delivery of `print` to
the device console, which is the same mechanism `[Scroll]` already uses.

**Doing this caught a real defect in the line itself.** The first version reported
`heard=<newest word in the window>` and the script pair at `freshestScriptIndex` — neither of which is
the join site. It emitted, for example, `heard=smoothly script="smoothly once"` for a window whose
only join was `backup` → `back up`. Read against a device capture, that would have appeared to show
joins that never happened, on words that never joined. `ConfidenceModel.JoinSite` now records where
each join actually occurred, and every emitted line is asserted to name it:

```
[Join] FIRED anchor=215 consumed=10 cursor=220->225 score=0.796 heard=backup script="back up" at=223
```

**Also learned: the join fires once per tick while the compound is in the window** — seven lines in
the captured replay, all naming the same site (`at=223`). That is correct (the alignment is re-scored
each tick) and is now documented so repeats are not misread as multiple joins.

This is the second time in this milestone that verifying an instrument changed the finding rather
than confirming it. The general rule it supports: **an instrument that has never been observed
producing output is not evidence, and its silence is not a measurement.**

## 2026-09-12 — M5.6 diagnostic: join-site accuracy, role, and occurrence identity

Diagnostic only. **No matching decision changed** — every edit is inside `#if DEBUG`, and the
acceptance run below re-confirms the engine numbers.

**The line now carries what a device capture actually needs:**

```
[Join] role=selected site=223 script=[223..<225]="back up" heard="backup" win#8 seq#22 occ=1 obs=1 anchor=215 consumed=10 cursor=220->225 score=0.796
```

- **`role`** — `selected` (drove the cursor decision) vs `evaluated` (best local candidate, scored,
  advance refused). Without this a capture cannot distinguish "the join scored but we held" from
  "the join never happened". The captured replay contains one `evaluated` line (`seq#26`, score
  0.769, `cursor=228->228`), which is precisely the case that would otherwise have been misread.
- **`site` / `script=[a..<b]="…"` / `heard` / `win#` / `seq#`** — the join site, the matched script
  range and text, the spoken token that covered both, its index in the window and in the spoken
  stream.
- **`occ` / `obs`** — occurrence identity, below.

**Occurrence identity, because one join produces many lines.** The alignment is re-scored every tick,
so a compound is reported once per tick while it remains inside the `alignmentWindow`. A site can
therefore persist for at most `alignmentWindow` ticks; a reappearance after a longer gap means the
window has fully turned over and the reader has reached that text again. `obs` counts
re-observations within one visit, `occ` counts visits. Captured replay: **eight lines, one `occ`,
`obs=1…8`** — one join observed eight times.
`aLaterSeparateOccurrenceIsDistinguishableFromRepeatedObservations` demonstrates the contrast
directly: `occ=1 obs=1…9`, then `occ=2 obs=1` on the revisit.

**A test-design error worth recording.** The first version of that test placed the synthetic compound
near script index 6 and never produced a second occurrence. The cause was not the classifier: a join
can only land on script index `i` if the spoken window aligns so the compound falls there, and with
the compound that near the start there is no anchor putting a full nine-word window in front of it
(it would need anchor −2). Moving the compound to index 12 reproduced the revisit immediately. The
lesson generalises — **a synthetic fixture can fail for reasons that have nothing to do with the
behaviour under test**, and "the feature doesn't work" was the wrong first conclusion.

**Counters are per-instance and reset with the session.** There is no `reset()` on the matcher;
`PromptViewModel.beginSession` constructs a new `SlidingWindowMatcher`, so sequence and occurrence
numbering restart per take rather than accumulating. Asserted by
`diagnosticCountersAreScopedToTheMatcherInstance`.

**A correction to something I told the owner.** I reported the working tree as half-applied and
non-building after an interrupted command. That was wrong: inspecting the diff showed both edits had
landed and the tree compiled — only the verification step had not run. I should have read the diff
before characterising the state.

## 2026-09-13 — M5.7: automatic resumption after manual repositioning (rule specified before coding)

**Supersedes** the M5.3.4 clause "automatic following stays suspended until the reader taps Resume
following". The owner's updated contract: after a manual reposition, reading the passage they moved
to must resume following on its own; the button becomes an optional immediate override, not a
requirement.

**The defect this fixes**, from the 2026-09-12 capture: tracking resumed correctly but every target
stayed suppressed — at 124.592 s the cursor reached token 141 at confidence 1.00 and the target was
still `SUPPRESSED (manually detached)`, and the same held through tokens 155-165. `isManuallyDetached`
had no path back to `false` except the button or Restart.

### Definitions

| Term | Definition |
|---|---|
| **Manual interaction** | From the first `DragGesture` change until `ScrollPhase` returns to `.idle`. Deliberately includes deceleration, so a flick is one interaction, not a drag followed by an idle period. |
| **Chosen region** `V` | The union of `tokenStart..<tokenEnd` over every sentence block whose content rect intersects `ScrollGeometry.visibleRect`, **captured at the instant the interaction ends**. Captured once, so later automatic movement cannot widen it. |
| **Fresh reading evidence** | A cursor update delivered *after* the interaction ended, whose `tokenIndex` **changed** from the previously observed value, with `state == .advancing`. A held cursor, a re-layout, or a confidence value alone is not evidence. |

### The resumption rule

Automatic following resumes when **all** of these hold at once:

| # | Condition | Which requirement it serves |
|---|---|---|
| R1 | `isManuallyDetached == true` | — |
| R2 | current `ScrollPhase == .idle` | "Do not resume while dragging or decelerating"; "never fight the gesture" |
| R3 | at least `resumeEvidenceCount` = **3** fresh-evidence updates since the interaction ended | "fresh matching evidence", not one coincidence |
| R4 | **every** one of those updates had `tokenIndex ∈ V` | "the matched passage corresponds to the visible region"; "do not snap back because recognition is still tracking the old passage elsewhere" — the old passage is outside `V` |
| R5 | those updates are strictly increasing in `tokenIndex` | establishes *reading*, not a single stray match |

On resume: clear `isManuallyDetached`, reset the pacing state (`lastTargetAt`, `lastAppliedOffset`),
and perform **one** `ScrollAnimator.recovery` glide to `readingOffset`.

**Why the glide target is the existing `readingOffset` and not a new fraction.** The owner asks for
the reading line to land "in the first two usable lines below the safe area and controls".
`readingLineFraction` = 0.12 already does this: on a ~800 pt viewport that is ~96 pt from the top,
against a ~59 pt top safe area and a ~41 pt line box at the 34 pt reading size — i.e. the first line
below the safe area. Introducing a second fraction would mean the resume glide and the subsequent
following motion target different positions, producing a visible correction right after the glide.
Reusing `readingOffset` keeps the accepted motion intact.

**Evidence is reset** whenever a new manual interaction begins, so evidence gathered before a second
drag cannot resume following after it.

### What this rule deliberately does not do

- It never reads or writes matcher state. The scroll path only *observes* `viewModel.cursor`;
  nothing here can move the cursor or mark a token spoken.
- It does not resume on confidence alone, on `.holding`/`.recovering`/`.frozen`, or on a cursor that
  has not moved — those are exactly the "stale cursor / layout / confidence" cases excluded above.
- It does not change any matching threshold, the joined-word path, the fading safeguards, or the
  false-jump protection.

### M5.7 implementation and verification

**Where the rule lives.** `prompter/Prompt/ScrollOwnership.swift` — a pure value type with no SwiftUI
and no matcher dependency, so each clause is testable directly instead of being inferred from a
rendered view. `PromptScreen` holds one `@State ScrollOwnership` and feeds it three inputs:

| Input | Source | SDK symbol verified |
|---|---|---|
| interaction began | existing `simultaneousGesture(DragGesture)` | — |
| interaction settled + chosen region | `onScrollPhaseChange` → `.idle`, region from `onScrollGeometryChange(for: CGRect.self, of: \.visibleRect)` | `ScrollPhase` SwiftUICore.swiftinterface:625-630; `onScrollPhaseChange` SwiftUI.swiftinterface:12974; `onScrollGeometryChange` :12980; `ScrollGeometry.visibleRect` SwiftUICore:248 |
| reading evidence | `onChange(of: viewModel.cursor)` | — |

Resumption is driven by **cursor** updates rather than offset changes, because while detached the
offset target is suppressed and therefore produces no signal at all — which is precisely why the
2026-09-12 capture showed tracking recovering with the page still frozen.

`visibleTokenRange()` maps the visible rect to script tokens through the already-measured block
geometry (`contentOffset(ofBlock:)` + `blockHeights`) and `ScriptIndex.SentenceSpan.tokenStart/End`.
A partially visible sentence counts, since the reader can read from it.

**When the layout has not been measured it returns `nil`, and the rule is left unarmed.** The first
version substituted the whole script instead, justified as "so the rule waits for evidence rather
than becoming unsatisfiable". **That justification was wrong and is withdrawn.** Substituting the
whole script makes the in-region check (R4) vacuously true, so the one condition that distinguishes
"reading what I moved to" from "recognition still tracking the passage I left" would have been
disabled precisely when the layout was least trustworthy — it could have resumed, and glided the
page, on geometry nobody had measured. That is the snap-back the rule exists to prevent.

The correct failure mode is the **safe** one: stay detached, do not arm, and say so —

```
[ScrollOwner] HH:mm:ss.SSS settled — no geometry, rule not armed (Resume following still available)
```

The reader is never stranded, because "Resume following" and Restart both work in the unarmed state
(`explicitResumeAndRestartStillWork`, and asserted again inside the unarmed test). A measured region
is now required: `visibleTokenRange()` also demands at least one block with a non-zero height, since
without heights every block is a zero-height sliver at its computed top and the intersection test
means nothing. An empty measured range is treated as no region rather than as a region nothing can
match.

**Guarded by a matched pair**, which is what makes the check load-bearing rather than decorative:
`settlingWithoutGeometryDoesNotArmTheRuleAndNeverResumes` and
`theSameSequenceResumesWhenGeometryIsPresent` run the *same* input sequence — the exact one from
`readingTheNewlyVisiblePassageResumesAutomatically` — and differ only in whether geometry was
available at settle. Remove the guard and the pair disagrees.

**Ownership diagnostics** are timestamped (`HH:mm:ss.SSS`) so a device capture can be read against
the matcher's own lines:

```
[ScrollOwner] 16:20:41.883 user -> manual (automatic following suspended)
[ScrollOwner] 16:20:42.140 settled — chosen region tokens 138..<171 (awaiting 3 fresh in-region advances)
[Scroll] token=141 SUPPRESSED (manual ownership) targetY=1640.2 evidence=1/3
[ScrollOwner] 16:20:44.592 RESUME — 3 fresh advances (tokens 141->147) inside chosen region 138..<171
```

The suppression line now carries `evidence=n/3`, so a capture shows *how close* the rule was rather
than only that it was suppressed.

**Verification** — `ScrollOwnershipTests`, 15 cases. The owner's six:

| Case | Test |
|---|---|
| Drag, release, silence → stay detached | `dragReleaseThenSilenceRemainsDetached` |
| Drag while old-position recognition continues → no snapback | `recognitionStillTrackingTheOldPassageDoesNotSnapBack` |
| Read the newly visible passage → resume near the top | `readingTheNewlyVisiblePassageResumesAutomatically` |
| Off-script commentary → stay detached | `offScriptCommentaryRemainsDetached` |
| Drag again during resumed following → manual wins | `draggingAgainDuringResumedFollowingTakesControlImmediately` |
| Resume following / Restart still work | `explicitResumeAndRestartStillWork` |

Plus the constraints: `neverResumesWhileDraggingOrDecelerating`,
`aRepublishedUnchangedCursorIsNotEvidence` (a re-layout republishing the same advancing cursor ten
times is not evidence), `backwardOrStationaryMatchesRestartTheEvidence`, `oneMatchIsNotEnough`,
`evidenceDoesNotSurviveANewInteraction`, `leavingTheChosenRegionClearsEvidence`,
`settlingWithoutGeometryDoesNotArmTheRuleAndNeverResumes` + its control
`theSameSequenceResumesWhenGeometryIsPresent`, and `anEmptyMeasuredRegionDoesNotArmTheRule`.

**Motion is untouched.** `applyScroll`, `ScrollAnimator`, `readingLineFraction`, the no-op
suppression and the pacing estimate are all unchanged; the resume glide reuses the existing
`ScrollAnimator.recovery`. The only change to the following path is *when* ownership returns.

## 2026-09-13 — Rule: test counts come from `xcresulttool`, not from log greps

**Test counts are read from `xcrun xcresulttool get test-results summary`. A count produced by
grepping the build log is not evidence and must not be reported as one.** Today's miss is the reason:
`grep "Test case.*passed" | sort -u | wc -l` reported 109 for a run `xcresulttool` scored at 110
passed / 1 failed / 111 collected, and the same method was low by exactly one in four of six runs
this session (`09dd311`, `754bf7a`, `eb15f0d`, `c3a4287`) while being right in two — so it is not even
consistently wrong, which is worse. Pass `-resultBundlePath` on every verification run so the bundle
survives; DerivedData keeps only the most recent, and two baseline bundles had already been pruned
when they were needed. Where a bundle no longer exists, mark the number **grep-sourced, unverified**
rather than presenting it as measured. See the provenance audit in `AGENT_PROGRESS.md`.

## 2026-09-13 — M5.8 SPECIFICATION: positional retained evidence (spec only, nothing implemented)

**Read the correction first: my two earlier censuses were both invalid, and the cause of the device
symptom is not what I told the owner.**

`PromptViewModel.applyCursor` calls `newlySpokenTokens(fedWords: fedHistory, …)` — the **accumulated
16-word history** (`PromptViewModel.swift:203`), not the words of the current feed. Both censuses
passed the single feed, which made `earliestEligible` far too tight and attributed 93.7 % of the gap
to a cap that was not binding. Corrected:

- With a realistic history the device case `30->36` is eligible from token **26**, well before 30.
  **The cap is not the cause.**
- Replayed session-level through the real pipeline, the four `cleanRead` fixtures leave **0 tokens
  dark** out of 230 / 175 / 254 / 262. The fixture suite does **not** reproduce the symptom at all.
- So the earlier "15 unmarked of 921 in cleanRead, 100 % cause (f)" was an artefact. Cause **(f) as I
  defined it does not exist**, and the target metric the owner proposed cannot be measured on the
  current fixtures.

### 1. The exact mechanism, with the code

```swift
// PromptViewModel.newlySpokenTokens
let earliestEligible = max(0, newIndex - fedWords.count)
var tokenIndex = newIndex - 1
var wordIndex = fedWords.count - 1
while tokenIndex >= earliestEligible, wordIndex >= 0 { … tokenIndex -= 1; wordIndex -= 1 }
```

The walk pairs the **newest fed word with the newest script token** and steps both back in lockstep.
That is sound only while the tail of `fedHistory` corresponds positionally to the tail of the advance.

**Why the two findings connect.** At 21.9 s the recogniser emitted `"2"` for script token 34 `"two"`.
`rawSimilarity("2","two") = 0.000`, so that window position contributed nothing and the cursor **held
at 30** while the reader finished "not just one or two lines". Those words entered `fedHistory` during
feeds that moved nothing. The reader then began the next sentence, and the FINAL `" As you speak..."`
fed one new word. Now the cursor advanced **30 → 36** in one step, and the history tail was
`[… "not","just","one","or","2","lines","as","you","speak"]`. The walk paired

```
  token 35 "lines"  ↔  "speak"   fail   (bar rises)
  token 34 "two"    ↔  "you"     fail   → two consecutive failures → stop
```

The evidence for tokens 30-35 **was in the buffer**, three positions further back. The walk could not
reach it because three words belonging to the *next* sentence sat between. **The defect is positional
misalignment of retained evidence, not insufficient retention.** The stall that separates the words
from the advance is caused by the numeral mismatch — which is why these are one finding, not two.

### 2. What is retained, precisely

Replace the flat `fedHistory: [String]` with a bounded log of **observations**:

```
struct SpokenObservation { let word: String; let sequence: Int; let atCursor: Int; let state: State }
```

| Question | Answer |
|---|---|
| Which words | Every word passed to `applyCursor` as `fedWords`, exactly as now — no new source. |
| From which feeds | **All** feeds, including those that did not move the cursor. Those are the material: they are where the evidence for a later multi-token advance lives. |
| For how long | The same bound as today, `fedHistoryLimit = 16` observations. Not increased. |
| Volatile superseded by a final | **Counted once.** The volatile path already feeds only *new* words per delta (`TranscriptStream`), and a final re-feeds only its new tail (`n new of m total`). An observation is recorded per word actually handed to `applyCursor`, so a word revised by a later final appears once under its original sequence number. A word the recogniser genuinely repeats is two observations — correctly, because the reader said it twice. |
| What is added | `sequence` (monotonic feed counter) and `atCursor` (cursor position when the word arrived). Nothing else. |

**The change in marking:** instead of pairing the history *suffix* against the advance *suffix*, pair
each unmarked token in `[previousIndex, newIndex)` against the observations, allowing the matched
observation to sit anywhere in the retained window rather than at a fixed offset. Order is still
enforced — observations must be consumed in increasing `sequence` as tokens increase — so this is an
*alignment*, not a bag-of-words match.

### 3. The invariant, case by case

**Grey means the reader said THAT word AT THAT POSITION.** Each way retained evidence could break it,
and the exclusion:

| Case | Exclusion |
|---|---|
| Words spoken during a hold that matched nothing — the log's `"thanks for reading all the way to the end"` while the cursor sat at 176/177 | An observation may only be consumed by a token whose **similarity clears `spokenWordMinSimilarity`**. "thanks" never clears against any token in 177..248. Retention changes *which* observations are reachable, never *whether* a pair is good enough. |
| A recovery landing | **Clears all retained observations.** A recovery means "you are somewhere else and we found you" — by construction the preceding words do not correspond to the landing region. Already the rule for `continuityBreaks`; it now also empties the observation log. |
| A backward cursor move | **Clears all retained observations.** The reader has gone back; retained words describe text ahead of the new position. |
| A new manual interaction | **Clears all retained observations.** The reader repositioned; nothing before the drag describes what they will read next. Aligns with `ScrollOwnership.beginManualInteraction`. |
| `spokenWordMinSimilarity` | **Unchanged at 0.5, and still gates every individual mark.** Retention changes eligibility only. The raised bar after a failure (`shiftedPairMinSimilarity` 0.8) is unchanged. |
| The 177→248 case (71 unread tokens) | Still marks **nothing**. It is `state == .recovering`, which clears the log before any token is considered; and even without that, no retained observation clears the bar against those 71 tokens. This case is a required regression test, not a hoped-for outcome. |
| Interval marking | **Not introduced.** A token is marked only by an observation that individually clears the bar. `bridgedTokens` is untouched, `maximumBridgedTokens` stays 6. |

### 4. Falsification plan — stated before implementation

**The owner's proposed target metric cannot be used: `cleanRead` already leaves 0 of 921 dark.** The
fixtures do not exercise the defect, so "closing most of the 15" is not available as a prediction —
the 15 were an artefact of my own error.

What this design predicts instead, on the **device session**, which is the only evidence that contains
the defect:

| Prediction | Now | Predicted |
|---|---|---|
| `applyCursor 30->36` marks tokens 30-35 | 0 of 6 | **≥ 4 of 6** (tokens 30,31,32,33 from `"not","just","one","or"`; token 34 requires the numeral fix, token 35 requires `"lines"` to be reachable) |
| `applyCursor 44->50` marks tokens 44-49 | 0 of 6 | **≥ 4 of 6** |
| `applyCursor 177->248` marks anything | 0 of 71 | **0 of 71** (must not change) |
| `cleanRead` fixtures dark count | 0 | **0** (must not change) |
| M1 `meanCursorError` / `falseJumps` | 0.7658760520275439 / 0 | **byte-identical** |

**If the design does not predict ≥ 4 of 6 on both device lines, it is the wrong design.** A new
fixture reproducing the hold-then-catch-up pattern must be added *before* implementation, since no
existing fixture does — and it must be added as a **new** fixture file so the M1 denominators
(1307 / 6395) do not move.

### 5. The control test

`retainedEvidenceControl`: the same device-derived sequence replayed with retention disabled
(`retainedEvidenceEnabled = false`), asserting the **current** behaviour — `30->36` marks nothing and
`44->50` marks nothing. With retention enabled the paired test asserts ≥ 4 of 6 each. If the control
ever goes green while the feature is off, the feature is not what is doing the work. Plus a
regression test asserting `177->248` marks nothing **in both configurations**.

### 6. What this cannot fix, and the blast radius

**Cannot fix:** token 34 `"two"` will still not be marked, because `"2"` scores 0.000 against it — that
needs the numeral normalization recorded separately, which is a `Matching/` change with its own
authorization and its own M1 proof. Nor does it help where the recogniser never produced the word at
all (token 35 `"lines"` is only reachable if that observation is still inside the 16-word window).
It does nothing for `mediocreStall`-type sessions where the cursor advances over text the reader did
not say — correctly.

**Blast radius — files that change:**

| File | Change |
|---|---|
| `prompter/Prompt/PromptViewModel.swift` | `fedHistory` → observation log; `newlySpokenTokens` gains positional matching; clear-on-recovery/backward/manual |
| `prompterTests/Prompt/…` | new tests + control |
| new fixture file under `prompterTests/Matching/Fixtures/` | reproduces hold-then-catch-up, outside the M1 suite |

**`Matching/` is NOT touched.** No score, threshold, normalization, cursor destination, join rule,
recovery or suffix change. The only reason to enter `Matching/` would be the numeral normalization,
which is explicitly *not* part of this design.

**Cost if rejected:** none to correctness — the current behaviour is conservative and never marks a
word the reader did not say. The cost is cosmetic and bounded: after a stall-then-catch-up, roughly
6 tokens per occurrence stay dark. In the device session that happened **twice in 90 seconds** of
reading. §12.6's joined-word mapping stays deferred regardless; it is a separate 5-token case.

## 2026-09-13 — M5.9: standalone numeral equivalence, and the resume-glide collision

### 1. Numeral equivalence — chosen representation and affected paths

**Boundary.** `Tokenizer.normalizeWord` (`prompter/Matching/Tokenizer.swift:25`) is the single shared
normalization point. It is called by `ScriptIndex` for script preprocessing (`ScriptIndex.swift:67`),
by `TranscriptStream` for spoken text (`TranscriptStream.swift:37`), by `PromptViewModel` for volatile
deltas (`PromptViewModel.swift:413`), and by `ScriptEditorScreen` for a word count. Putting the
equivalence here is why **no second styling rule is needed**: `newlySpokenTokens` compares normalized
spoken words against normalized script tokens through the same `ConfidenceModel`, so a confirmed
spoken `"2"` becomes eligible to fade on script `"two"` automatically.

**Chosen representation: the word form.** A normalized token of exactly `"2"` becomes `"two"`. The
script is the authority and spells numbers out; mapping digit → word also leaves the more distinctive
string for Levenshtein comparison against neighbouring tokens. The mapping is symmetric in effect —
a script written `"2"` also becomes `"two"`, so a spoken `"two"` matches it.

**Why normalization and not scoring.** `rawSimilarity("2", "two") = 0.000` — the strings share no
characters. No threshold can reach a zero, so this cannot be a scoring change, and no threshold or
fuzzy-scoring rule was touched.

**Affected-token count, measured before implementing:**

| Corpus | script `"two"` | script `"2"` | spoken `"two"` | spoken `"2"` |
|---|---|---|---|---|
| M1 suite (28 fixtures, 6447 script / 6395 spoken tokens) | 14 | **0** | 12 | **0** |
| Demo script (248 tokens) | 1 (index 34) | 0 | — | — |
| Device-audit corpus (635 transcript words) | — | — | 0 | **3** |

M1 contains **no digit form at all**, so the change cannot move M1 — `"two"` → `"two"` is identity.
The device-audit corpus contains three `"2"` tokens, so its totals *can* change; any movement is
reported rather than suppressed.

**Currency and percent are excluded explicitly.** `normalizeWord` strips punctuation *before* this
point, so `"$2"` and `"2%"` already reduce to `"2"` and would otherwise be swept in. The rule
therefore inspects the pre-strip text and declines when it contains `$ £ € ¥ %`. Untouched because
they do not normalize to exactly `"2"`: `"2nd"`, `"22"`, `"20"`, `"2000"`, `"12"`, `"1st"`, `"2.5"`
(→ `"25"`), `"two-thirds"` (→ `"twothirds"`). The homophones `"to"` and `"too"` are unrelated strings
and stay distinct.

**Preserved:** token counts (one word in, one word out), script indices, original display text
(`TokenSpan.rangeStart/rangeEnd` still point into the raw script), and raw captured transcripts —
the fixtures store what the recogniser actually emitted, including `"2"`.

**Scope limit.** Standalone `"2"` / `"two"` only. No general number parsing, ordinals, years,
decimals, currency, times, ranges, or homophones. `NumeralEquivalenceTests` names each excluded form
individually so a future widening fails there first.

### 2. The resume-glide callback collision

**Cause, verified in current source.** The resume path in `onChange(of: viewModel.cursor)` set
`lastTargetAt = nil` and `lastAppliedOffset = nil` before gliding. The same cursor change also moves
`readingOffset`, so `onChange(of: readingOffset)` fired in the same frame, found the no-op guard
cleared, passed it, rewrote the pacing state a second time — the
`onChange(of: Optional<CGFloat>) action tried to update multiple times per frame` warning in the
2026-09-13 capture — and re-issued the same target with the **following** animation, overwriting the
recovery glide the reader was meant to see.

**Fix: the resume glide owns the transition and the pacing update.** It now records its own target
(`lastAppliedOffset = offset`, `lastTargetAt = Date()`) instead of clearing them, so the existing
M5.4 no-op suppression absorbs the duplicate callback, while a genuinely newer target still differs
by more than `offsetEpsilon` and is followed normally. No new mechanism, no motion retuning:
`applyScroll`, `ScrollAnimator`, `readingLineFraction` and the pacing estimate are unchanged.

**Not an M5.4 regression** — that suppression is demonstrably still firing after resumption in the
same capture (`token=170/171/172/175 unchanged targetY — not re-issued`, all post-RESUME).

### 3. Replay requirements — determination only, nothing implemented

**Is a complete session-start capture of inputs, timestamps, configuration and resets sufficient for
deterministic replay? Yes — and internal matcher state does not need capturing.**

`SlidingWindowMatcher` stores `ringBuffer`, `cursor`, `confidence`, `state`, `lastTokenTimestamp`,
`stalledSince`, `bestStallCandidate`, `previousLocalAnchor` and `consistentAnchorRun`. **Every one is
derived** from the ordered input sequence; `now` is supplied by the caller, and there is no clock,
randomness or external input inside the engine. Given the same script, the same config and the same
ordered `(tokens, now)` calls from session start, replay is deterministic.

**This corrects a claim I made in the M5.8 stop entry** — I wrote that the trajectory could not be
reconstructed because the log omits *internal state*. That reasoning was wrong. The blocker is
missing **input**, which is a much smaller problem:

| Needed for replay | Logged today? |
|---|---|
| Volatile fed words | **Yes** — `VOLATILE-FED n word(s) "…"` |
| Volatile `now` | Only by association with the preceding `VOLATILE audio_ts=` line |
| **FINAL catch-up words** | **NO — only the count** (`(final, K new of M total)`); `catchUpTokens` text is never printed |
| FINAL `now` | Yes — `advance(… now: delta.timestamp)` and `audio_ts=` is on the FINAL line |
| Script identity | Only token/sentence counts, not a fingerprint |
| Config | Only 3 thresholds; `trackedRunLength`, `alignmentWindow`, `ringBufferSize`, join settings etc. are absent |
| Resets | Yes — `start()` builds a new matcher, logged as `SESSION START` |

**Smallest Debug-only addition, proposed not implemented** — three log-line edits, no subsystem:

1. print `catchUpTokens.map(\.text)` on the `CURSOR (final, …)` line;
2. print `audio_ts` on the `VOLATILE-FED` line, removing reliance on association;
3. print a script fingerprint and the full `MatcherConfig` on `SESSION START`.

With those three, a captured session replays deterministically and the M5.8 fixture-faithfulness
blocker dissolves. **Not implemented this round** — it must not delay the bounded fixes, and it
should not be bundled with them.

### 4. MEASURED COST OF THE NUMERAL CHANGE — two required gates go red

**Reported, not traded away. No gate was weakened and no assertion relaxed.**

The clean verification at this change is **124 passed / 2 failed / 0 skipped (126 collected)**. One
failure is the pre-existing `DeviceLogAuditTests` LOST 3. **The second is new and caused by this
change:**

```
SuffixReacquisitionTests.suffixScoringDoesNotMakeAnyIndividualUtteranceWorse
  C — heavy off-script commentary (the false-jump session) t=27.172: HOLDING -> UNRESOLVED (cursor 26 -> 36)
```

Device-audit totals move **HOLDING 35 → 34, UNRESOLVED 1 → 2**. M1 is byte-identical as predicted
(`meanCursorError 0.7658760520275439`, `falseJumps 0`, denominators 1307 / 6395), because the M1 suite
contains no digit form at all.

**The cause, isolated to a single token** (`docs/evidence/M5.9/numeral_regression.txt`). The utterance
is the reader *commenting on* the script while quoting it verbatim:

> "[captured utterance redacted — see private historical repository]"

```
  normalized WITHOUT equivalence: […, "not", "just", "one", "or", "2",   "lines"]  -> cursor 27, holding,   conf 0.61
  normalized WITH    equivalence: […, "not", "just", "one", "or", "two", "lines"]  -> cursor 36, advancing, conf 0.75
  script 30..<36 = ["not", "just", "one", "or", "two", "lines"]
```

With the equivalence the last six spoken words are an **exact** match for script 30-35, so the window
legitimately looks like reading. The matcher is not malfunctioning; it is being given a better match.

**This is inherent to the requested change, not an implementation defect.** Any correct
`"2"` ≡ `"two"` mapping produces it. The only way to avoid it would be to make the equivalence
conditional on surrounding context — i.e. the general normalization engine that was explicitly ruled
out of scope. There is no narrower correct implementation.

**The trade, stated for the owner rather than decided here:** the change closes a real tracking stall
on a *reading* capture (cursor held at 30 for the whole phrase) at the cost of one *commentary*
utterance that quotes the script including the numeral becoming indistinguishable from reading. Both
are single observations from the same small corpus. The owner's standing rule — "a change that
improves one metric and degrades another has not made a trade, it has probably broken something" —
is why this is surfaced before any device test rather than after.

### 5. DECISION: numeral equivalence reverted, deferred

**Owner chose to revert the numeral-equivalence behaviour and retain the independent resume-glide
correction.** Applied exactly that: `prompter/Matching/Tokenizer.swift` restored to its `4f166f0`
state; the resume-glide fix in `PromptScreen` kept.

**No gate was touched to accommodate the change.** The `UNRESOLVED` allowance was not raised, no
assertion was weakened, and no ground-truth label in `DeviceLogAuditTests` was edited. The revert —
not a rebaseline — is what returns the audit to its prior totals.

**The regression evidence is preserved** in `docs/evidence/M5.9/` and as live tests in
`NumeralMismatchDeferredTests`, including the commentary utterance as a case any future attempt must
survive.

**Scope of what the regression proved, stated precisely:** that an *unconditional* equivalence applied
at the normalization boundary affects commentary containing quoted script text. It does **not** prove
that no narrower approach exists. That is left open and unexplored; no further matching experiments
were run this round.

**The three replay-log edits remain documented and unimplemented** (§3 above): print the catch-up
words on the `CURSOR (final, …)` line, print `audio_ts` on `VOLATILE-FED`, and print a script
fingerprint plus full config on `SESSION START`.


## 2026-09-13 — M5.10: light/dark visual system, compact reader controls, editor toolbar removed

**Presentation round.** `Matching/`, `Tokenizer`, production `Speech/`, ASR reconciliation, scoring
thresholds and spoken-word eligibility are untouched.

### Removals, recorded explicitly

| Removed | Where | Note |
|---|---|---|
| Small-A font-size button | `ScriptEditorScreen.toolbox` | gone, not hidden |
| Large-A font-size button | same | gone |
| `[ ]` button inserting `[pause]` | same | **the insertion action is deleted, not relocated** |
| The toolbar `Divider()`, its `HStack` container and padding | same | the space now belongs to the script body |
| `editorFontScale` state | same | reader text size lives in Settings only |
| Hard `.preferredColorScheme(.light)` app lock | `PrompterApp` | see below |

`EditorToolbarRemovalTests` asserts all of the above at source level — including a repo-wide scan
proving no `"[pause]"` literal is inserted anywhere — because a UI test could only show the controls
are *invisible*, not that the action no longer exists.

**No standalone `Aa` reader shortcut was added**, and there is exactly one text-size control in the
app: a single labelled slider in Settings. No duplicate "A" buttons anywhere.

### User text is preserved

The screenshot showed `"[pause]ot just [pause]one or two lines."` in a stored script. **That is
existing document content and this round does not touch it.** Removing the way to insert a marker
must not strip markers, rewrite titles or repair stored scripts, so there is no migration and no
clean-up pass. `existingPauseMarkersInStoredTextArePreserved` pins that: the string survives
verbatim and tokenizes unchanged.

**Separately reproducible editing defect, recorded not fixed:** the stored text begins `"[pause]ot"`,
i.e. an `"N"` is missing from `"Not"`. That is consistent with the insertion replacing a selection
that included the adjacent character, but the capture does not prove it — the defect is recorded
here as unreproduced, and the insertion path it would have come from no longer exists.

### Visual system

Adaptive semantic tokens in `Theme.Color`, each a dynamic `UIColor` provider resolved against the
active trait collection, so one token serves both appearances.

| Token | Light | Dark |
|---|---|---|
| `paper` (background) | `#F7F4EF` | `#151719` |
| `ink` (primary text) | `#242331` | `#F2F0EB` |
| `action` (accent) | `#216A60` | `#9ED8C4` |

Derived tones are **measured, not copied from image pixels** (`ThemeContrastTests`, WCAG):

```
  ink on paper            light 14.08:1   dark 15.78:1
  spoken on paper         light  4.73:1   dark  5.58:1
  onDark on action        light  6.37:1   dark 11.19:1
  ink on currentSentence  light 12.94:1   dark 13.02:1
```

**Unread text is full contrast.** `Theme.Color.future` is now *identical* to `ink` — there is no
dimmer "not yet spoken" tone, because nothing except confirmed speech may look completed. Only
`spoken` is muted, and it is asserted to be both legible (≥ 3:1) and visibly quieter than unread text.

**The app-wide light lock is gone.** `PrompterApp` forced `.preferredColorScheme(.light)` because the
v2 palette was light-only and system chrome would otherwise render white-on-light. The v3 palette is
fully adaptive, so that failure mode cannot occur, and the lock would have made the approved dark
design unreachable. `RootView` now applies the stored System / Light / Dark preference, defaulting to
System.

**Appearance changes do not disturb a session.** The preference is read through the existing
`@Query`, so changing it re-renders the view tree; it does not rebuild the matcher, reset the cursor,
clear spoken history or restart recognition.

### Reader controls

Large `Pause` / `Restart` / `Exit` buttons — which the screenshot showed sitting **on top of the
script text** — are replaced by a compact group in a translucent capsule: restart, a prominent
pause/resume transport, and an overflow menu containing Exit. A compact close control sits top-left
with the session status beside it.

**Session pause/resume is unchanged and unrelated to the removed `[pause]` insertion.** One is the
transport; the other typed a marker into a script.

**Top space is reserved, not guessed.** The text column's top inset is `safeAreaInsets.top +
topControlRowHeight + 8`. **No pacing or animation value was touched to compensate**:
`viewportHeight` is measured by the `GeometryReader` inside `textColumn`, so it already excludes that
padding, and `readingLineFraction` still places the reading line at 12 % of the *scrollable* area —
which now begins directly below the controls. That is the correct coordinate space.

### Library

`Scripts` heading with a Settings gear, search over title **and** body, a prominent floating
`New script` action, and `Recent` rows carrying real titles, first-line previews and word counts.
Existing storage, navigation and deletion behaviour are reused unchanged.

**The prominent action is labelled "Open script", not "Continue reading".** The mockup says the
latter, but nothing stores a reading position — `Script` has no cursor field and `PromptSession`
records only duration and completion. Opening starts from the beginning, so "Continue reading" would
promise a capability that does not exist.

No import, AI-writing, account, subscription or synchronization features were added. The mockup's
sample scripts were not copied into storage and its device frames were not embedded.

## 2026-09-13 — M5.11: script deletion, debug menu removed, and transcript logging taken out of Release

**Cleanup round.** `Matching/`, `Speech/`, thresholds and spoken-word eligibility untouched. The
approved design and the accepted reading behaviour are preserved.

### Script deletion

Long-press context menu → confirmation naming the script, with **Cancel as the default/safe action**
and Delete marked destructive. Uses the existing SwiftData context.

**Swipe-to-delete is deliberately not offered.** `.swipeActions` requires a `List`; the approved
library is a card stack in a `ScrollView`. Converting it to a `List` to obtain the swipe would change
the design the owner just accepted, so the long-press menu is the affordance and a VoiceOver
`accessibilityAction(named: "Delete")` provides the assistive route. The instruction asked for native
swipe *"where the existing layout supports it"* — it does not.

**Relationships were inspected before implementing, not after:**

| Entity | Relationship to `Script` | Effect of deleting a script |
|---|---|---|
| `PromptSession` | `Script.sessions`, `.cascade` | its own sessions are removed — correct |
| `UsageLedger` | **none** — keyed by calendar day | daily allowance **unaffected** |
| `AppSettings` (incl. `premiumCachedActive`) | none | entitlement cache **unaffected** |

Pinned by `ScriptDeletionTests`: only the selected script is removed; deletion survives re-reading the
store; cascade touches only that script's sessions; usage and entitlement state are untouched;
cancelling leaves everything in place; the bundled demo remains available (it is a compiled-in
constant, not a stored user document).

**Failures are surfaced, not swallowed.** A failed `save` rolls the context back and raises an alert
saying the script is still in the library, rather than letting a row vanish and reappear on relaunch.
Navigation that pointed at the deleted row is cleared first so nothing holds a dangling reference.

Deletion lives only in the library, so an actively running script cannot be deleted from under its
session.

### Debug removal — and a real Release leak found while doing it

The menu entry is gone from `ScriptListScreen` and nothing outside `DebugTools/` references
`DebugMenuScreen`.

Removing the entry exposed two things that compiled into **Release**:

1. `DebugTranscriptScreen`, `ReplayDebugScreen`, `ReplayPlayer` and `PromptTextInputScreen` were not
   `#if DEBUG`-gated. They were unreachable, but a shipping binary should not contain debug UI at all.
   Gating `ReplayDebugScreen` broke the Release build, which is how a second problem surfaced: the
   production-looking `PromptTextInputScreen` depended on `ReplayButtonStyle` from a debug file — it
   was itself a debug screen living in `Prompt/`, reachable only from the debug menu.
2. **`[PromptDebug]` transcript logging was shipping in Release.** A `#if DEBUG` nesting scan found the
   `print` in `PromptViewModel.debugLog` outside every guard — while the comment directly above it
   asserted it was already gated "because this whole screen is". It was not. Every recognition event,
   including transcript text, and every cursor move went to the device console in a Release build.

Both fixed. The scan now reports zero ungated `print` in production source, and the Release binary
contains no `PromptDebug`, `DebugMenu` or replay-harness strings.

**Preserved deliberately:** `#if DEBUG` console diagnostics, all test fixtures, and the
`-promptReplay` harness. The request was to remove the menu, not to destroy regression evidence.

### Planning documents

`docs/RELEASE_READINESS.md` created, covering language scope, the RevenueCat implementation plan and
the App Store checklist. Three findings there are worth repeating here because they contradict the
older planning documents:

- **Bundle id is `talk.prompter`**, while the old checklist names `scriptwatch.premium.monthly`.
  Nothing was renamed or invented; the owner must say which identifier is actually registered.
- **`BUILD_SPEC.md:45` sells "future AI writing tools" as a premium benefit.** That must not appear in
  store or paywall copy as a current benefit.
- **The old blanket "Data Not Collected" privacy label is no longer accurate** once RevenueCat is
  configured — it transmits purchase and identifier data.
- The app currently passes **`Locale.current`** (the interface locale) to speech recognition
  (`PromptViewModel.swift:411`) and never reads the stored `Script.locale`. Any second script language
  requires fixing that assumption first.

## 2026-09-14 — M5.12: keyboard-aware editing, per-script reading language, ICU segmentation, Premium entry

### 1. Editing behind the keyboard

**Cause, found in the production editor.** The layout is a `VStack` of title → stats → `TextEditor` →
`Start` button. SwiftUI's keyboard avoidance was working; the problem was that the **`Start` button sat
between the editor and the keyboard**, permanently consuming the space the last paragraphs needed.

**Fix, native and without estimates.** `@FocusState` tracks editing; the `Start reading` button is
hidden while the keyboard is up and returns when editing ends; the editor takes
`.frame(maxHeight: .infinity)` so it owns the freed space and keeps its own insertion-point tracking.
A keyboard toolbar provides an accessible **Done**. **No fixed keyboard-height estimate** and **no
extra scroll gesture** were added — a drag-to-dismiss would compete with the editor's own scrolling.
Text is saved when editing ends, so it survives dismissal, backgrounding and appearance changes.

### 2. Reading language versus interface language

**The previously reported bug is confirmed in current source and fixed.**
`PromptViewModel.swift` passed **`Locale.current`** — the *interface* locale — into
`TranscriptionService.start(locale:)`, while `Script.locale` was written at creation and **never read
by anything**. A French script on an English phone was transcribed with an English model.

Now: `Script.readingLanguage` (new `ReadingLanguage` enum, stored as a raw string per this project's
convention) is chosen per script in the editor and threaded through `PromptScreen` →
`PromptViewModel` → `start(locale:)`. `SpeechAssetManager.supportedLocale(for:)` resolves it to a
locale the installed transcriber actually supports and **throws** if none is close enough, so nothing
is silently substituted. Legacy rows map their old `locale` string by language code rather than
discarding it. **English is the default**, including for unknown values.

Changing the interface language never touches script text (`interfaceLanguageDoesNotAlterScriptText`).

### 3. Segmentation — a production change, scoped and evidenced first

**The failure was demonstrated before any change**, and the first diagnosis was wrong in a way worth
recording. I initially concluded Chinese "cannot be tracked at all". The actual situation:

```
  "歡迎使用提詞機這是一個較長的測試腳本"
    script side  (ScriptIndex.build, ICU .byWords)        -> 14 tokens   ← always worked
    spoken side  (Tokenizer.normalize, whitespace split)  ->  1 token    ← the break
```

`ScriptIndex.build` has always used ICU word segmentation, which handles Chinese correctly. Only the
**spoken** side split on whitespace. The two sides disagreed, so nothing could align.

**Scope of the change: one function.** `Tokenizer.normalize` now uses the same
`enumerateSubstrings(options: [.byWords, .localized])` call the script side already used. No
threshold, scoring rule, recovery behaviour or similarity semantics changed.

**Measured before shipping:**

| | whitespace (before) | ICU (after) | |
|---|---|---|---|
| English prose, contractions, possessives, em dash | 11 / 6 / 6 tokens | **identical** | no-op |
| French `"qu'est-ce"` | `questce` | `quest`, `ce` | now **agrees with the script side** |
| Traditional Chinese | 1 token | **14 tokens, identical to the script side** | unblocked |

**M1 is byte-identical** after the change: `meanCursorError 0.7658760520275439`, `falseJumps 0`,
denominators 1307/6395.

### 4. Premium entry

A Settings row labelled **"Prompter Premium"** — the user-facing name; RevenueCat is the
implementation provider and is not a menu. One red `1` badge, an accessible label reading
"Prompter Premium, 1 new item", cleared **persistently** on first open
(`AppSettings.hasSeenPremiumAnnouncement`) and never re-added for not subscribing. No app-icon badge.

The destination states plainly that subscriptions are not available yet. **No Subscribe button, no
price, no purchase simulation, nothing implying an active subscription.**

### 5. Automatic language detection — deferred

Manual selection works and ships. Detection was not implemented: doing it honestly needs a
suggestion UI, a confidence floor, mixed-script handling and a rule that explicit choice always wins,
and that is more work than the remaining scope of this round allows. Deferring it does not block the
useful result. Recorded rather than half-built.

## 2026-09-14 — M5.13: RevenueCat subscriptions and daily usage metering

Presentation, matching, speech, segmentation and scrolling are untouched. No camera code.

### Metering rules, as implemented

`UsageMeter` is a **pure value type** — no SwiftData, no clock, no SwiftUI — so every rule below is
asserted directly (`UsageMeterTests`, 11 cases).

| Rule | Behaviour |
|---|---|
| Allowance | 600 s (10 min) per **local calendar day** |
| Metered | Active prompting of a **user script** only |
| Not metered | Editing, browsing, model downloads, **the demo**, explicit pause, background while suspended |
| Counted within a take | Ordinary speech pauses and off-script talking — the reader is still in a take |
| Manual scrolling | Not a session event; changes nothing |
| Clock | **Monotonic** (`ContinuousClock`), never `Date()` — time-zone moves and clock corrections cannot grant or steal allowance |
| Persistence | Banked on every suspend, so termination loses nothing |
| Day boundary | Local midnight in the device's current time zone, matching `UsageLedger.dayKey` |
| Midnight mid-take | The take **continues**; its time banks into the new day |
| Overrun | A take allowed to start may finish; the **full** elapsed time is recorded |
| Next take | Refused once exhausted — paywall **before** Start, never during |
| Script deletion | Cannot reset usage (`UsageLedger` has no relationship to `Script`) |

### Entitlements

`EntitlementService` wraps RevenueCat **5.83.1**, with symbols verified in the checked-out package
sources: `configure(withAPIKey:)`, `offerings()`, `purchase(package:)`, `restorePurchases()`,
`customerInfoStream`, `showManageSubscriptions()`, `EntitlementInfo.isActive/willRenew/expirationDate`.

- **Anonymous** — no account requirement anywhere.
- **Prices come from store product data** (`localizedPriceString` + `subscriptionPeriod`). The
  purchase button shows nothing until a real price loads; **no dollar amount is hardcoded**.
- **Cached entitlement survives network failure** (`.unavailable(cachedPremium:)`), so a paying
  reader offline keeps access — but a **verified-inactive** result reconciles and revokes. There is no
  local boolean that only ever turns on.
- Entitlement updates arrive via `customerInfoStream` and only change state; **nothing in that path
  touches the matcher, the session or the scroll**, so a refresh cannot interrupt a take.
- Outcomes modelled distinctly: purchased, **cancelled** (silent — the reader chose to stop),
  **pending** (Ask to Buy: nothing unlocks), failed, notConfigured.

### Missing configuration is a first-class state

With no `RevenueCatPublicKey` the app runs fully — scripts, editing, demo and the free allowance all
work — and Premium is simply unpurchasable. **Absent configuration never grants Premium and never
crashes.** An unsubstituted `$(…)` build setting or empty string counts as absent.

### Settings badge

The unread badge moved onto the **library's Settings gear**, so the announcement is visible without
opening Settings. **Opening Settings does not clear it**; opening the Premium screen does, and
permanently. It is never re-added for not subscribing, and there is no app-icon badge. Subscribers
see status, Manage Subscription and Restore rather than another invitation to buy.

### Camera boundary — documented, not implemented

Future filming would need `AVCaptureSession` with the camera **and** microphone. The microphone is
already held by `SFSpeechRecognizer`/`AVAudioEngine` during a take, so the two cannot naively coexist:
a shared `AVAudioSession` category (`.playAndRecord` with the right mode) and a single capture graph
feeding both recognition and recording would be required, plus `NSCameraUsageDescription`. None of
this exists and none was added.
