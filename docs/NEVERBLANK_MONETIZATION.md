# Neverblank monetization — 2 free AI answers, Pro, and access control

Status 2026-09-27. **Two free AI answers replace the 30-second listening preview** (superseded; no
listening-time limit remains). Code complete and tested locally; the backend release that enforces it
is **not deployed yet**, and nothing has been verified against Apple's sandbox.

## The rule

A paid request (question detection, a focused decision, an answer) is served when:

**authenticated installation AND (active `neverblank_pro` entitlement OR free answers left)**

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
  installation and new free answers (bounded by the per-address install throttle); a
  subscriber gets access back through **Restore Purchases**, which transfers the purchase to the new id
  — this needs the project's restore behaviour set to *Transfer to new App User ID* (below).
- Release builds never carry a bearer token. Operator tokens (`COINTERVIEW_TOKENS`) remain for
  development and evaluation only.

## 2 free AI answers

- A free installation gets **2 successful AI answers in total** — across sessions and launches. Not a
  daily allowance, not an App Store introductory trial, nothing charged.
- The app shows "2 free answers remaining", then "1 free answer remaining". The second answer finishes
  and stays readable; an inline **Unlock Pro** appears with it — never a modal over it. The **third
  Generate opens the paywall before any AI request is sent**, keeping that request's snapshot.
- After the allowance: history, files and on-device transcription keep working; question detection and
  focused decisions stop for free users. Subscription › View plans is always available.

### Counting (backend ledger, per installation)

| Case | Effect |
| --- | --- |
| Completed answer with text (prose or code) | consumes 1 |
| Failed stream, empty response, clarification-only or context-request response | consumes nothing |
| Client disconnects after answer text was sent | consumes 1 (it received an answer) |
| Client disconnects before any text | consumes nothing |
| Retry of the same generation (same `generationKey`, kept with the snapshot) | not charged again; at most 3 deliveries of one key |
| Regenerate, follow-up action | a new generation: uses the allowance |
| Simultaneous taps | capacity is reserved atomically; never more than 2 |
| Pro request | never touches the counters |

Bounded abuse control: after 10 unsuccessful free attempts (failures, empty, clarification-only) no more
free answers are served; free detection is capped at 300 calls; a reservation left by a crashed stream
stops holding capacity after 3 minutes. Env: `FREE_ANSWERS`, `FREE_MAX_UNCOUNTED`,
`FREE_MAX_DETECTIONS`, `FREE_REDELIVERIES`, `FREE_RESERVATION_TTL_MS`.

### Migration from the 30-second preview

Applied once, when the new backend first opens the database (`AccessStore.migrate`):
- a preview that had **ended** counts as the allowance used (`free_used = 2`);
- otherwise `free_used = min(answers already received, 2)` — nothing is given back;
- entitlements are untouched; migrated rows are marked `migrated_from = 'preview-30s'`.

Production had one installation at the time (the owner's phone, Pro, preview unused), which keeps Pro.
Older app builds calling `POST /v1/preview/end` get the current allowance and change nothing.

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
- Backend refuses (402 `pro_required`, reason `exhausted` or `too_many_unsuccessful`): the answer fails
  with the Pro message, Retry is kept, and the paywall is offered once for that request.

## Paywall

`NeverblankPaywallView`: headline "Never interview alone again.", supporting line, six benefit lines,
Monthly and Weekly at the **store's localized prices**, "BEST VALUE" and "Save N% compared with paying
weekly" only when `PlanSavings` finds a real saving in the same currency (rounded down), Continue,
"Cancel anytime.", auto-renewal terms, Restore Purchases, Terms and Privacy links. No urgency, fake
discounts, counts, ratings or testimonials. Without plans (no key, no offering) there is no Continue.

## Analytics

`POST /v1/events`, names and values from fixed lists only (`PRODUCT_EVENTS`, `sanitizeEvent`):
trial_started (first free answer used), free_answers_exhausted, paywall_viewed, weekly_selected, monthly_selected,
purchase_started, purchase_completed, purchase_failed, purchase_restored, paywall_dismissed; optional
`plan`, `trigger`, `reason`. Written as one log line; nothing else is stored.

**Disclosure findings (checked, not assumed):**
- Events require the installation credential; the event log line carries no installation id, address
  or content; the generic request log line carries a random request id, method, path, status, time.
- The access database stores, per installation: id, secret hash, app user id, created and
  **last-seen** timestamps (updated on every authenticated request, including events), free-answer
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

- Earlier (2026-09-26, still valid): existing-subscriber Test Store flow on the owner's phone —
  registration, RevenueCat identity merge, backend-verified `neverblank_pro`, Generate before and after
  a home-screen relaunch (authentication evidence indirect: installation last-seen, not per request).
- Two free answers (2026-09-27, local backend in fake-provider mode, fresh test identities):
  - `backend/test/access-test.mjs`: two answers then refusal, 10 simultaneous taps reserve exactly two,
    failures/empty/clarification do not count, code-only counts, retry not charged twice and bounded,
    disconnect rules, abuse cap, stale reservations, detection stops, Pro never counts, migration rules,
    persistence across a real restart, request log lines (auth, basis, outcome, credit). All six
    backend suites pass.
  - iOS focused suites (84 tests): free-answer controller, third Generate held without a request, rapid
    taps, empty/clarification not counted, Release configuration.
  - `FreeAnswersFlowUITests` (twice): disclosure → consent → "2 remaining" → "1 remaining" → "Free
    answers used" with inline Unlock Pro (no modal) → third Generate opens the paywall; the backend log
    shows exactly two answer requests, both `free_credit=consumed`, and no third → relaunch keeps the
    allowance.
  - Release simulator build: opens Neverblank; no Demo, Developer section, Prompter home, debug menu,
    reset hook or scripted speech in the binary.

## Not verified yet

- Any purchase, restore, renewal, cancellation or expiry through RevenueCat or Apple — blocked on the
  account setup above. Test Store runs will not be treated as proof that Apple purchases work.
- The deployed backend: the access release is not on Fly yet (item 5).
- A Release build on a device.
