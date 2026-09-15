import Foundation

/// The live matching loop (§10.2) and hysteresis rules (§10.4). Pure Foundation, synchronous,
/// deterministic: every input is a `Token` carrying its own audio-time timestamp, and every call
/// takes an explicit `now`, so the whole state machine is fully replay-testable without a real
/// clock or a microphone (§24.4, §24.5).
final class SlidingWindowMatcher {
    private let scriptTokens: [String]
    private let config: MatcherConfig

    private var ringBuffer: [String] = []
    private var cursor: Int = 0
    private var confidence: Double = 0
    private var state: PromptCursor.State = .holding
    private var lastTokenTimestamp: TimeInterval?
    /// Set the moment the local-search score first drops below `advanceThreshold` (either the
    /// low band or the ambiguous middle band), cleared on any real advance. Shared across both
    /// bands — deliberately not reset when the score crosses between them mid-stall — so a
    /// sequence that hovers near the low/mediocre boundary accumulates one continuous stall
    /// duration rather than resetting on every crossing (M4, docs/MATCHING_ENGINE.md).
    private var stalledSince: TimeInterval?
    /// Best recovery candidate seen since `stalledSince` was set, snapshotted on *every* stalled
    /// tick (not just the tick the sustain timer arms on) and reset alongside `stalledSince`.
    /// Decouples evidence-gathering from permission-to-act: the ring buffer's useful content can
    /// be evicted by newer speech before the timer allows a jump, so acting on a retained best
    /// snapshot — rather than a fresh search against whatever the ring buffer holds on the exact
    /// tick the timer happens to arm — is what actually fixes the freeze (M4,
    /// docs/MATCHING_ENGINE.md — token-155 freeze/timer-eviction race on build 56ba154).
    /// `capturedAt` is what stops this going stale: the snapshot must outlive the sustain timer,
    /// but retaining it indefinitely froze a mediocre early candidate for a whole session (M5.2 —
    /// see `stallCandidateFreshnessSeconds`).
    private var bestStallCandidate: (candidate: RecoverySearch.Candidate, windowSize: Int, capturedAt: TimeInterval)?

    /// The previous update's best local anchor, and how many consecutive updates it has advanced
    /// consistently with freshest-token support. See `MatcherConfig.trackedRunLength`.
    private var previousLocalAnchor: Int?
    private var consistentAnchorRun = 0

    #if DEBUG
    /// Read-only view of the tracked-read run for tests. Observation only — nothing in the engine
    /// reads it, so it cannot change matching behaviour.
    var debugConsistentAnchorRun: Int { consistentAnchorRun }

    /// Every diagnostic line this matcher has emitted, in order.
    ///
    /// This exists so the **logging path itself** can be verified rather than assumed. A device
    /// protocol that reads "the absence of `[Join]` means the join did not fire" is only sound if
    /// the `[Join]` emission has been positively observed somewhere; `xcodebuild` does not surface
    /// test stdout, so the print alone cannot be checked. `emitDebugLog` is the single place any
    /// such line is produced, so a test asserting on this array is asserting on the exact string
    /// that `print` receives.
    private(set) var debugEmittedLogLines: [String] = []

    /// The one emission point for matcher diagnostics. Records first, then prints, so what a test
    /// sees and what the device console sees are the same string from the same call.
    private func emitDebugLog(_ line: String) {
        debugEmittedLogLines.append(line)
        print(line)
    }

    /// Monotonic count of spoken tokens fed to this matcher, so a logged join can be located in an
    /// unfiltered device transcript. Diagnostic only — nothing in the engine reads it.
    private var debugSpokenSequence = 0
    private var debugJoinLastTick: [Int: Int] = [:]
    private var debugJoinOccurrence: [Int: Int] = [:]
    private var debugJoinObservation: [Int: Int] = [:]

