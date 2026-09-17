import Testing
import Foundation
@testable import prompter

/// The guarantees this increment exists to establish (§3, §7, §8): listening never stops because of
/// generation, events only ever reach the version that asked for them, and nothing the user is reading
/// changes underneath them.
@MainActor
struct CopilotSessionCoordinatorTests {
    private typealias Support = CopilotTestSupport

    private func question(_ text: String) -> DetectionResult {
        DetectionResult(kind: .newQuestion, questionText: text, confidence: 0.9)
    }

    /// Drives one finalized utterance through the coordinator and waits for the card it produces.
    @discardableResult
    private func ask(
        _ coordinator: CopilotSessionCoordinator,
        _ text: String,
        at time: TimeInterval,
        expectedCards: Int
    ) async throws -> QuestionCard {
        coordinator.ingest(Support.finalDelta(text, at: time))
        try await Support.waitUntil("card \(expectedCards) to appear") { coordinator.cards.count == expectedCards }
        return coordinator.cards[expectedCards - 1]
    }

    // MARK: Continuous listening

    @Test
    func captureKeepsRunningThroughGenerationAndCancellation() async throws {
        let provider = Support.StubProvider()
        provider.classifications = [question("Tell me about the corridor")]
        provider.manualStreams = true
        let (coordinator, audio, service) = Support.makeCoordinator(provider: provider)

        coordinator.startListening()
        try await Support.waitUntil("listening") { audio.state == .listening }
        let startsAfterListening = audio.startCount

        service.emit(Support.finalDelta("Tell me about the corridor you ran", at: 3))
        try await Support.waitUntil("a card") { coordinator.cards.count == 1 }
        let version = try #require(coordinator.cards[0].latestVersion)

        // Mid-generation, capture is untouched.
        #expect(audio.state == .listening)
        provider.push(.delta("I led the Eastgate corridor upgrade. "))
        try await Support.waitUntil("streamed text") { !(coordinator.cards[0].latestVersion?.committedText.isEmpty ?? true) }

        // Cancelling generation must not cancel listening (§8).
        coordinator.cancelGeneration(versionID: version.id)
        #expect(audio.state == .listening)
        #expect(service.stopCount == 0)
        #expect(audio.startCount == startsAfterListening, "the microphone was restarted for a question")

        // And speech after a cancellation still reaches the log.
        service.emit(Support.finalDelta("Right, understood.", at: 12))
        try await Support.waitUntil("speech after cancellation") { coordinator.conversation.utterances.count >= 2 }
        #expect(coordinator.cards[0].latestVersion?.status == .cancelled)
    }

    @Test
    func providerFailureLeavesListeningAndExistingTextUsable() async throws {
        let provider = Support.StubProvider()
        provider.classifications = [question("Tell me about the corridor")]
        provider.manualStreams = true
        let (coordinator, audio, service) = Support.makeCoordinator(provider: provider)
        coordinator.startListening()
        try await Support.waitUntil("listening") { audio.state == .listening }

        service.emit(Support.finalDelta("Tell me about the corridor you ran", at: 3))
        try await Support.waitUntil("a card") { coordinator.cards.count == 1 }

        provider.push(.delta("I led the Eastgate corridor upgrade for four years. "))
        try await Support.waitUntil("committed text") { !(coordinator.cards[0].latestVersion?.committedText.isEmpty ?? true) }
        provider.finishStream(0, throwing: CopilotProviderError.provider("upstream exploded"))

        try await Support.waitUntil("failed status") {
            if case .failed = coordinator.cards[0].latestVersion?.status { return true }
            return false
        }
        // Text already produced stays readable, and listening continues.
        #expect(coordinator.cards[0].latestVersion?.readableSegments.first?.contains("Eastgate") == true)
        #expect(audio.state == .listening)
        service.emit(Support.finalDelta("Let us move on to the risks.", at: 20))
        try await Support.waitUntil("more speech") { coordinator.conversation.utterances.count >= 2 }
    }

