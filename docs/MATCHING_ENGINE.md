# Matching Engine

> **INHERITED FROM PROMPTER — historical reference only.** This describes *Prompter*, a separate
> paused project. It is **not** a Co-Interview specification and its roadmap, milestones and release
> criteria do not apply here. Start at [`CO_INTERVIEW_START_HERE.md`](CO_INTERVIEW_START_HERE.md).


> **Status notice.** This remains the authoritative reference for the matching engine, its
> thresholds, tokenization and scroll ownership, and still governs that area. For *current* project
> status see [`PROMPTER_CURRENT_STATE.md`](PROMPTER_CURRENT_STATE.md).


Algorithm reference and tuning record for `prompter/Matching/` (§10 of the build spec).
All numbers below come from `SlidingWindowMatcherTests.fixtureSuiteMeetsM1Gate()`
(prompterTests target), run on 2026-08-09 against the fixture suite in
`prompterTests/Matching/Fixtures/`. Re-run it yourself:

```
xcodebuild test -project prompter.xcodeproj -scheme prompter \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:prompterTests
```

## Architecture

`Matching/` imports Foundation only (no SwiftUI, no Speech, no NaturalLanguage) so the
whole engine is pure, synchronous, and deterministic — provable on fixtures before any
speech code exists (§24.4).

| File | Responsibility |
|---|---|
| `Tokenizer.swift` | `Token` (normalized word + audio-time timestamp) and text normalization: lowercase → NFKD diacritic fold (`String.folding(.diacriticInsensitive)`) → strip non-alphanumerics. |
| `ScriptIndex.swift` | Script preprocessing (§10.1): paragraph/sentence/word segmentation via `String.enumerateSubstrings(in:options:)` with `.byParagraphs` / `.bySentences` / `.byWords` (ICU-backed, ships in Foundation — no NaturalLanguage import needed), token→UTF-16-offset map, `Codable` for `Script.tokenCacheData`. |
| `ConfidenceModel.swift` | Levenshtein distance, per-token similarity, and the recency-weighted windowed alignment score (§10.3). |
| `RecoverySearch.swift` | Anchor scanning over a token range — shared by the normal local search and the widened recovery search (§10.2). |
| `PromptCursor.swift` | The emitted `(tokenIndex, confidence, state)` value. `state` is `.advancing` / `.holding` / `.recovering` / `.frozen`. |
| `MatcherConfig.swift` | Every tunable threshold, in one place. |
| `SlidingWindowMatcher.swift` | The stateful orchestrator: ring buffer, local search, hysteresis, recovery trigger (§10.2, §10.4). |

## Live loop (§10.2)

```
advance(spoken: [Token], now: TimeInterval) -> PromptCursor
```

1. Empty `spoken` = a time tick with no new speech. If the gap since the last spoken
   token exceeds `silenceFreezeSeconds`, the cursor freezes (`.frozen`) and nothing
   else runs — no drift while the speaker pauses or holds eye contact.
2. New tokens are filler-filtered (standalone interjections and the `"you know"`
   bigram) and appended to a capped ring buffer (`ringBufferSize`).
3. The last `alignmentWindow` (K) buffered tokens are aligned positionally against
   every candidate anchor in `[cursor - localSearchBackward, cursor +
   localSearchForward)`; the anchor with the best `ConfidenceModel.score` wins.
4. `score >= advanceThreshold` → cursor advances to `anchor + K`, clamped by the
   hysteresis caps below.
5. `score < recoveryTriggerThreshold`, sustained for `recoverySustainedSeconds` of
   continued low-confidence speech → `RecoverySearch.recoverySearch` widens to
   `[cursor, cursor + recoveryWindowForward]`, then the whole script; a candidate
   only counts if it clears `recoveryJumpThreshold`.
6. Anything else (the ambiguous band between the two thresholds, or recovery that
   found nothing) → `.holding`, cursor unchanged.

## Scoring (§10.3)

Per-token similarity is 1.0 for an exact match; otherwise normalized Levenshtein
similarity (`1 - distance / max(len1, len2)`) if it clears `perTokenMatchThreshold`
(0.8), else **0** — a token that isn't at least a fuzzy match contributes no partial
credit, so noise can't quietly inflate a bad anchor's score.