    /// Distinguishes *re-observing the same join through overlapping windows* from a genuinely new
    /// occurrence of the same compound.
    ///
    /// The alignment is re-scored from scratch every tick, so one compound is reported once per tick
    /// for as long as it stays inside the `alignmentWindow`. A site can therefore persist for at
    /// most `alignmentWindow` ticks; if it reappears after a longer gap the window has fully turned
    /// over, which means the reader reached that text again — a new occurrence.
    private func debugClassifyJoin(site scriptIndex: Int) -> (occurrence: Int, observation: Int) {
        let previousTick = debugJoinLastTick[scriptIndex]
        let sameOccurrence = previousTick.map { debugSpokenSequence - $0 <= config.alignmentWindow } ?? false
        if sameOccurrence {
            debugJoinObservation[scriptIndex, default: 1] += 1
        } else {
            debugJoinOccurrence[scriptIndex, default: 0] += 1
            debugJoinObservation[scriptIndex] = 1
        }
        debugJoinLastTick[scriptIndex] = debugSpokenSequence
        return (debugJoinOccurrence[scriptIndex] ?? 1, debugJoinObservation[scriptIndex] ?? 1)
    }
    #endif

    init(scriptTokens: [String], config: MatcherConfig = .default) {
        self.scriptTokens = scriptTokens
        self.config = config
    }

    convenience init(scriptIndex: ScriptIndex, config: MatcherConfig = .default) {
        self.init(scriptTokens: scriptIndex.tokenTexts, config: config)
    }

    var current: PromptCursor {
        PromptCursor(tokenIndex: cursor, confidence: confidence, state: state)
    }

