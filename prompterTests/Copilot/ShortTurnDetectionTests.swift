import Testing
import Foundation
@testable import prompter

/// Short speech is where two opposite mistakes meet: a two-word backchannel that blocks the queue
/// forever, and a two-word question that is silently never answered.
///
/// The rule under test is narrow: length is a **noise filter**, and a short turn that is shaped like
/// a question still gets a classification. Whether it becomes a card is the detector's decision, not
/// this rule's.
@MainActor
struct ShortTurnDetectionTests {
    private typealias Support = CopilotTestSupport

    // MARK: The local shape test

    @Test(arguments: [
        "Why?", "Why", "How?", "Really?", "Et ensuite ?", "Pourquoi ?", "Pourquoi", "Comment ?",
        "What about cost?",
    ])
    func shortQuestionsAreWorthAClassification(_ text: String) {
        #expect(DetectionPolicy.looksInterrogative(text), "\"\(text)\" should reach the detector")
    }

    @Test(arguments: ["Right. Understood.", "Okay.", "Mm hmm.", "D'accord.", "Très bien.", "Thanks."])
    func shortBackchannelsAreNot(_ text: String) {
        #expect(!DetectionPolicy.looksInterrogative(text), "\"\(text)\" should not spend a classification")
    }

    // MARK: The policy gate

    @Test
    func aShortQuestionPassesTheWordMinimum() {
        let decision = DetectionPolicy().decide(.init(
            pendingText: "Why?", didFinalize: true, now: 10, lastChangeTime: 10,
            lastClassificationTime: nil, lastClassifiedText: nil, isClassificationInFlight: false,
            allPendingOverlapsReading: false
        ))
        #expect(decision.shouldClassify)
    }

    @Test
    func aShortBackchannelDoesNot() {
        let decision = DetectionPolicy().decide(.init(
            pendingText: "Right. Understood.", didFinalize: true, now: 10, lastChangeTime: 10,
            lastClassificationTime: nil, lastClassifiedText: nil, isClassificationInFlight: false,
            allPendingOverlapsReading: false
        ))
        #expect(!decision.shouldClassify)
    }

    // MARK: End to end through the coordinator

    /// A short question asked after a backchannel must still produce a card — the backchannel is
    /// skipped, the question is not.
    @Test
    func aShortQuestionAfterABackchannelStillProducesACard() async throws {
        let provider = Support.StubProvider()
        provider.classifications = [DetectionResult(kind: .newQuestion, questionText: "Why?", confidence: 0.8)]
        let (coordinator, _, _) = Support.makeCoordinator(provider: provider)

        coordinator.ingest(Support.finalDelta("Right. Understood.", at: 4))
        coordinator.ingest(Support.finalDelta("Why?", at: 9))
        coordinator.tick(now: 10.2)

        try await Support.waitUntil("a card for the short question") { coordinator.cards.count == 1 }
        #expect(coordinator.cards[0].questionText == "Why?")
    }

    @Test
    func aFrenchShortFollowUpStillProducesACard() async throws {
        let provider = Support.StubProvider()
        provider.classifications = [DetectionResult(kind: .newQuestion, questionText: "Et ensuite ?", confidence: 0.8)]
        let (coordinator, _, _) = Support.makeCoordinator(provider: provider, project: Support.project(language: .french))

        coordinator.ingest(Support.finalDelta("D'accord.", at: 4))
        coordinator.ingest(Support.finalDelta("Et ensuite ?", at: 9))
        coordinator.tick(now: 10.2)

        try await Support.waitUntil("a card for the short French follow-up") { coordinator.cards.count == 1 }
        #expect(coordinator.cards[0].questionText == "Et ensuite ?")
    }

    /// Backchannels alone never create cards, and never stop what follows them.
    @Test
    func repeatedBackchannelsNeverBlockTheQueue() async throws {
        let provider = Support.StubProvider()
        provider.classifications = [DetectionResult(kind: .newQuestion, questionText: "the real question", confidence: 0.9)]
        let (coordinator, _, _) = Support.makeCoordinator(provider: provider)

        for (index, filler) in ["Right.", "Okay.", "Mm hmm.", "Sure."].enumerated() {
            coordinator.ingest(Support.finalDelta(filler, at: Double(index) * 4 + 2))
        }
        coordinator.ingest(Support.finalDelta("So tell me about the corridor you ran", at: 30))
        coordinator.tick(now: 31.2)

        try await Support.waitUntil("the real question got through") { coordinator.cards.count == 1 }
        #expect(provider.classifyCallCount == 1, "backchannels spent classifications")
    }

    /// A rapid exchange with short gaps still keeps its questions apart.
    @Test
    func twoQuestionsInQuickSuccessionStayTwoQuestions() async throws {
        let provider = Support.StubProvider()
        provider.classifications = [
            DetectionResult(kind: .newQuestion, questionText: "first", confidence: 0.9),
            DetectionResult(kind: .newQuestion, questionText: "second", confidence: 0.9),
        ]
        let (coordinator, _, _) = Support.makeCoordinator(provider: provider)

        coordinator.ingest(Support.finalDelta("What is your timetable for signal priority", at: 10))
        // 1.2 s later — a real rapid follow-up: beyond the turn gap, well inside an ordinary pause.
        coordinator.ingest(Support.finalDelta("And who signs off the risk note each month", at: 11.2))
        // The silence that follows, as the audio layer reports it every 0.5 s while listening. This
        // is what closes the last turn live; these tests drive `ingest` directly, so the tick has to
        // be supplied the same way the microphone would.
        coordinator.tick(now: 12.4)

        try await Support.waitUntil("two cards") { coordinator.cards.count == 2 }
        #expect(coordinator.cards.map(\.questionText) == ["first", "second"])
    }
}
