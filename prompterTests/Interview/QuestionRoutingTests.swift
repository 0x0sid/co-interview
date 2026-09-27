import Foundation
import Testing
@testable import prompter

/// **The question the user generates for is the question the answer model receives.**
///
/// Regression (owner's iPhone): the room had moved on to "the best thing you have done as a Python
/// developer", Generate was tapped, and the answer came back titled "Why managing 5 people was tough" —
/// an earlier question's words were still sent as new input next to the newest one.
///
/// End to end through the real feed and coordinator: detection, the transcript the screen holds, the
/// tap, and the request the provider receives.
@MainActor
struct QuestionRoutingTests {
    typealias Support = CopilotTestSupport

    static let q1 = "Why was managing five people difficult?"
    static let q2 = "Tell me about a difficult Python project."

    struct Session {
        let model: InterviewScreenModel
        let coordinator: CopilotSessionCoordinator
        let provider: CopilotTestSupport.StubProvider
    }

    static func session(manualStreams: Bool = false) -> Session {
        let provider = CopilotTestSupport.StubProvider()
        provider.manualStreams = manualStreams
        provider.classifications = [
            DetectionResult(kind: .newQuestion, questionText: q1, confidence: 0.9),
            DetectionResult(kind: .newQuestion, questionText: q2, confidence: 0.9),
        ]
        let (feed, coordinator, _) = LiveInterviewFeedTests.makeFeed(provider: provider)
        let model = InterviewScreenModel(mode: .live, feed: feed)
        model.start()
        return Session(model: model, coordinator: coordinator, provider: provider)
    }

    /// Speech, then silence long enough for detection; waits until the question has its page.
    static func ask(_ text: String, at time: TimeInterval, in session: Session, expecting count: Int) async throws {
        session.coordinator.ingest(Support.finalDelta(text, at: time))
        session.coordinator.tick(now: time + 3)
        try await Support.waitUntil("\"\(text)\" is detected") { session.model.questions.count == count }
    }

    static func question(_ text: String, in model: InterviewScreenModel) throws -> InterviewQuestion {
        try #require(model.questions.first { $0.text == text })
    }

    static func sentText(_ request: AnswerRequest?) -> String {
        guard let request else { return "" }
        return ([request.question] + request.newInput).joined(separator: " | ")
    }

    // MARK: The bottom Generate answers the newest question

    @Test
    func afterAnsweringQ1OnItsPageGenerateSendsQ2AndNeverQ1() async throws {
        let session = Self.session()
        try await Self.ask(Self.q1, at: 1, in: session, expecting: 1)
        let first = try Self.question(Self.q1, in: session.model)
        session.model.generate(for: first)
        try await Support.waitUntil("Q1 answered") { session.model.questions.first?.selectedAnswer?.isComplete == true }
        #expect(session.provider.lastAnswerRequest?.question == Self.q1)

        try await Self.ask(Self.q2, at: 10, in: session, expecting: 2)
        session.model.generate(now: Date().addingTimeInterval(5))
        try await Support.waitUntil("the second request is sent") { session.provider.generateCallCount == 2 }
        let request = try #require(session.provider.lastAnswerRequest)
        #expect(request.newInput.contains(Self.q2), "Q2 is what is asked: \(request.newInput)")
        #expect(!request.newInput.contains(Self.q1), "Q1 was already answered and must not be asked again: \(request.newInput)")
    }

    @Test
    func withQ1UnansweredGenerateAfterQ2SendsOnlyQ2() async throws {
        let session = Self.session()
        try await Self.ask(Self.q1, at: 1, in: session, expecting: 1)
        try await Self.ask(Self.q2, at: 10, in: session, expecting: 2)
        session.model.generate(now: Date())
        try await Support.waitUntil("sent") { session.provider.generateCallCount == 1 }
        let request = try #require(session.provider.lastAnswerRequest)
        #expect(request.newInput.last == Self.q2)
        #expect(!request.newInput.contains(Self.q1), "the room moved on from Q1: \(request.newInput)")
        #expect(request.recentConversation.contains(Self.q1), "Q1 stays available as context")
    }

