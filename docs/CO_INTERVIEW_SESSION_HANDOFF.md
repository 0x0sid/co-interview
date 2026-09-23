# Handoff — 2026-09-24 (Jev shadow increment)

Written so the next person, on a different machine or a different account, can pick this up without
the chat history. **The session transcript does not travel**: it is a local file on one Mac, readable
only by its owner. This document and the two repositories are the handoff.

## Identity — do not restore the old configuration

| | |
| --- | --- |
| App name (user-facing) | **Neverblank** — `CFBundleDisplayName` in both `Info.plist` files, and the app name in the permission prompts |
| Website | **neverblank.io** |
| Apple team | **`P9Q6984LRS`** on **every** target. `HKRALWACQ8` is the retired old team: never restore it, never use it as a temporary override |
| Bundle id | `talk.cointerview` — unchanged; provisions under `P9Q6984LRS` via Xcode's managed wildcard profile (checked 2026-09-24) |
| Internal names | Repository, scheme `Co-Interview`, targets, store `CoInterview.store`, backend endpoint — **deliberately unchanged**. A broad rename is its own increment |

## Where everything is

| | |
| --- | --- |
| App | `github.com/0x0sid/co-interview`, branch `main` |
| Canonical checkout | `/Users/sidousan/Desktop/co-interview-public` (macOS user `sidousan`) |
| Backend source of truth | `backend/` in the app repo |
| Deployment mirror | `/Users/sidousan/Desktop/prompter-backend` → `github.com/0x0sid/backend` (private). Sync rules: [`CO_INTERVIEW_HOSTING.md`](CO_INTERVIEW_HOSTING.md) |
| Hosted service | Fly app `backend--d7y3w`, region `ams`, **https://backend--d7y3w.fly.dev**, deployed with `flyctl deploy` from the mirror (no CI) |
| Old remote | `VRAM-AI/prompter-backend` is historical; neither checkout's remotes point at it |

**Two macOS accounts share this Mac.** `sidousan` owns the canonical checkouts; an ACL gives `sid`
write access. `sid` has its own separate clone at `/Users/sid/Desktop/co-interview-public`, which
holds an **unpushed local commit `ae0eef0`** (the team change only, message "first push from yanis…").
The same change is now on `main`; that clone can be reset to `origin/main` by its owner — nothing did
it automatically. Git on the `sidousan` checkouts, run as `sid`, needs `-c safe.directory=*`, and
`rsync -a` into the mirror reports harmless "utimensat" errors for files `sid` does not own (verify
with `rsync -rl --checksum -n -i`). `flyctl` and SSH credentials are per-user; as `sid`, pushes go over
HTTPS through `gh`.

## What this increment delivered

**Jev (TypeSafe) typed decisions, in shadow** — pipeline doc §15.

- `backend/providers/typesafe.mjs`: HTTP adapter. Default transport is **OpenRouter's Decisions API**
  (`POST https://openrouter.ai/api/alpha/decisions`) with the existing `OPENROUTER_API_KEY` — no
  TypeSafe account; model pinned to `typesafe/jev-1.13-20260917`. TypeSafe's own endpoint remains as
  an option. Deadline, one retry on 408/429/5xx/524/529, every error an explicit fallback, never throws.
- `backend/decisions.mjs`: three independent questions (role of the newest speech, parent question,
  answer need) plus a transcription-ambiguity Noul; `off` / `shadow` / `active`; bounded concurrency,
  latest-wins per session, obsolete/stale/dropped records; metadata-only logs.
- Classification responses are unchanged; shadow runs after the response is written. Generate and
  answer streaming never touch it. Answer requests are never filtered by Jev's focused input.
- The app sends, with each classification, session id, snapshot id, utterance ids and revisions, and a
  generation count (all optional). The diagnostics export gains "Decision comparisons (shadow)".
- `backend/eval/decisions/`: 66 synthetic labelled cases (EN 36 / FR 30; 14 tuning / 52 held-out),
  metrics, and an answer-request completeness check.
- Display name Neverblank; team `P9Q6984LRS` on every target.

## Deployed state (verified 2026-09-24)

| | |
| --- | --- |
| App commit | `ce13de1` on `0x0sid/co-interview` `main` (this handoff update follows it) |
| Mirror commit | `c9790c0` on `0x0sid/backend` `main` (authored as `sid <sid@MacBookPro-001.lan>` because the mirror had no git identity; now set to `0x0sid`, history not rewritten) |
| Fly | release **v7**, image `deployment-01M37TBG9Y3BAFYZAPJ1ND3C1Z`, `COPILOT_BACKEND_VERSION=fly-c9790c0` |
| Decisions on Fly | `/health` → `mode: shadow`, `transport: openrouter`, `model: typesafe/jev-1.13-20260917`, `key_configured: true`, `active_decisions: []` |
| End-to-end on Fly | authenticated classify returned the detector's verdict in 0.98 s; its shadow record completed ~2 s later (`status: ok`, agreement, `controlled_by: baseline`, no conversation text); the log line carries metadata only; unauthenticated diagnostics → 401 |

