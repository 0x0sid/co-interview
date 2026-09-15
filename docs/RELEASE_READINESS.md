# Prompter — release readiness

> **INHERITED FROM PROMPTER — historical reference only.** This describes *Prompter*, a separate
> paused project. It is **not** a Co-Interview specification and its roadmap, milestones and release
> criteria do not apply here. Start at [`CO_INTERVIEW_START_HERE.md`](CO_INTERVIEW_START_HERE.md).


> **Status notice.** [`PROMPTER_CURRENT_STATE.md`](PROMPTER_CURRENT_STATE.md) is the single entry
> point for current status and the owner-input list. This document remains the **detailed** release
> checklist and still governs its area; where the two differ, the consolidated file is current.


Living document. Every line below is either **verified against this repository / the installed SDK**
or explicitly marked as an owner input or an open question. Nothing here is inferred from the older
planning documents without checking.

Baseline: commit recorded in the §22 entry for M5.11. **M5 is not closed.**

---

## 1. Completed

| Area | State | Evidence |
|---|---|---|
| Voice-following reader | Accepted on device ("best test ever") | M5.7 device retest, `docs/evidence/M5.7/device-retest-VERIFIED.md` |
| Approved light/dark design | Implemented, contrast measured | M5.10, `ThemeContrastTests`, `docs/evidence/M5.10/screenshots/` |
| Editor font/pause-marker controls removed | Done | `EditorToolbarRemovalTests` |
| Script deletion | Done this round | `ScriptDeletionTests` (7 cases) |
| Debug menu removed from the app | Done this round | no reference outside `DebugTools/`; Release binary contains no `PromptDebug` / `DebugMenu` / replay-harness strings |
| Transcript logging out of Release | **Fixed this round** | was shipping; see §6 |

## 2. Remaining work, in execution order

1. **RevenueCat + usage meter** (§4) — the only thing between here and a submittable build.
2. **App Store Connect setup** (§5) — owner inputs, can proceed in parallel.
3. **Release hygiene and privacy labels** (§6).
4. **Languages** (§3) — deliberately *after* billing; see the recommendation at the end.

---

## 3. Language support

> **Updated 2026-09-14 (M5.12).** The English-only launch scope is **superseded**: the owner now
> requests multilingual support. What follows records what is *implemented and measured* versus what
> is still unvalidated. A language is not "supported" because a picker lists it.

### 3.0 Per-language status — implementation versus validation

| | Interface localization | Speech locale routed | Segmentation (replay) | Device validated |
|---|---|---|---|---|
| **English** | n/a (base language) | ✅ `en-US` | ✅ unchanged — ICU output identical to the previous whitespace split | ✅ prior device sessions |
| **French** | ❌ not localized | ✅ `fr-FR` requested, resolved via `supportedLocale(for:)` | ⚠️ spoken/script tokenization now **agree**; accents fold; elision joins (`c'est`→`cest`) | ❌ **not validated** |
| **Traditional Chinese** | ❌ not localized | ✅ `zh-Hant-TW` requested, resolved the same way | ✅ segments — 14 tokens, identical on both sides (was 1 before) | ❌ **not validated** |

**Nothing here entitles the app to advertise French or Chinese.** Two gaps remain for both: the
interface is not localized (no string catalog yet — UI strings are still inline Swift literals), and
neither has been read aloud on a device. For French specifically, the open risk is that the
recogniser emits `c'` + `est` where tokenization produces `cest`; only a device capture settles that.



### 3.1 What the current repository actually requires

`docs/BUILD_SPEC.md` §21 (this repo, verified): *"languages beyond device-locale EN at launch (string
catalog ready for FR/zh-Hant later)"*. **This matches the older uploaded spec — no difference found.**
So v1 ships English only, and French / Traditional Chinese are explicitly deferred.

### 3.2 Three separable concerns

**A. Interface localization.** No `String Catalog` (`.xcstrings`) exists yet; UI strings are inline
Swift literals. `CFBundleDevelopmentRegion` is `en`. Inventory needed for: visible labels across
library / editor / reader / Settings, the two permission descriptions (already written, in
`prompter/Resources/Info.plist`), plurals (`"\(n) words"`, `"~\(n) min"`), accessibility labels
("Settings", "New script", "Close", "More options", "Restart", "Delete"), and locale-sensitive
formatting (`formatted(.relative(presentation: .named))` in `ScriptRow`, word/minute counts).

