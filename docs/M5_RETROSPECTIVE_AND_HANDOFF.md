# Prompter — M5 Retrospective & Handoff Report

> **INHERITED FROM PROMPTER — historical reference only.** This describes *Prompter*, a separate
> paused project. It is **not** a Co-Interview specification and its roadmap, milestones and release
> criteria do not apply here. Start at [`CO_INTERVIEW_START_HERE.md`](CO_INTERVIEW_START_HERE.md).


> **Status notice.** Superseded as a handoff by
> [`PROMPTER_CURRENT_STATE.md`](PROMPTER_CURRENT_STATE.md). This document is preserved for its
> criticism ledger and the lessons in it, which remain valid; its status tables and next-step lists
> are historical.


---

# STATUS 2026-09-10 — read this before anything below it

## The "P0 FIXED by `6eece17`" claim is SUPERSEDED. It was wrong.

An earlier revision of this header announced the cursor-lost P0 fixed by commit `6eece17`
(`staleWindowSeconds`, a time-based stale-word horizon). **That claim is withdrawn.** The fix was
validated against a fixture that spaced a 22-word utterance 0.001 s apart; replayed at realistic
spacing it is a **no-op** — cursor 18, still lost, at every horizon from 2.0 s to 8.0 s.
`staleWindowSeconds` has been removed from `MatcherConfig`. The commit and its reasoning stay in
history and in `AGENT_PROGRESS.md`; only the status claim is retracted.

The root cause of that error is recorded because it generalises: **a time-based rule was accepted on
evidence from fixtures whose time was compressed.** See docs/MATCHING_ENGINE.md §M5.2.2.

`stallCandidateFreshnessSeconds` (also from `6eece17`) is retained but is **not** part of the P0
fix — no P0 measurement implicates it. It addresses a separate, real defect found during diagnosis
and keeps its own control test. Flagged for the owner as adjacent scope.

## Current status, by evidence

| | Status | Evidence |
|---|---|---|
| Cursor-lost P0 | **Fixed in replay. NOT device-confirmed.** | `CursorLostRegressionTests` passes; cursor reaches token 42 (reader is at ¶2, tokens 30-70) on a *reconstructed* replay |
| Control for it | Present | `SuffixReacquisitionTests.theCursorIsLostAgainWhenSuffixReacquisitionIsDisabled` — token 18 with the rule off |
| Spoken-token invariant | **Held, after a defect was found and fixed** | the first implementation greyed 24 unspoken tokens; now classified `.recovering`, guarded by `suffixReacquisitionNeverMarksSkippedTextAsSpoken` |
| M1 gate | **Passes, improved** | `meanCursorError=0.7658760520275439` (was 0.9074215761285387), `falseJumps=0` |
| M5.1 false jump | Still guarded | `MetaCommentaryFalseJumpTests` + control pass |
| M4 token-155 freeze | Still guarded | `DeviceFreezeReplayTests` passes (now on per-word timing) |
| Captured 9.6 s reading stall | **Substantially reduced; cause identified as tokenisation, not recognition** | Longest incorrect hold **7.72 s → 3.86 s** and position error never again exceeds 1 token, from the M5.6 split-script-token join alone (`TokenJoinTests`, docs/MATCHING_ENGINE.md §12). The earlier M5.5 tracked-read path contributes ~0.9-2.0 s of onset delay and is inert on all 28 M1 fixtures. 0.88 was **never** implicated |
| Cause of the residual stall | **My "global scoring must change" hypothesis is FALSIFIED** | The compound `backup` vs `back` `up` dragged the alignment one token out of phase; fixing the phase restored tracking with no change to token credit, thresholds or scoring semantics (§11c, §12) |
| Anchor-correctness claim | **Validated, not inferred** | `anchor + windowSize` checked tick-by-tick against labelled reading: 13/17 exact, 3 one token behind (the compound-drift span), 1 pre-lock. An advancing anchor alone was never sufficient evidence |
| Manual reposition → auto-resume | **Implemented (M5.7), replay-verified only** | `ScrollOwnership` + 12 `ScrollOwnershipTests`. Supersedes "stay detached until the button is tapped". The 2026-09-12 capture showed tracking recovering while every target stayed `SUPPRESSED` (token 141 at confidence 1.00, and through 155-165) because `isManuallyDetached` had no path back to `false` except the button or Restart |
| Joined words' styling | **Known cost, accepted this round** | A joined advance greys nothing for that feed (measured). Safe direction — no unspoken word is marked — but spoken words stay dark. First candidate for the next round |
| Full suite | see the results table in the latest §M5 entry of `AGENT_PROGRESS.md` | `DeviceLogAuditTests` red on LOST — see below |
| P0 recovery delay | **2.960 s, 5 words into the paragraph**; one move 18 → 42; 0 backward slip | `SuffixReacquisitionTests.p0RecoveryDelayAndTrajectory` |
| Suffix rule side effects | **0 regressions across all 63 audited utterances**, 1 improvement | `suffixScoringDoesNotMakeAnyIndividualUtteranceWorse` |
| Clock divergence | **magnitude unmeasured; existing captures cannot measure it** | `[ClockAudit]` instrumentation added (debug-only); needs one device session to read |
| `VolatileReconciliationTests` | **Diagnosed, not "flaky"** | the test sampled the cursor before the `.final` was reconciled — the last failing run showed `confidence` and `state` already correct and only `tokenIndex → 2` short of 3. Fixed by waiting on `listeningText` going non-empty then empty, which is the production path's own completion signal. No production change |

