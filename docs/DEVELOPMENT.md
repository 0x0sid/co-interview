# Development

## Requirements

- macOS with **Xcode 26**, iOS 26 SDK; the project targets **iOS 26.0** with **Swift 6.0** strict concurrency.
- One package: RevenueCat (`purchases-ios-spm` **5.83.1**). After clearing DerivedData, Xcode can report
  "Missing package product RevenueCat": *File › Packages › Resolve Package Versions* and reopen.
- Testing is done on the owner's iPhone (iPhone 15, "Sid's iPhone"). The simulator is fine for UI work
  but not for billing.
- The Mac has two accounts; the checkout belongs to `sidousan`. Run git as
  `git -c safe.directory='*' …` from the other account.

## Schemes and billing modes

The billing mode comes from the **build configuration**, never from code:

| Configuration | RevenueCat key | `BILLING_STORE_MODE` | Purchases |
| --- | --- | --- | --- |
| Debug | Test Store `test_…` (from `Local-Debug.xcconfig`) | `test-store` | simulated by RevenueCat, never billed; the UI says "Test Store" |
| Release | App Store `appl_…` (from `Local-Release.xcconfig`) | `app-store` | Apple: Sandbox on development installs and TestFlight, real on the App Store |

| Scheme | Run | Archive | Use it for |
| --- | --- | --- | --- |
| **Neverblank (App Store billing)** | **Release** | Release | Everyday phone runs, archives, anything that touches billing |
| Co-Interview (shared, checked in) | Debug | Release | Unit and UI tests, Test Store work, Debug-only switches |

**Pressing Run on the shared Co-Interview scheme installs a Test Store build.** That is why the
App Store billing scheme exists and is listed first. It is a *user* scheme (`xcuserdata/`,
git-ignored), so a fresh clone does not have it: duplicate Co-Interview, set *Run › Build
Configuration* to **Release**, untick *Shared*, and move it to the top in *Manage Schemes*. Neither
scheme uses a `.storekit` file.

## Configuration files (`prompter/Config/`)

| File | Committed | Holds |
| --- | --- | --- |
| `Debug.xcconfig` | yes | `BILLING_STORE_MODE = test-store`; includes `Local-Debug.xcconfig` last |
| `Local-Debug.xcconfig` | **no** (template `Local-Debug.example.xcconfig`) | Test Store key, `COPILOT_DEV_BACKEND_HOST` (host only — `//` starts an xcconfig comment) |
| `Release.xcconfig` | yes | `BILLING_STORE_MODE = app-store`, `NEVERBLANK_BACKEND_HOST = backend--d7y3w.fly.dev`; includes `Local-Release.xcconfig` last |
| `Local-Release.xcconfig` | **no** (template `Local-Release.example.xcconfig`) | App Store key `appl_…`. Excluded from the app bundle by a target membership exception |

RevenueCat SDK keys are public, but they still stay out of the public repository. No backend token or
provider key is ever built into the app.

The app target has `GENERATE_INFOPLIST_FILE = NO` and uses `prompter/Resources/Info.plist`
(Release) and `prompter/Resources/Info-Debug.plist` (Debug). Xcode's Info editor has stripped keys
from `Info-Debug.plist` before (symptom: "invalid bundle", missing `CFBundleIdentifier`) — edit the
file as text.

### Release safety check

The app target's *Release safety check* build phase (`scripts/release-guard.sh`) fails a Release
build unless: the key is an `appl_` key, the mode is `app-store`, the backend URL is the https
production host, the bundle id is `io.neverblank.app` and the name Neverblank, the Terms and Privacy
URLs are https, no token-like build setting or Info.plist entry exists, and no `.xcconfig`,
`Info-Debug.plist` or `.storekit` file is in the bundle. It never prints a secret. A passing build
logs `Release safety check passed: App Store billing, production backend, no bundled credentials.`

## Build and install on the phone