**B. Script language and speech recognition.** **This is the real gap, and it is not a translation
problem.** Verified in source:

- `PromptViewModel.swift:411` passes **`Locale.current`** — the *device/interface* locale — into
  `TranscriptionService.start(locale:)`.
- `Script.locale` exists as a stored property (`Script.swift:38`) and is **never read anywhere**.

So today **the app assumes the interface language is the script language**, which is exactly the
assumption to avoid. Supporting a second script language requires surfacing a per-script locale and
threading `Script.locale` through to `start(locale:)` — a `Prompt/` + `Editor/` change, not a
`Speech/` one.

Locale capability APIs verified present in the installed iOS 26.5 SDK:
`SpeechTranscriber.supportedLocales`, `AssetInventory.status(forModules:)`, and the existing
`SpeechAssetManager.supportedLocale(for:)` / `ensureInstalled(locale:)` wrappers. **Availability must
be checked at runtime on a real device**, not assumed from this list.

**C. Tokenization, matching, spoken-word fading.** `Tokenizer.normalizeWord` lowercases, folds
diacritics and strips non-alphanumerics, then `Tokenizer.normalize` splits on **whitespace**.
Consequences:

- **French** — mostly works: diacritic folding handles `é`/`è`. But `l'accord` becomes one token
  `laccord`, while the recogniser may emit `l` + `accord`; and `qu'est-ce` collapses to `questce`.
  Contraction and hyphen handling is unvalidated.
- **Traditional Chinese** — **does not work at all.** Chinese has no whitespace between words, so
  `normalize` returns one enormous token per line; every downstream assumption (ring buffer,
  alignment window, per-token Levenshtein) breaks. This needs real segmentation, not a tweak.

### 3.3 Staged validation matrix

| Stage | Work | Device acceptance criteria |
|---|---|---|
| **EN (v1)** | none — current state | Existing M1 gate + device retest hold |
| **FR** | String catalog; per-script locale selection; contraction/hyphen rules in `Tokenizer`; FR fixtures added **outside** the M1 suite so 1307/6395 do not move | On device, FR locale installed: read a 200-word FR script; cursor tracks, apostrophes and hyphenated words do not stall it; spoken-word fading correct across `l'`/`d'` |
| **zh-Hant** | Everything above **plus** a segmentation strategy for `Tokenizer` and a re-derived matching window; new fixtures | On device: read a 200-word zh-Hant script; tracking, fading and recovery all behave; M1 EN numbers unchanged |

**Do not advertise a language on the strength of translated menus or Apple's recognition list.** A
language ships only when (B) and (C) are both validated on a device.

**Not touched this round:** `Matching/` and `Speech/` are unchanged.

---

## 4. RevenueCat — IMPLEMENTED locally (M5.13), NOT sandbox-validated

### 4.0 What is done versus what needs an account

| Item | State |
|---|---|
| RevenueCat SPM dependency 5.83.1 | ✅ present |
| `UsageMeter` + `UsageTracker` | ✅ implemented, 11 tests |
| `EntitlementService` | ✅ implemented, 7 tests |
| Paywall (`PaywallScreen`) | ✅ implemented — free, subscribed, loading, unconfigured, error states |
| Settings badge on the gear | ✅ implemented |
| StoreKit configuration file | ✅ `prompter/Billing/Prompter.storekit` — **product id is a placeholder** |
| **Apple public SDK key** | ❌ **owner input** |
| **Registered product identifier** | ❌ **owner input** |
| Apple sandbox / TestFlight validation | ❌ **not performed — no real purchase has ever been made** |

**Nothing here has been validated against a real purchase.** Every entitlement test exercises decision
logic, not receipts. Treat "implemented" and "verified working" as different claims.

### 4.1 Owner inputs — where each goes and what it unblocks