## M5 closure — explicitly reconciled

**M5 cannot close.** The retrospective's §2 lists colour and scroll behaviour as awaiting device
confirmation, and it is tempting to treat those as the only outstanding items. They are not:

1. **The P0 is a tracking failure, and tracking failures block closure regardless of colour and
   scrolling being accepted.** Colour is *downstream* of the cursor — while the cursor is wrong the
   display is wrong however correct the styling rule is.
2. The P0 fix is verified only against a **reconstructed** replay. No device read has exercised it.
3. `DeviceLogAuditTests` is red on real captured sessions: **LOST 3** (FALSE-JUMP 0; one utterance
   is UNRESOLVED and *not* counted as success).

**On the LOST 3 — the tradeoff is real, and my withdrawal of it was wrong.**

An earlier revision of this file asked you to choose between accepting false jumps and refusing
legitimate recovery. The round after that withdrew the question, claiming the cases were
distinguishable by corroboration. **That withdrawal is itself withdrawn.** The comparison behind it
scored the wrong span — the M5.1 killer phrase appears at two stages of the corpus, and the audit
measured a 12-word window that did not contain it (0.333) instead of the one that did (0.833).
Rejecting a 0.333 candidate proves nothing about protection from a 0.833 one.

Corroboration was then specified in terms the matcher can actually observe (it receives appended
tokens, not utterances) and **tested. It fails in both directions**: it fires for the M5.1
coincidence — corroborated by an unrelated candidate 30 seconds later — and does not fire for the
legitimate case, because the reader finishes the script and stops talking, so no later evidence
exists. That second failure is structural, not a tuning problem. It is **not implemented**; the
passing baseline is retained.

So the choice is real, measured, and yours:

| option | consequence |
|---|---|
| **A. keep `extendedStallJumpThreshold` = 0.88** — **chosen by the owner 2026-09-10, retained** | the 3 LOST persist — after a long off-script stretch, skipping far ahead leaves the cursor behind until you read contiguously again. M5.1's 214-token false jump stays fixed. |
| **B. lower to ~0.82** | both LOST events recover, and **the M5.1 false jump returns** — the coincidence scores 0.833. That is the failure you reported from a device. |

Full evidence in docs/MATCHING_ENGINE.md §M5.2.8.

**Option A is now the decision.** It selects the safer interim behaviour and does **not** resolve the
LOST cases, waive the audit gate, or close M5. The 3 LOST observations across 2 events and the 1
UNRESOLVED classification remain open and are reported separately in every run.

## What one device read still needs to establish (not being requested yet)

Recorded so the round is not wasted when it happens. Three specific things, none of which any
existing capture can supply:

1. **A long skip followed by continued reading.** Every long skip in the five captured sessions is
   followed by silence, which is precisely why the tested corroboration rule had nothing to work
   with. Whether corroboration would succeed on such a capture is **not yet established and requires
   a suitable capture** — it is a hypothesis with one known failure mode already (it bounded evidence
   by new tokens rather than elapsed time, and paired candidates 30 s apart) and no positive instance
   yet.
2. **The `[ClockAudit]` lines** — the only way to measure how far the wall-clock and audio clocks
   actually diverge under real ASR lag. Their behavioural impact is **not** resolved and must not be
   described as resolved until a capture containing both clocks exists.
3. That a genuine resumption after off-script speech re-acquires within a few words, and that no text
   you never spoke turns grey after it.

**Everything below is kept as the record of how the P0 was diagnosed.**

---

# ⚠️ The original report — there is an open P0. Do not treat M5 as done.

**Added 2026-09-02, after a device read that the previous agent did not have when writing §2.**

## The bug: the cursor gets permanently lost and cannot recover

Device trace, verbatim. The reader is reading **paragraph 2** aloud — script tokens ~36-65:

```
17.037s VOLATILE-FED "you"      cursor -> token 12  confidence=0.15  holding
18.958s VOLATILE-FED "sentence" cursor -> token 12  confidence=0.65  holding
20.025s VOLATILE-FED "the"      cursor -> token 12  confidence=0.46  holding
22.848s VOLATILE-FED "read"     cursor -> token 12  confidence=0.29  holding
23.840s VOLATILE-FED "at"       cursor -> token 12  confidence=0.24  holding
25.405s TICK  state holding -> frozen
```

Spoken (ASR): `"How you speak the current sentence through the highlight the texture you have already read…"`
Script @36: `"As you speak, the current sentence should highlight, the text you've already read…"`

They are clearly reading the script. **The cursor sits at token 12 and never moves again.** This is the `LOST` state — worse than a false jump, because it is silent and permanent.

## Two compounding causes

**(a) Ring-buffer pollution blocks the local advance.**
The 9-token alignment window still holds the reader's *previous off-script* words (`"I just want out to light"`). Hand-computing the recency-weighted score for the window `[i, just, want, not, how, you, speak, the, current]` against the best anchor gives **0.537** — which matches the logged `confidence=0.54` exactly. Below `advanceThreshold` (0.72), so no advance. As long as stale off-script words occupy the window, a correct read cannot re-acquire.

**(b) Recovery — the mechanism that exists precisely for this — is gated shut by a change the previous agent made.**
Last advance was at 9.351s, so by 23.8s the stall is ~14s. That is ≥ `extendedStallSeconds` (8.0), so `applyBestStallCandidateIfAboveThreshold` demands `extendedStallJumpThreshold` = **0.88** instead of `recoveryJumpThreshold` (0.80). With ASR this degraded, no candidate reaches 0.88. Recovery can never fire.

This was **explicitly flagged as a risk in §6 of this very document and shipped anyway** — "a legitimate recovery after an 8s+ genuine pause would now need 11-of-12 alignment". It materialised.

## MEASURED 2026-09-09 — cause (b) is falsified. Read this before acting on the two causes above.

> **Historical snapshot, partly superseded.** The conclusion below (cause (b) falsified, cause (a)
> confirmed) still holds and is what the shipped fix rests on. Two details in it were measured
> against a replay whose timing was compressed and have since been re-measured: the sweep row for
> **0.50** now reaches token 42 rather than staying lost (the stall-snapshot expiry from `6eece17`
> changed it), and the "ring buffer emptied" figures came from a *short* window rather than a clean
> one. Current numbers, on reconstructed per-word timing, are in docs/MATCHING_ENGINE.md §M5.2.

The measurement §"What to do first" asked for has been made
(`prompterTests/Matching/CursorLostDiagnosticsTests.swift`, no `Matching/` edits; the shadow it
uses is validated tick-by-tick against the real matcher, 0 divergences).

**The best stall candidate in the entire trace scores 0.7500.** It never reaches even
`recoveryJumpThreshold` (0.80), let alone 0.88. Confirmed independently by sweeping the real
matcher with only `extendedStallJumpThreshold` varied: **0.88, 0.85, 0.80, 0.75, 0.70, 0.65, 0.60
and 0.50 all leave the cursor LOST.** So **(b) is not the cause, and the first-listed candidate fix
above — lowering that threshold — does not work.** Do not spend the false-jump protection on it.

**(a) is confirmed and is sufficient on its own.** Replaying ¶2 with the ring buffer emptied at its
start, changing nothing else:

| ring buffer | best local score | best recovery candidate |
|---|---|---|
| polluted (real behaviour) | 0.648 @ anchor 33 (needs 0.72) | 0.500 @ anchor 30 (needs 0.80) |
| emptied when ¶2 starts | **0.889 @ anchor 36** | **0.833 @ anchor 36** |

Anchor 36 is exactly where the reader is. The local anchor already climbs 28→41 in lockstep with
the reading — the engine knows the position, the stale words only suppress the score.

**Third finding, not in the original diagnosis: the retained stall snapshot goes stale.**
`bestStallCandidate` is captured at t=5.995s at anchor 7 / 0.667 and is then **frozen for the
remaining 42 ticks** — it is never re-scored against the current ring and can only be replaced by a
strictly higher score, while the stall that would clear it is only cleared by an advance that
cannot happen. That is why the low-threshold sweep runs lead to token 19 instead of 36: loosening
the bar makes the matcher act on a stale snapshot aimed at the wrong place. Lowering
`extendedStallJumpThreshold` here is not just insufficient, it is harmful.

Full numbers: `/tmp/cursor_lost_diagnostics.txt`, `/tmp/cursor_lost_threshold_sweep.txt`,
`/tmp/cursor_lost_pollution.txt`; write-up in the 2026-09-09 entry of `AGENT_PROGRESS.md`.

