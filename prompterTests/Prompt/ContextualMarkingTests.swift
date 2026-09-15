import Testing
import Foundation
@testable import prompter

/// The M5.4 contextual-marking contract (docs/DECISIONS.md, 2026-09-12): a word may be confirmed by
/// direct recognition **or** by strong surrounding evidence of continuous reading — bounded, and
/// never across a landing the reader may have jumped over.
struct ContextualMarkingTests {

    private static let script = ScriptIndex.build(from: PromptDemoFixture.defaultScriptText).tokenTexts

    private static func bridged(_ direct: Set<Int>, breaks: Set<Int> = []) -> Set<Int> {
        PromptViewModel.bridgedTokens(
            directlySpoken: direct, continuityBreaks: breaks,
            maximumGap: PromptViewModel.maximumBridgedTokens
        )
    }

    /// **The screenshot case.** A misrecognised word inside a sentence the reader read through must
    /// not stay dark once the words either side are confirmed.
    @Test
    func aMisrecognisedWordIsBridgedOnceBothSidesAreConfirmed() {
        // Tokens 66-75 read; 70 misheard.
        let direct: Set<Int> = [66, 67, 68, 69, 71, 72, 73, 74, 75]
        #expect(Self.bridged(direct) == [70], "a single dark word between confirmed neighbours must be bridged")
    }

    /// Continuous reading with several ASR errors, followed by a clearly aligned next sentence.
    @Test
    func aShortGarbledRunIsBridgedWhenReadingClearlyContinued() {
        let direct: Set<Int> = [40, 41, 42, 46, 47, 48]      // 43-45 garbled
        #expect(Self.bridged(direct) == [43, 44, 45])
    }

    /// **A deliberately skipped sentence stays dark**, because the landing that crossed it is a
    /// continuity break.
    @Test
    func aDeliberateSkipIsNeverBridged() {
        let direct: Set<Int> = [40, 41, 120, 121]
        #expect(Self.bridged(direct, breaks: [120]).isEmpty, "a skip must not be coloured")
        // …and even without a recorded break, the gap is far beyond the bound.
        #expect(Self.bridged(direct).isEmpty)
    }

    /// The bound is a clause, not a sentence: anything longer stays dark.
    @Test
    func gapsLongerThanTheBoundStayDark() {
        let justInside: Set<Int> = [10, 10 + PromptViewModel.maximumBridgedTokens + 1]
        #expect(!Self.bridged(justInside).isEmpty, "a gap at the bound must bridge")
        let justOutside: Set<Int> = [10, 10 + PromptViewModel.maximumBridgedTokens + 2]
        #expect(Self.bridged(justOutside).isEmpty, "one token past the bound must not bridge")
    }

    /// A break *inside* the gap stops the bridge even when the gap is short.
    @Test
    func aBreakInsideAShortGapStopsTheBridge() {
        let direct: Set<Int> = [50, 54]
        #expect(Self.bridged(direct) == [51, 52, 53])
        #expect(Self.bridged(direct, breaks: [52]).isEmpty, "a landing inside the gap must stop it")
    }

    /// Off-script commentary produces no anchor after the gap, so nothing is inferred.
    @Test
    func offScriptCommentaryProducesNoInferredCoverage() {
        let direct: Set<Int> = [30, 31, 32]        // reading stopped here; commentary follows
        #expect(Self.bridged(direct).isEmpty, "with no later anchor there is nothing to bridge between")
    }

    /// **Direct marking now uses recent history**, so a reacquisition supported by a clause in the
    /// buffer marks what that clause covers — and still never the interval it jumped.
    @Test
    func aReacquisitionMarksTheClauseThatSupportedIt() {
        // Script 176-234 is ¶4. Take a real run and feed it as history with the landing at its end.
        let start = 200
        let history = Array(Self.script[start..<(start + 8)])
        let marked = PromptViewModel.newlySpokenTokens(
            fedWords: history, from: 151, to: start + 8, state: .recovering, scriptTokens: Self.script
        )
        #expect(marked == Set(start..<(start + 8)), "the supporting clause must be marked, got \(marked.sorted())")
        for skipped in 151..<start {
            #expect(!marked.contains(skipped), "the jumped interval must stay dark; \(skipped) was marked")
        }
    }

    /// A single substitution no longer discards the rest of the feed; two in a row still stop it.
    @Test
    func oneSubstitutionIsSkippedButAnInsertionStillStops() {
        // "this is a longer test" with one word misheard in the middle.
        let oneBad = PromptViewModel.newlySpokenTokens(
            fedWords: ["this", "is", "zzzz", "longer", "test"], from: 3, to: 8, state: .advancing, scriptTokens: Self.script
        )
        #expect(oneBad == [3, 4, 6, 7], "a single substitution must not discard the words before it, got \(oneBad.sorted())")

        // Two consecutive failures — the signature of an insertion shifting every earlier pair.
        let shifted = PromptViewModel.newlySpokenTokens(
            fedWords: ["zzzz", "qqqq", "a", "longer", "test"], from: 3, to: 8, state: .advancing, scriptTokens: Self.script
        )
        #expect(shifted == [5, 6, 7], "two consecutive failures must stop the walk, got \(shifted.sorted())")
    }
}
