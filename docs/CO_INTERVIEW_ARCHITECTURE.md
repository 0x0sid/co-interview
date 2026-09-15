# Co-Interview — inherited architecture

> **Fork-day survey, kept as history (note added 2026-09-16).** Its observations and defect list remain
> accurate for the code. Its reuse verdicts ("probably wrong for an interview app", "decide the matching
> question first") predate the confirmed copilot direction, which preserves teleprompter scrolling,
> matching and spoken-word fading. Current mapping and proposals are in
> [`CO_INTERVIEW_COPILOT_ARCHITECTURE.md`](CO_INTERVIEW_COPILOT_ARCHITECTURE.md). The `DeviceLogAuditTests`
> row below describes the private clone; that test was removed from the public snapshot. The text below is
> otherwise unchanged from the fork.

Everything under **Observations** was read from the source at fork time. Everything under
**Proposals** is a suggestion and is labelled as such.

## Observations — what is actually here

### Module map (`prompter/`)

The source directory is still called `prompter/`; renaming it would churn every file path for no
functional gain and was deliberately not done.

| Module | Contents | Interview relevance |
|---|---|---|
| `App/` | `PrompterApp` entry, `RootView`, `AppEnvironment` (SwiftData container) | **Reusable** — app wiring, appearance preference |
| `DesignSystem/` | `Theme` (adaptive light/dark tokens), `Typography`, button styles, mascot | **Reusable** — measured-contrast palette, verified in tests |
| `Models/` | `Script`, `PromptSession`, `UsageLedger`, `AppSettings`, `ReadingLanguage` | **Partly** — persistence *patterns* reusable; the entities are Prompter's domain |
| `Editor/` | `ScriptListScreen` (library, search, delete), `ScriptEditorScreen` (keyboard-aware editing) | **Reusable** — a solid text CRUD surface |
| `Speech/` | `TranscriptionService`, `AudioCaptureService`, `SpeechAssetManager`, `TranscriptStream` | **Most reusable part** — on-device capture, locale resolution, model download, permissions |
| `Settings/` | `SettingsScreen`, `PaywallScreen` host | **Partly** — the shell is reusable; its contents are Prompter's |
| `Matching/` | `SlidingWindowMatcher`, `ConfidenceModel`, `RecoverySearch`, `Tokenizer`, `ScriptIndex` | **Prompter-specific** — see below |
| `Prompt/` | `PromptScreen`, `PromptViewModel`, `ScrollOwnership`, `ScrollAnimator`, `ScriptStyling` | **Prompter-specific** — teleprompter presentation |
| `Billing/` | `UsageMeter`, `UsageTracker`, `EntitlementService`, `BillingConfiguration`, `PaywallScreen` | **Do not inherit as requirements** |
| `Accessibility/` | `OutdoorMode` high-contrast palette | Reusable if relevant |
| `DebugTools/` | Debug screens, all `#if DEBUG`, unreachable from the UI | Neutral |
| `Demo/` | Bundled demo flow | Prompter-specific |

### Data flow at a take (inherited)

```
AudioCaptureService ──▶ TranscriptionService ──▶ TranscriptStream ──▶ PromptViewModel
   (AVAudioEngine)        (SpeechAnalyzer/            (volatile/final     │
                           SpeechTranscriber)          reconciliation)    ▼
                                                                   SlidingWindowMatcher
                                                                          │
                                                          PromptCursor ───┼──▶ ScriptStyling (fading)
                                                                          └──▶ PromptScreen (scrolling)
```

**The coupling that matters:** everything downstream of `TranscriptStream` assumes *a known script
to align against*. `SlidingWindowMatcher` matches spoken words to an expected token sequence. An
interview has no expected script — the whole point is that you do not know what will be said. That is
the single largest inherited assumption to examine.

### What is genuinely reusable

- **Speech capture and transcription** (`Speech/`) — locale resolution via
  `SpeechAssetManager.supportedLocale(for:)` **throws** rather than silently falling back to English;
  model download with progress; permission handling. This is the most valuable inherited asset.
- **Design system** — adaptive light/dark with contrast asserted in tests, not eyeballed.
- **Local persistence patterns** — SwiftData models, a fetch-or-create settings singleton, cascade
  rules, deletion with confirmation and rollback on failure.
- **Editing surface** — keyboard-aware text editing that reaches the end of long documents.
- **Test infrastructure** — Swift Testing, deterministic replay fixtures, evidence-based verification
  conventions, and a `-promptReplay` harness that drives the real UI against scripted transcripts.

### Inherited components pending a product decision

**These are NOT confirmed dead code.** Their suitability depends on an interview workflow that has
not been defined, so they are retained and recorded as open:

| Component | Why its fate is undecided |
|---|---|
| `Matching/` (`SlidingWindowMatcher`, `ConfidenceModel`, `RecoverySearch`, `Tokenizer`, `ScriptIndex`) | Aligns speech to a *known* token sequence. Useless for open conversation — but if Co-Interview involves prepared questions, a rubric, or expected talking points, alignment against those is exactly this machinery. `Tokenizer` and `ScriptIndex` are useful independently of matching |
| `Prompt/` (`PromptScreen`, `ScrollOwnership`, `ScrollAnimator`, `ScriptStyling`) | Teleprompter presentation. If an interviewer reads prepared questions from the screen, the voice-following scroll and its ownership rules may transfer directly |
| `Billing/` | Prompter's commercial model carries no authority here; re-derive from Co-Interview's own decisions |
| Spoken-word fading, script-based recovery, the daily usage meter, the paywall | Coherent solutions to Prompter's problem; unevaluated against Co-Interview's |

**Decide these only after the product brief's questions 1–4 are answered.** Removing them now would
discard working, tested code on a guess about a workflow that does not exist yet.

### Defects inherited with the code

These are real and documented; they come with the fork.

| Defect | Note |
|---|---|
| `DeviceLogAuditTests` LOST 3 | Three captured utterances where the cursor lost a genuinely reading user. Fails in the inherited suite. **Prompter-domain** — irrelevant if matching is dropped |
| `restartClearsTheSpokenSet` intermittent | Fails occasionally in full runs, passes in isolation. Cause **unproven** |
| `onChange … multiple times per frame` | SwiftUI warning at scroll resume, diagnosed, unfixed |
| `[pause]` markers tokenize as a literal `"pause"` | Markers were never stripped before matching |
| Usage display stale across midnight | The *gate* rolls over correctly; the displayed remainder does not, within one app session |
| French / Traditional Chinese unvalidated | Wired but not localized and not device-tested |

### Untouched versus disconnected at the fork

- **Untouched:** all source, all tests, all inherited documentation.
- **Changed for identity only:** bundle identifiers, display name, project filename, shared scheme,
  and the SwiftData store filename.
- **Disconnected:** the Git remote (removed), and Prompter's App Store/RevenueCat configuration
  (never present in the repository — no key, no products).

## Proposals — not decisions

1. **Decide the matching question first.** If Co-Interview transcribes open conversation, `Matching/`
   and `Prompt/` are dead weight and should be removed rather than adapted; if some scripted element
   survives (prepared questions, for instance), parts may be salvageable.
2. **Keep `Speech/` as the foundation** and build the new domain around it.
3. **Treat speaker separation as a research question, not a feature.** Two voices on one microphone is
   substantially harder than one, and the inherited pipeline does not address it.
4. **Do not port `Billing/`.** Re-derive any commercial model from Co-Interview's own product
   decisions.