```bash
cd /Users/sidousan/Desktop/co-interview-public
xcodebuild build -project co-interview.xcodeproj -scheme "Neverblank (App Store billing)" \
  -configuration Release -destination 'generic/platform=iOS' -allowProvisioningUpdates
APP=~/Library/Developer/Xcode/DerivedData/co-interview-*/Build/Products/Release-iphoneos/prompter.app
xcrun devicectl list devices                                  # the phone's identifier
xcrun devicectl device install app --device <id> $APP        # in place: data and Keychain kept
xcrun devicectl device process launch --device <id> --terminate-existing io.neverblank.app
```

- The phone must be **unlocked** to launch or run tests (`devicectl device info lockState`).
- Stuck on "connecting": `killall CoreDeviceService`.
- App launch arguments go after `--`, or `devicectl` reads them as its own options.
- Console output: `OS_ACTIVITY_DT_MODE=enable xcrun devicectl device process launch --console …`.
- App preferences (including RevenueCat's cached CustomerInfo) can be read without changing anything:
  `devicectl device copy from --domain-type appDataContainer --domain-identifier io.neverblank.app --source Library/Preferences …`.

## Tests

Run the suites that cover the change, **on the phone**:

```bash
xcodebuild test -project co-interview.xcodeproj -scheme Co-Interview \
  -destination 'platform=iOS,id=<xcodebuild id from -showdestinations>' -allowProvisioningUpdates \
  -only-testing:prompterTests/SubscriptionDisplayTests -only-testing:prompterTests/SettingsPresentationTests
```

- Testing installs the **Debug** test host over the app. Reinstall the Release build afterwards.
- The unit-test host never configures RevenueCat; billing tests drive `EntitlementService` directly.
- Unit tests are `@testable` and Debug-only; they do not build in Release.
- The full `prompterTests` suite run in parallel makes the Copilot timing tests (3 s waits) time out
  under load. Run them on their own before treating a failure as real.
- Read counts from a result bundle (`-resultBundlePath`, then `xcrun xcresulttool get test-results
  summary`), not from the log.
- UI tests launch with `-UITestsQuietMotion`; without it XCUITest waits forever for the animated
  listening mark to go idle. `-UITestsSubscriptionState pro|pro-yearly|cancelled|grace|expired|free|…`
  fixes the Settings card for screenshots.
- Backend: `cd backend && npm test` (seven suites against local stubs; Node 22 or later).

### Test fixtures

No real person, organisation, interview recording or personal document may enter this public
repository. Fixtures (`SyntheticInterview`, `SyntheticProjectFixture`, `backend/eval/`) are written
for the purpose.

## Debug-only switches

| Switch | Effect |
| --- | --- |
| `-NeverblankResetAccess` | Deletes the installation credential and free-answer record from the Keychain: the next launch registers a new installation and a new RevenueCat id. The way to get a fresh billing identity — see [`BILLING.md`](BILLING.md) |
| `-CopilotInstallationAuth` | Switches a Debug build to installation access for good (remembered) |
| `-NeverblankDeveloperTools` | Shows the developer section (Demo and diagnostics) |
| `scripts/billing-test-phone.sh` | Debug build with installation access baked in; still the Test Store |

None of these exist in a Release build.

## Release

1. Bump `MARKETING_VERSION` (six entries in `project.pbxproj`: app and test targets);
   `CURRENT_PROJECT_VERSION` stays 1 for a new version.
2. Build with the App Store billing scheme and check the safety check passed.
3. *Product › Archive* with the same scheme; upload from the Organizer. Uploading and submitting are
   done by the owner.

App Review notes: [`APP_REVIEW.md`](APP_REVIEW.md).

## Troubleshooting

- **Simulator failures that look like test failures** (`Invalid device state`, `RequestDenied`,
  `launchd_sim … quit responding`): `xcrun simctl shutdown all`, then
  `killall -9 com.apple.CoreSimulator.CoreSimulatorService Simulator`.
- **Disk full** shows up as `mkstemp: No space left on device` inside a test failure. DerivedData and
  old archives are the safe things to delete.
- **`xcodebuild` sits at 0% CPU before compiling** (also `xcodebuild -list`): a stale file-coordination
  claim on the project directory, seen after a disk-full episode. Building a copy of the tree
  (`rsync -a --exclude .git … /tmp/buildcopy/`) works; a logout or reboot clears it.
- **Incremental builds have reported false passes.** For a load-bearing check, clean first.
