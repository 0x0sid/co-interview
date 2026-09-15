# Co-Interview — decisions

## 2026-09-15 — Fork from Prompter

**Decision.** Create Co-Interview as an independent app from the Prompter codebase. Prompter is
paused, not abandoned, and remains recoverable at its own repository.

**Method.** A local `git clone` of `~/Desktop/prompter` at commit **`8fcff26`**, preserving all 88
commits of history. A clone — not a worktree — so the two projects never share a checkout or index.

**Prompter's state at the fork, verified rather than assumed:** working tree clean, no uncommitted or
untracked work (only ignored `.DS_Store` / `xcuserdata` noise), no stashes, nothing pushed. **No
uncommitted work existed, so nothing had to be carried across or left behind.** No build products,
simulator data or credential files were present to copy — the tree was checked for `.p12`,
`.mobileprovision`, `.cer`, `.key`, `.env` and `.xcconfig` files and had none.

## Isolation measures

| Risk | Measure | Verified |
|---|---|---|
| Accidentally pushing to Prompter's GitHub repo | Prompter's `origin` **removed** at the fork; Co-Interview's `origin` now points at its **own** destination | `git remote -v` shows only `0x0sid/co-interview` |
| Sharing a checkout | Full clone, real `.git` directory, not a worktree | `.git` is a directory |
| Overwriting Prompter | Destination did not exist before creation | checked first |
| Replacing the installed app | Distinct bundle identifier | `talk.cointerview` vs `talk.prompter` |
| Corrupting Prompter's data | Distinct sandbox **and** an explicit store filename | `CoInterview.store` |
| Leaking credentials | None existed; none copied; none committed | tree scanned |
| Inheriting Prompter's billing | Left unconfigured — no key, no products | `BillingConfiguration` returns `nil` |

## Identity changes (Co-Interview only — Prompter untouched)

| | From | To |
|---|---|---|
| Display name | Prompter | **Co-Interview** (`CFBundleDisplayName`) |
| Bundle id (app) | `talk.prompter` | **`talk.cointerview`** — provisional, **not registered** |
| Bundle id (tests) | `talk.prompterTests` / `…UITests` | `talk.cointerviewTests` / `…UITests` |
| Xcode project | `prompter.xcodeproj` | **`co-interview.xcodeproj`** |
| Scheme | auto-generated `prompter` | **`Co-Interview`**, shared and checked in |
| SwiftData store | SwiftData default | **`CoInterview.store`** |
| Deployment target / Swift | iOS 26.0 / Swift 6.0 | **unchanged** — no build requirement justified moving it |

**Deliberately not renamed:** the `prompter/`, `prompterTests/` and `prompterUITests/` source
directories and the Xcode *target* names. Renaming targets rewrites every reference in the project
file and every source path for no functional benefit; the user-visible identity is fully changed
without that churn. Revisit only if it becomes genuinely confusing.

**Shared scheme added deliberately.** The clone had no scheme at all — `xcuserdata/` is gitignored, so
the auto-generated one did not travel. A checked-in shared scheme makes the build reproducible for
anyone who clones this.

## What was explicitly *not* inherited as requirements

Prompter's pricing (USD 6.99/month), its `premium` entitlement, its paywall, its 10-minutes-per-day
usage limit, its M5 milestones and its release criteria are **Prompter's product decisions**. They
carry no authority over Co-Interview. The code is present as scaffolding; the requirements are not.

## Unresolved product decisions

All of them. See [`CO_INTERVIEW_PRODUCT_BRIEF.md`](CO_INTERVIEW_PRODUCT_BRIEF.md) — who the user is,
in-person versus remote, what the app produces, live versus post-hoc, audio retention and consent,
on-device versus cloud, and language scope. **No interview feature should be built before questions
1–6 are answered**, because each changes the architecture rather than just the interface.

## Engineering safeguards carried forward deliberately

These were hard-won in Prompter and are worth keeping regardless of what Co-Interview becomes:

- Test counts read from `xcresulttool`, never from log greps.
- `xcodebuild clean` before any load-bearing verification — incremental builds have reported false
  passes in this codebase.
- Claims distinguish *implemented* from *automated-verified* from *device-verified*.
- No secret in the repository; only public client configuration ever ships in the app.
- Evidence is stored under `docs/evidence/` and linked rather than pasted.


## 2026-09-15 — Intended remote added, nothing published

**`origin` = `git@github.com:0x0sid/co-interview.git`.** Added because no remote existed; nothing was
overwritten. Verified read-only with `git ls-remote`: SSH authentication **succeeds** and the
repository has **zero refs** — it is genuinely empty, so a first push would not clobber anything.

**Nothing has been pushed**, and the publication decision is open. The destination is **public**,
while this repository carries Prompter's full 89-commit history. See the publication assessment in
[`CO_INTERVIEW_START_HERE.md`](CO_INTERVIEW_START_HERE.md) and the summary below.

### What a push of the current history would publish

| Category | Present? | Detail |
|---|---|---|
| Credentials / keys | **No** | No credential-shaped filenames anywhere in history; no `appl_`, private-key, or AWS-style strings in the tree. RevenueCat was never configured |
| Inherited Prompter source | **Yes** | The entire app — matcher, speech pipeline, billing scaffolding — across 89 commits |
| **Real device transcripts** | **Removed here** | Capture-derived fixtures and `docs/evidence/` held verbatim speech from real sessions, including unscripted asides. Stripped from this public snapshot; preserved in the private historical repository |
| **Screen recordings** | **Yes** | `docs/evidence/M5.3.4/replay-recording.mp4` (16 MB) and `M5.3.3/replay-recording.mp4` |
| Evidence files | **Yes** | 29 MB across 16 milestone folders — logs, screenshots, xcresult summaries |
| Personal information | **Yes** | Commit author email on all 89 commits; absolute home paths in 9 tracked files |
| Repository size | — | `.git` is 92 MB; 285 tracked files |

**No credentials would be exposed.** The material that warrants a decision is the device transcripts,
the screen recordings, and the personal identifiers — all of which are retained in history and cannot
be removed by deleting files in a new commit.
