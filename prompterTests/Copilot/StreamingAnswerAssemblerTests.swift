import Testing
import Foundation
@testable import prompter

/// The reader-stability contract (§7): text becomes readable only in whole sentences, and committed
/// text is **append-only** — never rewritten under a cursor.
struct StreamingAnswerAssemblerTests {
    @Test
    func committedTextOnlyEverGrows() {
        var assembler = StreamingAnswerAssembler()
        var snapshots: [String] = []
        for chunk in ["I led ", "the Eastgate ", "corridor upgrade. ", "It took ", "four years. ", "Then I moved on."] {
            assembler.append(chunk)
            snapshots.append(assembler.committedText)
        }
        // Every snapshot is a prefix of the next: nothing already committed was rewritten.
        for (earlier, later) in zip(snapshots, snapshots.dropFirst()) {
            #expect(later.hasPrefix(earlier), "committed text changed instead of growing: \"\(earlier)\" → \"\(later)\"")
        }
    }

    @Test
    func onlyCompleteSentencesAreCommitted() {
        var assembler = StreamingAnswerAssembler()
        assembler.append("I led the Eastgate corridor")
        #expect(assembler.committedText.isEmpty)
        #expect(!assembler.pendingText.isEmpty)

        assembler.append(" upgrade for four years. And then")
        #expect(assembler.committedText == "I led the Eastgate corridor upgrade for four years.")
        #expect(assembler.pendingText == "And then")
    }

    /// A terminator only closes a sentence when whitespace follows, so figures do not split text.
    @Test
    func decimalsDoNotSplitSentences() {
        var assembler = StreamingAnswerAssembler()
        assembler.append("Punctuality rose to 89.4 per cent")
        #expect(assembler.committedText.isEmpty)
        assembler.append(" in year two. ")
        #expect(assembler.committedText == "Punctuality rose to 89.4 per cent in year two.")
    }

    /// A terminator at the very end of the buffer may still be extended by the next delta, so it is
    /// not committed yet.
    @Test
    func aTrailingTerminatorWaitsForMoreInput() {
        var assembler = StreamingAnswerAssembler()
        assembler.append("Yes.")
        #expect(assembler.committedText.isEmpty)
        assembler.append(" That is right. ")
        #expect(assembler.committedText == "Yes. That is right.")
    }

    @Test
    func frenchQuestionsAndQuotesCommitCleanly() {
        var assembler = StreamingAnswerAssembler()
        assembler.append("Le délai médian est passé de 34 à 21 jours. ")
        assembler.append("Est-ce que cela répond à votre question ? ")
        #expect(assembler.committedText == "Le délai médian est passé de 34 à 21 jours. Est-ce que cela répond à votre question ?")
        #expect(assembler.pendingText.isEmpty)
    }

    @Test
    func finishCommitsAnUnterminatedTail() {
        var assembler = StreamingAnswerAssembler()
        assembler.append("The depot upgrade is not yet scheduled")
        #expect(assembler.committedText.isEmpty)
        let didCommit = assembler.finish()
        #expect(didCommit)
        #expect(assembler.committedText == "The depot upgrade is not yet scheduled")
        #expect(assembler.pendingText.isEmpty)
    }

    /// Word-at-a-time delivery, the way a real token stream arrives, must produce exactly the same
    /// committed text as one big delta.
    @Test
    func tokenByTokenMatchesSingleDelta() {
        let text = "I led the corridor upgrade. Punctuality rose by eighteen per cent. That is the headline."
        var wordByWord = StreamingAnswerAssembler()
        for word in text.split(separator: " ") { wordByWord.append(word + " ") }
        wordByWord.finish()

        var single = StreamingAnswerAssembler()
        single.append(text)
        single.finish()

        #expect(wordByWord.committedText == single.committedText)
    }
}
