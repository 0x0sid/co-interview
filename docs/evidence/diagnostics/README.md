# Generate diagnostics — Debug-only tracing for device testing

What each Generate tap did, from the tap to the answer, so a problem seen on a phone can be reported
without having to describe it from memory.

`live-report.md` and `live-report.json` are the export from **one synthetic session driven through
the whole real path** — `InterviewScreenModel` → `LiveInterviewFeed` → `CopilotSessionCoordinator` →
`BackendCopilotProvider` → the local backend → the configured provider — by
`DiagnosticsIntegrationTests`. They are not a hand-populated fixture: a fixture shows the formatter
works and nothing else, whereas every field in these files travelled the whole way. Nothing in them
came from a real interview.

## What to tap

### To record a problem without capturing any conversation

Nothing to switch on. Every Generate tap in a Debug build is already traced with counts, identities,
timings and outcomes — and no conversation text.

1. Run the interview as usual.
2. When an answer looks wrong, open **•••** in the toolbar → **Mark a problem**, optionally type a
   short note, and tap **Mark**.
3. Leave the interview. **Scripts → Interview Copilot → Provider diagnostics → Generate
   diagnostics**.
4. **Export test session** → share sheet → AirDrop, Files or Mail.

The report will say, at the top: *"This report contains no conversation text."*

### To capture the conversation as well, for one test session

Capture is per-session and **resets to off when a session starts**, so it is switched on from inside
the session it is meant to record. That is what the ••• entry is for.

1. Start the interview as usual.
2. **•••** → **Diagnostics** → turn **Capture test content** ON → **Done**.
   Tap the switch itself, not the row's label.
3. Carry on in the same session — nothing was restarted and listening did not stop. Capture applies
   to taps made **from now on**, so tap Generate after switching it on.
4. Reproduce the problem. **•••** → **Mark a problem**, optional note, **Mark**.
5. **•••** → **Diagnostics** → **Export test session** (or **Export last request**) → share sheet.

That report is headed with a warning that it contains what was said and what was written.

An earlier draft of these instructions said to enable capture *before* starting the interview. That
could not work: starting the session turns it off again, and there was no way into the diagnostics
screen from inside an interview. The ••• entry is the fix.

### To clear everything

**••• → Diagnostics → Clear diagnostics** (or the same section in the Debug surface). The store is also bounded at 40 traces and 200 000
captured characters, and is memory-only — closing the app discards it.

## What is always recorded

Correlation ids shared with the backend (session and request), the app build and commit and the
backend version, the tap time and its outcome — accepted, queued, debounced, or rejected with the
reason — the transcript's utterance ids, revisions, final/partial state and coverage, the whole
transcript size against the size actually sent, anything omitted and why, how much was new input
versus historical context, attachment counts, the requested and the **actual** model and provider,
each attempt and fallback, the answer version, HTTP status and sanitized errors, the time spent
queued, preparing, waiting for first text and completing, the interpreted title, and whether the
stream completed, failed, timed out or was cancelled.

**The actual provider is never inferred from the requested route.** When the gateway does not report
what served a request, the report says `unknown`.

## What capture adds

The raw transcript as it stood at the tap, the exact immutable snapshot, the serialized application
request, the final provider messages including the system instructions, and the returned title and
answer — all under the same request id, so a sentence that went missing can be followed to the step
that lost it.

## What is never recorded

API keys, client tokens, authorization headers and base64 image data. Attachments appear as counts
and preparation state only. `Redaction` is applied at every entry point that takes free text and
again on the way into an export, and the backend redacts before it stores rather than when it reads.

## The backend half

Off unless the operator sets `COPILOT_DIAGNOSTICS=1`. With it on, a request that explicitly asks has
its assembled provider messages kept **in memory only**, bounded to 40 entries, expiring after
`COPILOT_DIAGNOSTICS_TTL_MS` (default 10 minutes), and readable only at
`GET /v1/copilot/diagnostics/<request-id>` behind the same bearer token as every other route.

There is no global transcript logging, nothing is written to disk, nothing is kept for a request that
did not ask, and ngrok still runs with `--inspect=false`.

## Independence

Diagnostics observe; they never participate. No diagnostic value is read back into a request, and
`GenerateDiagnosticsTests.capturingDoesNotChangeTheRequest` asserts that the same speech produces an
identical payload with capture on and off. Recording failures are swallowed and surfaced in the
report rather than interrupting the interview, and the provider-messages fetch happens after the
answer is on screen. Release builds compile the recorder's bodies away.

## Tested

`prompterTests/Diagnostics/GenerateDiagnosticsTests.swift` — correlation from tap to answer, full
versus sent transcript counts, capture-off excluding conversation and answers, capture-on preserving
the tap snapshot against later revisions, redaction and image-byte exclusion, bounded storage,
clearing, orphan-event handling, failed requests remaining exportable, and capture not changing the
request.

`prompterUITests/CopilotEntryUITests.testDiagnosticsAreReachableWithoutLeavingTheInterview` —
••• → Diagnostics opens from inside a running interview, capture starts off, switches on, and after
closing and reopening the sheet the session id is unchanged and capture is still on.

`prompterTests/Diagnostics/DiagnosticsIntegrationTests.swift` — one synthetic Generate driven
through the real app and backend, asserting that the export carries the full transcript snapshot, new
input against historical context, the serialized request with no token and no image bytes, the actual
provider messages fetched back from the backend, the answer and the model's interpreted title, and
the correlated request id, route metadata and timings. Opt-in, because it needs a live backend and
makes one real provider call:

```bash
TEST_RUNNER_COINTERVIEW_LIVE_DIAGNOSTICS=1 \
TEST_RUNNER_COINTERVIEW_LIVE_TOKEN=<client token> \
xcodebuild test -project co-interview.xcodeproj -scheme Co-Interview \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:prompterTests/DiagnosticsIntegrationTests
```

`backend/test/diagnostics-test.mjs` — retrieval, session correlation, backend version, the assembled
messages, authentication (401 without or with the wrong token), nothing stored for a request that did
not ask, credential redaction, and expiry. The **off** case is asserted in `contract-test.mjs`, where
the flag must change nothing and the endpoint must not exist.
