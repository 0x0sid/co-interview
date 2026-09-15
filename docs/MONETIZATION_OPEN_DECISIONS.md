# Monetization — SETTLED (2026-09-14)

> **INHERITED FROM PROMPTER — historical reference only.** This describes *Prompter*, a separate
> paused project. It is **not** a Co-Interview specification and its roadmap, milestones and release
> criteria do not apply here. Start at [`CO_INTERVIEW_START_HERE.md`](CO_INTERVIEW_START_HERE.md).


> **Status notice.** The monetization model is **settled** — see
> [`PROMPTER_CURRENT_STATE.md`](PROMPTER_CURRENT_STATE.md) §2.5. Nothing in this file is an open
> question any more; the appendix is kept to record how the decision was reached.


**The model below is decided and implemented (M5.13).** This file previously listed it as open; the
owner has settled it. The earlier comparison is kept at the bottom as the record of how the decision
was reached.

## The model

| | |
|---|---|
| Free tier | **10 reading minutes per local calendar day** |
| Scripts | **Unlimited, no word-count restriction** |
| Demo | **Unlimited and unmetered** |
| Premium | **Unlimited reading**, USD **6.99/month** |
| Entitlement id | `premium` |
| Account | **None required** — anonymous customers |
| Active take | **Never interrupted.** A take allowed to start is allowed to finish, even past zero |

**Resolved questions, previously open:**

1. *Does the 1,000-word cap replace or supplement daily metering?* — **Neither. It is dropped.**
   Scripts are unlimited in length and count.
2. *Is USD 9.99 the price?* — **No. 6.99/month**, the originally documented offer. The 9.99 figure was
   tied to a filming tier that is **not part of this implementation**.
3. *What happens to existing scripts over 1,000 words?* — **Moot**; no cap exists, nothing is
   grandfathered, truncated or blocked.
4. *Is the free tier still useful?* — 10 minutes/day plus an unlimited demo.

**Deferred, not sold:** camera filming. It must not appear in store copy, paywall copy or the Premium
screen. `BUILD_SPEC.md:45`'s "future AI writing tools" likewise must not be advertised — the paywall
lists only unlimited reading time.

---

## Appendix — the original comparison (how the decision was reached)

**Status: none of this is implemented.** No word limit is enforced, no script is truncated, no
editing is prevented, no subscription product exists, and filming is not advertised anywhere. The
Settings entry added in M5.12 says "coming soon" and has no purchase path.

## The two models

| | **Existing spec** (`BUILD_SPEC.md`) | **Proposed** (owner, 2026-09-14) |
|---|---|---|
| Free tier | 10 reading minutes per local day | Scripts up to 1,000 words |
| Scripts | Unlimited | Unlimited in count; limited in length |
| Price | USD 6.99/month | USD 9.99/month (scope unclear — see below) |
| Entitlement | `premium` | unchanged |
| Demo | Unlimited, unmetered | unchanged |

## How each one actually affects the reader

**Existing (10 minutes/day).** The limit is felt *during* use and resets at the user's midnight.
A reader rehearsing a 3-minute script can run it three times a day free. Someone reading a 20-minute
keynote hits the wall mid-take — which is why the spec forbids interrupting an active take, so the
take finishes and the paywall appears afterwards. Cost of the model: the meter has to run, pause
correctly on interruption and background, and reset on the local calendar day.

**Proposed (1,000-word cap).** The limit is felt *before* use, at the moment of writing or pasting.
It is far easier to understand ("your script is too long") and needs no timer, no background
accounting and no local-day reset. But it is a harder wall: a 1,200-word script is unusable rather
than partly usable, and the reader hits it while *authoring*, which is the worst moment to be
stopped. For reference, the bundled demo script is ~250 words; 1,000 words is roughly 6–7 minutes of
speech.

**Combining both would be strictly worse for the reader** than either alone, and should be an
explicit decision rather than an accident.

## Unresolved — owner decisions required

1. **Does the 1,000-word cap replace daily metering, or supplement it?** These are different products.
   Replacing is simpler to build and to explain; supplementing means a reader can be blocked twice for
   different reasons.
2. **Is USD 9.99 the price of Premium as it exists today, or of a future filming tier?** The current
   spec says 6.99 for unlimited minutes. If 9.99 is meant to cover filming, then Premium-today and
   Premium-with-filming are two products, and the one that ships first cannot be sold on the promise
   of the other.
3. **What happens to scripts already over the limit?** They exist now — the app has never had a cap.
   Options: grandfather them permanently; allow reading but not editing; allow editing but not
   reading; block both. Only the first avoids taking away something a reader already has.
4. **Is the free tier still usable enough to be worth having?** A 1,000-word cap with no time limit is
   generous for short scripts and useless for long ones; 10 minutes/day is the reverse.

## Explicitly not built this round

Camera permissions, capture sessions, recording controls, video storage and export are **not**
implemented and not designed. Filming must not appear in store copy, paywall copy or the Premium
screen as an available feature.

`BUILD_SPEC.md:45` currently lists *"future AI writing tools"* as a Premium benefit — that must not be
sold as a current benefit either (carried over from M5.11).
