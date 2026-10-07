# Neverblank — start here

Neverblank is an iPhone interview copilot. While Live is on it transcribes the conversation on the
device; when the user taps Generate it writes a suggested answer from the conversation and the user's
notes and files, through Neverblank's backend. A few answers are free; Neverblank Pro is a subscription.

## Status (2026-10-07)

**1.2 (build 1) is in App Store review.** Archived 2026-10-01 with the *Neverblank (App Store billing)*
scheme; commit `a0978ba` is the reviewed code.

**Since 1.2 — answers lead with a highlighted answer** ([`AI_PIPELINE.md`](AI_PIPELINE.md) §19):
- the backend prompt (highlight the answer itself, never repeat the question) is pushed to the
  mirror (`0x0sid/backend` `2cf82fd`) but **not deployed** — `flyctl deploy -a backend--d7y3w` from the
  mirror puts it live, also for 1.2 users;
- the new highlight colours (yellow in light, aqua-mint in dark) are in the app and ship with the
  next version after 1.2.

| | |
| --- | --- |
| App name / bundle id | **Neverblank** / **`io.neverblank.app`**, team `P9Q6984LRS` |
| Internal names | Xcode project `co-interview.xcodeproj`, app target and module **`prompter`**, local store `CoInterview.store`. Kept on purpose — do not rename |
| Repository | `/Users/sidousan/Desktop/co-interview-public` → `github.com/0x0sid/co-interview` (**public**: no secret, key or personal data may be committed) |
| Backend | `backend/` here is the source; deployed from the mirror `/Users/sidousan/Desktop/prompter-backend` (`0x0sid/backend`, private) to Fly app **`backend--d7y3w`** — see [`HOSTING.md`](HOSTING.md) |
| Billing | RevenueCat project *Neverblank*, entitlement **`neverblank_pro`**, products **`io.neverblank.pro.monthly`** and **`io.neverblank.pro.yearly`**, offering `default` — see [`BILLING.md`](BILLING.md) |
| Website | `https://www.neverblank.io` — `/terms`, `/privacy`, `/support` (live; linked from the paywall and Settings) |
| Platform | iOS 26.0, Swift 6.0, Xcode 26 |

## Documents

| Document | Owns |
| --- | --- |
| [`DEVELOPMENT.md`](DEVELOPMENT.md) | Schemes and billing modes, configuration files, building, testing on the phone, release builds, troubleshooting |
| [`BILLING.md`](BILLING.md) | Access rule, identity, free answers, plans, paywall states, refresh rules, Sandbox testing |
| [`HOSTING.md`](HOSTING.md) | Backend mirror, Fly deployment, secrets, health checks, open security item |
| [`AI_PIPELINE.md`](AI_PIPELINE.md) | Detection and answer pipeline, providers, routing, streaming, measurements |
| [`APP_REVIEW.md`](APP_REVIEW.md) | App Review notes for App Store Connect |
| [`DECISIONS.md`](DECISIONS.md) | Dated record of what was decided and why |
| [`prompter/`](prompter/README.md) | Inherited Prompter reference, cited by the reused reader and matching code |
| `evidence/` | Measurements and captures that the documents above cite |

Each subject has one owner above; other documents link to it rather than repeat it.