    @Test
    func whileReadingAnOlderPageTheBottomGenerateStillSendsTheNewestQuestion() async throws {
        let session = Self.session()
        try await Self.ask(Self.q1, at: 1, in: session, expecting: 1)
        session.model.select(questionID: try Self.question(Self.q1, in: session.model).id)
        try await Self.ask(Self.q2, at: 10, in: session, expecting: 2)
        #expect(session.model.currentQuestion?.text == Self.q1, "a new question does not move the reader")
        session.model.generate(now: Date())
        try await Support.waitUntil("sent") { session.provider.generateCallCount == 1 }
        #expect(!Self.sentText(session.provider.lastAnswerRequest).contains(Self.q1))
        #expect(session.provider.lastAnswerRequest?.newInput.last == Self.q2)
    }

    // MARK: A page's own Generate answers that page

    @Test
    func generateOnQ2sPageSendsQ2() async throws {
        let session = Self.session()
        try await Self.ask(Self.q1, at: 1, in: session, expecting: 1)
        try await Self.ask(Self.q2, at: 10, in: session, expecting: 2)
        session.model.generate(for: try Self.question(Self.q2, in: session.model))
        try await Support.waitUntil("sent") { session.provider.generateCallCount == 1 }
        #expect(session.provider.lastAnswerRequest?.question == Self.q2)
        #expect(!Self.sentText(session.provider.lastAnswerRequest).contains(Self.q1))
    }

    @Test
    func goingBackToQ1AndGeneratingThereSendsQ1() async throws {
        let session = Self.session()
        try await Self.ask(Self.q1, at: 1, in: session, expecting: 1)
        try await Self.ask(Self.q2, at: 10, in: session, expecting: 2)
        let first = try Self.question(Self.q1, in: session.model)
        session.model.select(questionID: first.id)
        session.model.generate(for: first)
        try await Support.waitUntil("sent") { session.provider.generateCallCount == 1 }
        #expect(session.provider.lastAnswerRequest?.question == Self.q1, "the page the user chose is the question asked")
        #expect(!Self.sentText(session.provider.lastAnswerRequest).contains(Self.q2))
    }

    // MARK: Identity survives asynchronous events

    @Test
    func aQuestionDetectedWhileAnAnswerIsStreamingCannotTakeThatAnswer() async throws {
        let session = Self.session(manualStreams: true)
        try await Self.ask(Self.q1, at: 1, in: session, expecting: 1)
        let first = try Self.question(Self.q1, in: session.model)
        session.model.generate(for: first)
        try await Support.waitUntil("Q1 streaming") { session.provider.generateCallCount == 1 }

        try await Self.ask(Self.q2, at: 10, in: session, expecting: 2)
        let second = try Self.question(Self.q2, in: session.model)
        session.model.select(questionID: second.id)

        // Q1's answer arrives after Q2 appeared and the reader moved to Q2.
        session.provider.push(.delta("Managing five people taught me to delegate. "))
        session.provider.push(.completed(usageOutputTokens: nil))
        session.provider.finishStream()
        try await Support.waitUntil("Q1's answer lands") {
            session.model.questions.first { $0.id == first.id }?.selectedAnswer?.isComplete == true
        }
        #expect(session.model.questions.first { $0.id == second.id }?.answers.isEmpty == true,
                "Q2 received nothing from Q1's request")
        #expect(session.model.currentQuestion?.id == second.id, "the reader was not moved")
    }

    @Test
    func aGenerateTappedBeforeDetectionKeepsItsOwnEntry() async throws {
        let session = Self.session(manualStreams: true)
        session.coordinator.ingest(Support.finalDelta(Self.q1, at: 1))
        try await Support.waitUntil("the line is on screen") { !session.model.transcript.isEmpty }
        session.model.generate(now: Date())                      // before detection has run
        try await Support.waitUntil("sent") { session.provider.generateCallCount == 1 }
        let entryID = try #require(session.model.questions.last?.id)
        #expect(session.provider.lastAnswerRequest?.newInput == [Self.q1])

        session.provider.push(.delta("An answer about the team. "))
        session.provider.push(.completed(usageOutputTokens: nil))
        session.provider.finishStream()
        try await Support.waitUntil("answered") {
            session.model.questions.first { $0.id == entryID }?.selectedAnswer?.isComplete == true
        }
        #expect(session.model.questions.filter { !$0.answers.isEmpty }.map(\.id) == [entryID],
                "the answer belongs to the tapped entry only")
    }
}