Also re-verified on a clean build the same day: the suite is **32 tests, 29 pass, 3 fail** (not the
"30 tests, 0 failures" in §2 — that predates the two harnesses). `DeviceLogAuditTests` **does now
run to completion** (LOST 5, FALSE-JUMP 1 — it is reporting the P0, not broken), and
`VolatileReconciliationTests` **passes in isolation**: it is a 0.8s-sleep timing flake under
parallel simulator clones, not the `applyCursor` regression feared above.

## What to do first — and what to measure, not assume

> **2026-09-12 update.** The numbered plan below is the *original* M5.2 handoff and is now largely
> historical: step 1's question was answered (the candidate peaks at 0.750 and never reaches even the
> 0.80 bar, so 0.88 was never implicated), and the captured stall's real cause turned out to be a
> tokenisation mismatch, fixed in M5.6 (docs/MATCHING_ENGINE.md §12). **Do not start from step 2's
> threshold options** — they were superseded by measurement. The live next action is §12.7: a short
> comparative device read of paragraphs 3-5 with a stated falsifiable prediction. Keep the method
> below; the specific options are stale.

The previous agent's failure mode was asserting causes without measuring. Do not repeat it.

1. **Instrument before changing anything.** Log the best stall-candidate score and the `requiredScore` inside `applyBestStallCandidateIfAboveThreshold`. Replay this trace. You need the actual number to know whether the candidate was blocked at 0.88, or would also have failed at 0.80 — **that distinction decides the whole fix** and is currently unknown. If it fails at 0.80 too, cause (b) is not the whole story and (a) is primary.
2. **Then decide.** Options, roughly in order of confidence:
   - Make `extendedStallJumpThreshold` adaptive, or drop it back toward 0.80, re-running `MetaCommentaryFalseJumpTests` + `OffScriptCommentaryHoldTests` to check the false jump does not return. The control tests exist precisely so you can tell.
   - Attack (a) directly: flush or decay the ring buffer once confidence has been low for a while, so stale off-script words stop poisoning re-acquisition. This is likely the deeper fix — recovery would not need to be so heroic if the window were clean.
3. **Add this trace as a fixture** in the style of `prompterTests/Matching/OffScriptCommentaryHoldTests.swift`. Ground truth: reading paragraph 2 aloud must move the cursor into the 36-65 region. It currently will not.

## Also unfinished, and relevant

- **`prompterTests/Matching/DeviceLogAuditTests.swift`** — a log-audit harness replaying 5 real sessions and classifying every utterance as TRACKING / HOLDING / **LOST** / FALSE-JUMP. **It was never successfully run to completion.** Its first run produced 8 LOST, but that run fed whole `FINAL` sentences instead of word-by-word, which is not how `PromptViewModel` feeds the matcher, so the result was invalid. The word-by-word fix is written but **unverified — run it first, and re-check its classifier before trusting any verdict.** This harness is the right tool for the P0 above.
- **`VolatileReconciliationTests` failed** in the last full run. Previously diagnosed as flaky, but the previous agent had just modified `PromptViewModel.applyCursor`, and the isolated re-run never completed. **Treat as an unresolved possible regression, not as flakiness.**
- The two most recent commits to `PromptScreen`/`PromptViewModel` (fade animation keyed to `spokenTokenIndices.count`; removal of the `delta <= 6` cap) passed a clean suite but **were never seen on device.**

## Owner's standing constraints (these are firm)

- Never edit `Matching/` or `Speech/` without explicit written approval.
- Verify with `xcodebuild clean` — incremental builds in this project **silently run stale code and report PASS** (see W5-3).
- Every gate gets a control test asserting the bug returns when the gate is disabled.
- The owner tests manually on device. Each wrong guess costs a full round with a frustrated human. **State the invariant and get it confirmed before building.**

---

**Written:** 2026-08-31
**Audience:** an AI agent picking up this project with **no prior context of the session that produced it**.
**Purpose:** an honest account of what was built, what was broken (mostly by the agent), what the owner objected to and how much each objection should weigh, and what to do differently.

This report is deliberately unflattering to its author. The owner asked for the negative feedback specifically, weighted. Read §3 and §4 before touching any code.

---

## 1. Project context

**Prompter** is an iOS teleprompter app. You read a script aloud; on-device speech recognition tracks your position and scrolls the text for you.

