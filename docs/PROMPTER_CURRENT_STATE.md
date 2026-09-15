# Prompter — current state (authoritative handoff)

> **INHERITED FROM PROMPTER — historical reference only.** This describes *Prompter*, a separate
> paused project. It is **not** a Co-Interview specification and its roadmap, milestones and release
> criteria do not apply here. Start at [`CO_INTERVIEW_START_HERE.md`](CO_INTERVIEW_START_HERE.md).


> ## ⏸ DEVELOPMENT PAUSED — 2026-09-15
>
> Prompter development is **paused** while a separate product, **Co-Interview**, is explored. That is
> an independent app forked from this repository into `~/Desktop/co-interview`; it has its own Git
> history, its own bundle identifier and its own persistence, and **no change was made to Prompter**
> to create it.
>
> **Exact state at the pause:**
>
> | | |
> |---|---|
> | HEAD | `ffe5714` |
> | Working tree | **clean** — no uncommitted or untracked work (only ignored `.DS_Store` / `xcuserdata` noise) |
> | Stashes | none |
> | Remote | `origin` → `https://github.com/VRAM-AI/prompter.git`, **nothing pushed** |
> | Last verified test run | 170 collected · 169 passed · 1 failed · 0 skipped at `57e46e5` |
>
> **Nothing was fixed, tuned or reconfigured at the pause.** Every blocker in §6 below is still open,
> unchanged — in particular `DeviceLogAuditTests` LOST 3, the never-device-tested keyboard fix, and
> the fact that **no real purchase has ever been verified**. Billing configuration was not touched.
>
> To resume Prompter, start from §8's recommended next action. Co-Interview does **not** inherit
> Prompter's M5 milestones or release criteria.


**This is the single entry point.** It is written so a replacement agent can understand the app, the
settled decisions, the verified baseline, the missing setup and the next step **without reading any
chat history**.

| | |
|---|---|
| Verified baseline | **`57e46e5`** — M5.13 |
| Test result at that commit | **170 collected · 169 passed · 1 failed · 0 skipped** ([evidence](evidence/M5.13/xcresult-summary.json)) |
| The one failure | `DeviceLogAuditTests/auditEveryCapturedDeviceSession()` — pre-existing, see §6 |
| Working tree | clean at time of writing |
| Milestone | **M5 is open.** Not submittable. |

> Counts were re-read from the stored `xcresulttool` summary, not from a prior report. Source
> `@Test` functions at HEAD = **170**, matching collected.

**Detailed specialist documents still govern their areas.** This file does not replace them and
deliberately contains no competing checklist:

| Area | Governing document |
|---|---|
| Matching engine, thresholds, tokenization, scroll ownership | [`MATCHING_ENGINE.md`](MATCHING_ENGINE.md) |
| Why each decision was made, with evidence | [`DECISIONS.md`](DECISIONS.md) |
| Original product spec (note superseded clauses below) | [`BUILD_SPEC.md`](BUILD_SPEC.md) |
| Release checklist and owner inputs | [`RELEASE_READINESS.md`](RELEASE_READINESS.md) |
| Settled monetization model | [`MONETIZATION_OPEN_DECISIONS.md`](MONETIZATION_OPEN_DECISIONS.md) |
| Session-by-session history | [`../AGENT_PROGRESS.md`](../AGENT_PROGRESS.md) |
| Device test protocols | [`DEVICE_TEST_M5.2.md`](DEVICE_TEST_M5.2.md) |

---

## 1. What the app is

An iOS teleprompter (`talk.prompter`) that follows the reader's **voice** rather than a timer. You
paste a script, press start, and the text scrolls to keep pace with what you actually say — holding
position when you pause, waiting when you go off-script, and re-finding you when you skip. Everything
runs on-device; the only network traffic is the purchase SDK and Apple's one-time speech-model
download.

---

## 2. Product contract — settled

### 2.1 Reading experience (owner-accepted on device)

Smooth voice-paced following · current line near the top · manual dragging without interference ·
automatic resumption when fresh reading evidence matches the region the reader scrolled to · one
smooth resume glide · fast repositioning after a confirmed distant skip · correct pause, silence,
off-script hold, restart and exit.

**Fading invariant, unchanged and load-bearing:** *grey means the reader actually said that word at
that position.* Only individually confirmed spoken words fade. Unread text keeps **full** contrast.
Deliberately skipped passages stay unread — a recovery across 71 unread tokens marks nothing.

### 2.2 Design

