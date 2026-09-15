import Testing
import Foundation
@testable import prompter

/// The presentation contract's first requirement: **a word goes grey only when it was individually
/// confirmed spoken.** Greyness may never be deduced from where the cursor went.
///
/// The rule these exercise, `PromptViewModel.newlySpokenTokens`, replaced one that inserted the
/// whole interval `previous..<new` on any `.advancing` move. On the 2026-09-10 device session that
/// greyed 29 tokens at once on the `155 -> 184 advancing` step at 94.041 s — text the reader never
/// said, which is what the screenshots show.
struct SpokenTokenMarkingTests {

    private static let script = ScriptIndex.build(from: PromptDemoFixture.defaultScriptText).tokenTexts

    private static func spoken(_ words: [String], from: Int, to: Int, state: PromptCursor.State = .advancing) -> Set<Int> {
        PromptViewModel.newlySpokenTokens(fedWords: words, from: from, to: to, state: state, scriptTokens: script)
    }

    /// Ordinary reading: each word confirmed one at a time greys exactly its own token.
    @Test
    func ordinaryReadingGreysOnlyTheWordJustSpoken() {
        // Script tokens 0-2 are "welcome to prompter".
        #expect(Self.spoken(["welcome"], from: 0, to: 1) == [0])
        #expect(Self.spoken(["to"], from: 1, to: 2) == [1])
        #expect(Self.spoken(["prompter"], from: 2, to: 3) == [2])
    }

    /// A whole paragraph may go grey — but only by accumulating individually confirmed words.
    @Test
    func aParagraphGoesGreyOnlyByAccumulatingConfirmedWords() {
        var accumulated: Set<Int> = []
        for index in 0..<36 {                      // paragraph 1 is tokens 0...35
            accumulated.formUnion(Self.spoken([Self.script[index]], from: index, to: index + 1))
        }
        #expect(accumulated == Set(0..<36), "reading every word of ¶1 should grey exactly ¶1")
        #expect(!accumulated.contains(36), "¶2's first token must stay dark")
    }

    /// **The device defect.** A 29-token advance carrying one spoken word greys that word only.
    @Test
    func aLargeAdvanceDoesNotGreyTheInterval() {
        let marked = Self.spoken([Self.script[183]], from: 155, to: 184)
        #expect(marked == [183], "expected only the spoken word; got \(marked.sorted())")
        for skipped in 155..<183 {
            #expect(!marked.contains(skipped), "token \(skipped) was skipped over, not spoken")
        }
    }

    /// **Recovery: the skipped interval stays dark, but the words it was given still count.**
    ///
    /// An earlier version of this rule returned nothing at all for `.recovering`, which was an
    /// over-correction — it left genuinely-read words black. The contract is that *paragraph
    /// membership and cursor movement* never imply speech, not that recovery erases evidence.
    /// Both properties come from the same cap: at most `fedWords.count` tokens ending at the new
    /// cursor are ever eligible, so a jump cannot reach back over what it skipped.
    @Test
    func recoveryGreysItsOwnWordsButNeverTheIntervalItSkipped() {
        // Script token 40 is "current"; the device capture logged `"current" cursor -> 41 recovering`.
        let marked = Self.spoken([Self.script[40]], from: 18, to: 41, state: .recovering)
        #expect(marked == [40], "recovery must still grey the word it was given; got \(marked.sorted())")
        for skipped in 18..<40 {
            #expect(!marked.contains(skipped), "recovery greyed token \(skipped), which it skipped over")
        }

        // A recovery carrying several words greys each that aligns, and still nothing before them.
        let multi = Self.spoken(Array(Self.script[36..<42]), from: 18, to: 42, state: .recovering)
        #expect(multi == Set(36..<42), "expected each aligned word greyed, got \(multi.sorted())")
        #expect(!multi.contains(35), "nothing before the fed window may grey")
    }

    /// A word that does not resemble the token it landed on is not evidence that token was read.
    @Test
    func anUnrelatedWordDoesNotGreyTheTokenItLandedOn() {
        #expect(Self.spoken(["zzzzqqq"], from: 5, to: 6).isEmpty)
        // ASR wobble on the right word still counts — "write" for "written" is 0.71.
        #expect(Self.spoken(["write"], from: 9, to: 10) == [9], "ordinary ASR imperfection must not leave read text black")
    }

    /// Only the words in *this* feed are eligible, so a feed can never grey more than it carried.
    @Test
    func aFeedNeverGreysMoreTokensThanItCarriedWords() {
        for advance in [2, 5, 12, 29] {
            let marked = Self.spoken(["prompter"], from: 100, to: 100 + advance)
            #expect(marked.count <= 1, "one fed word greyed \(marked.count) tokens over an advance of \(advance)")
        }
    }

    /// Nothing is marked when the cursor does not move forward.
    @Test
    func stationaryOrBackwardCursorMarksNothing() {
        #expect(Self.spoken(["welcome"], from: 10, to: 10).isEmpty)
        #expect(Self.spoken(["welcome"], from: 10, to: 7).isEmpty)
    }

    /// Restart clears the grey set, so a second take never inherits the first take's greys.
    /// Driven through a real session because `spokenTokenIndices` is `private(set)` — seeding it
    /// directly would test nothing that happens on device.
    @Test
    @MainActor
    func restartClearsTheSpokenSet() async throws {
        let results: [FakeTranscriptionService.ScriptedResult] = [
            .init(text: "Welcome to", isFinal: false, elapsed: 0.05),
            .init(text: "Welcome to Prompter.", isFinal: true, elapsed: 0.15),
        ]
        let viewModel = PromptViewModel(
            scriptText: PromptDemoFixture.defaultScriptText,
            makeService: { FakeTranscriptionService(results: results) }
        )

        viewModel.start()
        // Bounded wait on the precondition this test actually needs: that reading has greyed
        // something. The previous version additionally required *observing* `listeningText` go
        // non-empty, but the scripted volatile and final are only 100 ms apart — under the CPU
        // starvation this suite's measurement tests create, a 10 ms poll can miss that window
        // entirely, leave `sawVolatile` false forever, and spin to the deadline. Waiting directly on
        // the precondition removes the fragile gate; the assertions below are unchanged, and the
        // bounded deadline still fails the test if greying never happens.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, viewModel.spokenTokenIndices.isEmpty {
            try await Task.sleep(for: .seconds(0.01))
        }

        #expect(!viewModel.spokenTokenIndices.isEmpty, "reading should have greyed something before Restart is meaningful")
        viewModel.start()                                   // this is what the Restart button calls
        #expect(viewModel.spokenTokenIndices.isEmpty, "Restart must clear the grey set")
        viewModel.stop()
    }
}
