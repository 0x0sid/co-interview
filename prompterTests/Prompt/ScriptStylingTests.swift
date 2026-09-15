import Testing
import Foundation
import SwiftUI
@testable import prompter

/// Live read styling — grey means "you actually said this", nothing else.
///
/// Every earlier version coloured from the cursor position (grey everything behind it). A real
/// device trace showed why that is wrong: while the reader talked off-script the matcher jumped
/// the cursor to token 156 and parked there, so a position-based rule greyed ~150 tokens the
/// reader had never spoken. The rule under test now takes an explicit set of pronounced tokens,
/// so text the cursor merely skipped over stays black.
struct ScriptStylingTests {
    /// Sentence 0: tokens 0-4, sentence 1: tokens 5-10, sentence 2: tokens 11-14.
    /// Every word is unique so the word-boundary lookup in `color(_:word:)` is unambiguous.
    private let script = "Welcome to the show today. This is a longer middle line. Third final part here."
    private var scriptIndex: ScriptIndex { ScriptIndex.build(from: script) }

    @Test
    func onlyPronouncedTokensAreGrey() {
        let index = scriptIndex
        // Read the first three words only.
        let cursor = PromptCursor(tokenIndex: 3, confidence: 1.0, state: .advancing)
        let attributed = ScriptStyling.styledAttributedString(
            rawText: script, scriptIndex: index, cursor: cursor, spokenTokenIndices: [0, 1, 2]
        )

        #expect(color(attributed, word: "Welcome") == OutdoorMode.normal.spoken)
        #expect(color(attributed, word: "show") == OutdoorMode.normal.ink)
        #expect(color(attributed, word: "This") == OutdoorMode.normal.ink)
        #expect(color(attributed, word: "here") == OutdoorMode.normal.ink)
    }

    /// The device bug, stated as a test: the cursor jumps far ahead without the reader speaking,
    /// and everything it skipped must stay black.
    @Test
    func textSkippedByACursorJumpStaysBlack() {
        let index = scriptIndex
        // Cursor leapt to the last sentence; only the first two words were ever pronounced.
        let cursor = PromptCursor(tokenIndex: 13, confidence: 0.9, state: .recovering)
        let attributed = ScriptStyling.styledAttributedString(
            rawText: script, scriptIndex: index, cursor: cursor, spokenTokenIndices: [0, 1]
        )

        #expect(color(attributed, word: "Welcome") == OutdoorMode.normal.spoken)
        // Everything the jump flew past was never spoken — it must not be greyed.
        #expect(color(attributed, word: "show") == OutdoorMode.normal.ink)
        #expect(color(attributed, word: "today") == OutdoorMode.normal.ink)
        #expect(color(attributed, word: "This") == OutdoorMode.normal.ink)
        #expect(color(attributed, word: "middle") == OutdoorMode.normal.ink)
        #expect(color(attributed, word: "Third") == OutdoorMode.normal.ink)
        #expect(color(attributed, word: "part") == OutdoorMode.normal.ink)
    }

    /// With nothing pronounced yet, the whole script is black regardless of where the cursor is.
    @Test
    func nothingIsGreyBeforeAnythingIsSpoken() {
        let index = scriptIndex
        let cursor = PromptCursor(tokenIndex: 9, confidence: 0.8, state: .advancing)
        let attributed = ScriptStyling.styledAttributedString(
            rawText: script, scriptIndex: index, cursor: cursor, spokenTokenIndices: []
        )
        for word in ["Welcome", "show", "today", "This", "longer", "middle", "line", "Third", "here"] {
            #expect(color(attributed, word: word) == OutdoorMode.normal.ink, "\(word) should be black")
        }
    }

    @Test
    func noBackgroundHighlightAnywhere() {
        let index = scriptIndex
        let cursor = PromptCursor(tokenIndex: 7, confidence: 1.0, state: .advancing)
        let attributed = ScriptStyling.styledAttributedString(
            rawText: script, scriptIndex: index, cursor: cursor, spokenTokenIndices: [0, 1, 2, 3]
        )
        #expect(attributed.runs.allSatisfy { $0.backgroundColor == nil })
    }

    @Test
    func progressWithinCurrentSentenceReflectsTokenFraction() {
        let index = scriptIndex
        let sentence = index.sentences[1]
        let midpointCursor = PromptCursor(tokenIndex: sentence.tokenStart + 2, confidence: 1.0, state: .advancing)
        let progress = ScriptStyling.progressWithinCurrentSentence(scriptIndex: index, cursor: midpointCursor)
        #expect(progress > 0 && progress < 1)

        let startCursor = PromptCursor(tokenIndex: sentence.tokenStart, confidence: 1.0, state: .advancing)
        #expect(ScriptStyling.progressWithinCurrentSentence(scriptIndex: index, cursor: startCursor) == 0)
    }

    private func color(_ attributed: AttributedString, word: String) -> Color? {
        guard let range = String(attributed.characters).range(of: "\\b\(word)\\b", options: .regularExpression),
              let attrRange = Range(range, in: attributed) else { return nil }
        return attributed[attrRange].foregroundColor
    }
}
