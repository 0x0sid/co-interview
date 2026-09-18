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


## 2026-09-16 — Interview copilot direction confirmed; planning track opened

### Confirmed by the owner

Co-Interview becomes an **interview copilot used on an iPhone**. Confirmed requirements, recorded in
full (C1–C13) in [`CO_INTERVIEW_COPILOT_BRIEF.md`](CO_INTERVIEW_COPILOT_BRIEF.md) §1:

- preserve normal script reading, voice-following scrolling and spoken-word styling;
- listen to available interview speech and keep conversation context, including while the user reads;
- detect questions and requests that call for an answer, and generate suggested answers;
- present answers in the existing teleprompter reading experience, for successive and follow-up questions;
- swipe left/right between question-and-answer cards;
- organize preparation around **projects** with user-supplied documents that are processed so
  suggestions can use them;
- support interviews across subjects, not only job or software interviews;
- the interview happens "on phone" — this confirms the **device only**, not the audio route.

**Consequences for earlier records.** This supersedes the fork-day statement that no interview
functionality is approved, and the fork-day "Inherited components pending a product decision": the
teleprompter scrolling, script matching and spoken-word fading are now intended for reuse.
`Billing/`, Prompter's pricing, subscriptions, daily allowance and release milestones remain **not**
Co-Interview requirements.

### Not decided — recommendations only, labelled as such

Everything in the copilot architecture, implementation plan and open questions is a **proposal**. In
particular, these are **unapproved recommendations**:

- *Recommendation:* first-release audio route is acoustic capture only (in person, or another device on
  speaker). Same-phone call capture is **not** proposed: no documented iOS route exists (Q1).
- *Recommendation:* on-device speech recognition, text-only cloud answer generation through an
  app-owned backend relay; OpenAI models evaluated from current documentation (Q2, Q3).
- *Recommendation:* small-context grounding over processed documents within a project budget;
  retrieval later (architecture §7.3).
- *Recommendation:* first-release formats TXT, Markdown, PDF with text layer, DOCX conditionally;
  proposed limits (Q6).
- *Recommendation:* no audio or transcript persistence; saved sessions hold questions, answer versions
  and sources (Q5).
- *Recommendation:* card, versioning and reading rules in the brief §4.4.
- *Recommendation:* first implementation increment is a debug-only device spike measuring acoustic
  capture and speech/reading interference.

### Documentation changes in this round

- New: `CO_INTERVIEW_COPILOT_BRIEF.md`, `CO_INTERVIEW_COPILOT_ARCHITECTURE.md`,
  `CO_INTERVIEW_COPILOT_IMPLEMENTATION_PLAN.md`, `CO_INTERVIEW_COPILOT_OPEN_QUESTIONS.md`.
- `CO_INTERVIEW_START_HERE.md`: copilot planning track linked; obsolete checkout path (`~/Desktop/co-interview`
  → `~/Desktop/co-interview-public`), first-commit description and remote status corrected.
- `CO_INTERVIEW_DEVELOPMENT.md`: checkout path, public-snapshot test baseline (113 reported; capture-derived
  suites removed) and remote status corrected; the fork-point baseline is kept, labelled historical.
- `CO_INTERVIEW_PRODUCT_BRIEF.md`, `CO_INTERVIEW_ARCHITECTURE.md`: a dated provenance note at the top;
  bodies unchanged.
- The 2026-09-15 entries above are left as written. Their remote status ("nothing pushed") and history
  description describe the private clone at that time; the public snapshot has since been published
  with fresh history.
- Inherited Prompter documents are unchanged and remain historical references.

No code, model, store, dependency, speech behaviour, billing or service was changed. Prompter is
untouched.

## 2026-09-17 — v2.5 interview screen: manual generation, waveform listening mark

The design concept v2.5 is now a working screen in `prompter/Interview/`. **This increment is
interface and demo data only.** It adds no provider call, no backend request, no microphone use and
no new network code of any kind.

### Detection and generation are separate actions

