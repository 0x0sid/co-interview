# SCRIPTWATCH

> **INHERITED FROM PROMPTER — historical reference only.** This describes *Prompter*, a separate
> paused project. It is **not** a Co-Interview specification and its roadmap, milestones and release
> criteria do not apply here. Start at [`CO_INTERVIEW_START_HERE.md`](CO_INTERVIEW_START_HERE.md).


> **Status notice.** For *current* project status, the verified baseline and what is settled, read
> [`PROMPTER_CURRENT_STATE.md`](PROMPTER_CURRENT_STATE.md). This spec remains the original product
> definition and is preserved as history; several clauses are **superseded** (English-only launch,
> the AI-writing-tools premium benefit, the "Data Not Collected" label) — see that file's §7.

## White Paper & Complete Build Specification
### The teleprompter that follows you.

> **Version 2.0 — August 4, 2026**
> **Audience:** Eric (dev lead), Sid (product owner), and any coding agent (Devin / Hermes / Claude Code) working on the project.
> This single document is the source of truth. It supersedes SCRIPTWATCH_AGENT_BRIEF.md v1.
> Read Part I to understand WHAT and WHY. Read Part II to build. Part III is process, deadlines, and rules.

---

# PART I — PRODUCT WHITE PAPER

## 1. The problem

Every phone teleprompter today forces the speaker to manage the tool: set a scroll speed, chase or wait for the text, thumb the screen mid-take, restart when they ad-lib. Incumbents (PromptSmart, Teleprompter Premium, BIGVU) promise "voice tracking" but reviews consistently report drift, lost position on ad-libs, paywalls before value, and camera-app bloat. The result: creators read badly, look like they're reading, and burn takes.

Sid's own pain (filming YouTube videos) is the founding use case: either your eyes visibly track a scrolling screen, or the speed drifts from your pace and you secretly scroll by hand.

## 2. The insight (why now)

iOS 26 shipped **SpeechAnalyzer / SpeechTranscriber**: Apple's new on-device, long-form, low-latency speech recognition. It is free (no per-minute API cost), offline, private, and built for exactly this kind of live streaming use. The incumbents were built on the old SFSpeechRecognizer (short-form, server-assisted, drifty) and haven't rebuilt. **There is a 6–12 month window where a small team can ship the first teleprompter that actually follows the speaker.**

## 3. The product

Paste your script. Start talking. Forget the app exists.

- The script follows your **voice**, not a timer.
- Pause → the script waits. Ad-lib → the script holds your place. Skip a paragraph → it finds you.
- Because the cursor waits for you, you can look into the **lens**, deliver a line from memory, glance back — and you're exactly where you left off. No competitor allows safe eye contact. This is the demo, the Reels clip, and the whole pitch.
- Offline. No account. No camera features. No settings jungle. One job.

## 4. What ScriptWatch is NOT

- Not a camera/recording app (v1 assumes filming on a separate camera; the iPhone is the prompter).
- Not an AI app. AI (script rewrite) is an optional, feature-flagged helper. **The tracking engine is 100% deterministic — no LLM in the matching path, ever.**
- Not configurable. No WPM sliders, no scroll-speed settings. The engine adapts; the user speaks.

## 5. Business model

| Tier | Terms |
|---|---|
| Demo | Bundled 100-word script, unlimited, never metered, no signup |
| Free | 10 prompt-minutes/day, unlimited scripts, fully offline |
| Premium | **USD 6.99/month** — unlimited minutes, future AI writing tools, early features |

Monetization runs through **RevenueCat** (hackathon requirement, see §20) wrapping StoreKit 2.

## 6. Strategic context — RevenueCat Shipaton 2026

We are building this inside the Shipaton window (**Aug 1 – Sep 30, 2026**, >$700K prizes):