    /// Advances the matcher with newly spoken (already-normalized) tokens, or an empty array to
    /// represent a time tick with no new speech (used to detect silence).
    @discardableResult
    func advance(spoken newTokens: [Token], now: TimeInterval) -> PromptCursor {
        if newTokens.isEmpty {
            let gap = now - (lastTokenTimestamp ?? now)
            if gap > config.silenceFreezeSeconds {
                state = .frozen
            }
            return current
        }

        ingest(newTokens)

        #if DEBUG
        debugSpokenSequence += newTokens.count
        #endif

        let spokenWindow = Array(ringBuffer.suffix(config.alignmentWindow))
        guard !spokenWindow.isEmpty else {
            state = .holding
            confidence = 0
            return current
        }

        let localRange = (cursor - config.localSearchBackward)..<(cursor + config.localSearchForward)
        let localBest = RecoverySearch.bestAnchor(
            spokenWindow: spokenWindow,
            scriptTokens: scriptTokens,
            range: localRange,
            config: config,
            allowJoin: true            // local search only — recovery and suffix stay strictly 1:1
        )

        guard let localBest else {
            state = .holding
            confidence = 0
            return current
        }

        // A high aggregate score alone isn't enough to advance: it can come almost entirely from
        // older, already-confirmed matches still sitting in the window while the newest word is
        // unrelated noise (an off-script ad-lib). `hasFreshestTokenSupport` requires the newest
        // word specifically to support the advance, not just the window average (§10.4).
        // Join-aware: a join shifts the script index the newest spoken word lands on, so the gate
        // must ask about that position rather than `anchor + windowSize - 1` (§12, M5.6).
        let hasFreshest = RecoverySearch.hasFreshestTokenSupport(spokenWindow: spokenWindow, scriptTokens: scriptTokens, candidate: localBest, config: config)

        // A run of consistently advancing, freshest-supported local anchors is evidence in its own
        // right that the alignment is following the reader (M5.5, docs/MATCHING_ENGINE.md). The run
        // is tracked here so a *tracked* read can clear a lower bar.
        //
        // Exact rule, because the boundaries matter more than the intent:
        //   * one observation per `advance` call that reaches this point — an observation is a new
        //     matcher tick, **not** necessarily a new word, so re-feeding the same word counts;
        //   * `step == 0` **counts**. A stationary anchor extends the run. This is deliberate (the
        //     reader pausing mid-window should not have to rebuild the run) but it does mean the
        //     run is not proof of forward progress, only of a stable, freshest-supported alignment;
        //   * a backward step, a step larger than `trackedAnchorStep`, or lost freshest support
        //     breaks the run — to 1 if this tick still has freshest support, otherwise to 0;
        //   * recovery is **not** reset explicitly. `previousLocalAnchor` keeps the pre-jump value,
        //     so the tick after a jump sees a large step and breaks the run itself. Covered by
        //     `StallAssessmentTests.aRecoveryJumpDoesNotLeaveAStaleRunBehind`.
        let step = previousLocalAnchor.map { localBest.anchor - $0 }
        if hasFreshest, let step, step >= 0, step <= config.trackedAnchorStep {
            consistentAnchorRun += 1
        } else {
            consistentAnchorRun = hasFreshest ? 1 : 0
        }
        previousLocalAnchor = localBest.anchor

        let isTrackedRead = consistentAnchorRun >= config.trackedRunLength
        let requiredScore = isTrackedRead ? config.trackedAdvanceThreshold : config.advanceThreshold
        let canAdvance = localBest.score >= requiredScore && hasFreshest

        #if DEBUG
        // Reported for the *selected* alignment whether or not it moved the cursor: "the join
        // scored but the advance was refused" and "the join never happened" are different
        // findings, and a device capture has to tell them apart.
        //
        // Every field names the join **site**, never the newest word in the window. An earlier
        // version logged `spokenWindow.last` and the pair at `freshestScriptIndex`, emitting
        // e.g. `heard=smoothly script="smoothly once"` for a window whose only join was
        // `backup` -> `back up` — describing joins that never happened.
        for site in localBest.joinSites where site.scriptIndex + 1 < scriptTokens.count {
            let heard = site.spokenIndex < spokenWindow.count ? spokenWindow[site.spokenIndex] : "?"
            let counts = debugClassifyJoin(site: site.scriptIndex)
            let destination = min(localBest.anchor + localBest.scriptConsumed, scriptTokens.count)
            emitDebugLog(String(
                format: "[Join] role=%@ site=%d script=[%d..<%d]=\"%@ %@\" heard=\"%@\" win#%d seq#%d occ=%d obs=%d anchor=%d consumed=%d cursor=%d->%d score=%.3f",
                (canAdvance ? "selected" : "evaluated") as NSString,
                site.scriptIndex, site.scriptIndex, site.scriptIndex + 2,
                scriptTokens[site.scriptIndex] as NSString, scriptTokens[site.scriptIndex + 1] as NSString,
                heard as NSString, site.spokenIndex, debugSpokenSequence,
                counts.occurrence, counts.observation,
                localBest.anchor, localBest.scriptConsumed,
                cursor, canAdvance ? destination : cursor,
                localBest.score))
        }
        #endif

        if canAdvance {
            // `scriptConsumed`, not the spoken count: a join covers two script tokens with one
            // spoken word, and the cursor belongs past both because the reader said both. On the
            // 1:1 path these are identical, so ordinary reading is unaffected.
            applyAdvance(anchor: localBest.anchor, windowSize: localBest.scriptConsumed, score: localBest.score)
            stalledSince = nil
            bestStallCandidate = nil
        } else if let reacquisition = suffixReacquisition(spokenWindow: spokenWindow, range: localRange) {
            // The reader has resumed reading and the window straddles the boundary — its older
            // half is the ad-lib they just finished, its newer half is real reading, so no anchor
            // scores well against the whole thing. The newest few words do (§ M5.2,
            // docs/MATCHING_ENGINE.md).
            //
            // Classified as **recovery, not advance**, and that is load-bearing rather than
            // cosmetic. `PromptViewModel.applyCursor` marks every token between the old and new
            // cursor as *spoken* when the state is `.advancing`, and a suffix re-acquisition can
            // legitimately move the cursor a long way — the reader was elsewhere and has been
            // found again, not read every word in between. Labelling it `.advancing` would grey
            // out text the reader demonstrably never said, which is exactly the invariant
            // established in "Grey means you actually said this — never infer it from cursor
            // position". Recovery is the honest label for "you are somewhere else and we found
            // you", and `applyCursor` already declines to mark spans spoken for it.
            applyAdvance(anchor: reacquisition.anchor, windowSize: reacquisition.windowSize, score: reacquisition.score, isRecovery: true)
            stalledSince = nil
            bestStallCandidate = nil
        } else if localBest.score < config.recoveryTriggerThreshold {
            confidence = localBest.score
            if stalledSince == nil {
                stalledSince = now
            }
            snapshotStallCandidate(now: now)
            let sustained = now - (stalledSince ?? now) >= config.recoverySustainedSeconds
            if sustained, applyBestStallCandidateIfAboveThreshold(now: now) {
                // applied
            } else {
                state = .holding
            }
        } else {
            // Ambiguous middle zone: not confident enough to advance, not low enough to satisfy
            // the low-confidence recovery path above — but sustained *mediocre* confidence is
            // its own stall that deserves a (longer) escape hatch too, or the cursor can sit
            // here indefinitely, which is exactly the on-device "stuck" report this fixed
            // (docs/MATCHING_ENGINE.md, M4). Note this does NOT touch `recoveryJumpThreshold`:
            // escaping the stall still requires `RecoverySearch` to find a genuinely strong
            // match, same bar as the low-confidence path already uses.
            confidence = localBest.score
            state = .holding
            if stalledSince == nil {
                stalledSince = now
            }
            snapshotStallCandidate(now: now)
            let stalled = now - (stalledSince ?? now) >= config.mediocreConfidenceSustainedSeconds
            if stalled {
                _ = applyBestStallCandidateIfAboveThreshold(now: now)
            }
        }

        return current
    }

