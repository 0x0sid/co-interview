# Billing and access

## The rule

A paid request (question detection, a focused decision, an answer, an interview review) is served when:

**authenticated installation AND (active `neverblank_pro` entitlement OR free answers left)**

The backend (`backend/access.mjs`) enforces it on every paid route. The app (`prompter/Access/`,
`prompter/Billing/EntitlementService.swift`) applies the same rule to decide what to offer, and never
unlocks anything on its own say-so.

## RevenueCat and App Store Connect

| | |
| --- | --- |
| RevenueCat project | *Neverblank*, with an App Store app (`io.neverblank.app`) and a Test Store app |
| Entitlement | **`neverblank_pro`** (app and backend) |
| Products | **`io.neverblank.pro.monthly`**, **`io.neverblank.pro.yearly`** — one auto-renewable subscription group |
| Offering | `default`, packages `$rc_monthly` and `$rc_annual` |
| Keys | App Store `appl_…` → Release; Test Store `test_…` → Debug (see [`DEVELOPMENT.md`](DEVELOPMENT.md)); backend verification on Fly → see [`HOSTING.md`](HOSTING.md) (currently the public key, `REVENUECAT_VERIFY_KEY`) |

Plans are recognised from the store product itself (its billing period, or one-time for Lifetime),
never from the package slot. The code also handles Weekly and Lifetime; the offering does not sell them.

## Identity

- `POST /v1/installations` issues an installation id, a random secret (stored hashed) and the RevenueCat
  App User ID **`nb_<installation id>`**. The app never chooses its own identity.
- The credential lives in the **Keychain** (service `io.neverblank.access`, account `installation`,
  after-first-unlock, not synchronised). **It survives deleting and reinstalling the app**, so a
  reinstall comes back as the same `nb_…` customer with the same purchases. iOS does not promise this;
  if the credential is lost, the app registers again and Restore Purchases brings Pro back.
- Every request carries `Authorization: Installation <id>.<secret>`. The backend checks entitlement
  for the id **it** bound to that installation, so a client cannot point the check at another customer.
- RevenueCat is configured with that id (`configure(appUserID:)`, or `logIn` on the very first launch).
- The id is random and server-issued; nobody can guess or pick one. The only way to inherit someone
  else's active subscription is to be on their un-erased iPhone (or a restore of its backup) with a
  different Apple Account — until that subscription expires.

## Free answers

- A new installation gets **3 free AI answers in total** (`FREE_ANSWERS`, app `FreeAnswersRecord.limit`) —
  not per day, not an App Store trial, nothing charged.
- One credit per answered question: Retry, Regenerate and follow-ups on the same answer page reuse its
  generation key and are not charged again. Failed, empty and clarification-only answers cost nothing;
  an answer whose text reached the client counts even if it then disconnected.
- Capacity is reserved atomically before the model is called, so simultaneous taps cannot exceed the
  limit. Abuse bounds: `FREE_MAX_UNCOUNTED`, `FREE_MAX_DETECTIONS`, `FREE_REDELIVERIES`,
  `FREE_RESERVATION_TTL_MS`.
- When they are used up, a new question opens the paywall **once** per installation, before any request
  is sent; after that an inline Upgrade is shown instead. History, files and on-device transcription
  keep working.

## Purchase continuity

A Generate without access keeps its entry and snapshot, opens the paywall, and is sent **once** after
the **backend** confirms Pro (`verifyProAfterPurchase`). Closing the paywall leaves the entry with
Retry. The session is never reset by the paywall.

## Paywall states

`NeverblankPaywallView`, from RevenueCat CustomerInfo through `EntitlementService.planAvailability`
and `EntitlementService.paywallAction`:

| State | Plans | Main button |
| --- | --- | --- |
| Never subscribed, or expired (entitlement inactive) | all selectable | **Become Pro** |
| Monthly active | Monthly "Current plan"; Yearly "Upgrade", preselected | **Upgrade to Yearly**, plus Manage subscription |
| Yearly active | Yearly "Current plan"; Monthly dimmed ("Change in Apple subscriptions") | **Manage subscription** |
| Active on a product the offering does not contain | none selectable | **Manage subscription** |

- The current plan is the offered product whose id **equals** the entitlement's `productIdentifier`.
  There is no fallback.
- A purchase is never started for the product the active entitlement already comes from.
- "Renew" is never shown; an inactive user is a new customer.
- The page always shows Restore Purchases, Terms of Use, Privacy Policy, Support and the auto-renewal
  terms. Prices are the store's localized prices; no badges, discounts or urgency. When nothing is
  current, the plan the prices make cheapest per week is preselected.
- Settings › Subscription shows Become Pro (free or expired) or the plan, its renewal or end date and
  Manage subscription (active).

## Refresh rules

RevenueCat's cached CustomerInfo judges "active" against the time it was fetched, so a cached plan
stays "active" after it changed or ended until the app fetches again. **Every refresh therefore fetches
from the server** (`invalidateCustomerInfoCache()` then `customerInfo(fetchPolicy: .fetchCurrent)`):

- at launch, when the paywall opens, and when the app returns to the foreground;
- before and after every purchase attempt, whatever the outcome;
- when Apple's subscription sheet closes, and again 5 seconds later;
- at the active entitlement's expiry while the paywall is open.

A failed fetch keeps the known state; it never downgrades on a network error.

## Sandbox testing

- Use a **Release** build (App Store billing scheme). Debug is the Test Store.
- Sandbox periods are short: a month is about 5 minutes and a year about an hour at the default rate.
- A Monthly → Yearly change made in Apple's subscription settings took effect **at the next renewal**
  (observed 2026-09-30), so Monthly stays current until then.
- Deleting the app does **not** give a fresh customer (the Keychain keeps the `nb_…` id), and neither
  does a new Sandbox tester. For a genuinely fresh state: run the Debug build once with
  `-NeverblankResetAccess`, then install and launch the Release build — it registers a new `nb_…` id
  with no entitlement. Release builds cannot reset.
- To see what the app believes, read RevenueCat's cache from the app container
  (`com.revenuecat.user_defaults.plist`); to see the truth, `GET /v1/subscribers/<nb_…>` with the
  public key returns the same CustomerInfo the SDK fetches.

## Failure behaviour

- RevenueCat unreachable from the backend: only a previously **verified, unexpired** expiry is honoured.
  Cancelling auto-renew keeps the expiry, so access lasts to the end of the paid period.
- Backend refuses (402 `pro_required`, reason `exhausted` or `too_many_unsuccessful`): the answer
  fails with the Pro message, Retry is kept, and the paywall is offered.

## Analytics and privacy

`POST /v1/events` accepts names and values from fixed lists only (`PRODUCT_EVENTS`, `sanitizeEvent`):
trial_started, free_answers_exhausted, paywall_viewed, weekly_selected, monthly_selected,
purchase_started, purchase_completed, purchase_failed, purchase_restored, paywall_dismissed; optional
`plan`, `trigger`, `reason`. Each is one log line.

The access database stores per installation: id, secret hash, App User ID, created and last-seen
times, free-answer counters, cached entitlement expiry — **no interview content**. Client addresses are
held in memory for one hour for the install throttle. RevenueCat holds the purchase history under the
App User ID.

App Privacy declaration: *Product Interaction* and *Purchases* collected and linked to a pseudonymous
id, not used for tracking; *User Content* (transcript text, notes, file excerpts) collected for app
functionality and sent to the AI provider, not stored by the backend.
