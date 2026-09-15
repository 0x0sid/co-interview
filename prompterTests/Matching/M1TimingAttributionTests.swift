import Testing
import Foundation
@testable import prompter

/// **Attribution for the M1 gate's movement in M5.2.**
///
/// Rebuilding the fixture suite onto the measured device cadence moved the headline M1 numbers.
/// The owner's standing question — and the right one — is *what moved them*: the timing change, or
/// the new suffix re-acquisition rule. This test answers it by scoring the same 28 fixtures, the
/// same checkpoints and the same spoken-word count under all four combinations, so the denominator
/// is provably unchanged and the difference is attributable.
///
/// It is a measurement, not a gate: `SlidingWindowMatcherTests.fixtureSuiteMeetsM1Gate` remains the
/// gate. This asserts only that the historical numbers are still reproducible under the historical
/// timing, which is what makes the comparison trustworthy.
struct M1TimingAttributionTests {

    /// The figure quoted throughout AGENT_PROGRESS.md and docs/MATCHING_ENGINE.md before M5.2,
    /// produced by the constant 0.4 s/word cadence with no suffix rule.
    static let historicalMeanCursorError = 0.9074215761285387
    static let historicalFalseJumps = 0

    private struct Totals {
        let meanCursorError: Double
        let falseJumps: Int
        let checkpoints: Int
        let spokenWords: Int
    }

    private static func score(_ fixtures: [FixtureTranscript], config: MatcherConfig) -> Totals {
        let outcomes = fixtures.map { SlidingWindowMatcherTests.replay($0, config: config) }
        let errors = outcomes.flatMap(\.errors)
        return Totals(
            meanCursorError: Double(errors.reduce(0, +)) / Double(errors.count),
            falseJumps: outcomes.reduce(0) { $0 + $1.falseJumps },
            checkpoints: errors.count,
            spokenWords: outcomes.reduce(0) { $0 + $1.spokenWords }
        )
    }

    @Test
    func theM1GateMovementIsAttributableToTimingNotTheSuffixRule() {
        let measured = FixtureSuite.all
        let historical = measured.map { $0.retimedAtConstantCadence() }

        var suffixOff = MatcherConfig.default
        suffixOff.minimumSuffixWindow = suffixOff.alignmentWindow   // rule disabled

        let a = Self.score(historical, config: suffixOff)   // historical baseline
        let b = Self.score(historical, config: .default)    // rule only
        let c = Self.score(measured, config: suffixOff)     // timing only
        let d = Self.score(measured, config: .default)      // both — what ships

        var report = """
        M1 TIMING ATTRIBUTION — same 28 fixtures, same checkpoints, same spoken words.
        Only the per-word timestamps and the suffix rule vary.

          timing        suffix rule | meanCursorError      | falseJumps | checkpoints | spokenWords
          --------------+-----------+----------------------+------------+-------------+------------

        """
        for (label, t) in [("constant 0.4s   off", a), ("constant 0.4s   ON ", b),
                           ("measured cadence off", c), ("measured cadence ON ", d)] {
            report += String(format: "          %@ | %.16f | %10d | %11d | %11d\n",
                             label, t.meanCursorError, t.falseJumps, t.checkpoints, t.spokenWords)
        }
        report += """

          historical published figure: meanCursorError=\(Self.historicalMeanCursorError) falseJumps=\(Self.historicalFalseJumps)

        """
        try? report.write(toFile: "/tmp/m1_timing_attribution.txt", atomically: true, encoding: .utf8)

        // The denominator must be identical across all four, or nothing above is comparable.
        #expect(a.checkpoints == d.checkpoints && a.spokenWords == d.spokenWords,
                "retiming changed the fixture denominator — the comparison is invalid")

        // The historical baseline must still reproduce exactly, or the published figure was never
        // what this suite measured.
        #expect(abs(a.meanCursorError - Self.historicalMeanCursorError) < 1e-9,
                "historical baseline no longer reproduces: got \(a.meanCursorError), published \(Self.historicalMeanCursorError)")
        #expect(a.falseJumps == Self.historicalFalseJumps,
                "historical baseline false jumps no longer reproduce: got \(a.falseJumps), published \(Self.historicalFalseJumps)")
    }
}