    /// Re-scores the newest K spoken words against the same local range when the full window has
    /// failed, returning the **longest** suffix that clears `suffixJumpThreshold` (§ M5.2,
    /// docs/MATCHING_ENGINE.md — the full rule table lives there).
    ///
    /// Longer suffixes are preferred because they carry more evidence. Every suffix is held to the
    /// same `suffixJumpThreshold` (0.92) — measured, not assumed: off-script speech scores *higher*
    /// at wider suffixes against this script, so a ramp that eased the bar for wide windows would
    /// have let a W8 off-script suffix fire at 0.833. `minimumSuffixWindow` (5) stops the search
    /// before windows so short that a coincidence is likely regardless of score.
    ///
    /// Deliberately confined to the **local** range. The M5.1 59 → 214 false jump was produced by
    /// the whole-script recovery search; a local candidate cannot move further than
    /// `localSearchForward`, so this path is structurally incapable of reproducing it.
    /// `hasFreshestTokenSupport` is still required, so a suffix cannot ride forward on older
    /// matches with an unrelated newest word.
    private func suffixReacquisition(spokenWindow: [String], range: Range<Int>) -> (anchor: Int, windowSize: Int, score: Double)? {
        guard spokenWindow.count > config.minimumSuffixWindow else { return nil }
        for size in stride(from: spokenWindow.count - 1, through: config.minimumSuffixWindow, by: -1) {
            let suffix = Array(spokenWindow.suffix(size))
            guard let best = RecoverySearch.bestAnchor(
                spokenWindow: suffix,
                scriptTokens: scriptTokens,
                range: range,
                config: config,
                requireDistinctiveSupport: config.suffixRequiresDistinctiveSupport
            ), best.score >= config.suffixJumpThreshold else { continue }
            guard RecoverySearch.hasFreshestTokenSupport(
                spokenWindow: suffix, scriptTokens: scriptTokens, anchor: best.anchor, config: config
            ) else { continue }
            return (best.anchor, size, best.score)
        }
        return nil
    }