| # | Input | Where it is entered | What it blocks until supplied |
|---|---|---|---|
| 1 | App Store Connect app record for **`talk.prompter`** | App Store Connect | everything below |
| 2 | Subscription group + monthly product at **USD 6.99** | App Store Connect → Subscriptions | real prices, sandbox purchase |
| 3 | **The product identifier** — old docs say `scriptwatch.premium.monthly`, the app is now `talk.prompter`. **Confirm which is registered; product ids cannot be changed after creation.** Nothing was renamed or invented. | App Store Connect | the `.storekit` placeholder and the RevenueCat product mapping |
| 4 | App Store Connect **In-App Purchase key** + shared secret | RevenueCat dashboard → Apple integration | RevenueCat receiving Apple notifications |
| 5 | RevenueCat project → app → product → entitlement **`premium`** → default Offering | RevenueCat dashboard | offerings loading; the paywall currently shows "unavailable" |
| 6 | **Public** SDK key (`appl_…`) | build setting → `RevenueCatPublicKey` in Info.plist | SDK configuration; the app runs fine without it |
| 7 | Privacy-policy and Terms URLs | App Store Connect + the paywall footer | submission; the footer currently points at a placeholder domain |
| 8 | Sandbox tester / TestFlight access | App Store Connect → Users | purchase, restore, cancellation, expiry validation |

**Do not paste secrets into chat.** Items 4 and 6 are entered in dashboards and build settings
respectively; only the *public* key belongs in the app, and no secret is committed.



### 4.1 What exists versus what is missing — verified, not assumed

| Item | State |
|---|---|
| RevenueCat SPM dependency (`purchases-ios-spm`) | **Present** in `project.pbxproj` — the older doc's claim is correct |
| `UsageMeter` | **Missing** — no such type |
| `EntitlementService` | **Missing** — no such type |
| Paywall UI | **Missing** — no `Paywall/` directory |
| `UsageLedger` model | **Present** (`dayKey`, `secondsUsed`, `updatedAt`), local-calendar day key, **no writer anywhere** |
| `AppSettings.premiumCachedActive` / `premiumCachedAt` | **Present**, never written |

So the scaffolding is *data only*. All behaviour is still to be written.

### 4.2 Requirements (current spec, unchanged)

Unlimited unmetered demo · **10 free reading minutes per local day** · unlimited scripts ·
monthly premium at **USD 6.99** · entitlement id **`premium`** · no account · **no paywall during an
active take**.

⚠️ **One spec line needs owner correction before it appears in any store text.**
`BUILD_SPEC.md:45` lists premium as *"unlimited minutes, future AI writing tools, early features"*.
**Future AI writing tools must not be sold as a current benefit.** Paywall copy should promise
unlimited reading minutes only.

### 4.3 Identifier discrepancy — owner decision required, nothing renamed

| | Value |
|---|---|
| Actual bundle id (verified) | **`talk.prompter`** |
| Product id in the old checklist | `scriptwatch.premium.monthly` |

The app was renamed ScriptWatch → Prompter. **I have not renamed or invented any identifier.** The
owner must state whether `scriptwatch.premium.monthly` is already registered in App Store Connect (in
which case keep it — product ids cannot be changed after creation) or whether nothing is registered
yet (in which case choose a new id before creating it).

### 4.4 Implementation checklist

1. `UsageMeter` — accumulates active reading seconds into `UsageLedger` keyed by **local** day;
   pauses on session pause, background and interruption; resets at the user's midnight, not UTC.
2. `EntitlementService` — wraps `Purchases`; publishes entitlement state; writes
   `premiumCachedActive` / `premiumCachedAt` for offline unlock; reconciles on next successful fetch
   so a lapsed or revoked subscription cannot stay unlocked indefinitely.
3. Paywall — reached when the allowance is exhausted **between** takes, or from Settings. Never
   interrupts an active take: an in-progress session finishes gracefully and the paywall appears
   afterwards.
4. Prices and periods read from store product data (`StoreProduct.localizedPriceString`), never
   hardcoded.
5. States to handle explicitly: purchase, restore, manage subscription, cancellation, **pending
   (Ask to Buy)**, expiration, revocation, billing-retry/grace.
6. Settings gains **Restore Purchases** and **Manage Subscription**.
7. Tests: StoreKit configuration file for automated cases; then **Apple sandbox** on a real device.

### 4.5 Owner-only inputs (no dashboard changes were made)

- [ ] Apple Developer Program active; App Store Connect app record for **`talk.prompter`**.
- [ ] Decision on the product identifier (§4.3).
- [ ] Subscription group + monthly product at USD 6.99, with localized display names.
- [ ] RevenueCat project → app → product mapping → entitlement **`premium`** → default Offering.
- [ ] **Public** RevenueCat SDK key (safe as app configuration).
- [ ] Confirmation that paywall copy drops the AI-tools promise.

**Never commit or embed:** App Store Connect API keys, RevenueCat *secret* keys, signing certificates.

