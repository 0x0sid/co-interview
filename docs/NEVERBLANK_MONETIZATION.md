# Neverblank monetization — free preview, Pro, and access control

Status 2026-09-26. Code complete and tested locally; **not live** until the account setup below is done
and the backend is deployed. Nothing here has been verified against Apple's sandbox yet.

## The rule

A paid request (question detection, a focused decision, an answer) is served when:

**authenticated installation AND (active `pro` entitlement OR free-preview allowance left)**

The backend (`backend/access.mjs`) enforces it on every paid route. The app (`prompter/Access/`) uses
the same rule to decide what to offer, and never unlocks anything on its own say-so.

## Identity

- `POST /v1/installations` issues an installation id, a random secret (stored hashed server-side) and
  the RevenueCat app user id `nb_<installation id>`. The app keeps them in the Keychain.
- Every request carries `Authorization: Installation <id>.<secret>`. The server looks entitlement up
  for the app user id **it** bound to that installation, so a client cannot claim another customer.
- RevenueCat is configured with that id (`EntitlementService.configure(appUserID:)`, or `logIn` on the
  first launch once the id is issued).
- Keychain items often survive a reinstall, but iOS does not promise it. A lost credential means a new
  installation and a new preview (bounded by the server caps and the per-address install throttle); a
  subscriber gets access back through **Restore Purchases**, which transfers the purchase to the new id
  — this needs the project's restore behaviour set to *Transfer to new App User ID* (below).
- Release builds never carry a bearer token. Operator tokens (`COINTERVIEW_TOKENS`) remain for
  development and evaluation only.

## Free preview

- 30 seconds of Live **listening**, once per installation. Charged only while: the microphone is
  actually listening, the app is in the foreground, AI consent was given, answers are configured and
  no paywall is on screen (`InterviewScreen.previewConditionsMet`). Setup, permission prompts, the
  paywall and background time are never charged.
- Labelled as a free preview, not a subscription trial, on the start screen, in the consent sheet
  and on the Live screen (`AccessCopy`).
- At 30 s: an answer already accepted finishes (server grace 60 s for queued ones); detection stops;
  local transcription continues with a status line; the paywall opens **once** (recorded in the
  Keychain record `endPaywallShown`). The end is reported to the backend (`POST /v1/preview/end`).
- Pro users never touch the preview meter or the caps.

### Exact limits (code defaults; the backend reads them from the environment)

| Limit | Value | Where enforced | Env var |
| --- | --- | --- | --- |
| Listening time | 30 s of charged listening, once per installation | app (`FreePreviewMeter.allowance`) | — |
| Answers | 5 per installation | backend, atomic | `PREVIEW_MAX_ANSWERS` |
| Detections (classify + focused decisions) | 60 per installation | backend, atomic | `PREVIEW_MAX_DETECTIONS` |
| After the app reports the end | detections stop at once; an answer may still **start** for 60 s (one accepted before the end but queued) | backend | `PREVIEW_ANSWER_GRACE_MS` |
| Expiry | none — the preview does not lapse with calendar time, and never resets | — | — |

Whichever runs out first ends the preview. When the backend's caps end it before the 30 s, the next
answer is refused (402), the app shows the paywall once for that request, and `/v1/access` reports
the preview ended so the app's meter agrees. The user-facing text (`AccessCopy.previewDisclosure`)
says "30 seconds of Live listening, with question detection and up to 5 answers";
`AccessCopy.previewAnswerLimit` and the backend default are pinned together by
`backend/test/access-test.mjs`. The earlier plan proposed 3 answers; 5 was implemented so that a
30-second stretch with a couple of questions and a retry is not cut short — a one-line change if 3 is
preferred.

## Purchase continuity

- Generate without access creates the entry and freezes its snapshot exactly as usual, then **holds**
  it at the head of the queue and opens the paywall. After the backend confirms Pro
  (`verifyProAfterPurchase`, `GET /v1/access?refresh=1`, up to four attempts) it is sent **once**.
  Later speech is never substituted.
- Paywall closed without access: the entry stays with "Neverblank Pro is needed to write this answer."
  and its snapshot, so Retry re-sends the original.
- A paywall opened from the start screen ("See plans") never generates anything.
- The session (transcript, files, detected questions) is never reset by the paywall.

## Failure behaviour

- RevenueCat unreachable: the backend honours only a previously **verified, unexpired** expiry; with
  no verified history the answer is "not Pro". Cancelled auto-renew keeps the same expiry, so access
  continues until the paid period ends.
- Backend refuses (402 `pro_required`): the answer fails with the Pro message, Retry is kept, and the
  paywall is offered once for that request.

## Paywall

`NeverblankPaywallView`: headline "Never interview alone again.", supporting line, six benefit lines,
Monthly and Weekly at the **store's localized prices**, "BEST VALUE" and "Save N% compared with paying
weekly" only when `PlanSavings` finds a real saving in the same currency (rounded down), Continue,
"Cancel anytime.", auto-renewal terms, Restore Purchases, Terms and Privacy links. No urgency, fake
discounts, counts, ratings or testimonials. Without plans (no key, no offering) there is no Continue.

## Analytics

`POST /v1/events`, names and values from fixed lists only (`PRODUCT_EVENTS`, `sanitizeEvent`):
trial_started, trial_30s_consumed, paywall_viewed, weekly_selected, monthly_selected,
purchase_started, purchase_completed, purchase_failed, purchase_restored, paywall_dismissed; optional
`plan`, `trigger`, `reason`. Written as one log line; nothing else is stored.