- **Hard rule 1:** first-ever public release must go live on the App Store inside the window. ✅ by default.
- **Hard rule 2:** the RevenueCat SDK must power at least one in-app purchase. → §20.
- **Open source is NOT required** (only the student Next Gen track needs source). ScriptWatch ships closed-source; the matcher tuning is our moat.
- Target categories: RevenueCat core awards (Grand Prize, HAMM, Design Award, #BuildInPublic) + **Layers Growth Loop Award** (process-based, no SDK). OneSignal's category is deliberately skipped to protect the "data not collected" privacy label. JetBrains (KMP), Replit, Samsung, Stripe: wrong stack for v1.
- **#BuildInPublic is judged:** every milestone produces a shareable artifact (screen recording + honest paragraph). See §23.

---

# PART II — TECHNICAL SPECIFICATION

## 7. System map ("backend" = the device)

There is **no server**. Everything below runs on the iPhone. The only network traffic in the entire app is the RevenueCat SDK (purchases/entitlements) and Apple's one-time system download of the speech model asset.

```
┌─────────────────────────── iPhone (iOS 26+) ───────────────────────────┐
│                                                                        │
│  Mic ─▶ AVAudioEngine tap ─▶ AVAudioConverter ─▶ AnalyzerInput         │
│                                    │                                   │
│                          SpeechAnalyzer + SpeechTranscriber            │
│                          (on-device ASR, volatile + final results)     │
│                                    │  AsyncSequence (off main actor)   │
│                             TranscriptStream                           │
│                          (merge, normalize, token deltas)              │
│                                    │                                   │
│                        ┌── MATCHING ENGINE (pure Swift) ──┐            │
│                        │ Tokenizer → SlidingWindowMatcher │            │
│                        │ → ConfidenceModel → PromptCursor │            │
│                        └──────────────┬───────────────────┘            │
│                                       │ (position, confidence) 10 Hz   │
│                          PromptViewModel (@MainActor)                  │
│                                       │                                │
│                    ScrollAnimator ─▶ PromptTextRenderer (SwiftUI)      │
│                                                                        │
│  SwiftData ◀── Scripts · Sessions · UsageLedger · Settings             │
│  RevenueCat SDK ◀──(network)──▶ App Store / RC backend (entitlements)  │
│  FoundationModels (optional, on-device) ◀── AI rewrite (feature flag)  │
└────────────────────────────────────────────────────────────────────────┘
```

## 8. API map (every external surface we touch)

| Surface | Kind | Network? | Cost | Used for | Verify against |
|---|---|---|---|---|---|
| `Speech` — `SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory` | Apple framework (iOS 26+) | Model download once (system-managed) | Free | Live on-device ASR | developer.apple.com/documentation/speech |
| `AVFoundation` — `AVAudioEngine`, `AVAudioConverter`, `AVAudioSession` | Apple framework | No | Free | Mic capture, format conversion, interruption handling | Apple docs |
| `SwiftData` | Apple framework | No | Free | Local persistence | Apple docs |
| **RevenueCat iOS SDK** (`Purchases`) | 3rd-party SPM package (the ONLY one) | Yes | Free tier ample | Subscription purchase + `premium` entitlement | docs.revenuecat.com |
| `StoreKit 2` | Apple (behind RevenueCat) | Yes (Apple) | 15/30% commission | Actual billing | via RC docs |
| `FoundationModels` | Apple framework (on-device LLM) | No | Free | Optional script rewrite (feature-flagged) | Apple docs |
| `NaturalLanguage` — `NLTokenizer` | Apple framework | No | Free | Sentence segmentation | Apple docs |
| `UserNotifications` (local only) | Apple framework | No | Free | Optional local "minutes reset" reminder | Apple docs |

**Rule:** no other network calls of any kind. Privacy label: "Data Not Collected" (RevenueCat's minimal purchase data disclosed per their App Privacy guidance — check RC docs when filling the label).

### Internal service interfaces (protocol-first, so everything is fakeable in tests)

| Protocol | Implemented by | Key methods |
|---|---|---|
| `AudioCapturing` | `AudioCaptureService` | `start() -> AsyncStream<AVAudioPCMBuffer>`, `stop()` |
| `Transcribing` | `TranscriptionService` / `FakeTranscriptionService` | `start(locale:) -> AsyncStream<TranscriptDelta>`, `stop()` |
| `ScriptMatching` | `SlidingWindowMatcher` | `func advance(spoken: [Token]) -> PromptCursor` |
| `EntitlementProviding` | `EntitlementService` (RevenueCat) | `isPremium: Bool`, `offerings()`, `purchase()`, `restore()` |
| `UsageMetering` | `UsageMeter` | `remainingSecondsToday()`, `consume(seconds:)` |
| `ScriptStoring` | SwiftData layer | CRUD on `Script` |

`FakeTranscriptionService` replays recorded transcripts with timing — this is how the full pipeline is tested without a microphone, and how UI work proceeds in the Simulator (real speech does NOT work in the Simulator).

## 9. Data model (SwiftData)

```swift
@Model final class Script {
    @Attribute(.unique) var id: UUID
    var title: String            // auto-derived from first line, editable
    var rawText: String
    var locale: String           // BCP-47, default device locale, e.g. "en-US"
    var wordCount: Int
    var tokenCacheData: Data?    // encoded ScriptIndex; nil ⇒ rebuild on load
    var createdAt: Date
    var updatedAt: Date          // any edit invalidates tokenCacheData
    var lastUsedAt: Date?
    @Relationship(deleteRule: .cascade) var sessions: [PromptSession]
}

@Model final class PromptSession {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var activeSeconds: Int       // prompting time only; pauses excluded
    var completed: Bool          // reached end of script?
    var wasDemo: Bool            // demo sessions never meter
    var script: Script?
}

@Model final class UsageLedger {
    @Attribute(.unique) var dayKey: String   // "2026-08-04" in the user's LOCAL calendar
    var secondsUsed: Int                     // free-tier meter; premium ignores it
    var updatedAt: Date
}
// Persist every 15 s during prompting AND on scenePhase change → survives app kill.

@Model final class AppSettings {            // single row
    var fontScale: Double        // pinch-adjustable on prompt screen, persisted
    var mirrorDefault: Bool      // beam-splitter rigs
    var outdoorMode: Bool
    var hasCompletedDemo: Bool
    var aiRewriteEnabled: Bool   // feature flag, default false at launch
    var premiumCachedActive: Bool // last-known RC entitlement → offline unlock
    var premiumCachedAt: Date?
}
```

Notes for Eric: `tokenCacheData` stores the precomputed `ScriptIndex` (sentence spans, normalized tokens, token→character-range map) so the prompt screen opens instantly. Rebuild lazily if nil or if `updatedAt` > cache timestamp. `UsageLedger.dayKey` uses the local calendar deliberately — "10 minutes a day" must reset at the user's midnight, not UTC.

## 10. The matching engine (the product's soul)

Pure Swift, imports Foundation only, zero UI/Speech dependencies → fully unit-testable. Built and tuned against fixtures BEFORE any speech code exists.

### 10.1 Preprocessing (at script save)
1. Sentence segmentation via `NLTokenizer`; sentences grouped into paragraphs.
2. Per-sentence tokenization: lowercase → strip punctuation → NFKD diacritic fold → collapse whitespace. Keep token→character-range map (needed to highlight the original text).
3. Encode as `ScriptIndex` → `Script.tokenCacheData`.

### 10.2 Live loop (per transcript delta)
```
normalize new spoken tokens → append to ring buffer (last 20 tokens)
→ LOCAL SEARCH: candidate anchors in [cursor − 10, cursor + 40] script tokens
→ score each anchor (10.3)
→ best ≥ 0.72 (ADVANCE)  → move cursor
→ best < 0.45 (RECOVERY) sustained ≥ 2.5 s of speech
      → widen to [cursor, cursor + 400], then whole script forward
      → jump only if candidate ≥ 0.80 (glide-scroll ~0.6 s, never hard cut)
→ emit PromptCursor(position, confidence)  — rate-limited 10 Hz
```

### 10.3 Scoring
Align last K spoken tokens (K = 6–12) against script tokens at the anchor. Per-token similarity: 1.0 exact; else normalized Levenshtein, ≥ 0.8 counts as match (absorbs ASR errors: there/their, gonna/going-to, accent artifacts). Score = weighted match ratio with **recency weighting** (latest spoken tokens ×2 — the speaker's mouth is at the end of the buffer).

### 10.4 Stability rules (what makes it feel magical)
- **Hysteresis:** never move backward > 3 tokens; never jump forward > 6 tokens without recovery-grade confidence.
- **Silence > 1.5 s:** freeze cursor. The speaker is pausing or looking at the lens. Do not drift. **This is the eye-contact feature.**
- **Ad-lib:** confidence collapses → cursor holds, subtle "listening" pulse on current sentence. No modals during a take. Ever.
- **Repeat a sentence:** backward cap means the cursor waits; tracking resumes when the speaker moves on.
- Filler stoplist ("um, uh, like, you know") stripped from the spoken buffer.

### 10.5 Tuning
All thresholds in one `MatcherConfig` struct. Debug-only replay screen runs fixture transcripts (with injected misrecognitions, skips, repeats) against fixture scripts, printing: mean cursor error (tokens), false-jump rate. Tune on fixtures; record final values + reasoning in `docs/MATCHING_ENGINE.md`. **Gate: mean error ≤ 2 tokens, false jumps ≤ 1 per 500 words.**

## 11. Speech pipeline — verified facts & known traps (July 2026)

These are checked against Apple docs/forums. Do not "improve" them from memory; re-verify at build time.

1. Use `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)` with `reportingOptions: [.volatileResults]` (live interim text) and `attributeOptions: [.audioTimeRange]` if word timing aids scroll smoothing.
2. **Assets are system-managed:** `SpeechTranscriber.supportedLocale(equivalentTo:)` → if needed `AssetInventory.assetInstallationRequest(supporting:)` → `downloadAndInstall()`. **Pre-warm during onboarding/demo screen** so the first real session starts instantly.
3. Audio format: `await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])`; convert mic buffers via `AVAudioConverter` before yielding `AnalyzerInput`.
4. Results arrive on an `AsyncSequence`; each result has text + `isFinal`. Maintain `volatileTranscript` / `finalizedTranscript` per Apple's WWDC25 pattern (on final: clear volatile, append finalized — prevents duplicate tokens reaching the matcher).
5. **TRAP:** under Swift 6 strict concurrency it's easy to consume `results` on the main actor and serialize processing — forum reports of 14 s first-result latency. Consume OFF the main actor; hop to `@MainActor` only to publish cursor/UI state.
6. **TRAP:** `SpeechTranscriber.supportedLocales` can be EMPTY in the Simulator. All speech claims must be device-tested. Simulator work uses `FakeTranscriptionService`.
7. **LIMITATION:** custom-vocabulary support is weaker than legacy `contextualStrings`. If the current SDK exposes `AnalysisContext`/`setContext`, feed it distinctive script words (proper nouns, jargon). If not, do NOT fake it — the fuzzy matcher absorbs recognition errors by design.
8. `AVAudioSession` category `.playAndRecord`, mode `.measurement`; handle interruption notifications (phone call mid-take → auto-pause, preserve cursor, resume cleanly).
9. Info.plist: `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription` with friendly copy.
10. Battery: continuous ASR for 30 min is the M8 measurement, not an assumed problem.

## 12. Frontend — screens, states, UX contract

Global: SwiftUI only; portrait + landscape everywhere; Dynamic Type everywhere; every screen defines empty/loading/error states.

### 12.1 Home
- Script list (title, word count, ~duration estimate, last used), big "New Script" button, mascot idle top corner.
- First launch: Demo card is the hero ("See the magic — 30 seconds").
- Empty state: mascot + "Paste your first script."

### 12.2 Demo
- One tap → friendly pre-permission explainer → system mic permission → bundled 100-word script live-follows the user's voice.
- Never metered, no signup. While the explainer shows, pre-download the speech asset (§11.2) with a small progress hint.
- End: "That's ScriptWatch." → Create your first script.

### 12.3 Script Editor
- Paste/type; title auto from first line (editable); autosave to SwiftData.
- Word count + estimated speaking time (~150 wpm) live.
- "Optimize for speaking" button ONLY if `aiRewriteEnabled` flag: runs on-device FoundationModels, shows a **diff**, user accepts/rejects. Never auto-applies. If model unavailable → button hidden (graceful absence, no error).

### 12.4 Prompt Screen (the product)
- Layout: text column fills the available height (not a fixed-height box — an earlier capped-height layout left dead space below the reading position once the cursor advanced). Column width adjustable; ~34 pt default, pinch-to-scale (persisted).
- Text styling **(locked 2026-08-20 after five on-device iteration rounds — this is final, see docs/DECISIONS.md):** text is always full-contrast `ink` — there is no "future"/faded state and no current-sentence highlight or underlay. The only color change is a single moving marker: whichever word was *most recently confirmed spoken* is `spoken` grey, and that marker moves forward exactly one word at a time as the cursor advances. Already-read text does not stay grey — once the marker moves past a word it reverts to `ink`. This supersedes every earlier design in this doc (three-state teal current-word, two-state permanent grey trail, per-paragraph grey trail) — none of those matched intent on-device.
- Manual scroll is enabled (not disabled) — the reading `ScrollView` must remain user-scrollable in addition to auto-following the cursor.
- Scroll: smooth, interruptible, spring-based, critically damped (no overshoot — an underdamped spring re-triggering on every word visibly overshot and snapped back). The within-sentence continuous nudge and the between-sentence jump move in the same direction; they must never sawtooth against each other. Recovery jumps glide (~0.6 s).
- Controls: single bottom bar — Pause/Resume · Restart · Exit — auto-hides after 3 s, tap to reveal, all in bottom 40% (one-handed). Mirror-mode toggle in a corner (beam-splitter rigs).
- Ad-lib state: dim "listening" pulse on current sentence. NO modals during a take.
- Free-tier: if minutes run out mid-session, **finish the current session gracefully**, then show the paywall. Never cut a take.
- End of session: summary (duration, minutes left today) + subtle "shot something great? tag #ScriptWatch".
- Reduce Motion: scroll degrades to gentle cross-fade position changes. VoiceOver announces "Paused"/"Resumed".

### 12.5 Paywall
- Honest, retro-styled, custom-built (RC Paywall templates only as time-critical fallback): free-tier facts, USD 6.99/month, Restore Purchases, and the privacy line: *"Everything runs on your iPhone. We can't see your scripts — there's no server to send them to."*
- Reached only when free minutes are exhausted or via Settings. Handles pending (Ask to Buy), expired, revoked, grace period.

### 12.6 Settings
Outdoor mode · mirror default · default text size · Manage subscription (RC) · Restore · Licenses (fonts OFL) · About. Nothing else.

## 13. Design system (v2 — 2026-08-14, supersedes the v1 tokens; spec-only, see migration note)

Light "liseuse" mode is the default and only normal mode.

| Token | Hex | Use |
|---|---|---|
| `paper` | `#EAE0D5` | App background |
| `card` | `#F2EBE1` | Card surface — half-step lighter than paper; needs no border |
| `hairline` | `#DCD0BF` | Border/hairline, only where separation is needed without a card |
| `ink` | `#251F47` | Primary text (Space Indigo) |
| `action` | `#034C3C` | Buttons, links, accents (Pine Teal) |
| `current-sentence` | `#CDDCD3` | Current-sentence highlight underlay — teal-tinted paper; ink on top stays ≥ 10:1 |
| `spoken` | `#7A7186` | Already-spoken text — indigo greyed, intentionally muted, ~3.2:1 |
| `future` | `#A99E90` | Not-yet-spoken text |
| `warm` | `#B8641F` | Recording dot, success moments — use sparingly |
| `error` | `#8C3A2E` | Errors — muted brick, no alarm-red on warm paper |
| `on-dark` | `#FFFFFF` | Text on `ink`- or `action`-filled surfaces |

Verified contrast: ink on paper 11.8:1 (AAA) · teal on paper 7.7:1 (AAA) · white on teal 10.0:1 · white on indigo 15.4:1.

**HARD RULE:** `ink` and `action` must never sit directly on each other (1.5:1 — fails contrast and harms deuteranopia users). They may only meet through `paper`/`card` surfaces.

### High-contrast / outdoor mode (single override layer, §12.6 toggle)
- bg `#FFFBF2` (warm white, not pure white), ink `#0E0B14` (warm black, ~19:1).
- Current sentence: heavy 3pt underline in `#033D30` instead of the tint underlay — tints wash out in direct sunlight, strokes don't.
- `spoken` `#6B6B6B`, `future` `#8F8F8F`, buttons `#033D30` with white labels.

### Typography (v2)
- UI face: **Hanken Grotesk** (OFL) — replaces Inter everywhere.
- Display/wordmark: **Space Grotesk** — unchanged.
- Prompt reading face: user-selectable between **Hanken Grotesk** (default) and **Source Serif 4** (OFL) — the serif option is a product feature (liseuse reading mode), not decoration.
- Mono (debug, counters): **IBM Plex Mono** — unchanged.

All new/changed faces are OFL — bundle, register `UIAppFonts`, list licenses in Settings, same as M0's original three.

- Shape language: rounded rects 12–16 pt radius.
- **Hard bans:** gradients, glassmorphism, glow, "AI sparkle" iconography, pure `#FFFFFF`/`#000000` backgrounds anywhere in normal mode.
- Mascot: minimal geometric CRT, two simple eyes, no face/cartoon. Appears ONLY: Home idle, loading (eyes scan), success (eyes crescent). **Never on the Prompt screen.**
- Accessibility gates: WCAG AA contrast everywhere, largest Dynamic Type sizes tested on the prompt screen.

**Migration note (2026-08-14):** this v2 palette/type system supersedes v1
(`bg.cream`/`ink.primary`/`navy.deep`/`blue.vintage`/`yellow.warm`/`ink.spoken`, Inter). It is
recorded here as the spec going forward but is **not** retrofitted onto the existing `#if
DEBUG` scaffolding (`DebugTools/`, `Prompt/`, which still use v1's `Theme.swift` tokens as of
this date) — v2 is applied when the real M5 screens and M7 Settings/accessibility pass are
built, per the owner's explicit instruction not to restyle debug screens for this change. See
docs/DECISIONS.md.

## 14. Folder structure

```
ScriptWatch/
├── ScriptWatch.xcodeproj
├── AGENT_PROGRESS.md                  # running progress log (§22)
├── docs/
│   ├── ARCHITECTURE.md                # keep synced with reality
│   ├── MATCHING_ENGINE.md             # algorithm + tuning record
│   ├── DECISIONS.md                   # dated, every non-obvious choice
│   └── buildinpublic/                 # milestone clips + posts (§23)
├── ScriptWatch/
│   ├── App/            ScriptWatchApp.swift · AppEnvironment.swift
│   ├── Models/         Script.swift · PromptSession.swift · UsageLedger.swift · AppSettings.swift
│   ├── Speech/         AudioCaptureService.swift · TranscriptionService.swift ·
│   │                   TranscriptStream.swift · SpeechAssetManager.swift
│   ├── Matching/       Tokenizer.swift · ScriptIndex.swift · SlidingWindowMatcher.swift ·
│   │                   RecoverySearch.swift · ConfidenceModel.swift · PromptCursor.swift ·
│   │                   MatcherConfig.swift        # ← Foundation-only, pure, tested
│   ├── Prompt/         PromptScreen.swift · PromptViewModel.swift ·
│   │                   ScrollAnimator.swift · PromptTextRenderer.swift
│   ├── Editor/         ScriptListScreen.swift · ScriptEditorScreen.swift · AIRewriteService.swift
│   ├── Demo/           DemoScreen.swift · DemoScript.swift
│   ├── Paywall/        EntitlementService.swift (RevenueCat) · UsageMeter.swift · PaywallScreen.swift
│   ├── DesignSystem/   Theme.swift · Typography.swift · Components/ · Mascot/
│   ├── Accessibility/  OutdoorMode.swift
│   └── Resources/      Fonts/ · Assets.xcassets · Localizable.xcstrings (EN launch)
├── ScriptWatchTests/
│   ├── Matching/       TokenizerTests · SlidingWindowMatcherTests · RecoveryTests ·
│   │                   ConfidenceHysteresisTests · Fixtures/ (scripts + noisy transcripts)
│   ├── UsageMeterTests.swift
│   └── EntitlementServiceTests.swift  # StoreKitTest config
└── ScriptWatchUITests/ CoreFlowsUITests.swift   # demo → editor → prompt → paywall
```

## 15. Toolchain decisions

| Item | Decision |
|---|---|
| Min iOS | **26.0** (SpeechAnalyzer requirement; not available earlier) |
| Language | Swift 6.x, strict concurrency ON |
| UI | SwiftUI only (UIKit wrap only for a documented gap) |
| Persistence | SwiftData |
| Dependencies | **RevenueCat via SPM — the only third-party package.** Anything else needs Sid's written approval |
| Backend | None. Ever. |
| App size | < 25 MB download (speech models are system assets, not bundled) |
| Code hygiene | Zero warnings, no force-unwraps outside tests, no `TODO`/`fatalError("unimplemented")` in shipped paths |

---

# PART III — EXECUTION: TIMELINE, TEAM, PROCESS

## 16. Timeline (calendar-locked to Shipaton)

**Today is Aug 4. The window closes Sep 30. We target App Store submission Sep 15 to absorb review rejections. ~6 build weeks.**

| Week | Dates | Milestones | Gate (blocks next week) |
|---|---|---|---|
| **W1** | Aug 4–10 | **M0** scaffold (folders, theme, fonts, SwiftData models, CI compile) + **M1** matching engine + fixture suite | M1 metrics: mean cursor error ≤ 2 tokens, false-jump ≤ 1/500 words — **before any speech code** |
| **W2** | Aug 11–17 | **M2** speech pipeline (capture → SpeechAnalyzer → TranscriptStream) + debug transcript view | Live transcript on a physical device, < 1 s to first volatile result |
| **W3** | Aug 18–24 | **M3** prompt screen wired to engine via FakeTranscriptionService replay → **M4** live integration | **THE gate:** 400-word live read on device tracks end-to-end incl. one paragraph skip + one ad-lib, no manual intervention |
| **W4** | Aug 25–31 | **M5** Home/Editor/Demo flow + **M6** UsageMeter + RevenueCat + Paywall | Demo works on fresh-permissions path; `premium` entitlement unlocks in sandbox; StoreKitTest green |
| **W5** | Sep 1–7 | **M7** Settings, accessibility pass, AI-rewrite flag, polish + **M8** hardening (30-min battery/thermal, backgrounding, call-interruption) + **Sid's dogfood shoot: one real YouTube take** | No crashes; session survives interruption; dogfood friction list triaged |
| **W6** | Sep 8–14 | **M9** App Store package: screenshots, privacy labels ("Data Not Collected" + RC purchase disclosure), review notes explaining mic usage; **submit by Sep 15** | Passes App Store validation; submitted |
| Buffer | Sep 15–30 | Review round-trips, hotfixes, #BuildInPublic push, Shipaton submission on Devpost (video + store link) | **Live on the App Store ≤ Sep 30** |

Slip rule: if M4 hasn't passed by **Aug 26**, scope-cut ruthlessly (drop AI rewrite, drop mirror mode polish, keep demo + prompt + paywall) — the hackathon needs a shipped app, not a complete one.

## 17. Team & responsibilities

| Who | Owns | Notes |
|---|---|---|
| **Eric (dev lead)** | Architecture integrity, speech pipeline (§11 traps), matching engine review & tuning, all device testing, App Store submission mechanics | Final word on technical trade-offs; verifies every agent PR against §24 rules |
| **Sid (product owner)** | Product calls, design taste (§13 bans), RevenueCat + App Store Connect accounts, demo script copy, dogfood shoot (M8), all #BuildInPublic posting, Devpost registration + submission | Registers on Devpost NOW → unlocks ShipKit credits (some while-supplies-last) |
| **Coding agent** | Implementation under this spec, per-session progress reports (§22), anti-hallucination protocol (§24) | Never merges to main without Eric's review on Speech/Matching/Paywall code |

Accounts checklist (Sid, this week): Apple Developer ($99) · App Store Connect app record + subscription `scriptwatch.premium.monthly` @ 6.99 · RevenueCat project, entitlement **`premium`**, default Offering, public API key · Devpost registration.

## 18. Budget (≤ $900)

| Item | Est. |
|---|---|
| Apple Developer Program | $99 |
| Coding-agent / LLM credits | $300–600 |
| Fonts, assets | $0 (OFL) |
| Backend / ASR | $0 (on-device) |
| Contingency | remainder |

## 19. Definition of done (v1)

- [ ] All screens §12, matching §13 tokens, both orientations, Dynamic Type.
- [ ] Matcher fixture metrics met (§10.5) AND the M4 live test passed on device.
- [ ] Metering + RevenueCat entitlement + restore working in sandbox; offline premium unlock via cached entitlement.
- [ ] Accessibility gates §13 pass; Reduce Motion + VoiceOver on prompt screen.
- [ ] Zero warnings; strict concurrency; Matching coverage ≥ 90%, services ≥ 70%.
- [ ] < 25 MB; battery measured for a 30-min session (number recorded, not guessed).
- [ ] docs/ current; AGENT_PROGRESS.md complete; build-in-public artifacts for M1/M4/M6/M8.
- [ ] Archive validates; submitted ≤ Sep 15; live ≤ Sep 30.

## 20. RevenueCat implementation notes (hackathon-critical)

- SPM: add RevenueCat; configure `Purchases` at launch with the public key. **Check current SDK docs before coding — same verification rule as Apple APIs.**
- Single source of truth: `customerInfo.entitlements["premium"]?.isActive == true`. Subscribe to customer-info updates; cache into `AppSettings.premiumCachedActive` (+ timestamp) so paying users stay unlocked offline / on airplane mode. Verify lazily; never lock out.
- Local `.storekit` config + StoreKitTest for CI; RC works against sandbox.
- Disqualification risk lives here: the purchase flow must work in production sandbox before Devpost submission.

## 21. Out of scope for v1 (recorded so nobody "helpfully" builds them)

Same-device filming/camera features · Android/Galaxy Store · web billing (Stripe) · cloud AI rewrite · accounts/sync · analytics SDKs · push notifications (OneSignal) · iPad-optimized layout (works, not optimized) · languages beyond device-locale EN at launch (string catalog ready for FR/zh-Hant later — Sid's markets).

## 22. Progress reporting protocol (mandatory, every session + every gate)

Append to `AGENT_PROGRESS.md`:

```markdown
## [2026-MM-DD HH:MM] Session N — Milestone Mx
**Done:** facts only, each with evidence (test name passing / device-tested Y-N)
**Verified against docs:** API symbols checked this session + doc URL
**Blocked / Risks:** (empty is a valid answer)
**Deviations from spec:** with justification → also docs/DECISIONS.md
**Next:** concrete steps
**Questions for owner:** max 3, only if truly blocking
```

Rules: never "done" without a named passing test or device check · slips reported explicitly · bad news first.

## 23. #BuildInPublic artifacts (judged category — produce at each gate)

| Gate | Artifact (→ docs/buildinpublic/, Sid posts with #BuildInPublic #Shipaton) |
|---|---|
| M1 | Matcher replay visualization — cursor tracking a noisy fixture transcript |
| M4 | **THE clip:** live voice-follow with a visible paragraph skip + ad-lib hold — big type, obvious cursor. This is also the App Store preview and the Reels ad |
| M6 | Paywall + honest pricing-decision paragraph |
| M8 | A real YouTube video shot by Sid using ScriptWatch, incl. the eye-contact moment |

Each artifact ships with one honest paragraph: what broke, what we learned. Judges reward story + engagement, not audience size.

## 24. Anti-hallucination protocol (for the coding agent — structural, not aspirational)

1. **API verification loop:** before using any Speech / RevenueCat / SwiftData / FoundationModels symbol: read the current official docs for the exact signature → minimal compile check → integrate. Log verified symbols in the progress report. Docs beat memory; ambiguity → 10-line spike, run it.
2. **Compiler is ground truth.** Build after every meaningful change.
3. **No phantom features.** Missing API (e.g., custom vocabulary)? Don't stub a fake. Record in DECISIONS.md, adapt (the fuzzy matcher exists for this), flag in the report.
4. **Test-first core:** the matcher is proven on fixtures before speech exists — its correctness never rests on beliefs about ASR.
5. **Device-truth over simulator-truth:** any speech claim must say "device-tested" or it doesn't count.
6. **No invented numbers:** latency/battery/accuracy figures come from named measurements.
7. **Uncertainty:** can't cite a doc or a passing test for the code you're writing? Stop → verify → or ask one precise question.
8. **Scope honesty:** if something here is impossible on iOS 26, prove it (citation or failing spike) and propose the nearest alternative. No silent scope reduction.

## 25. Instant-rejection list (owner will bounce the build)

Network calls beyond RevenueCat / optional flagged AI rewrite · any other third-party dependency · LLM in the matching path · scroll-speed/WPM settings · mascot on the prompt screen · gradients/glassmorphism · paywall or any modal interrupting an active take · TODO/fatalError in shipped paths · progress reports claiming completion without a named passing test.

---

*Start at M0 today. First progress report due end of first session. The single most important date in this document is Aug 26: if M4 (live voice-follow) hasn't passed by then, cut scope and protect the ship date.*
