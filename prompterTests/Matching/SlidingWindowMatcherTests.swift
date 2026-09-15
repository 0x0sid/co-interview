import Testing
import Foundation
@testable import prompter

/// Replays the full fixture suite (§16 M1 gate) through the real matcher and asserts the two
/// required metrics: mean cursor error <= 2 tokens, false-jump rate <= 1 per 500 spoken words.
/// Numbers are printed so a real, named test run backs every figure quoted in
/// AGENT_PROGRESS.md / docs/MATCHING_ENGINE.md (§24.6 — no invented numbers).
struct SlidingWindowMatcherTests {
    /// A cursor landing this far from the ground truth while the matcher reports it moved with
    /// real confidence (advancing/recovering, not holding/frozen) counts as a false jump. Chosen
    /// comfortably above the alignment window (9) and the forward cap (6) so ordinary alignment
    /// slop during legitimate matches never counts as one.
    static let falseJumpTokenTolerance = 15

    struct ReplayOutcome {
        let scriptName: String
        let scenario: String
        let errors: [Int]
        let falseJumps: Int
        let spokenWords: Int
    }

    static func replay(_ fixture: FixtureTranscript, config: MatcherConfig = .default) -> ReplayOutcome {
        let matcher = SlidingWindowMatcher(scriptTokens: fixture.scriptTokens, config: config)
        var errors: [Int] = []
        errors.reserveCapacity(fixture.checkpoints.count)
        var falseJumps = 0

        for checkpoint in fixture.checkpoints {
            let cursor = matcher.advance(spoken: checkpoint.tokens, now: checkpoint.now)
            let error = abs(cursor.tokenIndex - checkpoint.expectedCursor)
            errors.append(error)
            let movedWithConfidence = cursor.state == .advancing || cursor.state == .recovering
            if movedWithConfidence, error > falseJumpTokenTolerance {
                falseJumps += 1
            }
        }

        return ReplayOutcome(
            scriptName: fixture.scriptName,
            scenario: fixture.scenario,
            errors: errors,
            falseJumps: falseJumps,
            spokenWords: fixture.spokenWordCount
        )
    }

    @Test
    func fixtureSuiteMeetsM1Gate() {
        let outcomes = FixtureSuite.all.map { Self.replay($0) }

        var report = ""
        for outcome in outcomes {
            let mean = Double(outcome.errors.reduce(0, +)) / Double(outcome.errors.count)
            report += "\(outcome.scriptName)/\(outcome.scenario): meanError=\(String(format: "%.3f", mean)) falseJumps=\(outcome.falseJumps) spokenWords=\(outcome.spokenWords)\n"
        }

        let allErrors = outcomes.flatMap(\.errors)
        let totalFalseJumps = outcomes.reduce(0) { $0 + $1.falseJumps }
        let totalSpokenWords = outcomes.reduce(0) { $0 + $1.spokenWords }

        let meanCursorError = Double(allErrors.reduce(0, +)) / Double(allErrors.count)
        let falseJumpRatePer500Words = Double(totalFalseJumps) / (Double(totalSpokenWords) / 500.0)

        report += "TOTAL fixtures=\(outcomes.count) checkpoints=\(allErrors.count) spokenWords=\(totalSpokenWords)\n"
        report += "TOTAL meanCursorError=\(meanCursorError) tokens (gate: <= 2.0)\n"
        report += "TOTAL falseJumps=\(totalFalseJumps) falseJumpRate=\(falseJumpRatePer500Words) per 500 words (gate: <= 1.0)\n"

        try? report.write(toFile: "/tmp/m1_replay_results.txt", atomically: true, encoding: .utf8)
        print(report)

        #expect(meanCursorError <= 2.0)
        #expect(falseJumpRatePer500Words <= 1.0)
    }
}