## Regression results

- Backend: all five suites pass (configuration, contract, OpenRouter, diagnostics, decisions), in the app
  repo and in the mirror.
- `prompterTests`, run alone: **332 tests in 43 suites passed** (344 in the result bundle, counting
  parameterised cases), 0 failed, 1 skipped (`aRealGenerateProducesAFullyPopulatedExport`, opt-in via
  `COINTERVIEW_LIVE_DIAGNOSTICS=1`). An earlier full run with backend suites competing for the CPU
  took 21 minutes and failed 27 tests, every one a 3-second `waitUntil` timeout; run alone the same
  tests pass in 55 s. **Run the iOS suites on an otherwise idle machine.**
- `prompterUITests`, run alone: **18 passed, 2 failed**. Both failures **reproduce on the baseline
  `0b912f7`** at the same lines (checked by running them on an extracted copy of that commit):
  - `testLiveStateIsReportedHonestlyWhenUnconfigured` — **fixed.** With no backend, a simulator that
    can listen shows "Start live (listening only)", enabled — the listen-only state `LiveReadiness`
    documents as intended. The test predated it and waited for "Start live". It now asserts, for
    whichever state the machine is in, that full answer-generating Live is never offered without a
    provider and that the reason is shown. Passes.
  - `testCaptureBarePromptScreen` — still failing, inherited (below).

## Phone (2026-09-24)

The old `talk.cointerview` install (team `HKRALWACQ8`, test data only) was removed with the owner's
authorisation and **Neverblank** installed: Debug build of `c35e924` (`GitCommitHash` in its
Info.plist), signed `P9Q6984LRS.talk.cointerview`, backend host `backend--d7y3w.fly.dev`. Prompter
(`talk.prompter`) was not touched.

**Restore: succeeded at the database level.** The backed-up `CoInterview.store` (+ WAL, SHM) was copied
into the new container before first launch. After launching, the store read back from the phone
passes `PRAGMA integrity_check` and still holds exactly the backed-up rows — one script with the
original UUID `EFEE56D8…D232` and creation time, one settings row — so the app opened it rather than
seeding a fresh one. The data was test data: the inherited sample script. The backup stays at
`/Users/sid/Desktop/cointerview-device-backup-2026-09-24/`.

Build note: as macOS user `sid`, the build-stamp script's `git` refuses the `sidousan` checkout and
stamps "unknown"; build with `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'`.

## Second phone test fixes (2026-09-24, evening)

Evidence: `docs/evidence/phone-2026-09-24/` — `phone-regressions-before.md` and `-after.md` (the real
provider's effective input, answer and timing per case) and `screens/` (the corrected build, real
backend, scripted speech).

| Reported | Cause found | Fix | State |
| --- | --- | --- | --- |
| Note "Secret: I love pizza" ignored | The note **did** reach the model; it answered as itself ("I cannot share personal information") because nothing said "you" meant the candidate | Rules and request labels now say who speaks and for whom the reply is written; the note is the candidate's own evidence, used exactly | 4/4 grounded in the final run, no added details |
| — | A request's note came from the live field, not its tap snapshot | `extraContext` now comes from the snapshot | unit-tested |
| "Java 10." reduced to 8 vs 10 | Not reproducible from any payload the transcript allows (all tap boundaries and a provisional last line: 12/12 in the final run). Most likely the transcript at the tap was still mid-revision | Rule: items stay in scope unless explicitly narrowed; the answer covers exactly what its title names | Turn on **Capture test content** in the next test so a repeat can be traced |
| Serif, oversized answer | — | Hanken Grotesk 21pt, Dynamic Type (`.title3`), 1.4 line height | screenshots |
| Gap under a short transcript | A scroll view given only a maximum takes all of it | Content-sized up to 168pt, then scrolls | screenshot |
| Backticks around `var` | — | Hidden in the rendered text only; speech tokens unchanged | unit-tested |
| Example/Go deeper under "no information" | — | The model marks `[needs: context|clarification]`; the page offers only **Add context**, which opens the note and sends nothing | unit- and screen-tested |

**Still open:** with no note, a personal question is now correctly flagged `needs: context`, but the
answer model (`google/gemini-2.5-flash-lite`) still words it as "I do not have a secret to share" — an
unsupported claim about the candidate. Three prompt variants did not remove it; one made other cases
worse and was reverted. Not fixed by switching models silently: that is a separate decision.

Real-provider UI capture (opt-in, billed): `TEST_RUNNER_COINTERVIEW_LIVE_UI=1 xcodebuild test …
-only-testing:prompterUITests/LiveProviderCaptureTests`. It drives Live with `-LiveScriptedSpeech`.

## Continuation contract (2026-09-24, midday)

