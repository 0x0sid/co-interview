# Co-Interview — START HERE

**Read this first.** It is self-contained: you do not need any chat history to understand where this
project came from, what exists, and what to do next.

## What this is

Co-Interview is a **new, independent app** forked from the Prompter codebase on 2026-09-15.
Prompter is an iOS teleprompter that follows a reader's voice; **Prompter development is paused**.

**The inherited interface is scaffolding, not a product.** Nothing in the current UI has been
approved as Co-Interview. No interview feature has been designed, specified or built.

## Identity and provenance

| | |
|---|---|
| **Active development checkout** | **`~/Desktop/co-interview-public`** — work here |
| Private historical clone | `~/Desktop/co-interview` — full 89-commit history, **not published**, keep for capture-derived fixtures and evidence |
| Forked from | Prompter commit **`8fcff26`** — history preserved only in the private clone above; **this** repository starts fresh |
| This project's first commit | see `git log` — the "Fork Prompter into Co-Interview" commit |
| Git remote | `origin` → `git@github.com:0x0sid/co-interview.git` — **published**. Prompter's remote was removed at the fork, so nothing here can reach Prompter's repository |
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
cd ~/Desktop/co-interview
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
question handling, no participant model, no recording policy, no consent flow.

**Billing is intentionally unconfigured.** No RevenueCat key, no products, no entitlement. Prompter's
pricing, entitlement, paywall and 10-minutes-per-day limit are **not** Co-Interview requirements.

## Documents

| Document | Purpose |
|---|---|
| [`CO_INTERVIEW_PRODUCT_BRIEF.md`](CO_INTERVIEW_PRODUCT_BRIEF.md) | Confirmed decisions, and the open product questions that block architecture |
| [`CO_INTERVIEW_ARCHITECTURE.md`](CO_INTERVIEW_ARCHITECTURE.md) | Inherited modules, data flow, reuse candidates, coupling |
| [`CO_INTERVIEW_DEVELOPMENT.md`](CO_INTERVIEW_DEVELOPMENT.md) | Setup, build/test commands, dependencies, signing limits, known failures |
| [`CO_INTERVIEW_DECISIONS.md`](CO_INTERVIEW_DECISIONS.md) | Fork decision, isolation measures, identity changes, open questions |

Everything else under `docs/` is **inherited Prompter documentation**, kept as historical engineering
reference. It describes Prompter's product and roadmap — **not Co-Interview's**.

## Recommended next action

**Define the interview workflow before writing any feature code.** The open questions in the product
brief — who uses it, in-person or remote, what it produces, what happens to audio — change the
architecture fundamentally, and several of them cannot be answered by an engineer. Answer those
first; the scaffolding will still be here.
