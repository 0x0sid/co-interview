import Foundation
import Testing
@testable import prompter

/// **Pages are what the user asked for, and each asks exactly its own question.**
///
/// Owner decisions and regressions this pins, end to end through the real feed and coordinator:
/// - A live interview never turns speech into a page by itself: no classifier guess ("Um, but this is
///   not what I'm asking") becomes a card, the transcript stays plain, the page count does not move.
/// - Generate answers the newest speech. After Q1 was answered, Q2's request must carry Q2 and never
///   Q1 (an answer about "managing five people" once came back for "a difficult Python project").
/// - A page's own Regenerate answers that page, from its own snapshot, whatever was said since.
@MainActor
struct QuestionRoutingTests {
    typealias Support = CopilotTestSupport

    static let q1 = "Why was managing five people difficult?"
    static let q2 = "Tell me about a difficult problem you faced as a Python developer."

    struct Session {
        let model: InterviewScreenModel
        let coordinator: CopilotSessionCoordinator
        let provider: CopilotTestSupport.StubProvider
    }

    static func session(manualStreams: Bool = false) -> Session {
        let provider = CopilotTestSupport.StubProvider()
        provider.manualStreams = manualStreams
        // Would call everything a question — and must never be asked in a live interview.
        provider.classifications = [DetectionResult(kind: .newQuestion, questionText: "anything", confidence: 0.95)]
        let (feed, coordinator, _) = LiveInterviewFeedTests.makeFeed(provider: provider)
        let model = InterviewScreenModel(mode: .live, feed: feed)
        model.start()
        return Session(model: model, coordinator: coordinator, provider: provider)
    }

    /// Speech, then a long silence — time a classifier would have used.
    static func say(_ text: String, at time: TimeInterval, in session: Session) async throws {
        session.coordinator.ingest(Support.finalDelta(text, at: time))
        session.coordinator.tick(now: time + 4)
        try await Support.waitUntil("\"\(text)\" is on screen") { session.model.transcript.contains { $0.text == text } }
    }

    // MARK: Speech alone never makes a page

    @Test
    func conversationalSpeechMakesNoPageAndNoClassification() async throws {
        let session = Self.session()
        for (index, line) in ["Esto es interesante.", "Pero eso no es lo que estoy preguntando.",
                              "Um, but this is not what I'm asking."].enumerated() {
            try await Self.say(line, at: Double(index * 5 + 1), in: session)
        }
        await Task.yield()
        #expect(session.model.questions.isEmpty, "a page appeared without Generate")
        #expect(session.model.counterText == "0/0")
        #expect(session.coordinator.cards.isEmpty)
        #expect(session.provider.classifyCallCount == 0, "a live interview sent a classification request")
        #expect(session.model.transcript.allSatisfy { !$0.isDetectedQuestion && $0.questionID == nil },
                "a transcript line is marked or linked as a question")
    }

    // MARK: Generate answers the newest speech

    @Test
    func generateForQ2SendsQ2AndNeverQ1() async throws {
        let session = Self.session()
        try await Self.say(Self.q1, at: 1, in: session)
        session.model.generate(now: Date())
        try await Support.waitUntil("Q1 answered") { session.model.questions.first?.selectedAnswer?.isComplete == true }
        #expect(session.provider.lastAnswerRequest?.newInput == [Self.q1])

        try await Self.say(Self.q2, at: 10, in: session)
        session.model.generate(now: Date().addingTimeInterval(5))
        try await Support.waitUntil("the second request is sent") { session.provider.generateCallCount == 2 }
        let request = try #require(session.provider.lastAnswerRequest)
        #expect(request.newInput == [Self.q2], "Q2 and only Q2 is asked: \(request.newInput)")
        #expect(!request.question.contains(Self.q1))
        #expect(request.recentConversation.contains(Self.q1), "Q1 stays available as context")
        #expect(session.model.questions.count == 2, "one page per Generate")
        #expect(session.model.currentQuestion?.id == session.model.questions.last?.id, "Generate opens its page")
        #expect(session.model.counterText == "2/2")
    }

    @Test
    func whileReadingAnOlderPageGenerateStillSendsTheNewestSpeech() async throws {
        let session = Self.session()
        try await Self.say(Self.q1, at: 1, in: session)
        session.model.generate(now: Date())
        try await Support.waitUntil("Q1 answered") { session.model.questions.first?.selectedAnswer?.isComplete == true }
        try await Self.say(Self.q2, at: 10, in: session)
        #expect(session.model.questions.count == 1, "speaking Q2 made no page")
        session.model.select(index: 0)

        session.model.generate(now: Date().addingTimeInterval(5))
        try await Support.waitUntil("sent") { session.provider.generateCallCount == 2 }
        #expect(session.provider.lastAnswerRequest?.newInput == [Self.q2])
    }

    // MARK: A page's own Regenerate answers that page

    @Test
    func goingBackToQ1AndRegeneratingThereAsksQ1() async throws {
        let session = Self.session()
        try await Self.say(Self.q1, at: 1, in: session)
        session.model.generate(now: Date())
        try await Support.waitUntil("Q1 answered") { session.model.questions.first?.selectedAnswer?.isComplete == true }
        try await Self.say(Self.q2, at: 10, in: session)
        session.model.generate(now: Date().addingTimeInterval(5))
        try await Support.waitUntil("Q2 answered") { session.model.questions.last?.selectedAnswer?.isComplete == true }

        let first = session.model.questions[0]
        session.model.select(index: 0)
        session.model.generate(for: first)
        try await Support.waitUntil("the Q1 regeneration is sent") { session.provider.generateCallCount == 3 }
        let request = try #require(session.provider.lastAnswerRequest)
        #expect(request.newInput == [Self.q1], "the page the user chose is the question asked: \(request.newInput)")
        #expect(!request.newInput.contains(Self.q2))
        #expect(session.model.questions.count == 2, "regenerating adds a version, not a page")
    }

    // MARK: Identity survives asynchronous events

    @Test
    func aLateAnswerLandsOnItsOwnPageOnly() async throws {
        let session = Self.session(manualStreams: true)
        try await Self.say(Self.q1, at: 1, in: session)
        session.model.generate(now: Date())
        try await Support.waitUntil("Q1 streaming") { session.provider.generateCallCount == 1 }
        let firstID = try #require(session.model.questions.first?.id)

        try await Self.say(Self.q2, at: 10, in: session)
        session.model.generate(now: Date().addingTimeInterval(5))            // queued behind Q1
        let secondID = try #require(session.model.questions.last?.id)
        #expect(firstID != secondID)

        session.provider.push(.delta("Managing five people taught me to delegate. "))
        session.provider.push(.completed(usageOutputTokens: nil))
        session.provider.finishStream()
        try await Support.waitUntil("Q1's answer lands") {
            session.model.questions.first { $0.id == firstID }?.selectedAnswer?.isComplete == true
        }
        #expect(session.model.questions.first { $0.id == secondID }?.selectedAnswer?.isComplete != true,
                "Q2's page received nothing from Q1's request")
        try await Support.waitUntil("Q2 is sent after Q1") { session.provider.generateCallCount == 2 }
        #expect(session.provider.lastAnswerRequest?.newInput == [Self.q2])
    }
}