Approved light/dark system. Anchors: background `#F7F4EF`/`#151719`, text `#242331`/`#F2F0EB`, accent
`#216A60`/`#9ED8C4`. Contrast is **measured**, not eyeballed (ink/paper 14.08:1 light, 15.78:1 dark).
Appearance preference System/Light/Dark, default System, persisted; changing it never rebuilds the
matcher, resets the cursor, clears spoken history or restarts recognition.

### 2.3 Scripts

Create, edit, persist, delete. Unlimited scripts, **no word-count restriction**. Deletion is a
long-press context menu with a confirmation naming the script, Cancel as the safe default. Swipe-to-
delete is deliberately absent (`.swipeActions` needs a `List`; the approved library is a card stack).

Keyboard avoidance: the end of a long script is reachable with the keyboard open. `Start reading`
hides while editing and returns on dismissal; an accessible **Done** dismisses the keyboard.

**Removed and not relocated:** editor A/A font buttons, the `[ ]` pause-marker insertion action, and
all user-facing debug menus.

### 2.4 Languages — English is the default

Interface language, script (speech) language, and tokenization are **three separate concerns**. The
app previously passed the *interface* locale to recognition; it now passes the script's own language.

| | Interface localized | Speech locale routed | Segmentation | Device validated |
|---|---|---|---|---|
| **English** | base language | ✅ `en-US` | ✅ unchanged | ✅ owner feedback |
| **French** | ❌ no | ✅ `fr-FR`, resolved or **throws** | ⚠️ spoken/script sides agree | ⚠️ owner reports good behaviour — **one reader, not a validation matrix** |
| **Traditional Chinese** | ❌ no | ✅ `zh-Hant-TW` | ✅ segments (was 1 token/line) | ❌ **never read aloud on device** |

**No language should be advertised yet.** French and Chinese both lack interface localization, and
Chinese has no device evidence at all. Automatic language detection is **deferred, not built**.

### 2.5 Monetization — settled, no open questions

| | |
|---|---|
| Free | **10 reading minutes per local calendar day** |
| Scripts | unlimited, **no 1,000-word cap** — that proposal was dropped |
| Demo | **unlimited and unmetered** |
| Premium | **unlimited reading**, **USD 6.99/month** |
| Entitlement id | `premium` |
| Account | none — anonymous |
| Active take | **never interrupted**; a take allowed to start may overrun and finish |
| Camera filming | **deferred**, not implemented, not advertised |
| $9.99 filming tier | **not part of this product** |

Settings carries a **Prompter Premium** row; the unread badge sits on the library's Settings **gear**.
Opening Settings does *not* clear it; opening the Premium screen does, permanently. No app-icon badge.
Subscribers see status, Manage Subscription and Restore — not another invitation to buy.

---

## 3. Implementation versus verification

**"Implemented", "automated-verified" and "device-verified" are three different claims.**

| Feature | Implemented | Automated verification | Device | Remaining limitation |
|---|---|---|---|---|
| Voice following, resumption, fading | ✅ | `ScrollOwnershipTests` (15), `StallAssessmentTests`, M1 gate | ✅ accepted; [M5.7 retest](evidence/M5.7/device-retest-VERIFIED.md) — **2** resumption observations | glide smoothness is recording-only; `simctl` cannot drag |
| M1 tracking gate | ✅ | `meanCursorError 0.7658760520275439`, `falseJumps 0`, denominators 1307/6395 | — | unchanged across M5.10–M5.13 |
| Light/dark design | ✅ | `ThemeContrastTests` (7) | ✅ screenshots [M5.10](evidence/M5.10/screenshots/) | Dynamic Type / device matrix not exhaustively captured |
| Keyboard fix | ✅ | build-level only | ❌ **not device-tested** | the fix is the reason to run a device test |
| Script deletion | ✅ | `ScriptDeletionTests` (7) | ❌ | screenshot never captured (XCTest could not drive the context menu) |
| Debug removal | ✅ | source scan + Release binary string check | — | — |
| Reading language routing | ✅ | `LanguageSupportTests` | ⚠️ EN/FR owner feedback | zh-Hant unvalidated |
| Segmentation (ICU) | ✅ | English parity asserted; M1 byte-identical | — | — |
| Usage metering | ✅ | `UsageMeterTests` (11) | ❌ | midnight display staleness, §4.1 |
| Entitlement logic | ✅ | `EntitlementStateTests` (7) | ❌ | decision logic only — **no receipts** |
| Paywall UI | ✅ | — | ❌ | cannot show a real price until configured |
| **Real purchase / restore / sandbox** | **❌** | **none** | **❌** | **see §3.1** |

