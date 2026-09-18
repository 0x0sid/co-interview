# Co-Interview — development

## Requirements

- macOS with **Xcode 26.x** (project targets **iOS 26.0**, **Swift 6.0** with strict concurrency).
- iOS 26 simulator runtime. Development has used **iPhone 17**.
- No account, API key or credential is needed to build and run.

## Build and test

```bash
cd ~/Desktop/co-interview-public

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

### Last measured run (2026-09-19, live mode)

| Suite | Result |
|---|---|
| `prompterTests` | **239 executions passed · 0 failed · 0 skipped** (226 test functions, 32 suites) |
| `backend` (`npm test`) | configuration, OpenAI contract and OpenRouter contract **all passed** |

The backend suites still run on the machine's Node v18.16.0, which is past end-of-life; `package.json`
declares `>=22`. Re-run on Node 22/24 before relying on them.

**No live provider request has been made from this build.** No `OPENROUTER_API_KEY` or
`OPENAI_API_KEY` is set on this machine, so every check above used local stubs or the labelled
development fake. Live latency and answer quality are unmeasured.

### Previous run (2026-09-17, v2.5 interview screen)

From the result bundle, not the log:

| Suite | Result |
|---|---|
| `prompterTests` | **223 passed · 0 failed · 0 skipped** (210 `@Test` declarations; parameterised cases expand) |
| `prompterUITests/CopilotEntryUITests` | **6 passed · 0 failed** |
| `prompterUITests/InterviewScreenCaptureTests` | **2 passed · 0 failed**, in light and again in dark |

No inherited failure appeared in this run — including
`SpokenTokenMarkingTests/restartClearsTheSpokenSet()`, which is documented below as intermittent and
passed here. Nothing was skipped, disabled or weakened to reach this.

**UI tests must launch with `-UITestsQuietMotion`.** XCUITest waits for the app to be idle before
every query, and the listening waveform animates for as long as it is listening, so without the flag
queries hang indefinitely rather than failing. `InterviewTestingFlags` holds the switch.

### Known inherited test failures

**Public snapshot (`32a583c`, corrected 2026-09-16):** the suite reportedly passes **113 tests**
(`prompterTests/` declares 113 `@Test` functions; not re-run in the planning round — re-establish with a
clean run and `xcresulttool` before relying on it). `DeviceLogAuditTests` was **removed** for
publication along with 14 other capture-derived test files, so the three **LOST** cursor-loss cases are
still unresolved but **no longer covered by any test here**. `SpokenTokenMarkingTests/restartClearsTheSpokenSet()`
remains **intermittent**; it passes in isolation and the cause is unproven. See
`CO_INTERVIEW_SNAPSHOT_NOTICE.md`.

*Historical, private clone only:* at the fork point (Prompter `57e46e5`) the suite was **170 collected ·
169 passed · 1 failed · 0 skipped**, the failure being `DeviceLogAuditTests/auditEveryCapturedDeviceSession()`.

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

#### `xcodebuild` hangs before it compiles anything (2026-09-17)

Symptom: `xcodebuild` prints its invocation line and then sits at **0% CPU indefinitely**, with no
`XCBBuildService` child process and an empty log. `xcodebuild -showsdks` still answers instantly, but
`xcodebuild -list` on *this project* hangs too. It looks like a slow build; it is not building at all.

Diagnose it with a stack sample rather than guessing:

```bash
(xcodebuild -project co-interview.xcodeproj -list &) ; sleep 10
sample $(pgrep -f "xcodebuild -project" | head -1) 3 -file /tmp/sample.txt
```

A stack ending in `IDEWorkspace initWithFilePath:` → `DVTFilePath performCoordinatedReadRecursively:`
→ `NSFileCoordinator … _blockOnAccessClaim:withAccessArbiter:` means the process is blocked on a
**stale file-coordination claim on the project directory**, not on the compiler, the simulator or the
network. It followed a disk-full episode here.

What worked, in order of least disruption:

```bash
# 1. Confirm it is path-specific: build a copy of the tree somewhere else.
rsync -a --exclude .git ~/Desktop/co-interview-public/ /tmp/buildcopy/
cd /tmp/buildcopy && xcodebuild -project co-interview.xcodeproj -list   # answers immediately
```

Building the copy is a complete workaround and touches nothing. `killall -9
com.apple.CoreSimulator.CoreSimulatorService` fixed a *separate* wedge that made `simctl list` hang,
but did **not** clear the coordination claim. The claim is held per path; a logout or reboot clears
it. Do not delete the working tree to escape this.

## Remote

`origin` → `git@github.com:0x0sid/co-interview.git` — public. **Corrected 2026-09-16:** the sanitized
snapshot is published; `git ls-remote` shows `main` at `32a583c`. This repository has fresh history and
does **not** contain Prompter's development history, device transcripts or screen recordings — those
remain only in the private clone `~/Desktop/co-interview`, which must never be pushed. Prompter's remote
was removed at the fork, so pushing from here cannot reach Prompter's repository. Do not force-push.

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
- All other `docs/` files are **inherited Prompter history** (`AGENT_PROGRESS.md`, `DEVICE_TEST.md` and
  `M4_DEVICE_TEST.md` exist only in the private clone; they were removed from this public snapshot). They describe Prompter's roadmap and release criteria, which are
  **not** Co-Interview's.