    /// A listening pause stops processing interview speech. Pausing voice-following does not.
    @Test
    func readingPauseAndListeningPauseAreDifferent() async throws {
        let provider = Support.StubProvider()
        provider.classifications = [question("Tell me about the corridor")]
        let (coordinator, audio, service) = Support.makeCoordinator(provider: provider)
        coordinator.startListening()
        try await Support.waitUntil("listening") { audio.state == .listening }
        service.emit(Support.finalDelta("Tell me about the corridor you ran", at: 3))
        try await Support.waitUntil("an answer") { coordinator.cards.first?.latestVersion?.status == .complete }

        coordinator.setReadingPaused(true)
        #expect(audio.state == .listening, "pausing following must not stop listening")
        service.emit(Support.finalDelta("And what about the depot power upgrade?", at: 30))
        try await Support.waitUntil("speech still logged while following is paused") {
            coordinator.conversation.utterances.count >= 2
        }

        coordinator.audio.pauseListening()
        #expect(audio.state == .pausedByUser)
    }

    // MARK: Identity, dedupe, association

    @Test
    func repeatedTranscriptEventsProduceOneCard() async throws {
        let provider = Support.StubProvider()
        provider.classifications = [question("What worries you about Mill Street?")]
        let (coordinator, _, _) = Support.makeCoordinator(provider: provider)

        coordinator.ingest(Support.finalDelta("What worries you most about Mill Street?", at: 5))
        try await Support.waitUntil("first card") { coordinator.cards.count == 1 }
        // The transcriber re-emits the same finalized text.
        coordinator.ingest(Support.finalDelta("What worries you most about Mill Street?", at: 5.5))
        try await Task.sleep(for: .milliseconds(120))

        #expect(coordinator.cards.count == 1)
        #expect(coordinator.conversation.utterances.count == 1)
    }

    @Test
    func aDistinctQuestionIsNeverDiscardedWhenBusy() async throws {
        let provider = Support.StubProvider()
        provider.manualStreams = true
        provider.classifications = [
            question("Question one"), question("Question two"),
            question("Question three"), question("Question four"),
        ]
        let (coordinator, _, _) = Support.makeCoordinator(provider: provider)

        var time = 5.0
        for index in 1...4 {
            coordinator.ingest(Support.finalDelta("This is spoken question number \(index) here", at: time))
            time += 6
            try await Support.waitUntil("card \(index)") { coordinator.cards.count == index }
        }

        #expect(coordinator.cards.count == 4, "a question was dropped")
        let streaming = coordinator.cards.filter { $0.latestVersion?.status == .streaming }.count
        let queued = coordinator.cards.filter { $0.latestVersion?.status == .queued }.count
        #expect(streaming == coordinator.maximumConcurrentGenerations)
        #expect(queued == 4 - coordinator.maximumConcurrentGenerations, "queued work must stay visible, not vanish")
    }

    @Test
    func lateAndOutOfOrderResponsesAttachToTheirOwnCard() async throws {
        let provider = Support.StubProvider()
        provider.manualStreams = true
        provider.classifications = [question("First question"), question("Second question")]
        let (coordinator, _, _) = Support.makeCoordinator(provider: provider)

        try await ask(coordinator, "Tell me about the first thing please", at: 5, expectedCards: 1)
        try await ask(coordinator, "Now tell me about the second thing", at: 15, expectedCards: 2)
        try await Support.waitUntil("both streams open") { provider.openStreamCount == 2 }

        // The second card's answer arrives first, then the first card's.
        provider.push(.delta("Second answer text here. "), stream: 1)
        provider.push(.delta("First answer text here. "), stream: 0)
        try await Support.waitUntil("both answers") {
            !(coordinator.cards[0].latestVersion?.committedText.isEmpty ?? true)
                && !(coordinator.cards[1].latestVersion?.committedText.isEmpty ?? true)
        }

        #expect(coordinator.cards[0].latestVersion?.committedText.contains("First answer") == true)
        #expect(coordinator.cards[1].latestVersion?.committedText.contains("Second answer") == true)
    }