| | |
|---|---|
| Bundle | `talk.prompter` |
| Repo | `https://github.com/VRAM-AI/prompter` |
| Working dir | `~/Desktop/prompter` |
| Stack | SwiftUI, Swift 6 strict concurrency, `@Observable`, SwiftData |
| Speech | Apple on-device `SpeechAnalyzer`/`SpeechTranscriber` |
| Only approved 3rd-party dep | RevenueCat (anything else needs written approval) |
| Spec | `docs/BUILD_SPEC.md` — read it directly, it is authoritative |
| Engine notes | `docs/MATCHING_ENGINE.md` — detailed root-cause write-ups |
| Session log | `AGENT_PROGRESS.md` — append a §22 entry per work round |

### Milestones
- **M0–M4** — done, shipped.
- **M5** — "the app stops being a debug menu and becomes Prompter": Home, Editor, Demo, Prompt screens + design system. **Code complete; awaiting the owner's device confirmation.**
- **M6** — RevenueCat + paywall. **Not started.** Blocked (see §6).
- **M7** — polish. Dark/light mode is parked here.

### The matching engine (the heart of the product)
`prompter/Matching/` — pure, synchronous, deterministic, fully replay-testable without a mic:
- `SlidingWindowMatcher` — the state machine. Holds a ring buffer of spoken words, scores it against script positions, moves a `PromptCursor` (`tokenIndex`, `confidence`, `state ∈ {advancing, holding, recovering, frozen}`).
- `ConfidenceModel` — per-token Levenshtein similarity + recency-weighted window scoring.
- `RecoverySearch` — anchor search, plus the eligibility gates.
- `MatcherConfig` — every threshold, in one place.

**M1 quality gate** (`SlidingWindowMatcherTests.fixtureSuiteMeetsM1Gate`): 28 fixtures, mean cursor error ≤ 2.0 tokens and ≤ 1 false jump per 500 words. It writes exact numbers to `/tmp/m1_replay_results.txt` — **use that file, do not claim you cannot get the numbers.**

Current: **mean 0.9074, false-jump rate 0.0** — the best recorded in the project.

---

## 2. Current state

### Verified on the owner's device
- Session starts; cursor advances through normal reading.
- **Cursor no longer freezes on imperfect ASR.** Device log shows `VOLATILE-FED "write" cursor -> token 10 confidence=0.85 advancing` where script token 9 is `written` (similarity 0.71) — this was blocked before the fix.
- **No false jump during ~45 s of continuous off-script speech** — cursor held at token 11 throughout.

### Verified only by tests (owner has not seen it yet)
- Grey/black text rule.
- Scroll behaviour (fixed reading line, one glide per sentence).

### Shipped vs proposed — read this before §5

A reviewer correctly flagged that this report blurred the two. To be unambiguous:

**Already shipped and on `main`.** All three are edits to `Matching/`, and **each was explicitly approved by the owner before it was made** — the "never touch `Matching/` without written approval" rule in §5.6 was honoured, not violated:

| Commit | Change | How it was approved |
|---|---|---|
| `b71de63` | `hasFreshestTokenSupport` — newest word must support the advance | Owner answered "Yes, fix it now" to a direct question |
| `219bc9a` | `extendedStallSeconds` / `extendedStallJumpThreshold` — stricter recovery bar after a long stall | Owner instructed the fix and its direction explicitly |
| `7061636` | `ConfidenceModel.rawSimilarity` + `freshestTokenMinSimilarity` (0.5) | Correction of the agent's own P0 regression from `b71de63` |

So the `rawSimilarity` mechanism described in §7 is **live code, not a recommendation**. The `mean 0.9074 / zero false jumps` figure is the measured result *with* all three in place.

**Proposed only, not built:** everything in §5.7–§5.9 (visual regression harness, log-replay tool, confidence in the debug UI) and dark/light mode.

### Test suite
**30 tests, 0 failures**, re-verified on a `xcodebuild clean` build on **2026-09-02** by reading raw output rather than a summary. M1 gate on the same run, quoted verbatim from `/tmp/m1_replay_results.txt`:

```
TOTAL fixtures=28 checkpoints=1307 spokenWords=6395
TOTAL meanCursorError=0.9074215761285387 tokens (gate: <= 2.0)
TOTAL falseJumps=0 falseJumpRate=0.0 per 500 words (gate: <= 1.0)
```

> **Counting gotcha — you will hit this.** `xcodebuild` writes its own progress lines into the same stream as test results, and will overwrite a result line mid-word. On this run the 30th test appeared as
> `Test case 'RealDeviceReadReplayTests/imper2026-09-02 …IDETestOperationsObserverDebug…` — name truncated, `passed` destroyed. Naively counting `'…' passed` lines yields **29** and looks like a silently skipped test. It was not: running that suite in isolation shows `imperfectAsrOnTheNewestWordStillAdvances() passed`. Trust `** TEST SUCCEEDED **` plus a zero failure count, and isolate the suite if a count looks short. Regression fixtures are all replays of **real device traces**, verbatim including ASR errors:

| Fixture | Guards |
|---|---|
| `DeviceFreezeReplayTests` | the M4 token-155 freeze |
| `MetaCommentaryFalseJumpTests` | 59 → 214 false jump, **plus a control test that disables the gate and asserts the bug returns** |
| `OffScriptCommentaryHoldTests` | 70 s of commentary must not move the cursor |
| `RealDeviceReadReplayTests` | imperfect ASR must still advance; unrelated words must not |
| `ScriptStylingTests` | unspoken text stays black even after a cursor jump |

The **control test** pattern (assert the bug reproduces when the fix is disabled) is the single most valuable convention established here. Keep it. It is the only thing that proves a green test is actually protecting something — and it also detects stale builds structurally (see §4.4).

---

## 3. The criticism ledger, weighted

Weights: **W5 = critical** (broke working functionality, or invalidated the evidence base) · **W4 = high** (made results untrustworthy, or repeated) · **W3 = medium** (rework/churn) · **W2 = low** · **W1 = environment**.

> **Apply this document's own lesson to this document.** Given W4-4 (sloppy verification reporting) and W5-3 (a build system that reported false passes), do not accept the numbers in §2 on this report's authority. Re-run `xcodebuild clean` followed by the suite yourself and read the raw output. The §2 figures were re-verified that way on 2026-08-31; anything you add should be too.

### W5-1 — Shipped a regression that broke a working app
> *"before at least things were working but now its completly broken"*
> *"there is a big white square that covers the text, text is unscrollable manually anymore"*

Manual scrolling was dead because of a literal `.scrollDisabled(true)` the agent had left in place. A hard-coded `0.56 × screen height` text column left ~44 % of the screen as dead `Spacer`. Both were self-inflicted and both shipped.

**Why it matters most:** the owner had a working app and got back a broken one. Everything else in this list is friction; this is loss.

### W5-2 — Froze the cursor with an unvalidated gate
> *"start button doesnet start, and welcome to prompter still clinging at the beggining, nothing start when i talk"*

The agent added a rule requiring the newest spoken word to be a **full** match (≥ 0.8) against the script. Streaming ASR routinely emits the right word imperfectly (`write`/`written` = 0.71, `prompt`/`prompter` = 0.75), so ordinary reading was vetoed and the cursor sat still. The app looked completely dead.

**Root cause:** the gate was validated against fixtures that happened not to contain ASR wobble in the final window position. It was never tested against the failure mode it would obviously cause.

### W4-1 — Design churn: the same feature re-interpreted ~7 times
> *"Locking prompt-screen text design now, final for M5 — stop re-interpreting between rounds"*
> *"i am tired of the text clignotant gris, je veux juste noire"*
> *"This is now genuinely LOCKED — no fourth reconsideration."*
> *"STOP — before implementing the paragraph-scoped version…"*

The read-styling rule was rewritten roughly seven times: sentence highlight → black/grey → dimmed+teal current word → back to black/grey → single travelling grey word → sentence-based grey → paragraph-scoped (aborted mid-build by the owner) → spoken-tokens-only.

Every intermediate version was implemented, tested, committed, and shipped for device review. The owner paid for each one with a manual test cycle.

**Root cause:** the agent kept inferring intent from short messages and building immediately, instead of first establishing the *invariant*. The correct invariant existed the whole time and is one sentence:

> **Grey is proof that the reader pronounced a word. It is never inferred from cursor position.**

Every discarded version violated it. Had that been written down and turned into a test first, five rounds disappear.

### W5-3 — Trusted a build system that silently lied *(originally filed W4; re-weighted — see note)*
Incremental `xcodebuild` runs in this project **execute stale binaries and report PASS**. Three styling tests "failed" against implementation code that was correct on disk *and had verifiably recompiled* (`SwiftCompile … ScriptStyling.swift` appeared twice in the log). A `clean` produced 26/26 with **zero source changes**.

**This is a trust-chain problem, not a process annoyance.** It means any "tests green / numbers byte-identical" claim in `AGENT_PROGRESS.md` made from an incremental run may be unfounded — and most of them were. The first draft of this report weighted it W4; that was too low, and re-weighting it was the single most important correction reviewers made to this document.

**How to treat the historical record:** entries in `AGENT_PROGRESS.md` that assert green suites or unchanged M1 numbers should be read as *claims*, not settled facts, unless the entry explicitly says the run was clean. Only runs from `2026-08-21` onward were reliably clean.

**Rule now:** `touch` is not enough; grepping the log for a recompile is not enough. For any load-bearing verification, run `xcodebuild clean` first, and **paste raw output rather than a summary of it**. Budget ~10 min.

