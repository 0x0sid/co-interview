# Co-Interview — development

## Requirements

- macOS with **Xcode 26.x** (project targets **iOS 26.0**, **Swift 6.0** with strict concurrency).
- iOS 26 simulator runtime. Development has used **iPhone 17**.
- No account, API key or credential is needed to build and run.

## Build and test

```bash
cd ~/Desktop/co-interview

# Build
xcodebuild build -project co-interview.xcodeproj -scheme Co-Interview \
  -destination 'platform=iOS Simulator,name=iPhone 17'

# Unit tests (inherited suite)
xcodebuild test -project co-interview.xcodeproj -scheme Co-Interview \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:prompterTests -resultBundlePath /tmp/ci.xcresult

# Read counts from the result bundle, NOT from the log
xcrun xcresulttool get test-results summary --path /tmp/ci.xcresult
```

### Two inherited engineering rules worth keeping

1. **Test counts come from `xcresulttool`, never from grepping build output.** Log-grep counts were
   repeatedly wrong by one in this codebase's history. Always pass `-resultBundlePath`.
2. **Incremental builds have silently reported false passes here.** For any load-bearing verification
   run `xcodebuild clean` first and confirm the log actually recompiled.

### Known inherited test failures

`DeviceLogAuditTests/auditEveryCapturedDeviceSession()` **fails** — three captured utterances where
Prompter's cursor lost a genuinely reading user. It was failing before the fork and is unrelated to
Co-Interview. `SpokenTokenMarkingTests/restartClearsTheSpokenSet()` is **intermittent**; it passes in
isolation and the cause is unproven.

Baseline at the fork point (Prompter `57e46e5`): **170 collected · 169 passed · 1 failed · 0 skipped**.

### Simulator troubleshooting

This project has repeatedly hit simulator infrastructure failures — `Invalid device state`,
`RequestDenied`, and `launchd_sim … quit responding` — which surface as *test failures* and are not
code problems. Recovery that has worked:

```bash
xcrun simctl shutdown all
killall -9 com.apple.CoreSimulator.CoreSimulatorService Simulator
xcrun simctl erase "iPhone 17"     # if still broken
```

Also watch disk space: a full disk produces `mkstemp: No space left on device` reported as a test
failure.

## Remote

`origin` → `git@github.com:0x0sid/co-interview.git` (public, currently **empty**, **nothing pushed**).
Prompter's remote was removed at the fork, so pushing from here cannot reach Prompter's repository.

**Before the first push**, read the publication assessment in `CO_INTERVIEW_DECISIONS.md`: this
repository retains Prompter's full history, which includes real device transcripts and screen
recordings.

## Dependencies

**One** third-party package: RevenueCat (`purchases-ios-spm` 5.83.1), inherited from Prompter and
**intentionally unconfigured**. `BillingConfiguration.publicAPIKey` reads a `RevenueCatPublicKey`
Info.plist entry that does not exist, so `EntitlementService` stays `.unconfigured`: the app runs
fully and Premium is simply unpurchasable. If Co-Interview has no subscription, remove the dependency
rather than leaving it dormant.

## Signing and configuration limits

- Bundle identifier **`talk.cointerview`** is **provisional and not registered** with Apple. It cannot
  be submitted, and push/associated-domain style entitlements will not work until it is registered.
- **No signing identity, provisioning profile or private credential was copied** from Prompter.
  Simulator builds need none; device builds require your own team.
- **No secret belongs in this repository.** Only a *public* RevenueCat client key would ever be app
  configuration, and there is none.

## Where project instructions live

- **`docs/CO_INTERVIEW_START_HERE.md`** — the entry point.
- Everything else under `docs/` prefixed `CO_INTERVIEW_` is current.
- All other `docs/` files, plus `AGENT_PROGRESS.md`, `DEVICE_TEST.md` and `M4_DEVICE_TEST.md`, are
  **inherited Prompter history**. They describe Prompter's roadmap and release criteria, which are
  **not** Co-Interview's.