Backend-only: an addition is answered first, with its parent as context (pipeline §18, last part).
The phone keeps app `7db02bd`. Jev stays in shadow.

## Focused Jev decisions, in shadow (2026-09-24, late morning)

See pipeline §18. **Fly: `COPILOT_DECISION_MODE = "shadow"`, session opt-in unset.** Rollback: set
`"off"` in the mirror's `fly.toml` and deploy. Limited-active for one session needs
`COPILOT_DECISION_SESSION_OPT_IN = "1"` *and* the app's Debug toggle "Apply Jev decisions" — not
enabled, because on the frozen held-out dialogues the decisions were accurate (relation 100%,
accepted 100% correct) but answers did not improve (A 83/86, C 81/86).

Also fixed: lines finalized after partial results never reached the screen as final, so requests
dropped them unless they were the newest line (`FinalizedPartialTests`).

Evidence: `docs/evidence/decisions-focused-2026-09-24/` (captured requests, per-tap decisions and
answers). Dialogues: `backend/eval/dialogues/{dev,heldout,regression}` — held-out frozen in `f528f45`;
it has now been used once, so new prompt wording needs **new** held-out dialogues.

## Latest-request priority (2026-09-24, morning)

See pipeline §17. **Jev is OFF on Fly** for the owner's comparison test: `COPILOT_DECISION_MODE = "off"`
in the mirror's `fly.toml`; to restore shadow, set `"shadow"` and deploy. Off and shadow were shown
byte-identical in what the app receives and what the models are sent (`decisions-test`).

Still limited: "the latest version of Angular" was stated as "Angular 17" in 1 of 8 final runs, and the
Angular 1-vs-2 answer once called version 1 the rewrite — this answer model's knowledge, not the
request. `[ClockAudit]` lines now carry a recognizer id and start time, so interleaved timelines can
be told apart next time; no duplicate recognizer was found in the code, and none is assumed.

## Evaluation — what is and is not known

Held-out (52 synthetic cases), real calls on both sides, identical snapshots — pipeline §15:

| | Existing detector | Jev (8 s deadline) |
| --- | --- | --- |
| Question precision / recall | 100% / 94.7% | 100% / 100% |
| Grouping (parent) | 91.2% | 100% |
| Lost / duplicate | 2 / 0 | 0 / 0 |
| Latency median / p95 | 663 / 752 ms | 362 / 1577 ms (max 6.0 s) |

Jev fixed both of the detector's losses ("simple maine in Java", "En Java.") with no new one. Its
latency is bimodal and provider-side; a first run with a 2.5 s deadline timed out on 9.6% of calls.
**This supports continuing shadow on real sessions, not activation**: the cases are few, synthetic and
labelled by one author, and active mode's 1.2 s deadline would fall back often. Evidence:
`docs/evidence/decisions/`. Re-run: start the backend locally with the real `.env`, then
`npm run eval:decisions -- --split heldout --base http://127.0.0.1:8787 --token <token> --out ../docs/evidence/decisions`.

## Outstanding

| Item | State |
| --- | --- |
| ~~iPhone install~~ | **Done 2026-09-24** — see "Phone" below. Previously: blocked by iOS, not signing. The installed copy was signed by `HKRALWACQ8`; iOS refuses a cross-team upgrade (`MismatchedApplicationIdentifierEntitlement`). Installing requires removing it, which deletes its data. A read-only copy of its data container's store is at `/Users/sid/Desktop/cointerview-device-backup-2026-09-24/` (`CoInterview.store` + `-wal` + `-shm`). **Restoration is unverified**: the three files are a copy of the SwiftData store, not a tested backup, and nothing has been restored from them. Removal is the owner's decision (not yet authorised); after it, restore would be `xcrun devicectl device copy to --domain-type appDataContainer --domain-identifier talk.cointerview` into `Library/Application Support/` before first launch, then check the data in the app |
| Dark-mode screenshots | Not captured (deliberately not resumed) |
| `COINTERVIEW_TOKENS` | Still the documented placeholder in some local configs; rotate on Fly and in `Local-Debug.xcconfig` together |

### Known failure, inherited and unrelated

`prompterUITests.prompterUITests.testCaptureBarePromptScreen` fails, and failed before this work: it
looks for `app.images["debugMenuButton"]`, an identifier that no longer exists.

## Known product issues, deliberately not fixed

- **Factual accuracy**: `var` credited to Java 9 (it is Java 10, JEP 286) on the default profile.
  Answer-model behaviour; untouched by the decision layer. `docs/evidence/context-handling/`.
- **Identical-sounding comparisons** still fail most of the time — `docs/evidence/answer-quality/`.

## Not started

RevenueCat (explicitly out of scope). Any Jev activation — only after shadow records from real sessions confirm the held-out result and the latency tail fits a deadline.

## Local things that do not travel

- `backend/.env` and `prompter/Config/Local-Debug.xcconfig` (git-ignored, real credentials).
- The device data backup above.
- The session transcript.
