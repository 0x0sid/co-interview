import Foundation
import Testing
@testable import prompter

/// A saved question is answerable from its saved context, and a request blocked by the paywall goes
/// out once, in its own session, after verified access.
///
/// Regression: a reopened interview's questions (and any question this feed instance had not
/// detected itself) failed every time with "That question is no longer part of this session." while
/// the page's Generate stayed enabled — the page path resolved questions through the live feed's
/// in-memory card map.
@MainActor
struct SavedQuestionGenerateTests {
    typealias Support = CopilotTestSupport

    private func reopened(provider: CopilotTestSupport.StubProvider = CopilotTestSupport.StubProvider())
        -> (InterviewScreenModel, CopilotTestSupport.StubProvider, InterviewQuestion) {
        let (feed, _, stub) = LiveInterviewFeedTests.makeFeed(provider: provider)
        let saved = InterviewQuestion(text: "How would you shard a payments table?")
        var restored = RestoredInterview()
        restored.transcript = [TranscriptLine(text: "How would you shard a payments table?", isFinal: true)]
        restored.questions = [saved]
        let model = InterviewScreenModel(mode: .live, feed: feed, restored: restored)
        model.start()
        return (model, stub, saved)
    }

    @Test
    func generateOnAReopenedSavedQuestionAnswersItWithoutTheMicrophone() async throws {
        let (model, stub, saved) = reopened()
        #expect(model.isAwaitingResume, "reopened: the microphone is off")
        model.generate(for: saved)
        try await Support.waitUntil("the saved question is answered") {
            model.questions.first { $0.id == saved.id }?.selectedAnswer?.isComplete == true
        }
        let answer = try #require(model.questions.first { $0.id == saved.id }?.selectedAnswer)
        #expect(answer.failureMessage == nil, "no 'no longer part of this session'")
        #expect(!answer.isIncomplete)
        #expect(stub.lastAnswerRequest?.newInput == ["How would you shard a payments table?"])
        #expect(model.questions.first { $0.id == saved.id }?.text == saved.text, "the saved question keeps its own words")
        #expect(model.isAwaitingResume, "answering did not start listening")
        #expect(model.questions.count == 1, "answered on its own page, not as a new entry")
    }

    @Test
    func aBlockedSavedQuestionResumesOnceAfterVerifiedAccess() async throws {
        let (model, stub, saved) = reopened()
        let gate = FakeGate(allows: false, freeRemaining: 0)
        model.accessGate = gate
        model.generate(for: saved)
        #expect(gate.paywalls == [.generate])
        #expect(stub.generateCallCount == 0, "nothing is sent without access")
        #expect(model.isWaitingForAccess(questionID: saved.id))

        // Purchase verified: repeated entitlement callbacks must not send it twice.
        gate.freeRemaining = nil
        gate.allowsPaidRequests = true
        model.releaseHeldRequests()
        model.releaseHeldRequests()
        model.releaseHeldRequests()
        try await Support.waitUntil("the held request is answered") {
            model.questions.first { $0.id == saved.id }?.selectedAnswer?.isComplete == true
        }
        #expect(stub.generateCallCount == 1, "resumed exactly once")
        #expect(model.questions.count == 1)
    }

    @Test
    func aSavedQuestionKeepsOneGenerationKeyForRetryAndRegenerate() async throws {
        let stub = CopilotTestSupport.StubProvider()
        stub.generationError = CopilotProviderError.timedOut
        let (model, _, saved) = reopened(provider: stub)
        model.generate(for: saved)
        try await Support.waitUntil("the first attempt fails") { model.canRetry(questionID: saved.id) }
        let firstKey = try #require(stub.lastAnswerRequest?.generationKey)

        stub.generationError = nil
        model.retry(questionID: saved.id)
        try await Support.waitUntil("the retry completes") {
            model.questions.first { $0.id == saved.id }?.selectedAnswer?.isIncomplete == false
        }
        #expect(stub.lastAnswerRequest?.generationKey == firstKey, "a retry is the same generation")

        model.regenerate()
        try await Support.waitUntil("the new version completes") {
            (model.questions.first { $0.id == saved.id }?.answers.count ?? 0) == 3
                && model.questions.first { $0.id == saved.id }?.selectedAnswer?.isComplete == true
        }
        // One key per page: another version of the same question uses the same free-answer credit.
        #expect(stub.lastAnswerRequest?.generationKey == firstKey, "another version of the same question keeps its key")
    }
}