### W4-3 — Explained away the agent's own contradicting metric
Commit `b71de63` moved suite mean error **0.9334 → 1.0872** while driving false jumps to zero. The agent reported this as an acceptable trade. It was in fact the signature of the over-conservative gate that would later freeze the cursor on device (W5-2). The warning was in the agent's own output, and it was rationalised instead of investigated.

**Rule:** a change that improves one metric and degrades another has not made a trade — it has probably broken something. Investigate before shipping.

### W4-4 — Sloppy verification reporting
Claimed "24/24 tests" when the real count was 23. Claimed the M1 numbers "could not be extracted from the `.xcresult`" when the test writes them to `/tmp/m1_replay_results.txt` on every run. Small individually; together they mean the owner could not trust any stated number without re-deriving it.

### W3-1 — Scope drift
> *"Next and ONLY next…"* · *"Don't let it become round nine of the same session."*

The agent began building dark/light mode when the owner's stated priority was the false-jump fix. Caught by the owner, backed out, parked in M7. Cost: a round.

### W3-2 — UI clutter, shipped and then removed
> *"too many button doing the same thing, the miror button is useless"*
> *"the edit button are complicated, the {} brasket is not good, [] lets use this instead"*

Controls were added that duplicated each other, plus a mirror toggle nobody wanted and an SF Symbol that read as `{}` while inserting `[pause]`.

### W3-3 — Scroll: three wrong iterations before the right diagnosis
> *"when i finish a line it scroll slowly up instead of scrolling down so reverse the movement"*
> *"the movement is smooth but pause make it look buggy"*
> *"still huge bug i cant manualy scroll through the text, huge empty white space useless"*

The real causes were only found on the third pass: (a) `scrollTo(id:anchor:)` couples "point in target" and "point in viewport" into **one** `UnitPoint`, so sweeping it with reading progress moves the text *backwards* when the sentence is shorter than the viewport; (b) the scroll re-fired on **every word**, restarting an unsettled spring dozens of times per sentence. The first two attempts guessed at damping and direction without diagnosing either.

### W2-1 — Debug logging was initially too thin to diagnose anything
> *"make sure the test logs contain everything said, and position, decision taken so we can debug this"*

Fixed — `[PromptDebug]` now logs every volatile/final delta, every cursor move with confidence and state, and prints the active thresholds in the `SESSION START` line. **This became the single most valuable diagnostic asset in the project**; nearly every real root cause was found in these logs. Keep it and keep it verbose.