---

## 5. App Store readiness checklist

**Identity & build** — bundle `talk.prompter`; `MARKETING_VERSION 1.0`, `CURRENT_PROJECT_VERSION 1`;
signing team; archive + `altool`/Organizer validation.

**Listing** — app icon (all sizes), screenshots per required device class, description, keywords,
support URL, marketing URL, **privacy policy URL** (required because a subscription is offered),
terms (Apple standard EULA acceptable).

**Subscriptions** — localized display name and description; review screenshot; review notes stating
the app needs microphone + speech and reads a script aloud; restore path demonstrated.

**Privacy** — ⚠️ **"Data Not Collected" is now definitively wrong and must not be submitted.**
RevenueCat purchase infrastructure is in the binary as of M5.13. Even before a key is configured the
SDK ships; once configured it transmits a purchase/app-user identifier and device metadata.
The app itself collects nothing, but the RevenueCat SDK transmits a purchase/app-user identifier and
device metadata. Privacy labels must reflect RevenueCat's configured data handling (typically
*Purchases* and *Identifiers*, linked to identity per configuration). Confirm against RevenueCat's
current privacy-label guidance at configuration time. Third-party **privacy manifests** ship inside
the RevenueCat SPM package — verify present in the archive.

**Permissions** — `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` are present
and clearly worded (verified in `prompter/Resources/Info.plist`). **Denial paths must be tested**:
refusing either permission must produce a clear explanation and a route to Settings, not a dead
reader.

**Speech model** — first use may download an asset (`SpeechAssetManager.ensureInstalled`). Test on a
device with the locale **not** yet installed, and offline: the failure must be explained, not silent.

**Purchases** — sandbox purchase, restore on a second device, cancellation, expiry, Ask-to-Buy
pending, and TestFlight end-to-end.

**Device matrix** — smallest supported iPhone and a Pro Max; largest Dynamic Type; VoiceOver over the
new icon-only reader controls and the delete flow; light/dark; call/Siri interruption mid-take;
extended session (battery, thermal, memory).

**Release hygiene** — no reachable debug routes (**done**, §6), no entitlement overrides, no simulated
purchase controls, no transcript logging (**fixed**, §6).

### Known failures and open evidence

| Item | Status |
|---|---|
| `DeviceLogAuditTests` LOST 3 | **Open** — cursor loses the reader in 3 captured utterances |
| Intermittent `restartClearsTheSpokenSet` under parallel load | Open, diagnosed as starvation |
| `onChange … multiple times per frame` warning | Open, diagnosed, not fixed |
| Joined-word fading (§12.6) | Deferred with numbers |
| Retained-evidence fading | Deferred, one unreproduced device example |
| `"2"`/`"two"` numeral mismatch | Deferred after a measured regression |
| App icon, screenshots, privacy policy, support URL | **Not started — owner inputs** |

**The app is not submittable today**, and archiving successfully would not change that: billing does
not exist yet.

---

## 6. Debug removal and Release hygiene — done this round

- Debug menu entry removed from `ScriptListScreen`; no reference to `DebugMenuScreen` remains outside
  `DebugTools/`.
- `DebugTranscriptScreen`, `ReplayDebugScreen`, `ReplayPlayer` and `PromptTextInputScreen` are now
  `#if DEBUG` — previously they compiled into **Release** as unreachable UI.
- **`[PromptDebug]` transcript logging was shipping in Release.** A `#if DEBUG` nesting scan found the
  `print` in `PromptViewModel.debugLog` outside every guard — while a code comment asserted the
  opposite. Now gated; the scan reports zero ungated `print` calls in production source.
- Release binary verified to contain no `PromptDebug`, `DebugMenu` or replay-harness strings.
- **Preserved deliberately:** console diagnostics under `#if DEBUG`, all test fixtures, and the
  `-promptReplay` harness — the owner asked for the menu to go, not for regression evidence to be
  destroyed.

---

## 7. Recommended next bounded round

**RevenueCat + usage meter (§4), before any language work.** Billing is the only remaining blocker to
a submittable build; languages are explicitly out of scope for v1 per §21, and zh-Hant in particular
needs tokenizer work that would touch `Matching/`. Suggested scope: `UsageMeter` + `EntitlementService`
+ paywall, with StoreKit-test coverage, stopping before sandbox validation (which needs the owner
inputs in §4.5).