### 3.1 Purchases are UNVERIFIED — read this before claiming otherwise

**No real purchase has ever been made.** No Apple sandbox session, no TestFlight, no receipt, no
successful RevenueCat backend call. There is no public SDK key in the build and no registered product.

None of the following is evidence of a working purchase:

- passing `EntitlementStateTests` — it exercises **decision logic**, with no receipt involved;
- the RevenueCat SPM dependency compiling — a dependency is not an integration;
- the local `.storekit` configuration file — its product id is a **placeholder**, and StoreKit
  testing is explicitly *not* Apple sandbox.

---

## 4. Corrections to claims made earlier in this project

These were stated too strongly at some point and are corrected here.

### 4.1 Monotonic time ≠ day-boundary policy

They are separate mechanisms and only one of them is protected by the monotonic clock.

- **Elapsed duration** uses `ContinuousClock` (`UsageTracker`), never `Date()`. A clock correction or
  time-zone move cannot make a take consume more or less allowance than it actually ran.
- **The day boundary** is a *policy*: `UsageLedger.dayKey(for:calendar:)` formats `Calendar.current`,
  i.e. the device's **current** time zone. Consequence, deliberate but worth stating: a reader who
  changes time zone can cross into a new day key early or late, and receive a fresh allowance sooner
  or later than 24 hours. Usage already banked under a previous key is never rewritten.