The windowed score is a weighted average of per-token similarities with a **linear
recency ramp**: for a window of `n` tokens (oldest → newest), token `i` gets weight
`1.0 + (i / (n-1)) * (recencyWeightMultiplier - 1.0)`, so the newest token in the
window weighs `recencyWeightMultiplier`x the oldest one ("the speaker's mouth is at
the end of the buffer" — §10.3).

Anchors are scored by direct positional pairing (`spoken[i]` vs `script[anchor+i]`),
not full sequence alignment (no DP/edit-path across insertions). Trying different
`anchor` values *is* how different offsets get evaluated, which is what §10.2's
"candidate anchors" search already does — a full Needleman-Wunsch-style alignment
per anchor would add real complexity for no gain the fixture suite could detect.

## Hysteresis rules (§10.4) and their dedicated tests

All four rules have a hand-crafted test in `ConfidenceHysteresisTests.swift` with a
by-hand-computed expected outcome (not just "did the suite average pass"):

| Rule | Test | Mechanism |
|---|---|---|
| Backward cap | `backwardCapLimitsRegressionOnARepeatedPhrase` | A repeated earlier phrase's true anchor would move the cursor back 4 tokens; `applyAdvance` clamps to `cursor - backwardCap` (3). |
| Forward cap without recovery-grade confidence | `forwardCapLimitsBigJumpsWithoutRecoveryGradeConfidence` | A blended 0.778-confidence match (below `recoveryJumpThreshold`, above `advanceThreshold`) targeting anchor+13 gets clamped to `cursor + forwardCapWithoutRecovery` (6). |
| Silence freeze | `silenceFreezesTheCursorAfterThreshold` | A 2.0s gap since the last token (> 1.5s `silenceFreezeSeconds`) reports `.frozen` with the cursor unchanged; a 1.0s gap does not freeze. |
| Recovery threshold (sustained low confidence) | `recoveryOnlyTriggersAfterSustainedLowConfidence` | Two low-confidence ticks 1s apart hold; a third at +3.0s (≥ `recoverySustainedSeconds`) triggers the widened search and jumps. |

## Config defaults (`MatcherConfig.default`)

These are the spec's §10.2/§10.3 values used as-is; the fixture suite passed the gate
on the first tuning pass, so none were adjusted away from the spec's stated numbers.

| Setting | Value |
|---|---|
| `ringBufferSize` | 20 |
| `localSearchBackward` / `localSearchForward` | 10 / 40 |
| `alignmentWindow` (K) | 9 |
| `perTokenMatchThreshold` | 0.8 |
| `recencyWeightMultiplier` | 2.0 |
| `advanceThreshold` | 0.72 |
| `recoveryTriggerThreshold` | 0.45 |
| `recoverySustainedSeconds` | 2.5 |
| `recoveryWindowForward` | 400 |
| `recoveryJumpThreshold` | 0.80 |
| `backwardCap` | 3 |
| `forwardCapWithoutRecovery` | 6 |
| `silenceFreezeSeconds` | 1.5 |
| `fillerStoplist` | um, uh, erm, hmm, like |
| `fillerBigrams` | ["you", "know"] |

## Fixture suite results (2026-08-09)

4 scripts (175–290 words each: productLaunch, cookingIntro, personalEssay,
techExplainer) × 6 scenarios (clean read, ~10% ASR misrecognition, paragraph skip,
20+ word ad-lib insertion, repeated sentence, long silence) = 24 fixtures, 1,122
checkpoints, 5,474 total simulated spoken words.

| Scenario (mean across 4 scripts) | Mean cursor error (tokens) | False jumps |
|---|---|---|
| Clean read | 0.084 | 0 |
| Misrecognition (~10% corruption) | 0.870 | 0 |
| Paragraph skip | 4.543 | 0 |
| Ad-lib insertion (20+ words) | 5.602 | 6 (all from one fixture — see below) |
| Repeated sentence | 0.194 | 0 |
| Long silence | 0.099 | 0 |

**Suite-wide gate (§10.5): mean cursor error ≤ 2 tokens AND ≤ 1 false jump per 500
spoken words.**

- **Mean cursor error: 1.577 tokens** (gate: ≤ 2.0) — PASS
- **False-jump rate: 0.548 per 500 words** (6 false jumps / 5,474 words × 500) (gate: ≤ 1.0) — PASS

Full per-fixture breakdown is printed by the test (also written to
`/tmp/m1_replay_results.txt` when run locally).

### What broke: `cookingIntro/adLibInsertion`

One fixture is a clear outlier: `cookingIntro/adLibInsertion` alone accounts for all 6
false jumps in the suite (mean error 21.9 tokens on that fixture vs. 0.1–0.2 on every
other ad-lib fixture). Root cause, confirmed by directly diffing the two token sets
rather than guessed: the synthetic ad-lib phrase ("so yeah i think what i really want
to say here is that this whole thing about the weather today has been absolutely wild
if you ask me honestly") shares 7 common function words — *about, is, that, the, to,
today, you* — with `cookingIntro`, which at 175 words is the shortest of the four
scripts. On a short script, a handful of common-word coincidences are enough for the
recency-weighted local search to occasionally clear `advanceThreshold` on pure noise,
producing a spurious local advance before the ad-lib content moves on.

This did **not** fail the M1 gate (the suite-wide averages have comfortable margin:
1.577 vs. 2.0, 0.548 vs. 1.0), so no threshold was retuned to specifically suppress
it — doing that against a single synthetic fixture would risk overfitting the matcher
to this one ad-lib phrase rather than improving real robustness. It's recorded here
as a known limitation to watch for in M4's live-device ad-lib testing: short scripts
with ordinary conversational filler are the most exposed case, and if real device
testing reproduces it, the fix is more likely in scoring (e.g. discounting very
common short tokens, or requiring a minimum absolute score contribution from
distinctive words) than in the thresholds.

**Update, M4 (2026-08-14):** on-device testing with owner-authored freeform text (proper
nouns, unusual vocabulary the ASR mangles heavily) surfaced a different, real bug: the cursor
could sit stuck for a long time — "sometimes it doesn't change paragraph and just stays where
it is," and "very slow to transition." Root cause, found by reading `SlidingWindowMatcher
.advance()` directly: a local-search score landing in the "ambiguous middle zone" (between
`recoveryTriggerThreshold` 0.45 and `advanceThreshold` 0.72 — not confident enough to advance,
not low enough to count as the sustained-low-confidence recovery trigger) explicitly resets
`lowConfidenceSince = nil` every single time it's hit. A score that hovers in that band for many
consecutive checkpoints — exactly what happens when ~30-40% of words are misrecognized, common
with unfamiliar proper nouns and no `contextualStrings` biasing yet (§11.7, M4 item 3) — never
accumulates toward recovery at all, because the timer keeps getting wiped. The cursor can stall
indefinitely as long as confidence never clearly drops below 0.45, which is a very plausible
zone for ordinary ASR noise to sit in for a while.

**Design (before any code change, per the owner's explicit process requirement):** the
ambiguous middle zone needs its own, *longer* sustained-stall timer that arms recovery search
the same way sustained low confidence already does — a "mediocre" stall (say ~4s, longer than
low-confidence's 2.5s, since a mid-band score is closer to correct and shouldn't trip recovery
as eagerly as a clearly-wrong one) should get the same chance to escape via
`RecoverySearch.recoverySearch`. Critically, this only changes *when recovery search gets a
chance to run* — it does not touch `recoveryJumpThreshold` (0.80), so a stall still only
resolves into an actual jump if a genuinely strong match is found; escaping a stall doesn't
mean escaping into a wrong place. The timer is shared across the low and mediocre branches
(renamed conceptually to "stalled since," not "low-confidence since") rather than reset when
the score crosses between the two bands mid-stall, so a checkpoint sequence bouncing between
0.40 and 0.50 accumulates toward whichever threshold applies to its current band instead of
resetting on every crossing. New tunable: `MatcherConfig.mediocreConfidenceSustainedSeconds`
(default 4.0s).

Checked whether this same mechanism explains the `cookingIntro/adLibInsertion` false jumps
above, per the owner's instruction to verify with the real trace before assuming: **it does
not**. A temporary trace (`SlidingWindowMatcherTests.debugCookingIntroAdLibConfidenceTrace`,
removed once this was answered) printed confidence/state at every checkpoint. The false jumps
are driven by the *existing* sustained-low-confidence path, not the ambiguous middle zone:

```
[18] spoken="so yeah i think what"          confidence=0.35 state=holding
[19] spoken="i really want to say"          confidence=0.14 state=holding
[20] spoken="here is that this whole"       confidence=0.13 state=holding
[21] spoken="thing about the weather today" confidence=1.00 state=recovering  <<< FALSE JUMP
```

Three consecutive checkpoints (~6s at the fixture's 2s-per-checkpoint cadence, comfortably past
`recoverySustainedSeconds` 2.5s) score *below* 0.45 — genuinely low, not mid-band — correctly
arming the existing recovery search exactly as designed. The bug isn't that recovery fires; it's
that `RecoverySearch.recoverySearch`'s whole-script fallback then finds a coincidentally
high-scoring (1.00) wrong anchor, because the ad-lib phrase's common words happen to cluster
against unrelated content elsewhere in this particular (short) script. This refines the original
Session 1 diagnosis: it isn't the *local* search clearing `advanceThreshold` directly, as first
described above — it's the *recovery* search's candidate-selection being fooled by coincidental
common-word overlap once it's (correctly) triggered. Since every score in this sequence is
already in the low band, the new shared `stalledSince` timer (vs. the old separate
`lowConfidenceSince`) doesn't change this case's behavior at all — no band-crossing happens
here for the shared-timer change to affect.

**Conclusion: the two bugs are unrelated and are fixed independently.** This stall fix doesn't
touch `RecoverySearch`'s candidate scoring, so it has no bearing on the ad-lib false jumps
either way. The earlier common-word-discount hypothesis for the ad-lib false jumps remains
falsified (it was found to perturb other fixtures while leaving this one's numbers
byte-identical) and was not revisited — a real fix for it would need to address
`RecoverySearch`'s whole-script fallback scoring specifically, which stays open for Step 2.

### Step 2 fix: recovery candidate eligibility, not scoring (M4, 2026-08-15)

The trace above already narrows this precisely: **recovery firing is correct** — three
genuinely-low-confidence checkpoints legitimately arm it — **candidate selection is the bug.**
`RecoverySearch.recoverySearch` finds the single best-scoring anchor across a wide range and
accepts it once it clears `recoveryJumpThreshold` (0.80), with no check on *what kind* of
overlap produced that score. The ad-lib phrase's coincidental common-word cluster (*about, is,
that, the, to, you*) was enough on its own, on `cookingIntro`'s short script, to outscore the
actual correct continuation.

This rules out both directions already tried or considered: **not local scoring** — the earlier
common-word weight-discount touched `ConfidenceModel.score`, which both searches share, and was
falsified: discounting a matching position's *weight* doesn't move a weighted average when every
position in the window is a match (common or not) — the ad-lib window here really is close to an
all-match window against the wrong anchor, so a weight change alone can't separate it from a
real match. **Not thresholds** — `recoveryJumpThreshold` already worked as designed (0.80 is a
real, high bar); the false anchor simply cleared it honestly. The fix has to be a different kind
of check: an anchor's *score* isn't sufficient evidence by itself; it also needs *support from
distinctive content*, not just common words.

**Design:** add an eligibility gate, checked only inside `RecoverySearch`'s own candidate
selection (a new `requireDistinctiveSupport` parameter on `bestAnchor`, defaulted `false` so the
*local* search inside `SlidingWindowMatcher.advance()` — which never opts in — is provably
unaffected): a candidate anchor is only considered if **at least one** of its matched positions
(similarity ≥ `perTokenMatchThreshold`, i.e. an actual match per §10.3) is a **non-common**
word. An anchor whose entire matching window is built from common words is skipped outright,
regardless of its raw score — this is a binary eligibility check, not a score adjustment, which
is exactly what the falsified discount approach couldn't do. `MatcherConfig.commonWords`
(the same list from the falsified attempt — the list itself was never the wrong part, applying
it as a *weight* was) is reused here as an eligibility filter, applied identically to both the
near-range and whole-script fallback searches inside `recoverySearch` (for a script as short as
`cookingIntro`, `recoveryWindowForward` (400) already covers nearly the whole thing, so treating
the two searches differently wouldn't meaningfully separate this case anyway).

**The known risk, stated up front:** `RecoverySearch` is also what lets `paragraphSkip` recover
after a real skip. If the correct post-skip continuation's alignment window happens to lean on
common words too (plausible if a paragraph opens with ordinary transition words), this same gate
could block a *legitimate* recovery, trading the ad-lib false-jump fix for a paragraph-skip
regression. This is checked explicitly below, not assumed away.

**Validation (full 28-fixture suite, `SlidingWindowMatcherTests.fixtureSuiteMeetsM1Gate`):**

| Scenario | Before Step 2 | After Step 2 |
|---|---|---|
| `cookingIntro/adLibInsertion` | 21.905 mean error, **6** false jumps | **0.238** mean error, **0** false jumps |
| `productLaunch/paragraphSkip` | 3.629 | 3.629 (unchanged) |
| `cookingIntro/paragraphSkip` | 3.348 | 3.348 (unchanged) |
| `personalEssay/paragraphSkip` | 3.846 | 3.846 (unchanged) |
| `techExplainer/paragraphSkip` | 4.000 | 4.000 (unchanged) |
| `productLaunch/mediocreStall` | 3.804 mean error, 1 false jump | **unchanged** — this fix does not cure it |
| **Suite-wide** | mean 1.630, false-jump rate 0.547 | **mean 0.933, false-jump rate 0.078** |

The ad-lib false jumps are fully resolved, not just brought under the ≤1 gate. All four
`paragraphSkip` scenarios are byte-identical to their pre-fix values — the stated risk
(blocking a legitimate skip-recovery) did not materialize in this fixture suite. The
`productLaunch/mediocreStall` false jump is a separate, still-open issue — per instruction, not
chased further as part of this fix; a different `RecoverySearch` candidate (still common-word-
free by this gate's own logic) is apparently winning there, which would need its own trace to
diagnose. All 13/13 tests green, including all four hysteresis tests and both new ones.

## M4 device gate: build 56ba154 — FAIL

Handheld run on record as **FAIL** against §16's gate ("tracks end-to-end incl. one paragraph
skip + one ad-lib, no manual intervention") until a retest passes. Real device log, cursor stuck
at token 155 in `PromptDemoFixture.defaultScriptText` for the entire remainder of the session —
four more spoken sentences (~90 of 245 tokens) after the freeze, none of them recovered.

### Root cause: two independent bugs, both required to reproduce

`DeviceFreezeReplayTests.recoversFromTheRealBuild56ba154Freeze` replays this byte-accurately: the
real script tokenized via `ScriptIndex.build` (ICU `.byWords` segmentation — **not**
`Tokenizer.normalize`'s whitespace split; ICU splits hyphenated compounds like `off-script` and
`mid-sentence` into separate tokens, which the initial by-hand trace analysis got wrong before
this replay caught it) and the verbatim `[PromptDebug] FINAL` lines from the device session.

**Bug 1 — recovery's scoring window couldn't tolerate an ordinary near-miss in its
recency-weighted tail.** The user skipped ~45 tokens ahead (155 → 200, a legitimate skip, same
kind as the earlier one that recovered fine). The resumed speech was transcribed almost
perfectly, but two ordinary ASR near-misses ("ups" for "up", "mostly" for "smoothly") landed in
the *last two* positions of the old 9-token, 2×-recency-weighted recovery window. Per-token
similarity below `perTokenMatchThreshold` contributes exactly 0, not partial credit, and those
two positions were the most heavily weighted in the window — enough to hold an otherwise
strongly-matching real candidate under `recoveryJumpThreshold` (0.80).

**Bug 2 — the sustain timer creates a race between evidence and permission.** Recovery only
evaluates the *current* ring-buffer tail on the tick where `stalledSince` has aged past
`recoverySustainedSeconds`/`mediocreConfidenceSustainedSeconds` — never on the tick the stall
began (elapsed is 0 by definition), because that's the tick that sets `stalledSince`. In this
trace, the single best opportunity existed only on that first tick; by the time the timer armed
on the *next* final result, that utterance's own words had already pushed the good window out of
the ring buffer, replaced by newer speech carrying its own, unrelated divergences. Every
subsequent tick's candidate score was strictly worse than the last — confirmed across a sweep of
recovery window sizes (12/15/18/20), where the pattern held at every size: only the very first
stalled tick ever came close to the threshold; none of the later ticks did, regardless of window
width. Bug 1 alone (fixed) is necessary but not sufficient — without fixing Bug 2, the one tick
where the fix would have mattered is never the tick recovery is permitted to act on.

### Fix 1: `recoveryAlignmentWindow` + `recoveryRecencyMultiplier` (RecoverySearch-only)

`RecoverySearch` now scores against a wider, flatly-weighted window than local per-tick
tracking — `MatcherConfig.recoveryAlignmentWindow` (independent of `alignmentWindow`) and
`MatcherConfig.recoveryRecencyMultiplier` (independent of `recencyWeightMultiplier`, default
`1.0` — recovery asks "does this window align here at all", not "where is the mouth right now",
so recency bias doesn't apply). Local per-tick scoring, the binary 0.8 per-token cutoff, and
`recoveryJumpThreshold` itself are all untouched — this only changes what recovery-candidate
scoring sees, never what counts as a match or how good a match has to be.

**Window size was swept, not guessed** (`recoveryAlignmentWindow` at 12/15/18/20, real numbers
via `DeviceFreezeReplayTests`, first-stalled-tick candidate score against `recoveryJumpThreshold`
0.80):

| Window | Call 1 (freeze tick) | Call 2 | Call 3 | Call 4 |
|---|---|---|---|---|
| 12 | **0.833** (clears) | 0.583 | 0.417 | 0.403 |
| 15 | 0.733 (fails) | 0.667 | 0.467 | 0.322 |
| 18 | 0.778 (fails) | 0.722 | 0.500 | 0.389 |
| 20 | 0.800 (exactly at gate) | 0.750 | 0.550 | 0.350 |

Non-monotonic: widening the window doesn't uniformly help, because the exact position of the
ASR word-count mismatch ("of script" ASR-inserted where the script has one token, "off"/"script"
via ICU segmentation — see above) relative to the window boundary matters more than raw width.
`12` is the empirically-best of the four — it's the narrowest window that still excludes the
insertion artifact while capturing the full clean tail. Shipped as the default.

### Fix 2: stall-candidate snapshot (decouples evidence from permission)

Per instruction, this does **not** shorten either sustain timer — that reopens the false-jump
front door Step 2 just closed. Instead: on every tick where the matcher is in a stall (either
band, `stalledSince != nil`), it now scores a recovery candidate against *that tick's* ring
buffer regardless of whether the timer has armed yet, and retains the best-scoring one seen since
the stall began (`SlidingWindowMatcher.bestStallCandidate`, reset whenever `stalledSince` resets).
When the timer finally arms, it acts on the retained best candidate, not a fresh search against
whatever the ring buffer happens to hold on that specific tick. This directly targets Bug 2: the
good candidate from the freeze tick is now still available by the time recovery is *permitted* to
use it, even though several ticks and several sentences have passed in between.

`RecoverySearch.bestStallCandidate` computes the best of near-range and whole-script search
*without* the `recoveryJumpThreshold` gate (evidence gathering only); the threshold is still
applied once, at the moment the matcher actually acts on the retained snapshot.

### Validation

`DeviceFreezeReplayTests` is a permanent regression test: starting from token 155 with the
verbatim real `FINAL` lines from build 56ba154, the gate is that the cursor reaches the
token-200 region and does not re-freeze. Confirmed failing before both fixes (cursor stuck at
155 throughout) and passing after.

## M5.1 (2026-08-20): the meta-commentary false jump

### Symptom

Real device trace. Cursor sitting correctly at token 59. The speaker stopped reading and began
narrating live feedback *about the app's matching behavior* into the same microphone. At
timestamp 99.660s the cursor jumped **59 → 214** (155 tokens) with `confidence=0.83
state=recovering`, drifted 214 → 216 → 221 → 222, and froze there for 40+ seconds while the
speaker kept talking — nowhere near any real reading position.

### Why this is the hardest false-jump case so far

The spoken phrase was:

```
narrated: "the qaw    should hold its position rather than chasing you  off script"
script  : "the cursor should hold its position rather than chasing your off script"   (tokens 202-213)
```

The script's paragraph 4 *describes exactly the behavior the speaker was describing*, so the
meta-commentary collided almost word-for-word with real script content. Only two positions
missed, both ordinary ASR/inflection noise: `cursor → qaw`, and `your → you` (normalized
Levenshtein 0.75, just under `perTokenMatchThreshold` 0.8).

**Checked before fixing, not assumed** (throwaway diagnostic against the real script tokens):

| Anchor | Score | `requireDistinctiveSupport` | Distinctive matches |
|---|---|---|---|
| 202 | **0.8333** | **true** | should, hold, position, rather, chasing, off, script (7) |

`anchor 202 + recoveryAlignmentWindow 12 = 214` — reproducing the logged jump exactly, and
`0.8333` rounds to the logged `0.83`.

This is qualitatively different from M4's `cookingIntro/adLibInsertion`, where the false anchor
was built from *common-word coincidence alone* and the `requireDistinctiveSupport` eligibility
gate kills it. Here the gate passes **overwhelmingly** — seven genuinely distinctive words —
because the overlap is *real content*. The speaker actually said the script's words.

**Therefore no content-based check can fix this.** "Reading the script" and "saying the same
words as the script" are textually identical; nothing in the spoken window distinguishes them.
Tightening `requireDistinctiveSupport`, adding phrase-level checks, or reweighting common words
would all pass this phrase just as readily, while risking the legitimate `paragraphSkip`
recoveries the same code path exists to serve.

### Fix: the bar depends on how long the stall has run

The one signal that *does* separate the two cases is **context, not content**. Before the jump,
the matcher had been stalled for ~27s with sustained very low confidence (0.07–0.41 across the
preceding ~15 words). A short stall is most likely misrecognized *on-script* speech — an ASR
stumble, a skipped line — and recovery should stay eager. A stall that long is far more likely
to be genuine *off-script* speech, where any high-scoring candidate is more plausibly a
coincidence than a real position.

Two config-tunable knobs (`MatcherConfig`):

- `extendedStallSeconds = 8.0` — how long a stall must run before the stricter bar applies.
- `extendedStallJumpThreshold = 0.88` — the bar applied after that.

`0.88` is not arbitrary. With `recoveryAlignmentWindow = 12` and flat recovery recency, the
achievable scores either side of the failure are **10-of-12 = 0.8333** (this false jump) and
**11-of-12 = 0.9167**. `0.88` sits in that gap: after a long off-script stretch the cursor moves
only on *near-perfect* alignment (11+ of 12), while a genuine return to the script carrying one
ordinary ASR error still recovers. Applied only in
`SlidingWindowMatcher.applyBestStallCandidateIfAboveThreshold`; `requireDistinctiveSupport` and
every M4 code path are untouched.

### Validation (full 28-fixture suite + targeted regression tests)

`MetaCommentaryFalseJumpTests` replays the device trace word-by-word at real audio timestamps,
and ships with a **control test** that disables the gate and asserts the original 214+ jump
still reproduces — so the gate is provably load-bearing rather than incidentally passing.

| | Result |
|---|---|
| `offScriptMetaCommentaryDoesNotTriggerAFalseRecoveryJump` | cursor holds ≤ 100 ✅ |
| `theSameTraceStillFalseJumpsWhenTheExtendedStallGateIsDisabled` (control) | reproduces 214+ ✅ |
| All 28 M1 fixtures | **byte-identical** to pre-fix baseline |
| `paragraphSkip` × 4 | 3.629 / 3.348 / 3.846 / 4.000 — unchanged |
| Suite-wide | meanCursorError `1.0872226472838562`, falseJumpRate `0.0` — unchanged |
| Tests | 25/25 passing (23 pre-existing + 2 new), 0 failures |

The stated risk — that a duration-based gate could block a *legitimate* long-stall recovery —
did not materialize in this fixture suite: every `paragraphSkip` scenario is byte-identical,
and both existing hysteresis recovery tests (`recoveryOnlyTriggersAfterSustainedLowConfidence`,
`sustainedMediocreConfidenceArmsRecoveryEvenWithoutEverGoingFullyLow`) stall for 3.0s and 4.5s
respectively — under the 8.0s bar — and recover on exact-match candidates scoring 1.0 regardless.

### M5.1 correction (2026-08-22): the freshest-token gate was too strict

The gate added alongside the meta-commentary fix — "the newest spoken word must support the
advance, not just the window average" — was **calibrated wrong on first attempt** and froze the
cursor on real device reads. Owner report: cursor stuck at the start of the script, nothing
advancing while speaking.

The gate demanded a full `perTokenMatchThreshold` (0.8) match on the newest word. Streaming ASR
does not deliver that. From the owner's own earlier *working* trace:

```
VOLATILE-FED 1 word(s) "write"  cursor -> token 10  confidence=0.85  state=advancing
```

Script token 9 is `written`; `write` vs `written` is **0.71** raw similarity — under 0.8, so the
gate would have vetoed an advance that genuinely happened on a healthy read. Truncations behave
the same way (`prompt` vs `prompter` = 0.75). The gate was rejecting *imperfect* words when its
only job was to reject *unrelated* ones.

**The warning sign was already in the data and was under-reported at the time:** that commit moved
suite mean error 0.9334 → 1.0872. A fix that eliminates false jumps *and* makes mean tracking
worse is a fix that has become too conservative; that should have been investigated then.

**Correction:** the gate now measures **raw** similarity against a separate, much looser
`freshestTokenMinSimilarity` (0.5). `ConfidenceModel.rawSimilarity` was added because
`tokenSimilarity` hard-zeroes anything below 0.8 — which made ASR wobble and unrelated speech
indistinguishable (both exactly 0), the very distinction this gate needs. 0.5 separates the two
populations cleanly:

| Newest word vs script token | Raw similarity | Verdict |
|---|---|---|
| `write` vs `written` (ASR wobble) | 0.71 | advance ✅ |
| `prompt` vs `prompter` (truncation) | 0.75 | advance ✅ |
| `can` vs `page` (off-script) | 0.25 | blocked ✅ |

**Validation (clean build, 28/28 tests, 0 failures):**

| | mean cursor error | false-jump rate |
|---|---|---|
| Before any gate | 0.9334 | 0.0782 |
| Over-strict gate (the regression) | 1.0872 | 0.0 |
| **After correction** | **0.9074** | **0.0** |

Better than *any* previous state on both metrics simultaneously. Every `misrecognition` fixture
improved sharply (2.761→2.326, 1.143→0.857, 0.882→0.686, 0.755→0.566) — those are exactly the
ASR-error scenarios, independent corroboration of the diagnosis. All four `paragraphSkip`
scenarios unchanged (3.629 / 3.348 / 3.846 / 4.000), and both `MetaCommentaryFalseJumpTests`
still pass including the gate-disabled control, so the loosening did not reopen the false jump.

`RealDeviceReadReplayTests` is the permanent guard: it replays the verbatim fed-word sequence
from the working device trace (ASR errors included) and asserts the cursor keeps advancing, with
a companion test asserting an unrelated newest word still does not.

---

## M5.2 (2026-09-09/10): the cursor-lost P0 — input contract, timing fidelity, suffix re-acquisition

### 1. The replay input contract, traced through production

Established by reading `Speech/TranscriptionService.swift`, `Speech/TranscriptStream.swift` and
`Prompt/PromptViewModel.swift`, not from memory:

| Question | Answer | Source |
|---|---|---|
| What is `delta.timestamp`? | `Date().timeIntervalSince(startTime)` — **wall-clock elapsed since the transcriber started**, captured when the app *observes* the result | `TranscriptionService.swift:101,112,114` |
| Its clock origin | the `start(locale:contextualStrings:)` call, not the audio buffer | same |
| Can one delta carry several words? | **Yes.** Volatile feeds the range `words[alreadyFed..<stableWordCount]`; FINAL catch-up re-feeds from the first disagreement, commonly many words | `PromptViewModel.swift:256-262` and the `.final` branch |
| Which tokens share a timestamp? | **Every word in the same delta.** `words.map { Token($0, at: timestamp) }` (FINAL) and `newWords.map { Token($0, at: delta.timestamp) }` (volatile) | `TranscriptStream.swift:39`, `PromptViewModel.swift:258` |
| How is matcher `now` obtained? | the same `delta.timestamp` value passed to `advance(spoken:now:)` | `PromptViewModel.swift:259` |
| Silence / stall / expiry clocks | all use that same wall-clock-derived value; `silenceFreezeSeconds` additionally extrapolates via `lastActivityWallClock` | `PromptViewModel.swift`, `SlidingWindowMatcher.advance` |

**Open discrepancy — established from code, magnitude NOT yet measured.**
`TranscriptDelta.timestamp` is documented as "audio-session-relative time" and `[PromptDebug]` logs
it as `audio_ts`, but the value supplied is wall-clock elapsed at observation.
`attributeOptions: [.audioTimeRange]` *is* requested (`TranscriptionService.swift:63`) so the
analyzer's own audio timing is available and unused.

**What the existing captures can and cannot show.** They cannot show the divergence at all: every
`[PromptDebug]` line records one clock only, so no capture in this project contains both a
wall-clock observation time and the corresponding audio time. The naming mismatch is established by
the code; its *causal role* in the remaining failures is not, and cannot be, from existing data.

**Minimum additional observation needed:** one device session logging both clocks per result. The
behaviour-neutral instrumentation for it is now in place — `[ClockAudit]` in
`TranscriptionService`, `#if DEBUG`, log-only, `ingest` still receives `elapsed` unchanged. Symbols
verified against the installed iOS 26.5 SDK's `Speech.swiftinterface` (§24.1):
`AttributeScopes.SpeechAttributes.TimeRangeAttribute`, `Value = CoreMedia.CMTimeRange`, reached as
`\.audioTimeRange` on an `AttributedString` run. It emits, per result,
`observed / audioEnd / lag / isFinal`.

**Why the obvious fix is not proposed.** Swapping `Date()`-elapsed for `audioTimeRange` is not a
one-line correction: the two clocks have different origins (session start versus the analyzer's
audio timeline), and each time-based rule means something different under each.
`silenceFreezeSeconds` asks "has the *speaker* stopped", which is an audio-time question;
`stallCandidateFreshnessSeconds` asks "is this evidence still current", which is arguably an
observation-time one. Establishing compatible origins and per-rule intended semantics has to come
before any substitution, and that needs the measurement above. **No production Speech behaviour was
changed.**

### 2. The fixtures were lying about time — and the first correction was invalidated by it

Several fixtures fed a whole utterance at a single instant (`DeviceFreezeReplayTests`,
`OffScriptCommentaryHoldTests`) or spaced words 0.001 s apart (`CursorLostRegressionTests`), so a
9-token window occupied ~0.01 s of fixture time against seconds of real time.

**Consequence, measured.** The first M5.2 attempt (`staleWindowSeconds`, a time-based horizon,
commit `6eece17`) passed its regression fixture and was a **no-op** once the replay used realistic
spacing:

```
  compressed timestamps, fix OFF -> token 18 (lost)
  compressed timestamps, fix ON  -> token 40 (tracking)   <- what the fixture reported
  realistic  timestamps, fix OFF -> token 18 (lost)
  realistic  timestamps, fix ON  -> token 18 (STILL LOST)
```

Sweeping that horizon from 2.0 s to 8.0 s never recovered the cursor. **`staleWindowSeconds` was
removed.** Any purely time-based rule is suspect here: a 9-word window spans 2.7 s at p25 event
spacing and 7.2 s at p75, so elapsed time is not a stable proxy for window content.

### 3. Replay provenance — classified honestly

| Replay | Class | What is real | What is reconstructed |
|---|---|---|---|
| `MetaCommentaryFalseJumpTests.offScriptTrace` | **captured matcher-input** | word sequence + per-event timestamps from the device trace | the 59-token lead-in is synthesised |
| `RealDeviceReadReplayTests.fed` | **captured matcher-input** | word sequence + timestamps | — |
| `CursorLostRegressionTests` / `CursorLostDiagnosticsTests` | **reconstructed** | the five `FINAL` texts and their timestamps | per-word grouping and intra-utterance spacing |
| `DeviceLogAuditTests` (5 sessions) | **reconstructed** | `FINAL` texts and timestamps | per-word grouping and spacing |
| `DeviceFreezeReplayTests`, `OffScriptCommentaryHoldTests` | **reconstructed** | utterance text and inter-utterance gaps | per-word spacing |
| M1 fixture suite (28) | **synthetic** | nothing — generated from scripts | all |

`DeviceTiming` supplies the reconstructed spacing. Its gap distribution is pooled from the two
captured traces above plus the `VOLATILE-FED` lines quoted in the M5 handoff — **56 gaps between
feed *events*, some of which carried more than one word**:

| n | p10 | p25 | p50 | p75 | p90 | max |
|---|---|---|---|---|---|---|
| 56 | 0.10 s | 0.30 s | 0.30 s | 0.80 s | 1.86 s | 3.87 s |

**Limitation, stated rather than buried:** `DeviceTiming` assigns each word its own timestamp, which
the production path does *not* do — words arriving in one delta share one. No captured
matcher-input trace exists for the P0 session, so its per-word grouping cannot be reproduced, only
approximated. Conclusions from it are therefore about scoring behaviour under plausible spacing, not
about a device execution.

### 4. The implemented rule: suffix-window re-acquisition

When a reader resumes reading after off-script speech, the alignment window straddles the boundary —
its older half is the ad-lib, its newer half is real reading — so no anchor scores well against the
whole thing. This is a property of **window composition**, which is why the rule is expressed in
words rather than seconds.

**Rule as implemented** (`SlidingWindowMatcher.suffixReacquisition`, reached only after the ordinary
full-window advance has already failed):

| Element | Value | Notes |
|---|---|---|
| Eligible suffix lengths | `alignmentWindow - 1` down to `minimumSuffixWindow` = 8…5 | longest first |
| Required score | `suffixJumpThreshold` = **0.92**, flat for every length | not a ramp — see below |
| Search range | the local range only, `[cursor - 10, cursor + 40]` | recovery search untouched |
| Candidate ranking | first (longest) suffix that clears the bar wins | more evidence preferred |
| Distinctive support | **required** (`suffixRequiresDistinctiveSupport`) | the gate that does the work |
| Freshest-token support | required, same as the ordinary path | |
| Cursor mapping | `anchor + suffix.count`, then the ordinary hysteresis caps | |
| Movement limit | `forwardCapWithoutRecovery` does **not** apply | it is classified as recovery |
| State reported | **`.recovering`**, never `.advancing` | see §5 |
| Stall state | cleared on success, like any advance | |

**The flat bar is measured; its exact value is not.** A ramp was drafted first, on the assumption
that narrower suffixes are more coincidental. The opposite holds against this script — off-script
speech scores *higher* at wider suffixes:

| trace | W9 | W8 | W7 | W6 | W5 | W4 |
|---|---|---|---|---|---|---|
| reading ¶2 — must fire | 0.926 | 1.000 | 1.000 | 1.000 | 1.000 | 1.000 |
| off-script commentary — must not | 0.852 | 0.833 | 0.810 | 0.778 | 0.733 | 0.778 |

A ramp anchored at `advanceThreshold` would have let a W8 off-script suffix fire at 0.833. But
**0.92, 0.95 and 1.00 are indistinguishable on every measurement available** — identical P0 cursor,
meta-commentary hold, M1 mean error and M1 false jumps. 0.92 is a conservative choice inside an
undiscriminated band, picked so one ordinary ASR wobble in a 6-8 word suffix does not veto a real
re-acquisition. It is not a tuned optimum and is not presented as one.

**`minimumSuffixWindow` = 5 — the earlier justification was withdrawn.** It was defended by noting a
4-word suffix let off-script speech reach 0.778, above `advanceThreshold` (0.72). That is not a
valid argument: suffix advances are gated at 0.92, and 0.778 is below it. The supported bound runs
the other way — running the actual rule at width 6 loses the P0 (cursor 18):

```
  minW  bar   distinctive | P0 cursor        meta | M1 mean   M1 false jumps
    5   0.92      yes     |    42              60 | 0.7659         0
    6   0.92      yes     |    18  LOST        60 | 0.7995         0
```

Whether 4 would also be safe is untested and deliberately left so.

**`suffixRequiresDistinctiveSupport` is the gate that actually discriminates**, measured across the
full 28-fixture M1 suite with everything else fixed:

| distinctive support | M1 meanCursorError | M1 false jumps |
|---|---|---|
| off | 0.8424 | **2** — `productLaunch/misrecognition`, `productLaunch/mediocreStall` |
| on | **0.7659** | **0** |

Without it the rule introduced two false jumps the suite had never had.

### 5. State-transition analysis (the questions that had to be answered before shipping)

- **Can a high short-suffix score bypass the six-token forward cap?** Yes, necessarily —
  `applyAdvance` skips `forwardCapWithoutRecovery` whenever the score clears `recoveryJumpThreshold`
  (0.80), and every suffix advance clears 0.92. A 5-word suffix can therefore move the cursor as far
  as `localSearchForward` allows.
- **Does that break the spoken-token invariant?** It would have. `PromptViewModel.applyCursor` marks
  every token between old and new cursor as *spoken* when the state is `.advancing`. The first
  implementation used `.advancing` and greyed 24 tokens the reader never said on the P0 replay
  alone. **Fixed by classifying suffix re-acquisition as `.recovering`**, which `applyCursor`
  already declines to mark. Guarded by
  `SuffixReacquisitionTests.suffixReacquisitionNeverMarksSkippedTextAsSpoken`.
- **Can a suffix advance reset a long stall and re-enable the looser recovery bar?** Yes — like any
  advance it clears `stalledSince`, so a subsequent recovery uses `recoveryJumpThreshold` (0.80)
  rather than `extendedStallJumpThreshold` (0.88). This is intended (the reader has been
  re-acquired, so the stall genuinely ended) but it is a real widening, and it is why distinctive
  support is required before the reset can happen.
- **Can successive local advances walk the cursor to a wrong distant position?** Each advance moves
  the local range forward, so in principle yes. Not observed: across 28 M1 fixtures, 1307
  checkpoints and 6395 spoken words the rule produces **zero** false jumps, and both dedicated
  off-script fixtures still hold. Bounded-but-not-proven; the honest statement is that no ratchet
  appears in the available evidence.

### 6. Verified results

Clean build (`xcodebuild clean` then `xcodebuild test -only-testing:prompterTests`, iPhone 17
Simulator, iOS 26.5), structured results from the result bundle rather than grepped console output:
**39 tests, 38 pass, 1 fail, 0 skipped** — `DeviceLogAuditTests` only, see below. M1 gate, same run:

```
TOTAL fixtures=28 checkpoints=1307 spokenWords=6395
TOTAL meanCursorError=0.7658760520275439 tokens (gate: <= 2.0)
TOTAL falseJumps=0 falseJumpRate=0.0 per 500 words (gate: <= 1.0)
```

Better than the pre-M5.2 published figure of 0.9074215761285387. The movement is attributable —
same 28 fixtures, same 1307 checkpoints, same 6395 spoken words, only timestamps and the rule vary
(`M1TimingAttributionTests`, `/tmp/m1_timing_attribution.txt`):

| timing | suffix rule | meanCursorError | false jumps |
|---|---|---|---|
| constant 0.4 s/word | off | 0.9074215761285387 | 0 | ← historical baseline, reproduces exactly |
| constant 0.4 s/word | on | 0.8806426931905126 | 0 |
| measured cadence | off | 0.7949502677888294 | 0 |
| measured cadence | on | **0.7658760520275439** | **0** | ← shipped |

Zero false jumps in every row of the shipped configuration. Before
`suffixRequiresDistinctiveSupport` existed the rule produced 2 under both cadences while the timing
change alone produced none — see the distinctive-support table in §4. The historical denominator is
unchanged — `FixtureTranscript.retimedAtConstantCadence()`
re-stamps timestamps only.

**`DeviceLogAuditTests` remains red, and is not weakened.** Its gates are `lost == 0` and
`falseJump == 0`; the product currently achieves LOST 3, FALSE-JUMP 1. Attribution shows the suffix
rule *improves* this and introduces nothing:

| verdict | suffix rule off | suffix rule on |
|---|---|---|
| TRACKING | 15 | **16** |
| LOST | 4 | **3** |
| FALSE-JUMP | 1 | 1 |

Classification of what remains:
- **All 3 LOST are one case** — the reader jumps to the script's final line ("That's the whole test.
  Thanks for reading…", tokens ~239-247) from token 74 or 156 after a long off-script stretch. That
  is a 91-165 token forward leap scoring 0.75-0.88 against an `extendedStallJumpThreshold` of 0.88.
  **Unresolved product tradeoff**, not a harness defect and not a regression: the same bar is what
  prevents the M5.1 214-token false jump.
- **The 1 FALSE-JUMP** (t=56.922 s, cursor 48 → 62 while `holding`, conf 0.10) is a **ground-truth
  ambiguity in the harness**. The reader says "And the page should scroll to keep…", which is
  near-verbatim script text; the classifier scores the whole 12-word utterance at 0.33 and calls it
  off-script, while the matcher advanced on its genuinely-matching prefix. Both are defensible.

### 7. Bounded timing audit of the M4 / M4.1 / M5.1 fixes

The failure mode that invalidated `staleWindowSeconds` — a time-dependent mechanism validated
against a fixture whose time was compressed — could have hidden elsewhere. Every previously shipped
matcher gate was audited against two questions: does elapsed time affect the mechanism, and what
timing model did its fixture use?

| Fix | Time-dependent? | Fixture timing model at the time | Verdict |
|---|---|---|---|
| `hasFreshestTokenSupport` (`b71de63`) | **No** — pure per-token similarity | `RealDeviceReadReplayTests` (**captured** per-word) | Sound. Not exposed. |
| `rawSimilarity` + `freshestTokenMinSimilarity` (`7061636`) | **No** — content only | same | Sound. Not exposed. |
| `recoveryAlignmentWindow` = 12, flat recovery recency (M4) | **No** — window *width*, not duration | `DeviceFreezeReplayTests` (whole utterance at one instant) | Mechanism not exposed; fixture was still unfaithful and has been rebuilt. Passes. |
| `bestStallCandidate` snapshot (M4, token-155) | **Yes** — armed by `recoverySustainedSeconds` (2.5 s) | `DeviceFreezeReplayTests` (whole utterance at one instant) | **Was exposed.** Rebuilt onto per-word timing; still passes. |
| `extendedStallSeconds` / `extendedStallJumpThreshold` (`219bc9a`, M5.1) | **Yes** — 8 s stall threshold | `MetaCommentaryFalseJumpTests` (**captured** per-word timestamps) | Sound — this one was always validated on real timing, which is why the M5.2 sweep could rely on it. |
| `mediocreConfidenceSustainedSeconds` (4.0 s, M4) | **Yes** | `ConfidenceHysteresisTests` + M1 `mediocreStall`, both **synthetic** | **Additional coverage warranted.** No captured trace exercises this timer. Flagged, not fixed — it is not implicated in the P0. |
| `silenceFreezeSeconds` (1.5 s) | **Yes** | `ConfidenceHysteresisTests`, gaps set explicitly | Adequate — the fixture's whole purpose is the gap, so it cannot be compressed by accident. |
| `stallCandidateFreshnessSeconds` (5.0 s, `6eece17`) | **Yes** | own control test, per-word timing | Retained, but **not part of the P0 fix** — no P0 measurement implicates it. Adjacent scope, flagged for the owner. |

Two conclusions. First, only one previously shipped mechanism (`bestStallCandidate`) was both
time-dependent and validated on compressed timing; it has been re-validated and still passes.
Second, `mediocreConfidenceSustainedSeconds` remains validated only against synthetic timing — the
one genuine coverage gap this audit found, recorded rather than opportunistically "fixed".

### 8. The 3 LOST events, diagnosed — and why no product decision is needed yet

Every LOST classification, from `classifyEveryUtterance` over the captured sessions:

| # | session | t | cursor | reader's actual position | best whole-script anchor / score | why recovery was refused |
|---|---|---|---|---|---|---|
| 1 | C | 129.775 s | 74 (held) | ~239 | 235 / **0.750** | 0.750 < `extendedStallJumpThreshold` 0.88 |
| 2 | C | 130.768 s | 74 (held) | ~247 | 239 / **0.875** | 0.875 < 0.88 — refused by 0.005 |
| 3 | D | 177.769 s | 156 (held) | ~239 | 235 / **0.750** | 0.750 < 0.88 |

**These are two independent events observed three times, not three events.** Events 1 and 2 are
consecutive utterances 0.993 s apart in one session — the reader reaching the script's final two
sentences near the end of the demo script (tokens ~235-247).
Event 3 is the same behaviour in a different session. Session D's *following* utterance (t=179.784)
anchors at 239 / 1.000, so it is the same two-utterance shape.

#### RETRACTED 2026-09-10 — the comparison that supported this was invalid

The paragraph that stood here claimed the cases are distinguishable by corroboration. **It was
wrong, and the measurement behind it never looked at the coincidence it claimed to reject.**

**Why the two figures were never comparable.** The M5.1 killer phrase appears twice in the corpus at
different *stages*, and the audit windowed the wrong one:

| observation | span scored | result |
|---|---|---|
| `MetaCommentaryFalseJumpTests.offScriptTrace` | the trace **ends** on "…off script", so the ring buffer at that instant **is** the killer phrase | anchor **202** / **0.833** |
| `DeviceLogAuditTests` session C, t=108.919 s | the FINAL is **36 words** and the killer phrase is its **prefix**; the audit scored `suffix(12)` = "all the the text which is annoying he shouldnt be doing that" | anchor **242** / **0.333** |

So §M5.2.8's "the coincidental match scores only 0.333 and is not corroborated" compared a
high-scoring coincidence against a window that did not contain it. Rejecting a candidate already
scoring 0.333 demonstrates nothing about protection from one scoring 0.833. The M5.1 gate-disabled
control is unaffected and still reproduces its documented failure exactly — **cursor 214**.

#### The corroboration hypothesis, tested properly and falsified

Re-measured on what the matcher can actually observe. It receives **appended tokens, not
utterances** — there are no utterance boundaries in its input, only overlapping ring-buffer windows,
so "an independent later utterance" is not a thing it can see. Corroboration was therefore defined
in observable terms: a later window scoring ≥ 0.80, anchoring within +30 of the pending candidate,
and separated by at least N **new** tokens so the same phrase cannot corroborate itself through
window overlap. Session C, word-by-word, N ∈ {6, 9, 12} — identical results at all three:

```
  t=100.359  anchor 202  score 0.833  -> not corroborated
  t=100.959  anchor 204  score 0.833  -> CORROBORATED by t=130.662 anchor 234 score 0.833
  t=130.662  anchor 234  score 0.833  -> not corroborated
  t=130.768  anchor 235  score 0.833  -> not corroborated
```

**It fails in both directions at once.**

1. **It fires for the coincidence.** The killer phrase at anchor 204 is "corroborated" by a candidate
   **thirty seconds later** — the end-of-script read at anchor 234, +30 away and inside the window.
   The two events are unrelated.
2. **It does not fire for the legitimate case.** The end-of-script candidates at 234 and 235 are the
   **last** things in the session: the reader finishes the script and stops talking. There is no
   later evidence to corroborate them, at any N.

**Scope of this result, stated precisely.** What is established is that **this rule fails on this
corpus**. It is *not* established that every recovery mechanism must fail, and nothing here should be
read that way — only this formulation, on these five sessions, was tested.

**Expiration behaviour.** The 30-second pairing in point 1 is the tested rule admitting evidence far
too far apart: it bounded corroboration by *new tokens*, not by elapsed time, so an unrelated
candidate half a minute later still qualified. An expiration bound would reject that pairing. It
would **not** help point 2, because expiring evidence sooner cannot create evidence that does not
exist after the speaker has stopped. That is why no further parameter sweep was run: the two failures
have different causes and only one of them is a parameter.

**Corroboration is therefore not implemented.** The baseline is retained rather than shipping a
mechanism that weakens M5.1 protection while not fixing the LOST events.

#### What this means for the LOST events — the tradeoff is real after all

The previous round withdrew the tradeoff question on the strength of the retracted comparison. That
withdrawal is itself withdrawn. Properly measured, at the moment the decision has to be made:

- the legitimate end-of-script skip offers candidates scoring **0.833-0.875**;
- the M5.1 coincidence offers a candidate scoring **0.833**;
- no later evidence separates them, because the legitimate case is followed by silence.

They are **genuinely indistinguishable on the evidence available to the matcher at decision time**,
which is what makes this a product choice rather than an engineering one. The smallest concrete
choice, with consequences:

| option | consequence |
|---|---|
| **A. Keep `extendedStallJumpThreshold` = 0.88** (current) | The 3 LOST persist: after a long off-script stretch, jumping far ahead — e.g. to the last line — leaves the cursor behind until the reader reads contiguously again. M5.1's 214-token false jump stays fixed. |
| **B. Lower it to ~0.82** | Both LOST events recover. The M5.1 candidate scores 0.833, so **the original false jump returns** — `MetaCommentaryFalseJumpTests` would fail, and that is the failure the owner reported from a device. |

There is no third option supported by current evidence. **Option A was chosen by the owner on
2026-09-10** and is retained. That decision selects the safer interim behaviour; it does **not** mark
the LOST cases resolved, waive the audit gate, or close M5.

Still open and deliberately visible: **two independent skip-to-end failures observed three times**
(session C t=129.775 s and t=130.768 s — one event; session D t=177.769 s — the other), and **one
UNRESOLVED intent classification** (session C t=56.922 s), which is reported separately and is not
counted as successful tracking.

**What would change the answer**, stated precisely so the eventual device read is not wasted: a
capture in which the reader skips a long way ahead **and then keeps reading**. Every long skip in the
five captured sessions is followed by silence, so the corroborating evidence has never been
observed — not shown absent, never observed.

Whether corroboration would work on such a capture is **not yet established and requires a suitable
capture to determine.** It is a hypothesis with one known failure mode already (the expiration issue
above) and no positive instance yet. It must not be described as viable, or as "working if the reader
continues", until a capture exists that tests it.

### 9. The FALSE-JUMP classification, resolved — and two rejected criteria

The single FALSE-JUMP (session C, t=56.922 s) was a **harness criterion defect**, now corrected.

```
  heard  : "And the page should scroll to keep, he should never go up, just knowing they were back."
  script : "...and the page should scroll to keep up with you automatically..."  (~tokens 48-62)
  cursor : 48 -> 62 (Δ+14) over 17 spoken words, then held. state holding, conf 0.10
```

The speaker quotes a script clause verbatim and then diverges into commentary. **Intent cannot be
established from the capture** — this is a person commenting *in the script's own words*, which is
the defining difficulty of this whole session. It is therefore classified `UNRESOLVED`, reported
separately, and **not counted as successful tracking**. The audit gate still fails on LOST, so the
acceptance gap stays visible.

Two criteria were tried and rejected first; both are recorded because each looked reasonable:

1. **Move magnitude alone** (the original `falseJumpMoveTokens > 12`) conflates "moved a lot" with
   "moved somewhere wrong". A 17-word utterance read continuously legitimately moves ~17 tokens.
2. **Displacement from where the utterance's own words match.** This fails for exactly the reason
   the M5.1 case exists: that false jump *also* had genuine near-verbatim script overlap, so its
   cursor also ended where its words pointed. Lexical overlap cannot separate the two, and a
   near-verbatim prefix does not prove reading.

The criterion adopted is **speech-relative movement**: a cursor cannot legitimately advance further
than the reader spoke. Here 14 tokens on 17 words; the M5.1 device false jump was **155 tokens on
~13 words**. It asks only whether the cursor travelled further than the speech that drove it, never
*what* was said.

### 10. Shipped rule, confirmed from source

Read back from `MatcherConfig.swift` / `SlidingWindowMatcher.suffixReacquisition` rather than from
the design note:

| Element | Shipped value |
|---|---|
| Eligible suffix lengths | `stride(from: spokenWindow.count - 1, through: minimumSuffixWindow, by: -1)` → 8, 7, 6, 5 |
| Required score | `suffixJumpThreshold` = **0.92**, flat for all lengths |
| Distinctive support | `suffixRequiresDistinctiveSupport` = **true**, passed to `bestAnchor` |
| Freshest-token support | required, `freshestTokenMinSimilarity` = 0.5 on raw similarity |
| Search range | `localRange` = `[cursor - 10, cursor + 40]` only |
| Ranking / tie-break | first match wins, scanning longest → shortest |
| Cursor mapping | `anchor + suffix.count`, then `backwardCap` |
| Forward cap | **not applied** — `isRecovery: true` |
| State | **`.recovering`** |
| Stall state | `stalledSince` and `bestStallCandidate` both cleared |
| Non-default configs | `minimumSuffixWindow == alignmentWindow` disables the path entirely |

**Control results.**

| control | result |
|---|---|
| `minimumSuffixWindow` = 6 (rule run, all else fixed) | P0 **lost at 18** — 5 is the widest workable floor |
| `minimumSuffixWindow` = `alignmentWindow` (disabled) | P0 **lost at 18** — the rule is what carries the fix |
| `suffixRequiresDistinctiveSupport` = false | M1 **2 false jumps**, mean 0.8424 |
| `suffixRequiresDistinctiveSupport` = true | M1 **0 false jumps**, mean 0.7659 |
| `suffixJumpThreshold` ∈ {0.92, 0.95, 1.00} | **identical** on all four metrics — the value is a conservative choice, not a tuned optimum |

**P0 trajectory and recovery delay** (`/tmp/p0_trajectory.txt`, reconstructed clock — a replay
property, not a device latency):

```
  paragraph-2 read begins   t=14.166s
  cursor enters 30...70     t=17.126s
  RECOVERY DELAY            2.960s — 5 words into the paragraph
  every cursor move: 3,4,5,6,7 (advancing) → 13,16,17,18 (advancing) → 42 (recovering)
  largest backward step: 0 tokens
```

One recovery move, no wandering, no backward slip.

**"Introduces nothing", asserted per event rather than by totals**
(`suffixScoringDoesNotMakeAnyIndividualUtteranceWorse`, `/tmp/per_event_comparison.txt`): all 63
audited utterances compared with the rule off vs on — **1 improvement** (session A t=31.877,
LOST → TRACKING, cursor 11 → 15), **0 regressions**. Aggregate counts alone could not have shown
that no new failure replaced an old one; this can.

### 11. M5.5 — the captured continuous-reading stall: diagnosed, and my earlier attribution corrected

**The 2026-09-12 capture pinned the cursor at token 216 for 9.6 s while the reader read paragraph 4
continuously.** `StallDiagnosisTests` replays the `VOLATILE-FED` sequence verbatim and records, per
update, the local candidate and why it was refused, freshest-token support, both fresh and retained
recovery candidates, stall duration and the bar actually required.

**My earlier attribution was wrong on two counts and is withdrawn:**

1. I said confidence "stayed in 0.45-0.72". It does not — the trace reaches **0.42 and 0.39**, so the
   low-confidence recovery path arms as well.
2. I said the escape hatch "demanded 0.88". **It never got the chance.** The retained recovery
   candidate throughout the stall is `205 / 0.750` — it never reaches even `recoveryJumpThreshold`
   (0.80), so the extended bar rejected nothing.

**The real cause is the local advance, and the evidence is unusually clean.** Through the entire
stall the best local anchor tracks the reader one token per fed word:

```
   t        word       local anchor/score   freshest
 119.209  somewhere       207 / 0.750         yes   <- last advance
 119.209  as              208 / 0.620         NO
 120.108  in              209 / 0.648         yes
 120.109  the             210 / 0.676         yes
 120.167  text            211 / 0.704         yes
 124.019  i               212 / 0.648         NO
 124.020  should          213 / 0.676         yes
 124.022  pick            214 / 0.704         yes
 124.918  backup          215 / 0.648         yes
 …
 128.803  whats           223 / 0.722         yes   <- finally crosses 0.72
```

The matcher knew exactly where the reader was the whole time. The cursor was pinned only because the
score sat a few hundredths under `advanceThreshold`.

**Correction: a run of consistently advancing anchors is evidence.** `trackedRunLength` (3)
consecutive local anchors advancing by 0-1 tokens **each with freshest-token support** permits an
advance at `trackedAdvanceThreshold` (0.70) instead of 0.72. This is not a loosened global
threshold — it is a second, independent kind of evidence, and it is exactly what off-script speech
does *not* produce: in the M5.1 capture the off-script anchors jump around (53, 202, 40, 41, 43, 6).

**Swept, not chosen.** All four constraints measured together:

```
  run  bar  | P0 (want 30...70)  meta (<=100)  stall cursor @127.9s  M1 false jumps
  off  --   |   42                  60              216                  0
   3   0.60 |   24  LOST            60              224                  0
   3   0.65 |   42                  60              220                  0
   3   0.70 |   42                  60              220                  0   <- shipped
   4   0.65 |   42                  60              216  (no gain)       0
   5   0.70 |   42                  60              216  (no gain)       0
```

`0.60` **breaks the M5.2 cursor-lost P0 at every run length** — it creeps the cursor through an
ad-lib to token 24, which is the very failure mode M5.2 exists to prevent. That regression was caught
by the existing suffix and P0 tests before anything shipped. `run >= 4` keeps the P0 but recovers
none of the stall. 0.65 and 0.70 are indistinguishable on every measurement, so the stricter is
taken: the concession is **0.02**, granted only on three consecutive consistent anchors.

**Result — measured over the whole capture, not at one checkpoint.** The earlier claim that "the
stall no longer pins" was based on a single sample (216 -> 220 at 127.9 s) and **overstated the
improvement**. `StallAssessmentTests.measureTheImprovementOverTheWholeCapturedStall` replays the
capture on one clock (the capture's `audio_ts`, the same value the production path passes as `now`)
and scores every fed word against the script position the reader had actually reached. Ground truth
is derived by hand from the FINAL texts against tokens 202-231, not from the matcher.

```
    t       word        truth | before  err | after  err
  ------------------------------+-------------+------------
   117.303  world         214 |    215    1 |   215    1
   119.209  somewhere     215 |    216    1 |   216    1
   119.209  as            216 |    216    0 |   216    0     <- both correct here
   120.108  in            217 |    216    1 |   216    1
   120.109  the           218 |    216    2 |   216    2
   120.167  text          219 |    216    3 |   220    1     <- paths diverge
   124.019  i             220 |    216    4 |   220    0
   124.020  should        221 |    216    5 |   220    1
   124.022  pick          222 |    216    6 |   220    2
   124.918  backup        224 |    216    8 |   220    4
   125.907  smoothly      225 |    216    9 |   220    5
   125.908  once          226 |    216   10 |   220    6
   126.919  you           227 |    216   11 |   220    7
   126.920  attend        228 |    216   12 |   220    8
   126.921  to            229 |    216   13 |   220    9
   127.892  reading       230 |    216   14 |   220   10
   128.803  whats         231 |    222    9 |   226    5
```

(The rows before 117.303 are the off-script section that precedes the stall; both paths are
identical there and both are far from the reader — errors of 135-185 tokens — because the reader is
elsewhere. They are excluded from the figures below, which concern the stall itself.)

```
                                      before      after
  longest incorrect hold               8.68s      7.72s
    …at token                            216        220
  error at the last fed word              14         10
```

**Two corrections to my own metrics.**

*First*, the previous report gave "time to regain the reader: 120.11 s, unchanged". That measured the
*pre-stall* acquisition at 117.3-119.2 s, when the cursor was already correct (error 0 at 119.209 s).
The stall is a subsequent, progressive loss of tracking, not a failure to re-acquire.

*Second*, the replacement line — "error first exceeds 3 tokens: 120.167 s -> 124.918 s, onset delayed
0.90 s" — was **internally inconsistent** and is withdrawn. 120.167 s is where the error *reaches* 3,
not exceeds it, and 124.918 - 120.167 is 4.751 s, not 0.90 s. The 0.90 s figure was the `err >= 4`
crossing (124.019 -> 124.918) reported against the wrong "before" timestamp.

**Event definition, stated once and derived from the complete trajectory.** "Onset" is the first tick
in the stall region (t >= 117.0 s) at which the position error reaches a given size. Because the
after-path skips from 2 to 4 without ever equalling 3, a single threshold is misleading, so all of
them are reported:

| error reaches | before | after | delay |
|---|---|---|---|
| 3 | 120.167 s | 124.918 s | +4.751 s |
| 4 | 124.019 s | 124.918 s | +0.899 s |
| 5 | 124.020 s | 125.907 s | +1.887 s |
| 6 | 124.022 s | 125.908 s | +1.886 s |
| 8 | 124.918 s | 126.920 s | +2.002 s |
| 10 | 125.908 s | 127.892 s | +1.984 s |

The honest single number is **roughly 0.9-2.0 s of delay depending on how much error counts as
"lost"**, not the 4.751 s that the `k = 3` row alone would suggest.

**Replay excerpt boundary is not the capture boundary — a second correction.** Two different
boundaries were conflated in my earlier reports and they must be kept apart:

| | Ends at | What it is |
|---|---|---|
| `StallDiagnosisTests.fed` (the replay excerpt) | **128.803 s audio_ts** | The escape — the tick where the cursor finally advances. This is where every number in this section stops. |
| The device log quoted in docs/DECISIONS.md | **130.571 s (log clock)** | The same event. Clock offset **+1.768 s**, confirmed independently at the stall's start (120.983 = 119.209 + 1.774). |
| The **full device capture** | **beyond 130.571 s, including events at 134.458 s** | Not transcribed into any fixture in this repository. |

I previously wrote that "the capture contains no events after the escape". **That is wrong** — it was
true of the *replay excerpt*, not of the capture. The correct statement: the replay excerpt was cut
at the escape, so every measurement here is bounded by that cut, and behaviour after 130.571 s is
**outside the replayed material** — neither measured nor contradicted. Any claim about post-escape
recovery would require transcribing the later events into the fixture first.

**The honest reading: it delays and shallows the divergence; it does not fix it.** The tracked-read
path buys **0.90 s** before the error exceeds 3 tokens, shortens the longest hold by **0.96 s** of a
9.6 s stop, and ends **4 tokens** closer. The hold does not break up — it relocates from token 216 to
token 220. The flat 4-token offset across every row is one shift, not progressive re-acquisition.
This is a real but **small** improvement, and it does not address the owner's complaint about stops
during continuous reading.

Guarded by `theCapturedStallNoLongerPinsTheCursor`, its control
`theStallReproducesWithTheTrackedReadPathDisabled` (216 with the path off), and
`theCorrectionPreservesTheFalseJumpProtectionAndTheP0`.

**The anchor-step bound is not what limits this.** `trackedAnchorStep` is 1, and the diagnostic
trace does contain +2 steps, so widening it was the obvious next lever. Measured, it changes
nothing:

```
  trackedAnchorStep | P0  meta | longest hold  at token | M1 mean  false jumps
        1           | 42   60  |    7.72s         220   | 0.7659       0
        2           | 42   60  |    7.72s         220   | 0.7659       0
        3           | 42   60  |    7.72s         220   | 0.7659       0
       off          | 42   60  |    8.68s         216   | 0.7659       0
```

The run is gated by freshest-token support, not by the step bound, so 1 is kept as the stricter
setting with no measured cost.

### 11a. The tracked-read rule, stated exactly

The intent ("a run of consistent anchors is evidence") is not precise enough to review, so the rule
is stated as the code implements it, with the boundary behaviour measured rather than assumed.

| Question | Answer | Evidence |
|---|---|---|
| What is one observation? | One `advance` call that reaches the local-anchor stage. **A tick, not a new word** — re-feeding the same word is a new observation. | `SlidingWindowMatcher` advance path |
| Do repeated identical anchors (`step == 0`) count? | **Yes**, and commonly: **242 of 6395 ticks** across the M1 suite hit `step == 0` *with* freshest support. | `stationaryAnchorsDoCountTowardTheTrackedRun` |
| So what does a run of 3 prove? | A **stable, freshest-supported alignment** — *not* forward progress. This is the rule's honest limit. | same |
| What breaks the run to 1? | Any backward step, or a step > `trackedAnchorStep`, when this tick still has freshest support. | advance path |
| What breaks it to 0? | Loss of freshest-token support. | `losingFreshestSupportBreaksTheRun` |
| Does a pause break it? | Not directly — the rule has no time term. A pause breaks it only insofar as the resumed audio produces an inconsistent anchor or loses freshest support. | advance path |
| Does recovery reset it? | **Not explicitly.** `previousLocalAnchor` keeps its pre-jump value, so the first tick after a jump sees a large step and breaks the run itself. | `aRecoveryJumpDoesNotLeaveAStaleRunBehind` |
| Why allow `step == 0` at all, given repetition? | Literal repetition of one word is the case that does *not* build a run: the repeat stops supporting the anchor and the run collapses to 0. | same test |
| The trace shows a **+2** anchor change — doesn't `trackedAnchorStep = 1` exclude it? | Yes, and it is the single +2 in the capture: **217 -> 219 at 126.919 s**. It breaks the run there. It costs nothing, because that tick's local score is **0.417**, which fails the tracked bar of 0.70 by 0.28 — an intact run could not have advanced on it either. | `docs/evidence/M5.5/stall-diagnosis.txt` |

**Reconciling the 0-1 requirement with the observed +2, in full.** The local anchors through the
stall are `207, 208, 209, 210, 211, 212, 213, 214, 215, 216, 217, 219, 220, 221, 222, 223` — fifteen
`+1` steps and exactly one `+2`. That `+2` is not noise: it is the alignment **correcting itself**
for the one-token drift introduced by the `backup` / `back up` tokenisation mismatch four words
earlier. So the rule does exclude a legitimate step. Two independent measurements show the exclusion
is inert:

1. that step's score is 0.417, far below the 0.70 tracked bar, so no run length would have advanced;
2. setting `trackedAnchorStep` to 2 or 3 produces **byte-identical** results on the P0, the M5.1
   false jump, the stall trajectory and M1 (table above).

`1` is therefore kept as the stricter setting at no measured cost — not because +2 steps do not
occur, but because the one that occurs is unusable on other grounds.

**Negative cases actually tested** — these are the traces checked, and the claim is limited to them:

| Trace | Tracked path fired |
|---|---|
| M5.1 off-script meta-commentary (the original false-jump capture) | 0 |
| Repeated common word, `"the the the the the"` | 0 |
| Off-script echo of nearby script vocabulary, `"the cursor should hold the page"` | 0 |

**This does not establish that off-script speech cannot satisfy the rule**, and that claim is not
made. What the three cases actually verify, tick by tick (`/tmp/tracked_rule_probe.txt`):

| Case | Ticks | Ticks with freshest support | Longest run reached | Best score on a supported tick | Fired |
|---|---|---|---|---|---|
| M5.1 off-script meta-commentary | 44 | 6 | **1** | 0.407 | 0 |
| Repeated common word `"the the the the the"` | 5 | 1 | **1** | 0.500 | 0 |
| Off-script echo `"the cursor should hold the page"` | 6 | 2 | **1** | 0.731 | 0 |

**The run never reached 2 in any of them**, so anchor consistency never got the chance to do the
blocking. The binding constraint in all three is that **freshest-token support never held on two
consecutive ticks** — in the M5.1 trace support appears 6 times out of 44 and never twice in a row,
and its anchors jump (`+37`, `-25`, `+12`, `+8`, `+17`) exactly as §11 describes. The protection in
evidence is therefore `hasFreshestTokenSupport` (§10.4). Off-script speech that happened to produce
freshest-supported, slowly-advancing anchors on three consecutive ticks **would** satisfy this rule;
no tested case did, and no general claim is made.

### 11b. What the remaining alignment failure actually is

"The gap needs better recognition" was too broad, and — measured — it is **not established**. The
recorded per-tick evidence shows the opposite is closer to true.

**The alignment was almost entirely correct, and this is validated rather than inferred from a
monotonic anchor.** An advancing anchor is *not* the same as a correct alignment, so the anchor's
actual claim about the reader's position — `anchor + windowSize`, which is what `applyAdvance` sets
the cursor to — is checked tick by tick against the labelled reading
(`TokenJoinTests.validateMappedScriptPositionsAgainstLabelledReading`):

```
    t       word        anchor  win  claim | truth | delta
   117.303  world           79    9     88 |   215 | -127   <- pre-lock recovery tick
   119.209  somewhere      207    9    216 |   216 |   +0
   …                                                    +0  (six consecutive exact ticks)
   124.022  pick           214    9    223 |   223 |   +0
   124.918  backup         215    9    224 |   225 |    -1   <- the compound mismatch
   125.907  smoothly       216    9    225 |   226 |    -1
   125.908  once           217    9    226 |   227 |    -1
   126.919  you            219    9    228 |   228 |   +0   <- the +2 unwinds the drift
   127.892  reading        222    9    231 |   231 |   +0
   128.803  whats          223    9    232 |   232 |   +0
```

**13 of 17 ticks map exactly**; three are exactly one token behind — and those three are precisely
the span between the `backup` mismatch and the `+2` self-correction — and one is the pre-lock
recovery tick at 117.303 s, before the alignment has acquired the reader at all. So the claim is not
"the anchor advanced, therefore it was right": the mapped positions were checked, and the only
sustained error is the one the compound word causes.

What the matcher did not have was a score clearing 0.72 (or 0.70 on a tracked run):
the scores over that span are 0.62, 0.65, 0.68, 0.70, 0.65, 0.68, 0.70, 0.65, 0.53, 0.48, 0.42,
0.39, 0.51, 0.62, 0.72. So the failure is located in **eligibility, not recognition**: the transcript
carried enough signal for the correct alignment to be found and held, and the rule declined to use
it.

**Why the score sits there is mechanical, and it is not a near-threshold effect.**
`ConfidenceModel.tokenSimilarity` (`prompter/Matching/ConfidenceModel.swift:47-50`) returns the
normalized similarity only if it clears `perTokenMatchThreshold` (0.8), and **exactly 0 otherwise** —
there is no partial credit. Classifying every fed word against the script token the reader had
actually reached:

| t | heard | script | similarity | contributes | class |
|---|---|---|---|---|---|
| 109.624 | `you` | `your` | 0.75 | 0 | substitution (0.05 under the bar) |
| 117.303 | `world` | `words` | 0.60 | 0 | substitution |
| 119.209 | `as` | `else` | 0.25 | 0 | substitution |
| 124.019 | `i` | `and` | 0.00 | 0 | substitution |
| 124.918 | `backup` | `back` `up` | 0.33 (**1.00** joined) | 0 | **tokenisation** |
| 126.920 | `attend` | `return` | 0.17 | 0 | substitution |

Over the 29 fed words: 23 exact, 5 substitutions, 1 tokenisation mismatch.

**Correction to my previous claim.** I wrote that there were "0 near-misses — nothing sits just under
`perTokenMatchThreshold`". That is wrong, and it was an artefact of my own classifier, which labelled
"near" only for scores *at or above* the bar. `you` / `your` scores **0.75**, which is 0.05 under the
token bar and contributes 0 instead of 0.75. The accurate statement is narrower: **five of the six
non-exact words are 0.25 or more below the token bar, and one is 0.05 below it** (and that one falls
at 109.624 s, outside the stall window, so it is not what held the cursor at 216/220).

**What this bounds.** Two mechanisms are implicated, both in alignment/eligibility rather than in the
recogniser:

1. **All-or-nothing token credit.** A 9-word window containing four or five zero-credit words cannot
   reach 0.72 however well the remaining words match, which is precisely the observed 0.39-0.70 band.
2. **Tokenisation.** `backup` is a single ASR word against two script tokens; it scores 0.33 against
   `up` alone and 1.00 against `back`+`up`. Nothing in the current path tries the join, so a correct
   transcription is scored as a mismatch and drifts the alignment by one token.

Neither conclusion licenses a recognition rewrite, and neither is addressed by moving a threshold —
the substitutions are far too far below the bar for that to reach them.

### 11c. Superseded by §12

This section previously named two blockers — all-or-nothing token credit, and the missing
tokenisation join — and judged the join "the narrower first move". The join has now been implemented
and measured (§12), and the result **falsifies the larger half of that diagnosis**.

I had written that all-or-nothing token credit "is the one that would actually move stop frequency".
That is **not established and no longer the leading hypothesis.** With the tokenisation join alone,
the captured stall's longest hold falls 7.72 s -> 3.86 s and the position error never again exceeds
one token — with **no** change to token credit, to any threshold, or to scoring semantics. The
residual error attributed to substitutions was largely the *phase shift* the compound word
introduced, not the substitutions themselves.

The correct conclusion is the narrow one: **on this capture, a local alignment correction was
sufficient, and a global scoring change was not required.** See §12.7 for what remains.

## 12. M5.6 — the split-script-token join (`backup` vs `back` `up`)

**Authorized narrow scope:** alignment only. No global token-scoring semantics changed, no threshold
changed, no `Speech/` or reconciliation change, no styling change.

### 12.1 Reproduction, before any edit

`TokenJoinTests.reproduceTheBackupMismatch` measures the case first:

```
  rawSimilarity("backup", "up")        = 0.333
  rawSimilarity("backup", "back")      = 0.667
  rawSimilarity("backup", "back"+"up") = 1.000
  tokenSimilarity credited by scoring  = 0.000   <- contributes NOTHING
```

The reader said both script tokens. A strictly positional 1:1 walk can only pair the single ASR word
against one of them, scores it as a non-match, and every later position in that window is shifted by
one until the alignment re-syncs — the three `-1` ticks in §11b.

### 12.2 The rule

| Aspect | Rule |
|---|---|
| **Eligibility** | All four must hold: (1) the ordinary 1:1 pairing at that position has **already failed** (`tokenSimilarity` < `perTokenMatchThreshold` 0.8), so nothing that currently matches can change; (2) `rawSimilarity(spoken, script[i] + script[i+1])` >= `joinedTokenMinSimilarity` = **0.95**; (3) the join beats the 1:1 alternative at that position; (4) at most `maximumJoinsPerWindow` = **1** join per window. |
| **Position advance** | Spoken index always +1. Script index +1 normally, **+2 on a join**. The two walk independently; the script's token indices are never rewritten and no text is concatenated in the script itself. |
| **Score normalization** | Unchanged. The denominator remains the recency-weight total over the **spoken** positions, exactly as `ConfidenceModel.score` computes it. A join therefore **cannot inflate** a window above what the same words would score if the script held the compound as one token. |
| **Cursor destination** | `anchor + scriptConsumed`, where `scriptConsumed` counts the script tokens the walk consumed (one extra per join). On the 1:1 path `scriptConsumed == spokenWindow.count`, so ordinary reading is bit-identical. |
| **Freshest-token support** | Join-aware. A join shifts the script index the newest spoken word lands on, so the gate asks about `candidate.freshestScriptIndex` rather than `anchor + windowSize - 1`, and a trailing compound may satisfy the gate against the **joined pair** it covers. |
| **Where it applies** | The **local search only** (`SlidingWindowMatcher.advance`, `allowJoin: true`). Recovery search, the suffix re-acquisition path and the stall-candidate snapshot keep the strict 1:1 walk, so this cannot move a recovery jump or a re-acquisition. |

### 12.3 Result — the compound word was causing the rest of the stall

Replayed on the captured sequence, join off vs on (tracked-read path on in both):

```
    t       word        truth | join off  err | join on  err
   124.022  pick          222 |      220    2 |     220    2
   124.918  backup        224 |      220    4 |     225    1   <- the join
   125.907  smoothly      225 |      220    5 |     226    1
   125.908  once          226 |      220    6 |     227    1
   126.919  you           227 |      220    7 |     228    1
   126.920  attend        228 |      220    8 |     228    0
   126.921  to            229 |      220    9 |     230    1
   127.892  reading       230 |      220   10 |     231    1
   128.803  whats         231 |      226    5 |     232    1

  longest incorrect hold : off 7.72s @220  |  on 3.86s @220
  error at last fed word : off 5           |  on 1
  error reaches 3        : off 124.918 s   |  on NEVER
```

**Two metrics, because the one I published before conflated them.** "Longest incorrect hold" measured
only how long the cursor *value stayed unchanged*, which says nothing about whether it was wrong. A
reader pausing, or reading words the cursor already covers, produces a stationary cursor that is
behaving correctly. With the join on that distinction is the whole point, so the two are now reported
separately (`TokenJoinTests.stationaryDurationAndOutOfRangeDurationAreDistinct`):

| Configuration | Longest **stationary** span | Longest span **out of range** (error > 2) | Max position error |
|---|---|---|---|
| Both corrections off | 8.68 s | — | 14 |
| M5.5 tracked-read only | 7.72 s | **3.88 s** | 10 |
| **M5.6 join added** | **3.86 s** | **0.00 s** | **2** |

**How 3.86 s stationary coexists with a max error of 2.** With the join on, the cursor reaches 225 at
124.918 s and the reader stays within one token of it until the next advance. The cursor is not
stalled *behind* the reader — it is sitting *where the reader is*. There is **no span at all** in
which the reader is more than two tokens ahead of it. The remaining stationary time is therefore not
a tracking failure and must not be reported as one.

**Correction to a claim I made in the commit message and the previous report.** I wrote that with the
join on "the position error never again exceeds one token". Unqualified, that is wrong: the maximum
error across the stall region (t ≥ 117.0 s) is **2**, reached at 120.109 s — *before* the join fires.
The accurate statement is narrower: **after the join fires at 124.918 s, the error never exceeds 1.**

`StallDiagnosisTests.theJoinAloneClearsTheStall` additionally checks the join clears the stall with
the tracked-read path switched off, so neither correction is silently carrying the other. This is not "helping only one word": the single compound mismatch was dragging the
alignment one token out of phase, and every subsequent window paid for it. Fixing the phase restores
tracking for the remainder of the capture.

### 12.4 Protection

| Guard | Join off | Join on |
|---|---|---|
| M5.2 cursor-lost P0 (want 30…70) | 42 | **42** |
| M5.1 meta-commentary high-water (must stay ≤ 100) | 60 | **60** |
| M1 checkpoints / spoken words (denominators) | 1307 / 6395 | **1307 / 6395** |
| M1 `meanCursorError` | 0.7658760520275439 | **0.7658760520275439** |
| M1 `falseJumps` | 0 | **0** |

Also tested: normal separate-word reading is **byte-identical** (the join-aware walk reproduces the
1:1 score to within 1e-12 and reports 0 joins across the script); every substitution in the capture is
offered the join and **refused** (`world`/`wordssomewhere` 0.214, `as`/`elsein` 0.167, `i`/`andshould`
0.000, `attend`/`returnto` 0.250, `you`/`youroff` 0.429); and one joined word cannot carry an
otherwise unrelated window over the bar.

**On the unchanged M1 average.** Byte-identical M1 means **no observed regression on this
28-fixture suite** — nothing stronger. It is not proof of universal non-regression, and it is not
evidence of benefit. No fixture in the suite contains a compound-word mismatch, so the suite cannot
detect this class of error in either direction; and a suite of 28 synthetic fixtures over one script
family cannot establish behaviour on scripts or recognisers it does not contain. The benefit is measured on the captured replay, which is the
only coverage that exercises it. Adding a compound fixture would move the M1 denominators (1307 /
6395) that every published figure is quoted against, so it is deliberately **not** done here and is
recorded as a gap.

### 12.5 What the fix broke in the test suite, and why that was correct

The first clean run after the join reported four failures. None was flaky and none was worked around:

| Test | Why it failed | Resolution |
|---|---|---|
| `StallDiagnosisTests.recordWhyAdvanceAndRecoveryBothFail` | It runs a **shadow** replication of the engine's decision logic and asserts `divergences == 0`. The shadow models the strict 1:1 walk; the engine no longer does, so it diverged. | **Pinned to the pre-correction configuration.** This test is the historical record of *why the original stall happened*; comparing its shadow against a join-aware engine would say nothing about that diagnosis. Current behaviour is asserted elsewhere. |
| `StallDiagnosisTests.theStallReproducesWithTheTrackedReadPathDisabled` | The control disabled only the M5.5 tracked-read path. With the join still on, the stall **correctly** failed to reproduce — so the control was asserting nothing. | Renamed to `theStallReproducesWithBothCorrectionsDisabled` and switched off both. A new test, `theJoinAloneClearsTheStall`, checks the join clears the stall with the tracked-read path off, so neither correction can silently carry the other. |
| `VolatileReconciliationTests` | CPU starvation, not a regression — passes in isolation. The new suite replayed the 28-fixture M1 suite twice per test. | The expensive replays are now computed once and reused, and this test's bounded wait was raised to 90 s. **No assertion changed.** |
| `DeviceLogAuditTests` | Pre-existing (LOST 3), unchanged by this round. | Unchanged — still red, still Option A's accepted cost. |

The second and third rows are worth stating plainly: a control that stops reproducing the bug is not
a passing control, it is a broken one, and it would have quietly turned the stall regression test
into a tautology.

### 12.6 Fading is NOT complete — the joined words stay dark

**Open presentation issue. Do not describe spoken-word fading as finished.**

A joined advance moves the cursor two tokens for one fed word.
`PromptViewModel.newlySpokenTokens` pairs backward 1:1 from the new cursor against the fed history,
so it pairs the compound against the *second* script token, fails, and stops. Measured for the
captured advance (cursor 220 -> 225, fed `["i","should","pick","backup"]`): **nothing is marked** —
`back` and `up` stay dark, and so does the rest of that feed.

This is the safe direction and it preserves the standing invariant ("grey means you actually said
this"): no word the reader did not say is marked, and neither neighbour is touched. But the reader
*did* say those words, and they do not fade. That is a real, visible gap.

**The alignment mapping the join already produces.** The information needed to close this is computed
and then discarded. `ConfidenceModel.JoinedAlignment` carries, per candidate:

| Field | Meaning |
|---|---|
| `scriptConsumed` | total script tokens the walk covered |
| `freshestScriptIndex` | script index the **newest** spoken token aligned to |
| `joins` | how many joins occurred (currently 0 or 1) |

What is *not* retained is the per-position mapping — which spoken index landed on which script
index(es). The walk knows it (`similarities` / `joinFlags` are built in lockstep); it simply is not
returned.

**Smallest follow-up that would mark both words without greying skipped neighbours.** Return the
walk's per-position mapping as `[(spokenIndex: Int, scriptRange: Range<Int>)]` on `JoinedAlignment`,
carry it on `RecoverySearch.Candidate`, and hand it to `applyCursor` alongside the cursor. Marking
then consults that mapping instead of re-deriving a 1:1 pairing: a spoken word whose entry covers two
script tokens marks **both**, and — critically — tokens that appear in **no** entry are marked by
nothing, which is exactly the skipped-neighbour protection the current backward walk provides by
accident. That keeps the invariant intact by construction rather than by conservatism.

This is a `Prompt/` + `Matching/` change and was **out of scope for this round** (styling behaviour
was to be preserved). It is the first candidate for the next one.

### 12.7 What remains, and the deferred scoring decision

**The stall is reduced but not gone.** A 3.86 s incorrect hold remains at token 220, spanning
124.022 -> 127.892 s. Its cause is now visible and is *not* the compound word: between `pick`
(124.022 s) and the join at `backup` (124.918 s) the cursor is already held by ordinary sub-threshold
scores, and the join only takes effect once the compound word arrives.

**The deferred proposal is not yet justified, and I am not making it.** The §11c claim that global
all-or-nothing token credit must change is withdrawn (§11c). Before any such proposal, the evidence
it would need is:

1. **Which exact windows would gain.** For each tick still below bar, the score under the proposed
   credit rule versus now — on the captured replay *and* on the 28-fixture suite.
2. **Which off-script windows would also gain.** Partial credit is symmetric: it raises the score of
   *every* near-miss, including the M5.1 meta-commentary windows whose anchors jump. The M5.1 trace
   currently peaks at 0.407 on a freshest-supported tick; the proposal must show what that becomes.
3. **Whether a local alternative suffices first.** Two remain untried and are strictly narrower:
   (a) extending the join to the reverse case (two spoken tokens against one script token, e.g. a
   reader saying "back up" where the script has "backup"); (b) allowing the local search to consider
   an anchor one token either side when the freshest token supports it, which addresses phase drift
   without touching credit at all.

Local alternatives must be measured before a global change is proposed.

**Next action — the focused device test.**

*Build:* Debug configuration (the `[Join]` and `[Scroll]` instrumentation is `#if DEBUG` and absent
from Release), scheme `prompter`, commit as recorded in the §22 entry. Install to the device, launch
the app normally — **not** the `-promptReplay` harness, which uses scripted transcripts.

*Passage to read* — paragraphs 3-5 of the built-in demo script, verbatim:

> Try reading at your normal pace first. Then try skipping a sentence on purpose, the way you might
> if you lost your place, and see whether the cursor recovers and finds you again further down the
> script. Try repeating a phrase you already said, too, and notice that it doesn't jump backward very
> far even when you do.
>
> Finally, try an ad-lib: say a few words that aren't in this script at all, as if you went off on a
> tangent mid-sentence. The cursor should hold its position rather than chasing your off-script words
> somewhere else in the text, and should pick back up smoothly once you return to reading what's
> actually written here.
>
> That's the whole test. Thanks for reading all the way to the end.

Read it straight through at normal pace. The load-bearing phrase is **"and should pick back up
smoothly once you return to reading"** — say "back up" naturally; do not over-articulate it, because
the whole question is what the recogniser emits.

*Attribution — the result cannot be credited to this fix on feel.* The log must show it:

```
[Join] role=selected site=223 script=[223..<225]="back up" heard="backup" win#8 seq#22 occ=1 obs=1 anchor=215 consumed=10 cursor=220->225 score=0.796
```

| Field | Meaning |
|---|---|
| `role` | **`selected`** = this alignment drove the cursor decision. **`evaluated`** = it was the best local candidate and scored, but the advance was refused. The two are different findings and a capture must tell them apart. |
| `site` | Script index of the **first** of the two joined tokens. |
| `script=[a..<b]="…"` | The matched script range and its text. |
| `heard` | The spoken token that covered both — **the join site, never the newest word in the window**. |
| `win#` | Its index within the alignment window. |
| `seq#` | Its index in the spoken stream, for locating it in an unfiltered transcript. |
| `occ` / `obs` | Occurrence identity: `occ` counts genuinely separate visits to this site, `obs` counts re-observations **within** one visit. |
| `cursor=X->Y` | Movement. On an `evaluated` line `X == Y`. |

**The logging path is positively verified**, so an absent line is informative rather than ambiguous.
`TokenJoinTests.theJoinLoggingPathEmitsOnADeterministicCase` replays a case known to join and asserts
on the recorded output of `emitDebugLog` — the single call site that records and then prints the
*same* string, so the test sees exactly what `print` receives.
`theJoinLoggingPathIsSilentWhenNoJoinFires` asserts the converse: with joining disabled, nothing is
emitted. Verification covers the guard, the string construction and the call; only delivery of
`print` to the device console is inferred, and that is the same mechanism `[Scroll]` uses.

**Expect repeats, not one line — and read `occ`/`obs` rather than counting lines.** The alignment is
re-scored from scratch every tick, so one compound is reported once per tick for as long as it stays
inside the 9-word window. In the captured replay that is **eight lines, all `site=223`, all `occ=1`,
with `obs=1…8`** — one join, observed eight times, not eight joins. A second visit to the same site
after the window has turned over increments `occ` instead
(`aLaterSeparateOccurrenceIsDistinguishableFromRepeatedObservations` demonstrates `occ=1 obs=1…9`
followed by `occ=2 obs=1`).

**One of those eight is `role=evaluated`** (`seq#26`, score 0.769, `cursor=228->228`): the join scored
but the advance was refused. That is exactly the case the `role` field exists to expose — without it,
a capture would show a join "firing" on a tick where the cursor did not move.

- **If `[Join]` lines appear at `script="back up"`:** the fix is engaged, and the read can be compared
  against the previous build.
- **If no `[Join]` line appears:** the recogniser emitted "back" and "up" as two words, and this build
  is expected to behave identically to the previous one. Report it as **"join did not fire"**, not as
  "the fix didn't work". This reading is sound because the emission path has been verified above.
- **Sanity check only:** `[Scroll]` lines should also be present in the capture. If *neither* appears,
  the capture itself is filtered or the build is Release, and the run says nothing either way.

*A logging defect this verification caught, recorded because it would have corrupted the diagnosis.*
The first version of the line reported `heard=<newest word in the window>` and the script pair at
`freshestScriptIndex`. Those are generally **not** the join site, so it emitted lines like
`heard=smoothly script="smoothly once"` for a window whose only join was `backup` -> `back up`. Had
the device capture been read against that, it would have appeared to show joins that never happened.
The line now reports the actual join site (`ConfidenceModel.JoinSite`), and
`theJoinLoggingPathEmitsOnADeterministicCase` asserts both directions: every emitted line names
`heard="backup"` / `script=[223..<225]="back up"`, **and** none of the six bogus pairings the old
version produced (`smoothly once`, `once you`, `you return`, `to reading`, `reading whats`,
`whats actually`) may ever reappear.

*What to send back:* a **screen recording** of the read, and the **unfiltered** log for the session
(no grep, no filtering — previous rounds lost the decisive lines to filters).

*What the test establishes.* If `[Join]` fires at "back up": the cursor should follow within about one
token instead of holding, and **the number of stops longer than ~2 s across that passage should drop
by at least one** versus the previous build. If it does not fire: no difference is expected, and the
capture still has value — it tells us this recogniser does not produce the compound, which bounds how
much this class of fix can ever be worth.

*Must remain intact* (check on the recording, not in logs): smooth scrolling, manual scroll ownership
and the "Resume following" control, and no false jump during the deliberate ad-lib in paragraph 4.

M5 remains open. No further tuning before this capture.

## 13. M5.9 — the `"2"` / `"two"` mismatch: measured, implemented, **reverted, deferred**

**Status: not in the product.** Implemented and then reverted in the same round, on evidence. The
measurements are kept because the next attempt should start from them.

**The mismatch is real and total.** The 2026-09-13 device capture emitted `"2"` where the demo script
says `"two"` (token 34, in *"not just one or two lines"*). `rawSimilarity("2", "two") = 0.000` — the
strings share no characters — so that window position contributed **nothing** and the cursor held at
token 30. No threshold can reach a zero, so this can only ever be a normalization question, never a
scoring one.

**What was tried.** Equivalence at `Tokenizer.normalizeWord`, the single boundary shared by script
preprocessing and both spoken paths — chosen so that spoken-word styling would inherit it through the
existing comparison rather than needing a second rule. Token counts, script indices, display text and
raw transcripts were all preserved; currency and percent were excluded explicitly because
`normalizeWord` strips punctuation first, so `"$2"` and `"2%"` already reduce to a bare `"2"`.

**Why it was reverted — one utterance, isolated to one token**
(`docs/evidence/M5.9/numeral_regression.txt`). The reader *commenting on* the script while quoting it:

> "[captured utterance redacted — see private historical repository]"

```
  without equivalence: cursor -> 27  holding    conf 0.61
  with    equivalence: cursor -> 36  advancing  conf 0.75
  script 30..<36 = ["not", "just", "one", "or", "two", "lines"]
```

With the equivalence the last six spoken words are an **exact** match for script 30-35, so commentary
becomes indistinguishable from reading. Device-audit totals moved **HOLDING 35 → 34, UNRESOLVED
1 → 2** and `suffixScoringDoesNotMakeAnyIndividualUtteranceWorse` went red. M1 was byte-identical
throughout, because the M1 suite contains 14 script / 12 spoken `"two"` and **zero** `"2"`.

**What that establishes, and what it does not.** It establishes that **this** implementation — an
unconditional equivalence at the normalization boundary — affects commentary containing quoted script
text. It does **not** establish that every narrower approach is impossible. That question is
**deferred and open**, not answered. No further matching experiments were run on it.

**Guarded by `NumeralMismatchDeferredTests`**, which asserts the current (uncorrected) behaviour, keeps
the commentary utterance as a live measurement that any future attempt must survive, and names the
excluded forms so a future widening fails there first.

