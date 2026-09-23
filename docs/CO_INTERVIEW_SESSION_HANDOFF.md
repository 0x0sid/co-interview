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
| **iPhone install** | **Blocked by iOS, not signing.** The installed copy was signed by `HKRALWACQ8`; iOS refuses a cross-team upgrade (`MismatchedApplicationIdentifierEntitlement`). Installing requires removing it, which deletes its data. A read-only copy of its data container's store is at `/Users/sid/Desktop/cointerview-device-backup-2026-09-24/` (`CoInterview.store` + `-wal` + `-shm`). **Restoration is unverified**: the three files are a copy of the SwiftData store, not a tested backup, and nothing has been restored from them. Removal is the owner's decision (not yet authorised); after it, restore would be `xcrun devicectl device copy to --domain-type appDataContainer --domain-identifier talk.cointerview` into `Library/Application Support/` before first launch, then check the data in the app |
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
