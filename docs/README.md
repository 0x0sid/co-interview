# Neverblank — start here

Neverblank is an iPhone interview copilot. While Live is on it transcribes the conversation on the
device; when the user taps Generate it writes a suggested answer from the conversation and the user's
notes and files, through Neverblank's backend. A few answers are free; Neverblank Pro is a subscription.

## Status (2026-10-11)

**1.2 (build 1) was submitted to App Review** on 2026-10-01 (commit `a0978ba`); App Store Connect has
its current status. **`main` is version 1.4** (set 2026-10-11; commit `072681c` says 1.3 in its message, but
carries 1.4).

**Since 1.2** ([`AI_PIPELINE.md`](AI_PIPELINE.md) §19–20):
- answers lead with a highlighted answer and never repeat the question — **live** (Fly v20, 2026-10-11);
- answer instead of asking, `**bold**` shown as a highlight, and the `smart` profile — pushed to the
  mirror, **live after the next `flyctl deploy -a backend--d7y3w`**;
- in the next app release (1.4 on `main`): highlight colour setting (Blue default, Yellow, Pink, Off), the logo launch screen, and the
  app-side bold fallback.

| | |
| --- | --- |
| App name / bundle id | **Neverblank** / **`io.neverblank.app`**, team `P9Q6984LRS` |
| Internal names | Xcode project `co-interview.xcodeproj`; app target and Swift module **`neverblank`** (renamed from `prompter` 2026-10-11; the source folders and test targets keep the `prompter` names); local store `CoInterview.store` |
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
