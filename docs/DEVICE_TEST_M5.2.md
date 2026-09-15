# M5.2 instrumented device session — protocol

**Diagnostic validation of the retained baseline. Not milestone sign-off. M5 does not close on it.**

---

## 1. Build and run

**Current checkout commit: `b67c7ff`.** Its **app-target source (`prompter/`) is identical to the
state the clean verification ran against** — every commit since that run has touched only
`prompterTests/` and `docs/`. Verify before installing:

```
git rev-parse HEAD                              # expect b67c7ff (or later docs-only commit)
git diff 4912859 HEAD --stat -- prompter        # expect: no output
```

Source equivalence is not installation. **You still have to build and install this checkout onto the
phone** — the app currently on the device is from an earlier round and does not contain
`[ClockAudit]`.

**In Xcode (needed — the debugger must be attached, see §5):**

1. Open `prompter.xcodeproj`.
2. Scheme **prompter**; run destination = **your iPhone** (plugged in or paired over Wi-Fi).
3. **Product → Scheme → Edit Scheme → Run → Info → Build Configuration = `Debug`.**
   Required: `[ClockAudit]` is inside `#if DEBUG` and does not exist in Release.
4. **Product → Run (⌘R).** Leave Xcode attached for the whole session.

Confirmed absent from app source: any corroboration mechanism
(`grep -rin "corrobora\|pendingCandidate" prompter/` → no matches). It was tested, falsified, and
never implemented.

Shipped recovery configuration (`MatcherConfig.swift`):

```
recoveryJumpThreshold            0.80
extendedStallSeconds             8.0
extendedStallJumpThreshold       0.88   <- Option A, owner decision 2026-09-10
minimumSuffixWindow              5
suffixJumpThreshold              0.92
suffixRequiresDistinctiveSupport true
```

Verification backing this build: **41 tests, 40 pass, 1 fail, 0 skipped**; M1
`meanCursorError=0.7658760520275439`, `falseJumps=0`. Evidence in `docs/evidence/M5.2-round2/`.

---

## 2. Load the right script

Use the **paste-a-script / editor** flow, whose default text is the 248-token script below.

