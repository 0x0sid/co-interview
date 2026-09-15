import Testing
import Foundation
@testable import prompter

/// Dedicated tests for the §10.4 hysteresis rules, each isolated with hand-crafted scripts so
/// the expected cursor position can be computed by hand rather than relying on the fixture
/// suite's statistical gate.
struct ConfidenceHysteresisTests {
    @Test
    func backwardCapLimitsRegressionOnARepeatedPhrase() {
        let script = (0..<20).map { "w\($0)" }
        let matcher = SlidingWindowMatcher(scriptTokens: script, config: .init(alignmentWindow: 3))

        // Establish cursor at 8 by speaking w5, w6, w7 (anchor 5 + window 3).
        let first = matcher.advance(
            spoken: [Token("w5", at: 1.0), Token("w6", at: 1.4), Token("w7", at: 1.8)],
            now: 1.8
        )
        #expect(first.tokenIndex == 8)
        #expect(first.state == .advancing)

        // Repeat an earlier phrase (w1, w2, w3): the true anchor (1) would put the cursor at 4,
        // more than 3 tokens behind the current position of 8 — the backward cap must clamp it.
        let second = matcher.advance(
            spoken: [Token("w1", at: 2.2), Token("w2", at: 2.6), Token("w3", at: 3.0)],
            now: 3.0
        )
        #expect(second.tokenIndex == 8 - 3)
        #expect(second.tokenIndex != 4, "raw anchor match would have been 4; the cap must prevent landing exactly there")
    }

    @Test
    func forwardCapLimitsBigJumpsWithoutRecoveryGradeConfidence() {
        // Per-token similarity below the 0.8 match threshold contributes exactly 0 (§10.3), so a
        // single-token window can never land strictly between advanceThreshold (0.72) and
        // recoveryJumpThreshold (0.80) — a blend is needed. With alignmentWindow = 3 and the
        // default recency weights (1.0 / 1.5 / 2.0 for oldest -> newest), one mismatched oldest
        // token plus two exact-matching newer tokens scores (0 + 1.5 + 2.0) / 4.5 = 0.778, which
        // sits inside that band.
        let script = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
                       "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
                       "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]
        let matcher = SlidingWindowMatcher(scriptTokens: script, config: .init(alignmentWindow: 3))

        let cursor = matcher.advance(
            spoken: [Token("zzzzzzzzzz", at: 1.0), Token("eleven", at: 1.4), Token("twelve", at: 1.8)],
            now: 1.8
        )
        #expect(cursor.state == .advancing)
        #expect(cursor.confidence >= 0.72 && cursor.confidence < 0.80)
        // Raw target would be anchor(10) + window(3) = 13; forward cap from cursor 0 allows at
        // most +6.
        #expect(cursor.tokenIndex == 6)
    }

    @Test
    func silenceFreezesTheCursorAfterThreshold() {
        let script = (0..<10).map { "w\($0)" }
        let matcher = SlidingWindowMatcher(scriptTokens: script)

        let spoken = matcher.advance(spoken: [Token("w0", at: 1.0)], now: 1.0)
        let cursorBeforeGap = spoken.tokenIndex

        // 1.0s gap: below the 1.5s freeze threshold, no freeze yet.
        let short = matcher.advance(spoken: [], now: 2.0)
        #expect(short.state != .frozen)

        // 2.0s gap from the last spoken token: exceeds the 1.5s threshold.
        let frozen = matcher.advance(spoken: [], now: 3.0)
        #expect(frozen.state == .frozen)
        #expect(frozen.tokenIndex == cursorBeforeGap, "a silence freeze must never move the cursor")
    }

    @Test
    func sustainedMediocreConfidenceArmsRecoveryEvenWithoutEverGoingFullyLow() {
        // M4 (2026-08-14): a score that never drops below recoveryTriggerThreshold but never
        // clears advanceThreshold either used to reset the recovery timer on every tick,
        // letting the cursor stall indefinitely — this reproduces exactly that band and checks
        // the new mediocreConfidenceSustainedSeconds escape hatch.
        var script = (0..<150).map { "tok\($0)" }
        script[0] = "alpha"
        script[1] = "beta"
        script[2] = "somethingElseLocal"
        script[100] = "alpha"
        script[101] = "beta"
        script[102] = "gamma"
        let matcher = SlidingWindowMatcher(scriptTokens: script, config: .init(alignmentWindow: 3))

        // Oldest two tokens exact-match anchor 0's window, the newest doesn't: recency-weighted
        // score (weights 1.0/1.5/2.0 for a 3-window at the default recencyWeightMultiplier) is
        // (1.0*1.0 + 1.0*1.5 + 0.0*2.0) / 4.5 ≈ 0.556 — inside the ambiguous middle band
        // (0.45–0.72), nowhere near the low band the existing recovery trigger watches.
        func mediocreWindow(at time: TimeInterval) -> [Token] {
            [Token("alpha", at: time), Token("beta", at: time), Token("gamma", at: time)]
        }

        let first = matcher.advance(spoken: mediocreWindow(at: 1.0), now: 1.0)
        #expect(first.state == .holding)
        #expect(first.tokenIndex == 0)
        #expect(first.confidence > 0.45 && first.confidence < 0.72, "must land in the ambiguous middle band, not the low band")

        // 3.0s since the first mediocre tick: still under mediocreConfidenceSustainedSeconds (4.0s).
        let second = matcher.advance(spoken: mediocreWindow(at: 4.0), now: 4.0)
        #expect(second.state == .holding)
        #expect(second.tokenIndex == 0)

        // 4.5s since the first tick: crosses the mediocre-stall threshold. Recovery search finds
        // the exact "alpha beta gamma" match at script[100...102] (score 1.0, clears
        // recoveryJumpThreshold) even though local confidence never touched the low band.
        let third = matcher.advance(spoken: mediocreWindow(at: 5.5), now: 5.5)
        #expect(third.state == .recovering)
        #expect(third.tokenIndex == 103)
    }

    @Test
    func recoveryOnlyTriggersAfterSustainedLowConfidence() {
        var script = (0..<150).map { "tok\($0)" }
        script[100] = "zzzzzzzzzz"
        let matcher = SlidingWindowMatcher(scriptTokens: script, config: .init(alignmentWindow: 1))

        // First low-confidence tick starts the sustain timer; not yet 2.5s, so the cursor holds.
        let first = matcher.advance(spoken: [Token("zzzzzzzzzz", at: 1.0)], now: 1.0)
        #expect(first.state == .holding)
        #expect(first.tokenIndex == 0)

        // Still under 2.5s of sustained low confidence.
        let second = matcher.advance(spoken: [Token("zzzzzzzzzz", at: 2.0)], now: 2.0)
        #expect(second.state == .holding)
        #expect(second.tokenIndex == 0)

        // Now 3.0s since the first low-confidence tick: recovery search runs and finds the
        // distinctive word 100 tokens ahead.
        let third = matcher.advance(spoken: [Token("zzzzzzzzzz", at: 4.0)], now: 4.0)
        #expect(third.state == .recovering)
        #expect(third.tokenIndex == 101)
    }
}