    @Test
    func newCardsDoNotStealFocus() async throws {
        let provider = Support.StubProvider()
        provider.classifications = [question("First question"), question("Second question")]
        let (coordinator, _, _) = Support.makeCoordinator(provider: provider)

        try await ask(coordinator, "Tell me about the first thing please", at: 5, expectedCards: 1)
        #expect(coordinator.selectedCardIndex == 0)

        try await ask(coordinator, "Now tell me about the second thing", at: 15, expectedCards: 2)
        #expect(coordinator.selectedCardIndex == 0, "a new card moved the reader")
        #expect(coordinator.hasNewerCardThanSelected)

        coordinator.selectLatestCard()
        #expect(coordinator.selectedCardIndex == 1)
        #expect(!coordinator.hasNewerCardThanSelected)
    }

    // MARK: Reading stability

    @Test
    func readableTextDoesNotChangeWhileMoreIsStreaming() async throws {
        let provider = Support.StubProvider()
        provider.manualStreams = true
        provider.classifications = [question("Tell me about the corridor")]
        let (coordinator, _, _) = Support.makeCoordinator(provider: provider)
        try await ask(coordinator, "Tell me about the corridor you ran", at: 5, expectedCards: 1)

        provider.push(.delta("I led the Eastgate corridor upgrade for four years. "))
        try await Support.waitUntil("first sentence committed") {
            !(coordinator.cards[0].latestVersion?.committedText.isEmpty ?? true)
        }

        #expect(coordinator.beginReadingSelectedCard())
        let frozen = try #require(coordinator.cards[0].latestVersion?.readableSegments.first)
        let alignment = try #require(coordinator.activeAlignment())

        // More text arrives while the user is reading the frozen opening.
        provider.push(.delta("Punctuality rose from seventy one to eighty nine per cent. "))
        provider.push(.delta("That is the result I would lead with. "))
        try await Support.waitUntil("more committed text") {
            (coordinator.cards[0].latestVersion?.committedText.count ?? 0) > frozen.count
        }

        #expect(coordinator.cards[0].latestVersion?.readableSegments.first == frozen, "readable text was rewritten")
        #expect(alignment.text == frozen)

        // The continuation only becomes readable as a new segment, once generation ends.
        provider.push(.completed(usageOutputTokens: nil))
        provider.finishStream(0)
        try await Support.waitUntil("completion") { coordinator.cards[0].latestVersion?.status == .complete }
        #expect(coordinator.cards[0].latestVersion?.readableSegments.first == frozen)
        #expect(coordinator.selectedCardHasNextSegment)
    }

    @Test
    func navigatingAwayAndBackPreservesReadingPosition() async throws {
        let provider = Support.StubProvider()
        provider.answerChunks = ["The corridor carries forty thousand journeys each day. ", "That is the headline figure. "]
        provider.classifications = [question("First question"), question("Second question")]
        let (coordinator, _, _) = Support.makeCoordinator(provider: provider)

        try await ask(coordinator, "Tell me about the first thing please", at: 5, expectedCards: 1)
        try await Support.waitUntil("answer complete") { coordinator.cards[0].latestVersion?.status == .complete }
        #expect(coordinator.beginReadingSelectedCard())

        // Read the opening words aloud; the alignment marks them spoken.
        coordinator.ingest(Support.finalDelta("The corridor carries forty thousand journeys", at: 20))
        try await Support.waitUntil("spoken words marked") {
            (coordinator.activeAlignment()?.spokenTokenIndices.count ?? 0) > 0
        }
        let spokenBefore = try #require(coordinator.activeAlignment()?.spokenTokenIndices)
        let cursorBefore = try #require(coordinator.activeAlignment()?.cursor.tokenIndex)

        try await ask(coordinator, "Now tell me about the second thing", at: 40, expectedCards: 2)
        coordinator.select(cardIndex: 1)
        coordinator.select(cardIndex: 0)

        #expect(coordinator.activeAlignment()?.spokenTokenIndices == spokenBefore)
        #expect(coordinator.activeAlignment()?.cursor.tokenIndex == cursorBefore)
    }