    /// Scores a recovery candidate against the *current* ring buffer and retains it if it beats
    /// whatever was previously seen during this stall (§ "Fix 2: stall-candidate snapshot",
    /// docs/MATCHING_ENGINE.md). Called on every stalled tick, independent of whether the sustain
    /// timer has armed — evidence-gathering is unconditional, only acting on it is gated.
    private func snapshotStallCandidate(now: TimeInterval) {
        // Expire first, so a candidate that has outlived its usefulness cannot outrank a fresh one
        // purely by having been captured when the ring buffer happened to look better. Retaining
        // the best-ever score forever froze a 0.667 candidate at the wrong anchor for an entire
        // session on the measured trace (M5.2).
        if let retained = bestStallCandidate, now - retained.capturedAt > config.stallCandidateFreshnessSeconds {
            bestStallCandidate = nil
        }
        let recoveryWindow = Array(ringBuffer.suffix(config.recoveryAlignmentWindow))
        guard let candidate = RecoverySearch.bestStallCandidate(
            spokenWindow: recoveryWindow,
            scriptTokens: scriptTokens,
            cursor: cursor,
            config: config
        ) else { return }
        if bestStallCandidate == nil || candidate.score > bestStallCandidate!.candidate.score {
            bestStallCandidate = (candidate, recoveryWindow.count, now)
        }
    }

    /// Applies the retained best-of-stall candidate if it clears the required jump bar, and
    /// clears the stall state either way once the timer has armed and a real decision is made.
    /// Returns whether it was applied.
    ///
    /// The bar itself depends on how long the stall has run (M5.1): a *long* low-confidence
    /// stretch is much more likely to be genuine off-script speech than misrecognized on-script
    /// speech, so a candidate found there must align near-perfectly rather than merely well. This
    /// is the only signal that separates the two cases — the real failure it fixes was a speaker
    /// describing the app's behavior in almost exactly the script's own words, which no
    /// content-based check (including `requireDistinctiveSupport`, which it passed with seven
    /// distinctive matches) can distinguish from real reading.
    private func applyBestStallCandidateIfAboveThreshold(now: TimeInterval) -> Bool {
        let stallDuration = now - (stalledSince ?? now)
        let requiredScore = stallDuration >= config.extendedStallSeconds
            ? config.extendedStallJumpThreshold
            : config.recoveryJumpThreshold
        guard let snapshot = bestStallCandidate,
              now - snapshot.capturedAt <= config.stallCandidateFreshnessSeconds,
              snapshot.candidate.score >= requiredScore else {
            return false
        }
        applyAdvance(anchor: snapshot.candidate.anchor, windowSize: snapshot.windowSize, score: snapshot.candidate.score, isRecovery: true)
        stalledSince = nil
        bestStallCandidate = nil
        return true
    }

    private func ingest(_ newTokens: [Token]) {
        lastTokenTimestamp = newTokens.last?.timestamp
        for token in newTokens {
            if let previous = ringBuffer.last, config.fillerBigrams.contains([previous, token.text]) {
                ringBuffer.removeLast()
                continue
            }
            if config.fillerStoplist.contains(token.text) {
                continue
            }
            ringBuffer.append(token.text)
            if ringBuffer.count > config.ringBufferSize {
                ringBuffer.removeFirst()
            }
        }
    }

    private func applyAdvance(anchor: Int, windowSize: Int, score: Double, isRecovery: Bool = false) {
        var newCursor = min(anchor + windowSize, scriptTokens.count)

        // Hysteresis (§10.4): never move backward more than `backwardCap` tokens.
        newCursor = max(newCursor, cursor - config.backwardCap)

        // Never jump forward more than `forwardCapWithoutRecovery` tokens without recovery-grade
        // confidence.
        if !isRecovery, score < config.recoveryJumpThreshold, newCursor - cursor > config.forwardCapWithoutRecovery {
            newCursor = cursor + config.forwardCapWithoutRecovery
        }

        cursor = newCursor
        confidence = score
        state = isRecovery ? .recovering : .advancing
    }
}