**Do not use the Demo screen** — it runs `DemoScript.text`, a different script ("…In about thirty
seconds, you'll see something most teleprompter apps can't do…"), and every position in this
protocol would be meaningless.

**Self-check:** the first log line of every take must read `SESSION START — 248 tokens`. If it says
anything else, you are on the wrong script.

Paragraph token ranges (0-based, from `ScriptIndex`): **P1** 0–35 · **P2** 36–117 · **P3** 118–175 ·
**P4** 176–234 · **P5** 235–247.

---

## 3. Resetting between takes — verified

**Press `Restart` between every take.** Code-checked, `Restart` → `PromptViewModel.start()` resets
all three kinds of state:

| state | reset by | verified at |
|---|---|---|
| matcher (cursor, ring buffer, confidence, stall timers) | a brand-new `SlidingWindowMatcher(scriptIndex:)` | `PromptViewModel.start()` |
| spoken-token / grey set | `spokenTokenIndices = []` | `PromptViewModel.start()` |
| volatile↔final reconciliation | `makeService()` builds a **new** `TranscriptionService`, which owns a fresh `TranscriptStream`; the new consume task gets a fresh `volatileWordsFedToMatcher` | `PromptScreen`/`ScriptEditorScreen` `makeService:`, `TranscriptionService:38`, `PromptViewModel:231` |

**Each take is identifiable in the log**: every Restart emits a new `SESSION START — 248 tokens …`
line, and the `[PromptDebug  %.3fs]` elapsed clock restarts near zero. Count `SESSION START` lines —
there must be **five**.

---

## 4. The five takes — read exactly this

### Take 1 — ordinary reading
Read aloud, normal pace, then stop:

> Welcome to Prompter. This is a longer test script, written specifically so you have enough material to read aloud and actually see the cursor track your voice across several paragraphs, not just one or two lines.

*Expect:* cursor tracks to ≈35.

**Restart.**

### Take 2 — off-script, then resume nearby (the P0 / suffix correction)
Read the Take 1 paragraph. Then say off-script for **~10 seconds**, roughly:

> Okay so I want to check the colours on this bit, the grey is a little bit much for me and I think this line is too wide.

Then read on, at least three sentences:

> As you speak, the current sentence should highlight, the text you've already read should fade to a quieter tone, and the page should scroll to keep up with you automatically. If you pause for a moment, the cursor should hold steady and wait for you, rather than guessing ahead. If you stop talking entirely for a couple of seconds, it should freeze in place completely, the same way a person keeps eye contact with you when you look up from the page.

*Expect:* cursor re-acquires into P2 (36–117) within a few words.

**Restart.**

### Take 3 — distant skip, then keep reading (exploratory)
Read the Take 1 paragraph. Off-script **~10 seconds**, roughly:

> Right, and the scrolling here, I'm not totally sure about the speed of it yet, we can come back to that later.

Then **skip straight to P4** and read it through to the end:

> Finally, try an ad-lib: say a few words that aren't in this script at all, as if you went off on a tangent mid-sentence. The cursor should hold its position rather than chasing your off-script words somewhere else in the text, and should pick back up smoothly once you return to reading what's actually written here.

*Exploratory — no pass/fail. This is the observation no capture contains.*

**Restart.**

### Take 4 — skip to the end, then stop
Read the Take 1 paragraph. Off-script **~10 seconds** (any wording). Then read **only**:

> That's the whole test. Thanks for reading all the way to the end.

…and **stop talking entirely.**

*Expect: the cursor does **not** recover.* That is Option A's documented cost, not a new finding.

**Restart.**

### Take 5 — the protected M5.1 case
Read the Take 1 paragraph, then continue into P2 and stop reading around "…rather than guessing ahead":

> As you speak, the current sentence should highlight, the text you've already read should fade to a quieter tone, and the page should scroll to keep up with you automatically. If you pause for a moment, the cursor should hold steady and wait for you, rather than guessing ahead.

Now talk off-script, on an **unrelated** subject, for **about 15 seconds** — this part matters, see
below. Roughly:

> Yeah so I think the thing I keep coming back to is whether people will actually use this on a phone or whether they'd rather have it on a tablet, because the screen size changes how much you can see at once, and that probably changes the whole layout question.

Then say the meta-commentary phrase **once**, clearly, and **stop**:

> also the cursor should hold its position rather than chasing you off script

*Expect:* the cursor **holds**; it must not jump toward P4 (176–234).

**Why the 15 seconds is required.** The protection under test only engages once a stall has run past
`extendedStallSeconds` = **8.0 s**. Said immediately after reading, the phrase is judged by the
ordinary bar and the take proves nothing about M5.1.

**Confirm from the log that it actually engaged.** In take 5's block: find the last line where the
cursor *value changed*, note its `audio_ts`; find the `audio_ts` of the first fed word of the
meta-commentary phrase. The gap must be **≥ 8.0 s**, with every line between showing the cursor
unchanged and `state=holding`. If the gap is under 8 s, take 5 is void — Restart and redo it with a
longer off-script stretch.

---

## 5. Exporting the logs

Instrumentation is plain `print()`, so **Xcode must be attached** — Console.app and `log stream` will
not capture it.

1. Run from Xcode (Debug) and do all five takes **in one run**, without stopping.
2. Click into Xcode's console pane, **⌘A**, **⌘C**.
3. Paste into a plain text file and send it.

**Export the console unfiltered.** Do not apply a filter — the filter box hides lines from the copy,
and the two streams (`[PromptDebug]`, `[ClockAudit]`) plus any warnings or errors between them are
all part of the evidence.

### What the instrumentation cannot capture

- `[ClockAudit]` prints **only when a result carries an `audioTimeRange` attribute**. A missing line
  is not evidence of zero lag.
- It logs **one audio end-time per result**, not per word.
- **Neither the ring buffer nor the chosen anchor is logged** — only cursor, confidence and state.
  The candidate the matcher actually weighed has to be reconstructed by replay afterwards.
- **`spokenTokenIndices` — the grey set — is never logged.** Hence the visual check below.

---

## 6. Visual check — every take

After any re-acquisition, look at the text the cursor jumped **over**. **It must stay black.** Grey
means "you actually said this"; skipped text turning grey is a defect wherever the cursor lands.
Nothing in the logs records this.

---

## 7. Criteria, fixed before the session

Existing requirements that apply:

- **§10.4 / M4** — the cursor holds during off-script speech (takes 2, 5).
- **M5.1 regression** — the meta-commentary phrase must not move the cursor toward P4 (take 5, valid
  only if the ≥ 8 s stall is confirmed).
- **Spoken-token invariant** — text never spoken must not render grey (all takes).
- **The P0** — a genuine resumption re-acquires (take 2). The replay figure, 2.960 s / 5 words, is a
  *replay property on reconstructed timing*, **not** a device latency target.

Explicitly **exploratory**, no pass/fail: **take 3**, and **all `[ClockAudit]` figures** — this
session produces that capture, it does not interpret it. **Take 4 is expected not to recover.**

---

## 8. Acceptance status going in — unchanged

- Suffix re-acquisition: improvement verified **on the stated replays only**, never on device.
- Full suite: **40 of 41 passing**.
- Device audit: **3 LOST observations across 2 independent events**, **1 UNRESOLVED** classification.
- **M5 remains open.**


---

# 9. Short presentation check (2026-09-11) — run this one first

**This does not replace §4's five takes and does not close M5.** It checks the three presentation
requirements recorded in `docs/DECISIONS.md` (2026-09-11), which are verified by unit test for
fading and by code inspection only for scrolling — motion cannot be asserted by a unit test in this
project, so it needs your eyes.

## Build

**Install a fresh Debug build of the current checkout — the phone's build predates these changes.**

```
git rev-parse HEAD                      # note this; it must be the commit you install
xcodebuild -project prompter.xcodeproj -scheme prompter -configuration Debug \
  -destination 'platform=iOS,name=<your iPhone>' build
```

Then **⌘R from Xcode with the debugger attached** (Run configuration must be **Debug** — `[ClockAudit]`
is `#if DEBUG`). Same script as §2: the log's first line must read `SESSION START — 248 tokens`.

## Record the screen

**Start iOS screen recording before the first take** (Control Centre → Record). The scrolling and
fading requirements are motion and colour — the console cannot show either, and
`spokenTokenIndices` is never logged. Send the video with the log.

## Three takes — press `Restart` between each

### A — normal read: individual fading and smooth following

Read straight through, at your normal pace:

> Welcome to Prompter. This is a longer test script, written specifically so you have enough material to read aloud and actually see the cursor track your voice across several paragraphs, not just one or two lines.

Watch for: words fading **one at a time as you say them**; the word you are on and everything ahead
staying dark; the page rising **smoothly and continuously**, not lurching once per sentence and not
juddering per word.

**Restart.**

### B — distant skip: fast repositioning, skipped text dark

Read the paragraph above. Then **skip straight to paragraph 4** and keep reading to its end:

> Finally, try an ad-lib: say a few words that aren't in this script at all, as if you went off on a tangent mid-sentence. The cursor should hold its position rather than chasing your off-script words somewhere else in the text, and should pick back up smoothly once you return to reading what's actually written here.

Watch for: the page arriving at paragraph 4 **promptly, in one short glide** — not scrolling through
paragraphs 2 and 3 on the way; normal smooth following resuming afterwards; and **everything you
skipped staying dark**, never greying.

**Restart.**

### C — pause and off-script: holding

Read the first paragraph, then **stop talking for ~10 seconds**. Then talk off-script for ~10
seconds about anything unrelated. Then stop.

Watch for: any in-flight scroll **settling and then holding** — no drift, no creep, no jitter while
you are silent or off-script; and no text greying while you talk off-script.

## Export

All three takes in **one run**. Click Xcode's console, **⌘A**, **⌘C**, paste into a text file.
**Export unfiltered** — no filter in the box; both `[PromptDebug]` and `[ClockAudit]` and anything
between them are evidence. Send that file **and the screen recording**.

## What this check cannot settle

- It does not address the **3 LOST / 1 UNRESOLVED** device-audit cases. Those are unchanged and
  remain open (Option A's recorded cost).
- It is not milestone sign-off. **M5 stays open**, and §4's five-take protocol is still outstanding.

---

# M5.7 retest — automatic resumption after manual repositioning

**Build:** Debug configuration (the `[ScrollOwner]` / `[Scroll]` diagnostics are `#if DEBUG` and
absent from Release), scheme `prompter`, on device. Launch the app **normally** — *not* the
`-promptReplay` harness, which drives scripted transcripts and no real gesture.

**Capture:** screen recording **and** the unfiltered log for the whole session. Do not grep the log
before sending it; earlier rounds lost the decisive lines to filters.

## Steps

1. Start a take and read paragraph 1 normally until the page is clearly following you.
2. **Drag** the text to a different passage — paragraph 4 is the useful one, it contains
   *"and should pick back up smoothly once you return to reading"*.
3. **Release and let it settle.** Then sit still and stay quiet for ~5 seconds.
4. **Ad-lib** a sentence that is not in the script at all, still without touching the page.
5. Now **read the passage you moved to**, aloud, from its beginning, at a normal pace.
6. **Do not touch "Resume following" at any point.**
7. Optional tail: while it is following again, **drag once more** mid-sentence to confirm manual
   control still wins instantly.

## Pass criteria — observable events, not impressions

| # | Observable | Where to look |
|---|---|---|
| 1 | After the drag settles, a line appears naming the region you landed on | `[ScrollOwner] … settled — chosen region tokens N..<M (awaiting 3 fresh in-region advances)` |
| 2 | **No movement at all** during steps 3-4 (silence, then ad-lib) | recording: the page does not shift; log: `SUPPRESSED (manual ownership) … evidence=0/3` or `1/3` that never reaches 3 |
| 3 | While reading (step 5), the page glides back **once**, after roughly 3 real advances — not on the first word, not after a long delay | `[ScrollOwner] … RESUME — 3 fresh advances (tokens A->B) inside chosen region N..<M` |
| 4 | The glide is a **single** smooth movement, not a jump followed by a correction | recording |
| 5 | After the glide, following continues with the motion already accepted | recording + `[Scroll] … owner=auto transition=following` |
| 6 | During the drag and its deceleration, the page never fights you | recording; and **no** `RESUME` line timestamped inside the drag |
| 7 | Dragging again (step 7) detaches immediately | `[ScrollOwner] … user -> manual` |

**If it does not resume**, the two diagnostics say why without guesswork: the `evidence=n/3` counter
on the suppression lines shows how far the rule got, and the `settled — chosen region` line shows
whether the captured region actually covers where you moved. A `settled — no geometry, rule not
armed` line means the layout was unmeasured and the rule deliberately stayed off — tap Resume
following, and report it, because that path should be rare.

## Regression check: the motion must be unchanged

This round was required to preserve the smoothness already accepted, and *"we didn't touch that
code"* is not evidence. Check on the recording, comparing against the previous accepted take:

- ordinary sentence-to-sentence following is still one continuous glide per target, with no stepping
  or restart-from-rest mid-sentence;
- no target is re-issued for an unchanged position (log: `unchanged targetY=… — not re-issued`
  should still appear, and should still be followed by silence rather than movement);
- the reading line still sits near the top through long sentences rather than drifting down.

If any of these changed, that is a regression in this round even though the motion code is
byte-identical — it would mean ownership is being handed back at the wrong moments.

## What this protocol still cannot exercise

Stated plainly, because these are the owner's own six cases and two of them are only partly covered:

- **"Drag while old-position recognition continues → no snapback"** is only *opportunistically*
  covered. It requires the recogniser to still be emitting finals for the passage you left at the
  moment you drag away. Step 2 makes that likely if you drag mid-sentence, but the protocol cannot
  force it. If the log shows no cursor advances between the drag and your first word of step 5, this
  case was **not** exercised and should be re-run.
- **Deceleration specifically** (as distinct from the drag itself) cannot be forced: whether a flick
  decelerates long enough for a cursor update to land inside `.decelerating` depends on the gesture.
  A hard flick makes it more likely.
- **The unmeasured-geometry path** cannot be triggered deliberately on device at all; it is covered
  only by `settlingWithoutGeometryDoesNotArmTheRuleAndNeverResumes` and its control.
- Everything here is **single-session**. Nothing in this protocol tests resumption across a Restart
  or an app relaunch.