    // MARK: Session end

    @Test
    func endingTheSessionRejectsLaterEvents() async throws {
        let provider = Support.StubProvider()
        provider.manualStreams = true
        provider.classifications = [question("Tell me about the corridor")]
        let (coordinator, audio, service) = Support.makeCoordinator(provider: provider)
        coordinator.startListening()
        try await Support.waitUntil("listening") { audio.state == .listening }
        service.emit(Support.finalDelta("Tell me about the corridor you ran", at: 5))
        try await Support.waitUntil("a card") { coordinator.cards.count == 1 }

        coordinator.endSession()
        #expect(coordinator.state == .ended)
        try await Support.waitUntil("capture stopped") { audio.state == .idle }

        // Everything arriving afterwards is ignored: no new cards, no new text, no reopening.
        let cardsAtEnd = coordinator.cards.count
        let textAtEnd = coordinator.cards[0].latestVersion?.committedText ?? ""
        provider.push(.delta("This text arrives after the session ended. "))
        coordinator.ingest(Support.finalDelta("And one more question after the end?", at: 60))
        try await Task.sleep(for: .milliseconds(150))

        #expect(coordinator.cards.count == cardsAtEnd)
        #expect(coordinator.cards[0].latestVersion?.committedText == textAtEnd)
    }

    // MARK: Manual paths and grounding

    @Test
    func typedQuestionsWorkWithNoAudioAtAll() async throws {
        let provider = Support.StubProvider()
        let (coordinator, _, _) = Support.makeCoordinator(provider: provider)

        coordinator.askTyped("What is the punctuality figure?")
        try await Support.waitUntil("typed card") { coordinator.cards.count == 1 }
        #expect(coordinator.cards[0].origin == .typed)
        #expect(provider.classifyCallCount == 0, "a typed question does not need the detector")
        try await Support.waitUntil("answer") { coordinator.cards[0].latestVersion?.status == .complete }
    }

    @Test
    func generationReceivesInstructionsQuestionConversationAndPassages() async throws {
        let provider = Support.StubProvider()
        // The opening remark is not a question; the second turn is. Both are classified — each turn
        // gets its own decision — so the stub answers them in order.
        provider.classifications = [
            DetectionResult(kind: .none, questionText: "", confidence: 0.7),
            question("What is the punctuality figure?"),
        ]
        let (coordinator, _, _) = Support.makeCoordinator(provider: provider)

        coordinator.ingest(Support.finalDelta("Some earlier remark about the programme.", at: 2))
        try await ask(coordinator, "What is the punctuality figure for the corridor", at: 8, expectedCards: 1)

        let request = try #require(provider.lastAnswerRequest)
        #expect(request.question.contains("punctuality"))
        #expect(request.projectInstructions.contains("first person"))
        #expect(!request.passages.isEmpty, "no document passages were supplied")
        #expect(request.passages.allSatisfy { !$0.documentVersion.isEmpty }, "sources must carry a document version")
        #expect(request.targetWordRange == [CopilotSessionCoordinator.targetMinimumWords, CopilotSessionCoordinator.targetMaximumWords])
        #expect(request.language == "en")
    }

    /// Only ids the model was actually given may become sources.
    @Test
    func unknownCitationsAreDroppedRatherThanShown() async throws {
        let provider = Support.StubProvider()
        provider.manualStreams = true
        provider.classifications = [question("What is the punctuality figure?")]
        let (coordinator, _, _) = Support.makeCoordinator(provider: provider)
        try await ask(coordinator, "What is the punctuality figure for the corridor", at: 8, expectedCards: 1)

        provider.push(.delta("Punctuality rose to eighty nine per cent. "))
        provider.push(.sources(["test-project#2", "invented#99"]))
        provider.push(.completed(usageOutputTokens: nil))
        provider.finishStream(0)

        try await Support.waitUntil("completion") { coordinator.cards[0].latestVersion?.status == .complete }
        let sources = try #require(coordinator.cards[0].latestVersion?.sources)
        #expect(sources.map(\.id) == ["test-project#2"])
    }
}