**Disclosure findings (checked, not assumed):**
- Events require the installation credential; the event log line carries no installation id, address
  or content; the generic request log line carries a random request id, method, path, status, time.
- The access database stores, per installation: id, secret hash, app user id, created and
  **last-seen** timestamps (updated on every authenticated request, including events), preview
  counters, cached entitlement expiry. No interview content.
- Client addresses are held in memory for one hour for the install throttle, never written.
- Fly's platform may record client addresses at its edge, outside this code.
- RevenueCat holds the purchase history under the app user id.

**Recommendation:** declare *Product Interaction* and *Purchases* as collected and **linked to the
user** (a pseudonymous installation/app user id), not used for tracking — because last-seen activity
is stored against the same id that holds the purchase. Declare *User Content* (transcript text,
notes, file excerpts) as collected for app functionality, sent to third-party AI processors, not
linked beyond the request and not stored by the backend. Confirm against the final privacy policy.

## Plans and entitlement (decided 2026-09-26)

Weekly, Monthly, Yearly and Lifetime; entitlement **`neverblank_pro`** (app and backend). Plans are
recognised from the store product itself — a one-time product is Lifetime, a subscription by its
billing period — never from its package slot. "Best value" goes to the subscription the store's
prices make cheapest per week; savings are measured per week against the priciest subscription.

Test Store check (2026-09-26, Debug key `test_IazA…`): offering `default` loads, but its products
are misdefined — `yearly` is a **1-month** subscription and `lifetime` is a **1-year**
auto-renewing subscription; `weekly` does not exist. The paywall therefore shows Monthly $9.99 and,
truthfully, the `lifetime` product as a Yearly plan at $79.99.

## Account setup still needed (one list)

1. **RevenueCat — project "Neverblank"** (separate from cine; nothing in cine is used or changed).
   - App Store app, bundle id `talk.cointerview`, with the App Store Connect In-App Purchase key.
   - A Test Store app in the same project (implementation testing only).
   - Entitlement `pro`; products attached to it.
   - Offering `default` (current) with packages `$rc_weekly` and `$rc_monthly`.
   - Project settings → Restore behaviour: **Transfer to new App User ID**.
2. **App Store Connect** — auto-renewable subscription group "Neverblank Pro" (Weekly, Monthly,
   Yearly); **Lifetime is a separate non-consumable In-App Purchase, outside the group**. First
   milestone: Monthly only, end to end (sandbox purchase → backend Pro → Generate), same-device
   Restore; new-identity Restore on a second device stays a separate open check. Earlier wording:
   `talk.cointerview.pro.weekly` (1 week) and `talk.cointerview.pro.monthly` (1 month), unless other
   ids are already registered. **Prices to be confirmed by the owner before creation** (proposed
   $5.99/week and $12.99/month). No introductory offer. Paid Applications agreement active.
3. **Keys to hand over**
   - RevenueCat **public** App Store SDK key (`appl_…`) → build setting `REVENUECAT_PUBLIC_KEY` for
     Release (Release refuses `test_` keys by construction).
   - RevenueCat **Test Store** public key (`test_…`) for the Neverblank project → `Local-Debug.xcconfig`.
   - RevenueCat **secret** key for the Neverblank project (v1 subscriber read) → Fly secret
     `REVENUECAT_SECRET_KEY` and `backend/.env`; never committed. The key currently in `backend/.env`
     belongs to cine and has been disabled there.
4. **Legal URLs** — Terms of Use and Privacy Policy (https) → build settings `NEVERBLANK_TERMS_URL`,
   `NEVERBLANK_PRIVACY_URL` (both configurations, in the project); also in App Store Connect metadata.
   On 2026-09-26 every path on https://neverblank.io returned 404, including `/`, `/terms` and
   `/privacy`: the pages have to be published first.
5. **Fly** — the app has two machines (one stopped standby). SQLite on the volume needs exactly one:
   remove the stopped standby (`flyctl machine destroy 8e4359c77219e8 -a backend--d7y3w`, owner's
   decision), then deploy from the mirror. Volume `neverblank_data` (1 GB, ams) already exists.
6. **Apple sandbox tester** account for the purchase and restore verification.

## Verified so far

- Backend: `node test/access-test.mjs` — 52 checks: credentials, throttle, atomic preview caps under
  10 simultaneous requests, grace window, Pro never limited, cache, fail-closed, RevenueCat parsing,
  event sanitising, and the HTTP contract across a real process restart on the same database file.
  All six backend suites pass, in the app repo and the mirror.
- iOS unit tests: 31 new (preview meter, savings, Release configuration, access transitions, held
  requests); full unit suite 429 tests, all passing after aligning one plist guard test.
- UI, end to end against a local backend in fake-provider mode (`FreePreviewFlowUITests`): fresh
  install → credential → disclosure → consent → 30 s preview → paywall once → session intact →
  Generate offers Pro and keeps the request → paywall does not reopen. Backend log confirmed no
  detection or answer request after the preview ended.
- Release simulator build succeeds and opens Neverblank directly.
- Release **device archive** (2026-09-26) builds and signs for team `P9Q6984LRS` (development identity):
  `CopilotBackendURL` is the Fly URL; no development host/token or ATS exception; no Debug harness,
  reset hook, scripted speech or Test Store key in the binary; RevenueCat key and legal URLs empty.

## Not verified yet

- Any purchase, restore, renewal, cancellation or expiry through RevenueCat or Apple — blocked on the
  account setup above. Test Store runs will not be treated as proof that Apple purchases work.
- The deployed backend: the access release is not on Fly yet (item 5).
- A Release build on a device.