### W1-1 — Disk exhaustion repeatedly blocked builds
The APFS container exposes only ~6 GB free despite a 228 GB volume. Builds died with `No space left on device`. Safe to clear: `DerivedData`, Homebrew/go/TypeScript caches. **Do not delete:** `iOS DeviceSupport` (in use by the owner's device), the iOS 26.5 simulator runtime (~16 GB, needed for tests), or the owner's personal app caches. This will recur.

---

## 4. Root causes (what an incoming agent should actually internalise)

1. **The feedback loop is human and slow.** There is no device automation. Every visual claim costs the owner a manual test cycle. This is the structural amplifier behind every W4-1 complaint: a wrong guess is not cheap here, it is a whole round-trip with a frustrated human in it.
   → **Change fewer things per round. State the invariant first. Get it confirmed before building.**

2. **Fixtures were treated as sufficient proof.** They are necessary, not sufficient. Both W5-level bugs passed the full suite. Real device traces are the ground truth; the suite only encodes what has already gone wrong once.
   → **Before shipping a gate, ask: what normal input does this reject? Then build that fixture.**

3. **The agent optimised for looking verified rather than being verified** — stale builds, mis-stated counts, rationalised metrics. All three are the same failure: reporting a conclusion the evidence did not support.

4. **Ambiguous natural-language design feedback was resolved by guessing instead of asking.** The owner writes short, mixed French/English, sometimes with typos, sometimes mid-test and frustrated. Guessing wrong is expensive (see 1). One clarifying question is cheaper than one wrong build.

---

## 5. What to do — concrete

### Process
1. **Invariant first.** For any behaviour change, write the one-sentence rule and, where possible, a failing test that encodes it, *before* implementing. Get the sentence confirmed if it came from ambiguous feedback.
2. **Clean build for anything load-bearing.** `xcodebuild clean` then test. Never trust an incremental green.
3. **Control tests.** Every fix that adds a gate gets a paired test asserting the bug returns when the gate is disabled.
4. **Metrics are blockers, not trades.** If mean error worsens, stop and find out why.
5. **One behavioural change per device-review round**, so a report maps to a single cause.
6. **Never touch `Matching/` or `Speech/` without explicit written approval.** This was a standing rule all session and it is a good one — the M1 gate is the product's quality floor.

### Engineering
7. **Build a visual regression harness.** The single highest-leverage investment available. Snapshot tests (or an XCUITest screenshot run) over the prompt screen for: nothing-spoken, mid-sentence, post-jump, end-of-script — in both palettes. This converts the ~7-round colour churn into a same-minute check and removes the human from the loop for visual states.
8. **Add a replay-from-log tool.** A debug entry that ingests a pasted `[PromptDebug]` log and replays it through the matcher. Every device report becomes a fixture in minutes rather than by hand-transcribing timestamps.
9. **Consider surfacing cursor confidence in the debug UI** so off-script drift is visible while testing rather than only in the log afterwards.

### Product decisions still owed by the owner
10. Whether grey should exist at all. Currently: grey = spoken, black = everything else. The owner confirmed this ("keep it as implemented"), but it was reversed several times, so treat any new colour instruction as a **spec change requiring an explicit invariant**, not a tweak.

---

## 6. Open items

| Item | State | Blocking |
|---|---|---|
| **White square covering text** | **Unresolved — do not read the absence of reports as a fix.** Requested 6×; no screenshot ever showed it, and it was never definitively confirmed *or* denied. There is a plausible benign explanation (it may have been the same fixed-height-column bug that also produced the "huge empty white space", fixed in `dbde15d`) but **that is a hypothesis, not a diagnosis.** It equally may just not have recurred by luck. Needs one explicit device screenshot — confirming or denying — before anyone writes it off. Note it was reported *on device*; a simulator screenshot would not settle it. | M5 sign-off |
| **RevenueCat / App Store Connect status** | Unclarified. Asked repeatedly; last answer contained an unfilled template placeholder. | **M6 entirely** |
| Device confirmation of grey + scroll | Pending owner's next read | M5 close |
| Dark/light mode | Parked, M7. Owner chose "button on the prompt screen bottom bar" if built. Note: §13 of the spec says light is the only normal mode — this is a spec deviation to log. | — |
| Off-script cursor drift | Mitigated, not eliminated. The stall-duration gate only engages after 8 s; shorter stalls can still admit a recovery jump at ≥ 0.80. No reproduction in recent traces. | — |

**M5 closes** when the owner does one clean device read confirming the text colour and scroll. Everything else in M5 is already device-confirmed.

---

## 7. Key files

```
prompter/
  Matching/          ← DO NOT EDIT without written approval
    SlidingWindowMatcher.swift    state machine, advance/hold/recover/freeze
    ConfidenceModel.swift         rawSimilarity (unthresholded) + tokenSimilarity (0.8 floor)
    RecoverySearch.swift          hasDistinctiveSupport, hasFreshestTokenSupport
    MatcherConfig.swift           every threshold
  Speech/            ← DO NOT EDIT without written approval
  Prompt/
    PromptScreen.swift            reading UI, scroll, bottom bar
    PromptViewModel.swift         feeds ASR → matcher; owns spokenTokenIndices
    ScriptStyling.swift           THE ONLY place text colour is assigned
    ScrollAnimator.swift          spring presets
  Accessibility/OutdoorMode.swift palettes (normal / outdoor)
docs/
  BUILD_SPEC.md                   authoritative spec
  MATCHING_ENGINE.md              root-cause write-ups, read before engine work
  DECISIONS.md                    spec deviations
AGENT_PROGRESS.md                 §22 log, newest at bottom
```

### Two engine subtleties worth knowing before you touch anything

**`hasDistinctiveSupport` cannot catch commentary that quotes the script.** The demo script's paragraph 4 *describes the app's own behaviour*, so when the owner narrated feedback about the app, their words collided near-verbatim with real script content and passed that gate with **seven** distinctive matches. No content-based check can separate "reading the script" from "saying the same words as the script" — they are textually identical. The fix had to be contextual (stall duration), not lexical.

**`tokenSimilarity` hard-zeroes anything below 0.8.** That makes ASR wobble and unrelated speech indistinguishable — both are exactly `0`. Use `ConfidenceModel.rawSimilarity` when you need to tell them apart. Forgetting this is precisely what caused W5-2.

---

## 8. One-paragraph summary

M5 is functionally complete and the matching engine is in its best measured state (mean error 0.9074, zero false jumps, 30 green tests, all fixtures drawn from real device traces). Getting here cost far more rounds than it should have: the agent shipped two regressions that broke a working app, rewrote the same text-colour rule about seven times by guessing at intent instead of fixing the invariant, and reported verification it had not actually earned — including trusting a build system that silently ran stale code. The engineering is now sound and well-documented; the process is what needs fixing. The highest-leverage next move is not a feature — it is a visual regression harness and a log-replay tool, because the binding constraint on this project is that a human must currently look at a phone to validate anything.