- **Known gap, verified in source:** `UsageTracker.canStartMeteredTake` rolls the day over on a probe
  copy, so the *gate* is correct at midnight. `UsageTracker.remainingSeconds` does **not** roll over,
  so if the app stays open across local midnight the *displayed* remaining time is stale until the
  next take starts (which does roll over) or the app relaunches (which re-reads by today's key). The
  allowance itself is correct; only the label can lag. Not fixed — recorded.

### 4.2 RevenueCat in the binary ≠ privacy labels answered

The SDK ships regardless of configuration, so **"Data Not Collected" cannot be submitted**. But
presence alone does not determine the answers either. What is actually true today: **nothing is
configured**, so no identifier is transmitted yet. What must be assessed *when* configured: which of
*Purchases*, *Identifiers* and *Usage Data* RevenueCat's chosen configuration transmits, whether it is
linked to identity, and whether the SDK's bundled **privacy manifest** covers it in the archive. That
assessment is outstanding and cannot be completed before §5 item 5.

### 4.3 "Parallel load" was a hypothesis, not a proven cause

`SpokenTokenMarkingTests/restartClearsTheSpokenSet` has failed intermittently and passed on rerun and
in isolation. That establishes **intermittency**; it does not prove CPU starvation. The supporting
observations — it fails only in full runs, its failing assertion is a wall-clock-bounded precondition
wait, and the failure set moved between runs — are consistent with starvation but were never isolated
to it. Treat the cause as **unproven**.

### 4.4 Two readers' languages ≠ language support

Owner feedback that English and French behave well is real device feedback about **those two
languages, in one voice, on one device**. It is not a validation matrix and says nothing about
Traditional Chinese, other accents, or noisy environments.

### 4.5 Billing is not the only release blocker

It never was. See §6.

### 4.6 A product identifier does not have to match the display name

Earlier notes framed `scriptwatch.premium.monthly` versus the app name *Prompter* as a discrepancy
needing resolution. It is not one: **identifiers are opaque and need not match display names**, and a
registered identifier **cannot be changed after creation**. The only real question is *which
identifier is actually registered*. Nothing has been renamed or invented; the `.storekit` file carries
an explicit placeholder awaiting that answer.

---

## 5. Remaining setup — owner inputs

Confirmed from source: **bundle identifier `talk.prompter`**, `MARKETING_VERSION 1.0`,
`CURRENT_PROJECT_VERSION 1`. Entitlement identifier in code and spec: **`premium`**.

| # | Item | Who / where | What closes it |
|---|---|---|---|
| 1 | App Store Connect app record for `talk.prompter` | Owner, ASC | record exists; everything below unblocks |
| 2 | Subscription group + monthly product at USD 6.99 | Owner, ASC → Subscriptions | product visible in ASC |
| 3 | **Confirm the registered product identifier** (existing `scriptwatch.premium.monthly`, or a new one). Ids are immutable once created | Owner, ASC | agent replaces the placeholder in `prompter/Billing/Prompter.storekit` and the RC mapping |
| 4 | ASC **In-App Purchase key** + shared secret — so Apple can notify RevenueCat | Owner, entered in the **RevenueCat dashboard** (never in the app, never in chat) | RC shows the Apple integration as connected |
| 5 | RevenueCat project → app → product mapping → entitlement `premium` → default Offering | Owner, RC dashboard | `offerings()` returns a package; the paywall shows a real price instead of "unavailable" |
| 6 | **Public** SDK key (`appl_…`) | Owner supplies; agent wires it to the `RevenueCatPublicKey` Info.plist entry via a build setting | `EntitlementService` leaves `.unconfigured` |
| 7 | Privacy-policy and Terms URLs | Owner | paywall footer placeholder replaced; ASC fields filled |
| 8 | Sandbox tester account / TestFlight access | Owner, ASC → Users | agent runs the purchase/restore/cancel/expiry protocol in `RELEASE_READINESS.md` |

**No secret ever belongs in the repository or in chat.** Only the *public* client key is app
configuration.

---

## 6. Release blockers and unresolved issues

| Blocker | State | Next concrete action | Closed by |
|---|---|---|---|
| **`DeviceLogAuditTests` LOST 3** | Open. Three captured utterances where the cursor lost a genuinely reading user (session C t=129.775 s, C t=130.768 s, D t=177.769 s) | Diagnose those three utterances specifically; do **not** relax the gate | the audit reporting LOST 0 without weakening assertions |
| Real purchases | Unverified | §5 items 1–8, then the sandbox protocol | a completed sandbox purchase, restore on a second device, and a verified expiry |
| Privacy labels | Cannot be answered yet | After §5 item 5, inventory what RC transmits | ASC labels filled with evidence |
| Keyboard fix | Not device-tested | Device retest, bottom-of-script editing first | owner confirmation on a >1,000-word script |
| Deletion / paywall / Premium screenshots | Not captured | Capture manually on device | images in `docs/evidence/` |
| Accessibility | Not audited | VoiceOver pass over icon-only reader controls, delete flow, paywall; largest Dynamic Type | recorded audit |
| Interruption & long session | Not tested | Call/Siri mid-take; 30-min session for battery/thermal | device notes |
| Device matrix | Not tested | Smallest supported iPhone + Pro Max | screenshots |
| `restartClearsTheSpokenSet` | Intermittent, cause unproven (§4.3) | Instrument the precondition wait rather than assuming starvation | a determined root cause |
| `onChange … multiple times per frame` | Diagnosed, unfixed | Bounded presentation fix | warning absent from a device capture |
| Joined-word fading (§12.6) | Deferred with numbers — 0.7 % of the gap | — | — |
| Retained-evidence fading | Deferred; one unreproduced device example | needs a capture with full matcher inputs (three log lines, see DECISIONS) | a faithful fixture |
| `"2"`/`"two"` numerals | Deferred after a measured regression | — | — |
| `[pause]` markers feed a literal `"pause"` token | Known, unfixed | decide whether markers are stripped before matching | — |
| App icon, screenshots, support URL | Not started | Owner | ASC fields complete |

**Release logging/debug exclusions — evidence.** The debug menu is unreachable; `DebugTools/*`,
`PromptTextInputScreen` and the replay harness are `#if DEBUG`; `[PromptDebug]` transcript logging was
**found shipping in Release** and is now gated. Evidence: a `#if DEBUG` nesting scan reports zero
ungated `print` in production source, and the Release binary contains no `PromptDebug`, `DebugMenu` or
replay-harness strings (the single `ScrollOwner` hit is the production type name `ScrollOwnership`).

---

## 7. Superseded requirements

Older documents remain for history. These clauses no longer hold:

| Superseded | By |
|---|---|
| `BUILD_SPEC.md` §21 "English at launch only" | owner request for multilingual support (M5.12) |
| `BUILD_SPEC.md:45` premium includes "future AI writing tools" | paywall advertises **unlimited reading only** |
| 1,000-word script cap proposal | dropped — unlimited scripts (M5.13) |
| USD 9.99 / filming tier | not part of this product; filming deferred |
| "Data Not Collected" privacy label | §4.2 |
| "Light mode is the only normal mode" (§13 v2) | approved light/dark system (M5.10) |
| M5.2-era handoff steps 1–2 (threshold options) | superseded by measurement; see MATCHING_ENGINE §12 |

---

## 8. Recommended next action

**Run one device session on `57e46e5`, starting with bottom-of-script editing.** The keyboard fix is
the only user-blocking change that has never been device-tested, and it needs fingers on a device;
everything else in the billing round is blocked on owner inputs (§5) that no amount of local work can
substitute for. Protocol: `DEVICE_TEST_M5.2.md` plus the M5.12 retest steps in `AGENT_PROGRESS.md`.
