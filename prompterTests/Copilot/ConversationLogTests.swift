import Testing
import Foundation
@testable import prompter

/// The dedupe and windowing rules that make everything downstream idempotent (§4).
struct ConversationLogTests {
    @Test
    func volatileRevisionsKeepOneIdentity() {
        var log = ConversationLog()
        let first = log.ingest(CopilotTestSupport.volatileDelta("Tell me", at: 1.0), overlapsReading: false)
        let second = log.ingest(CopilotTestSupport.volatileDelta("Tell me about the", at: 1.4), overlapsReading: false)
        let third = log.ingest(CopilotTestSupport.volatileDelta("Tell me about the corridor", at: 1.8), overlapsReading: false)

        #expect(first?.utterance.id == second?.utterance.id)
        #expect(second?.utterance.id == third?.utterance.id)
        #expect(log.utterances.isEmpty)               // nothing finalized yet
        #expect(log.openUtterance?.revision == 2)
    }

    @Test
    func finalizingClosesTheOpenUtteranceWithTheSameIdentity() {
        var log = ConversationLog()
        let open = log.ingest(CopilotTestSupport.volatileDelta("Tell me about", at: 1.0), overlapsReading: false)
        let closed = log.ingest(CopilotTestSupport.finalDelta("Tell me about the corridor.", at: 2.0), overlapsReading: false)

        #expect(open?.utterance.id == closed?.utterance.id)
        #expect(closed?.didFinalize == true)
        #expect(log.utterances.count == 1)
        #expect(log.openUtterance == nil)
    }

    /// The inherited transcriber re-emits finalized text as it settles. A repeat must not become a
    /// second utterance — that is what would turn one question into two cards.
    @Test
    func repeatedFinalResultIsNotASecondUtterance() {
        var log = ConversationLog()
        log.ingest(CopilotTestSupport.finalDelta("What worries you about Mill Street?", at: 5.0), overlapsReading: false)
        let repeated = log.ingest(CopilotTestSupport.finalDelta("What worries you about Mill Street?", at: 5.6), overlapsReading: false)

        #expect(log.utterances.count == 1)
        #expect(repeated?.utterance.id == log.utterances[0].id)
        #expect(log.utterances[0].revision == 1)
    }

    /// The same sentence genuinely said again much later is new speech, not a duplicate.
    @Test
    func theSameSentenceMuchLaterIsNewSpeech() {
        var log = ConversationLog()
        log.ingest(CopilotTestSupport.finalDelta("Could you say more?", at: 5.0), overlapsReading: false)
        log.ingest(CopilotTestSupport.finalDelta("Could you say more?", at: 95.0), overlapsReading: false)
        #expect(log.utterances.count == 2)
    }

    @Test
    func theWindowIsBoundedByCountAndAge() {
        var log = ConversationLog(maximumUtterances: 3, windowSeconds: 30)
        for index in 0..<5 {
            log.ingest(CopilotTestSupport.finalDelta("Sentence number \(index).", at: Double(index)), overlapsReading: false)
        }
        #expect(log.utterances.count == 3)

        log.ingest(CopilotTestSupport.finalDelta("Much later sentence.", at: 400), overlapsReading: false)
        #expect(log.utterances.count == 1)
        #expect(log.utterances.last?.text == "Much later sentence.")
    }

    /// Speech the reader confirmed against the answer they are reading is not conversation context: a
    /// suggestion must never be fed back as something a participant said (§5).
    @Test
    func readingOverlapIsExcludedFromContext() {
        var log = ConversationLog()
        log.ingest(CopilotTestSupport.finalDelta("What is the journey time saving?", at: 1), overlapsReading: false)
        log.ingest(CopilotTestSupport.finalDelta("Average journey time fell by eighteen per cent.", at: 6), overlapsReading: true)

        let context = log.recentContext().map(\.text)
        #expect(context == ["What is the journey time saving?"])
        #expect(log.utterances.count == 2)      // it is still recorded, just not used as context
    }

    @Test
    func pendingTextCombinesFinalizedAndInFlightSpeech() {
        var log = ConversationLog()
        log.ingest(CopilotTestSupport.finalDelta("And what about the depot?", at: 10), overlapsReading: false)
        log.ingest(CopilotTestSupport.volatileDelta("Who signs", at: 12), overlapsReading: false)

        #expect(log.pendingText(after: 5) == "And what about the depot? Who signs")
        #expect(log.pendingText(after: 11) == "Who signs")
    }
}
