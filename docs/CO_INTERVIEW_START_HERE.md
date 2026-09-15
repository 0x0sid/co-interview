# Co-Interview — START HERE

**Read this first.** It is self-contained: you do not need any chat history to understand where this
project came from, what exists, and what to do next.

## What this is

Co-Interview is a **new, independent app** forked from the Prompter codebase on 2026-09-15.
Prompter is an iOS teleprompter that follows a reader's voice; **Prompter development is paused**.

**The inherited interface is scaffolding, not a product.** Nothing in the current UI has been
approved as Co-Interview. No interview feature has been built.

## Current planning track — the interview copilot (2026-09-16)

The owner confirmed a direction: Co-Interview becomes an **interview copilot on iPhone** that keeps the
voice-following teleprompter, listens to the interview, detects questions, and shows document-grounded
suggested answers as swipeable cards in the existing reader. **This is a plan for review. No copilot
code exists.** Start with these, in order:

| Document | Owns |
|---|---|
| [`CO_INTERVIEW_COPILOT_BRIEF.md`](CO_INTERVIEW_COPILOT_BRIEF.md) | Confirmed requirements, user journeys, proposed MVP, exclusions |
| [`CO_INTERVIEW_COPILOT_ARCHITECTURE.md`](CO_INTERVIEW_COPILOT_ARCHITECTURE.md) | Code mapping, boundaries, data models, document lifecycle, audio feasibility, AI options, data handling |
| [`CO_INTERVIEW_COPILOT_IMPLEMENTATION_PLAN.md`](CO_INTERVIEW_COPILOT_IMPLEMENTATION_PLAN.md) | Ordered increments, acceptance criteria, verification, stopping points |
| [`CO_INTERVIEW_COPILOT_OPEN_QUESTIONS.md`](CO_INTERVIEW_COPILOT_OPEN_QUESTIONS.md) | Unresolved owner decisions only, each with a recommendation |
| [`CO_INTERVIEW_DECISIONS.md`](CO_INTERVIEW_DECISIONS.md) | Dated record of what was decided |

Each category of information has one owner above; other documents link rather than restate it. The
fork-day documents below remain as history where the copilot documents supersede them.

## Identity and provenance

| | |
|---|---|
| **Active development checkout** | **`~/Desktop/co-interview-public`** — work here |
| Private historical clone | `~/Desktop/co-interview` — full 89-commit history, **not published**, keep for capture-derived fixtures and evidence |
| Forked from | Prompter commit **`8fcff26`** — history preserved only in the private clone above; **this** repository starts fresh |
| This project's first commit | **`32a583c`** "Co-Interview: initial public snapshot" — fresh history (the fork commit exists only in the private clone) |
| Git remote | `origin` → `git@github.com:0x0sid/co-interview.git` — **published**; `main` at `32a583c` verified with `git ls-remote` on 2026-09-15. Prompter's remote was removed at the fork, so nothing here can reach Prompter's repository |
| Xcode project | `co-interview.xcodeproj` |
| Scheme | **`Co-Interview`** (shared, checked in) |
| Display name | **Co-Interview** |
| Bundle identifier | **`talk.cointerview`** — provisional, **not registered** with Apple |
| Local store | `CoInterview.store` — separate from Prompter's |
| Deployment target / Swift | iOS 26.0 / Swift 6.0 (inherited, unchanged) |

> **Work in `~/Desktop/co-interview-public`.** That is the published repository and the active
> checkout. `~/Desktop/co-interview` is the private historical clone — consult it for the
> capture-derived fixtures and evidence that were removed here, but do not develop in it and never
> push it. Read [`CO_INTERVIEW_SNAPSHOT_NOTICE.md`](CO_INTERVIEW_SNAPSHOT_NOTICE.md) for what was
> removed, including the test coverage lost and the inherited defects still open.

## Build

```bash
cd ~/Desktop/co-interview-public
xcodebuild build -project co-interview.xcodeproj -scheme Co-Interview \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Verified building at fork time. Co-Interview installs alongside Prompter — different bundle
identifiers mean iOS treats them as separate apps with separate data.

## What exists versus what does not

**Inherited and working (scaffolding):** light/dark design system with measured contrast · script
create/edit/delete with SwiftData persistence · keyboard-aware editing · on-device speech capture and
transcription with permission handling · a settings screen · a substantial test suite.

**Inherited but probably wrong for an interview app:** teleprompter scrolling, script matching,
spoken-word fading, script-based recovery, daily usage limits and the subscription paywall. See
`CO_INTERVIEW_ARCHITECTURE.md`.

**Not built at all:** every interview-specific feature. There is no interview workflow, no
question handling, no participant model, no recording policy, no consent flow. The copilot plan proposes
reusing the teleprompter scrolling, script matching and spoken-word fading for answer reading (the
confirmed direction preserves them); see the copilot architecture.

**Tests.** The public snapshot reportedly passes **113 tests** (`prompterTests/` declares 113 `@Test`
functions). Capture-derived regression coverage was removed for publication and known tracking defects
remain unresolved — see [`CO_INTERVIEW_SNAPSHOT_NOTICE.md`](CO_INTERVIEW_SNAPSHOT_NOTICE.md).

**Billing is intentionally unconfigured.** No RevenueCat key, no products, no entitlement. Prompter's
pricing, entitlement, paywall and 10-minutes-per-day limit are **not** Co-Interview requirements.

## Documents

| Document | Purpose |
|---|---|
| [`CO_INTERVIEW_PRODUCT_BRIEF.md`](CO_INTERVIEW_PRODUCT_BRIEF.md) | Fork-day confirmed decisions and open questions — partly superseded by the copilot brief |
| [`CO_INTERVIEW_ARCHITECTURE.md`](CO_INTERVIEW_ARCHITECTURE.md) | Fork-day inherited module survey, defects, coupling — reuse verdicts superseded by the copilot architecture |
| [`CO_INTERVIEW_SNAPSHOT_NOTICE.md`](CO_INTERVIEW_SNAPSHOT_NOTICE.md) | What the public snapshot removed, and the coverage lost |
| [`CO_INTERVIEW_DEVELOPMENT.md`](CO_INTERVIEW_DEVELOPMENT.md) | Setup, build/test commands, dependencies, signing limits, known failures |
| [`CO_INTERVIEW_DECISIONS.md`](CO_INTERVIEW_DECISIONS.md) | Fork decision, isolation measures, identity changes, open questions |

Everything else under `docs/` is **inherited Prompter documentation**, kept as historical engineering
reference. It describes Prompter's product and roadmap — **not Co-Interview's**.

## Recommended next action

**Review the copilot plan, answer Q1 (where the interviewer's voice comes from) and Q7 (test
language), then approve or amend Increment 1** — a debug-only device spike that measures whether the
iPhone microphone hears the interviewer well enough and how interviewer and reading speech interfere.
No feature code before that approval.

*Superseded 2026-09-16:* the fork-day recommendation here was "define the interview workflow before
writing any feature code". The confirmed copilot direction answers the workflow question; the remaining
owner decisions are in [`CO_INTERVIEW_COPILOT_OPEN_QUESTIONS.md`](CO_INTERVIEW_COPILOT_OPEN_QUESTIONS.md).
