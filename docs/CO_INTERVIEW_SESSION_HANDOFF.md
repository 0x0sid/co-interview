# Handoff — 2026-09-24

Written so the next person, on a different machine or a different account, can pick this up without
the chat history. **The session transcript does not travel**: it is a local file on one Mac, readable
only by its owner. This document and the two repositories are the handoff.

## Where everything is

| | |
| --- | --- |
| App | `github.com/0x0sid/co-interview`, branch `main`, at **`2810956`** |
| Backend (standalone, deployed from) | `github.com/0x0sid/backend` (private), `main`, at **`a7b700b`** |
| Backend source of truth | `backend/` **in the app repo** — the standalone repo is a mirror. Sync rules: [`CO_INTERVIEW_HOSTING.md`](CO_INTERVIEW_HOSTING.md) |
| Hosted service | Fly app `backend--d7y3w`, region `ams`, **https://backend--d7y3w.fly.dev** |
| Owner-tested build | tag `owner-device-tested-2026-09-21` on `9a0f1d0` |

Both working trees were clean and fully pushed at the time of writing.

## State of the deployment

Healthy and verified from the terminal on 2026-09-21 and again on 2026-09-24:

- `/health` → `200`, `provider: configured`, `auth: configured`, `openrouter` / `balanced`
- authenticated `/v1/copilot/config` → `google/gemini-2.5-flash-lite`, route `google-ai-studio`
- no token / wrong token → `401` on both answer and config
- streamed generation: first text **603–802 ms**, complete **1052–1498 ms**, multiple delta events
- cancellation mid-stream leaves the machine healthy

Two faults were fixed to get there, both configuration rather than code: Fly Launch's generated
`fly.toml` (wrong `internal_port`, no `[env]`, `min_machines_running = 0`) and **no public IP ever
allocated**, which is why the hostname did not resolve. See `CO_INTERVIEW_HOSTING.md`.

`flyctl` auth is per-user: a new operator runs `flyctl auth login` before anything else.

## What the last increment delivered

**Answer presentation** — readable cards, keyword emphasis, contextual follow-up actions.

- `AnswerKeywords` marks the phrases an answer turns on: identifiers, acronyms, versions, quantities
  with units, multi-word proper nouns, defined terms, quoted phrases. Emphasis is **weight only**,
  never colour — colour already means "you have said this" (the reading fade), and the two compose.
- `FollowUpActions` offers up to three chips under a finished answer, chosen from what the answer
  contains: explain the code, give an example, go deeper *or* make it shorter (never both).
- A tapped chip is **not speech**. It never enters the transcript, and it reserves no spoken line as
  answered — speech that arrived while the reader was browsing is still waiting for the next
  ordinary Generate.
- A chip **belongs to its page**. The request carries that page's question, answer text and version,
  and the prompt tells the model to apply the action there rather than following the newest topic.
  Verified against the live service: an action on an older lambda answer, with a more recent
  "tell me about my last project" in the conversation, correctly returned a lambda example.

## Outstanding

| Item | State |
| --- | --- |
| **iPhone install** | **Blocked.** `devicectl` reports `available (paired)` but every `xcodebuild` device build fails: *"Ensure the device is unlocked and attached with a cable… previously reported preparation errors."* Unlock the phone, connect by cable, then build and install — do **not** uninstall or erase data |
| Dark-mode screenshots | Not captured. Light ones are verified. Boot the simulator, `xcrun simctl ui <udid> appearance dark`, then run `testCaptureAnswerKeywordsAndFollowUpActions` with `CAPTURE_SUFFIX=dark`. The appearance command fails if the simulator is shut down — boot it first |
| Full regression suite | Not run since the last three commits. Focused suites all pass (below) |

## Test state

- `prompterTests/AnswerPresentationTests` — **22 passed**
- `prompterTests` (full unit suite, one commit earlier) — **322 passed**
- Backend, all four suites — **passed**, including six contract checks for the tapped action
- `InterviewScreenCaptureTests` — 4/5 in one class run, and the fifth passes in isolation after its
  scroll fix; not yet re-run as a class

### Known failure, inherited and unrelated

`prompterUITests.prompterUITests.testCaptureBarePromptScreen` fails, and failed before any of this
work (verified at `ee06061`). It looks for `app.images["debugMenuButton"]`, an accessibility
identifier that no longer exists anywhere in the app. Fixing it means touching Prompter's UI, which
is out of bounds. **The suite is therefore not entirely green, and that is why.**

## Known product issues, deliberately not fixed

- **Factual accuracy is 6/8** on the context evaluation. J1 and J2 credit Java 9 with local-variable
  type inference; `var` is Java 10 (JEP 286 `Release: 10`). Systematic across runs on the default
  profile, absent in the French equivalent. Recorded in `docs/evidence/context-handling/`. Not
  patched into the prompt: hardcoding one date would make the evaluation self-confirming.
- **A comparison whose two sides transcribe identically** still fails most of the time on the default
  profile — `docs/evidence/answer-quality/`.
- **`COINTERVIEW_TOKENS` is still the documented placeholder** (`replace-with-a-random-token`, public
  in `config.example.env`). Survivable behind an ad-hoc tunnel; **not** survivable on a public hosted
  URL. Rotate it in Fly secrets and in `prompter/Config/Local-Debug.xcconfig` together.

## Not started

Neither of the remaining increments has any code:

1. **RevenueCat** — `prompter/Billing/` exists but is *inherited Prompter scaffolding*, wired into
   Prompter's own surfaces, and explicitly not a Co-Interview requirement (`CO_INTERVIEW_DECISIONS.md`).
   `BillingConfiguration` returns nil without a key.
2. **Jev question/context decision layer** — nothing at all; searched and confirmed.

## Local things that do not travel

- `backend/.env` and `prompter/Config/Local-Debug.xcconfig` are git-ignored and hold the real
  credentials. A new machine needs both recreated from `config.example.env` and
  `Local-Debug.example.xcconfig`.
- The ngrok tunnel and local backend used before Fly. The app now points at the Fly hostname via
  `COPILOT_DEV_BACKEND_HOST`; rollback instructions are in `CO_INTERVIEW_HOSTING.md`.
- The session transcript, and the in-memory Generate diagnostics (`docs/evidence/diagnostics/`).