The single most important rule on this screen: **listening detects questions; only a tap writes an
answer.** `DemoInterviewFeed` plays a script that produces transcript lines and detected questions
and stops there. An answer exists only after `InterviewScreenModel.generate()`, which asks the feed
through `requestAnswer(requestID:question:isRegeneration:)`.

- Generate targets the question the user explicitly selected; with nothing selected it takes the
  most recent detected question that has no answer. The button *on a page* bypasses that rule and
  answers its own question, because a button on a page cannot mean anything else.
- One question keeps one identity. Generating its first answer does not duplicate it, and a feed
  that re-announces a question adds nothing.
- A second tap while a generation is running is ignored: one question never has two requests.
- Every exchange carries a `requestID`. A chunk, completion or failure whose request the model no
  longer knows — cancelled, superseded, or arriving after the session ended — is dropped. That is
  what stops a late event writing into the page being read.
- An answer that finishes on a page the user is not looking at raises a "Qn ready →" chip. It never
  changes the page.

### Owner corrections applied in this pass

- **The listening mark is a waveform, in red** (`WaveformShape`), not a dot and not a sparkle. The
  sparkle now means Generate and nothing else. There is no REC label and no timer anywhere.
- **The demo never implies the microphone is open**: during scripted playback the waveform is drawn
  in the muted tone, its VoiceOver label is "Demo playback", and the badge reads
  "Demo · scripted playback, microphone off" — or "Demo · simulated reading" while words are fading.
- The transcript shows **exactly two lines collapsed**; expanding reveals more of it plus the
  Context controls. Note and up to five thumbnails survive collapsing.
- `n/N` lives **inside the question bar**. There is no separate "Question 2/3" row. The denominator
  counts questions actually detected — never a planned demo count, which would be a promise about a
  live interview that nothing can keep.
- No Quick Take, no chips, no Speak-mode button.
- The floating toolbar stays compact: pause/resume, centred Generate sparkle, more menu. Page
  content reserves the toolbar's full height, so the last line of an answer and the Follow-ups link
  can always be scrolled clear of it.

### Structure that was kept rather than replaced

- **Tokens live in `InterviewTheme`, not in `Theme`.** v2.5 asks for `#F8F5EF` / `#2F6B5E`; `Theme`
  carries Prompter's inherited `#F7F4EF` / `#216A60` and paints the library, editor and
  teleprompter. Editing `Theme` would have repainted every inherited screen.
- **Reading is the inherited engine.** `Matching/` is untouched. Each completed answer gets its own
  `ReadingAlignment`, each page its own `ScrollOwnership`, and the text is rendered by
  `ScriptStyling.sentenceBlocks` through a palette bridge.
- **Prose and code keep their original order.** A code card that belongs between two paragraphs is
  rendered there, not collected at the end: `AnswerPageView` walks the blocks in order and pairs
  prose block *i* with paragraph *i* of the aligned text.
- **Code is excluded from alignment by construction.** `InterviewAnswer.proseText` never contains a
  `.code` block, so a code sample cannot be greyed out as if it had been spoken.
- **Simulated reading is demo-only**, starts only after an answer has finished arriving, is labelled
  while it runs, and is switchable off from `•••`. It is bound to the answer it started on, so a
  step left over from another page is dropped rather than applied.
- **Regenerate appends.** `answers` is append-only, the newest is shown with a muted
  "v2 · Generated just now", and the previous version is kept.
- `CopilotScreen` is superseded as the interface but **not deleted**: it is still the only screen
  wired to a provider, it carries a deprecation comment, and the start screen keeps it reachable
  under "Pipeline prototype — previous screen" with its existing honest readiness list. The
  OpenRouter/OpenAI backend work is untouched.

### Content

Every question, answer, code sample and follow-up in `DemoInterviewFeed` is invented development
text about an invented service. The Context screenshot uses placeholder thumbnails the app draws
itself, behind a debug-only launch argument — never anyone's photos. No real interview, candidate,
employer or document is represented.
