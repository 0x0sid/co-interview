# This is a sanitized public snapshot

This repository is a **clean snapshot** of Co-Interview, prepared for public publication. It has
**fresh Git history** — one initial commit — and is not the development history.

## Why

Co-Interview was forked from **Prompter**, a voice-following teleprompter. Prompter's development
history contains material that should not be public: verbatim transcripts of real device sessions
(including unscripted remarks made while testing), screen recordings, and personal identifiers. None
of that can be removed by deleting files in a later commit, so the public repository starts fresh.

**The complete development history is preserved privately** and is unaffected by anything here.

## What was removed

| Removed | Why |
|---|---|
| `docs/evidence/` (29 MB, 16 milestone folders) | logs, screenshots and two screen recordings from real sessions |
| `AGENT_PROGRESS.md`, `DEVICE_TEST.md`, `M4_DEVICE_TEST.md` | development logs quoting captured sessions |
| 15 test files (below) | contained or depended on verbatim captured speech |
| Personal identifiers | absolute home paths and email addresses |

### Test files removed, and the coverage lost with them

**This is a real reduction in coverage and is not claimed otherwise.**

| Removed test | Coverage lost |
|---|---|
| `DeviceLogAuditTests` | audit of 5 real sessions classifying every utterance TRACKING/HOLDING/LOST/FALSE-JUMP — including the known **LOST 3** failure |
| `CursorLostRegressionTests`, `CursorLostDiagnosticsTests` | the M5.2 cursor-lost P0 regression and its diagnosis |
| `OffScriptCommentaryHoldTests`, `MetaCommentaryFalseJumpTests` | false-jump protection during off-script speech |
| `DeviceFreezeReplayTests` | the M4 token-155 freeze regression |
| `StallDiagnosisTests`, `StallAssessmentTests` | the captured 9.6 s reading-stall diagnosis and its before/after measurement |
| `SuffixReacquisitionTests` | suffix re-acquisition and its per-utterance regression check |
| `TokenJoinTests`, `NumeralMismatchDeferredTests` | the split-token join and the `"2"`/`"two"` deferral evidence |
| `RetainedEvidenceTests`, `CapturedSessionMarkingTests` | capture-derived spoken-word marking cases |
| `Fixtures/DeviceTiming`, `Fixtures/DeviceHoldCatchUpCapture` | real inter-word timing and the hold-then-catch-up capture |

**No synthetic replacement reproduces any of these failures.** `Fixtures/SyntheticTiming.swift`
replaces the capture-derived timing with a plausible cadence so the fixture suite still runs at
non-constant intervals — it is explicitly *not* a reproduction of measured behaviour, and a
timing-sensitive regression cannot be investigated with it.

One capture-derived test was **kept**: `RealDeviceReadReplayTests`. It contains only demo-script
vocabulary plus one recognition error (`"write"` for `"written"`) and no personal utterance. Flagged
here so the judgement is visible and reversible.

## What was kept

The full application source, the Co-Interview handoff documents, and the inherited Prompter
engineering documentation (architecture, matching-engine reference, decisions) with captured
utterances redacted. That documentation describes **Prompter's** product and roadmap, not
Co-Interview's — see `CO_INTERVIEW_START_HERE.md`.

## Licensing

**No licence file exists.** It was absent from the original repository and none was invented here.
Without one, default copyright applies — all rights reserved. Add a licence before treating this as
open source.
