import Foundation
import Testing
@testable import prompter

/// **Quota identity is the page, not the request.** Each new answer page gets one stable generation
/// key for its lifetime — its first answer, Regenerate, follow-ups, Retry, and reopening it later — and
/// a page uses one free answer, the first time usable answer text reaches it. Request ids stay unique
/// per request (stale-response protection) and never decide quota. The backend is authoritative; these
/// check that the app mirrors it (`backend/test/access-test.mjs` checks the ledger itself).
@MainActor
struct QuotaIdentityTests {
    typealias Support = ManualGenerationTests
    typealias Request = (requestID: UUID, questionID: UUID, discussion: DiscussionSnapshot)

    static let shorter = FollowUpActions.Action(id: "shorter", title: "Shorter", instruction: "Make it shorter.", systemImage: "scissors")

    static func ask(_ text: String, _ model: InterviewScreenModel, _ feed: Support.RecordingFeed, at offset: TimeInterval) -> Request? {
        Support.speak(text, in: model)
        Support.tap(model, at: offset)
        return feed.discussionRequests.last
    }

    /// Streams some answer text into a request without finishing it.
    static func deliverText(_ request: Request, _ model: InterviewScreenModel) {
        model.handle(.answerStarted(requestID: request.requestID, questionID: request.questionID))
        model.handle(.answerChunk(requestID: request.requestID, text: "Kafka keeps an ordered log "))
    }

    @Test
    func pageAsFirstAnswerCountsOnceAndItsRegenerateAndFollowUpDoNot() throws {
        let (model, feed) = Support.make()
        let gate = FakeGate(allows: true, freeRemaining: 3)
        model.accessGate = gate
        let a = try #require(Self.ask("Question A?", model, feed, at: 0))
        let keyA = try #require(a.discussion.generationKey)
        Support.completeActiveRequest(model, feed)
        #expect(gate.freeRemaining == 2, "A's first answer uses one free answer")

        model.regenerate()                                                   // Regenerate A
        let regen = try #require(feed.discussionRequests.last)
        #expect(regen.discussion.generationKey == keyA, "same page, same key")
        #expect(regen.requestID != a.requestID, "a new request id: stale-response protection is separate")
        Support.completeActiveRequest(model, feed)

        let pageA = try #require(model.questions.first)
        model.generate(action: Self.shorter, for: pageA, now: Date().addingTimeInterval(20))   // follow-up A
        #expect(feed.discussionRequests.last?.discussion.generationKey == keyA)
        Support.completeActiveRequest(model, feed)

        #expect(gate.freeRemaining == 2, "Regenerate and follow-up on A never count")
    }

    @Test
    func aFailedFirstAnswerIsNotChargedAndItsRetryIsChargedOnceOnSuccess() throws {
        let (model, feed) = Support.make()
        let gate = FakeGate(allows: true, freeRemaining: 3)
        model.accessGate = gate
        let a = try #require(Self.ask("Question A?", model, feed, at: 0))
        model.handle(.answerStarted(requestID: a.requestID, questionID: a.questionID))
        model.handle(.answerFailed(requestID: a.requestID, message: "The backend did not answer"))
        #expect(gate.freeRemaining == 3, "a failure before any answer text uses nothing")
        model.retry(questionID: a.questionID)
        let retry = try #require(feed.discussionRequests.last)
        #expect(retry.discussion.generationKey == a.discussion.generationKey, "Retry keeps the page's key")
        Support.completeActiveRequest(model, feed)
        #expect(gate.freeRemaining == 2, "charged once, on success")
    }

    @Test
    func cancellingBeforeUsableTextIsNotChargedAndTheRetryIsChargedOnce() throws {
        let (model, feed) = Support.make()
        let gate = FakeGate(allows: true, freeRemaining: 3)
        model.accessGate = gate
        let a = try #require(Self.ask("Question A?", model, feed, at: 0))
        model.handle(.answerStarted(requestID: a.requestID, questionID: a.questionID))   // no text yet
        model.cancelGeneration(for: a.questionID)
        #expect(gate.freeRemaining == 3, "cancelled before any answer text: no charge")

        model.generate(for: try #require(model.questions.first))                          // ask that page again
        let again = try #require(feed.discussionRequests.last)
        #expect(again.discussion.generationKey == a.discussion.generationKey, "the same page, the same key")
        Support.completeActiveRequest(model, feed)
        #expect(gate.freeRemaining == 2, "the successful answer is charged once")
    }

    @Test
    func cancellingAfterUsableTextIsChargedOnceAndNothingAfterChargesAgain() throws {
        let (model, feed) = Support.make()
        let gate = FakeGate(allows: true, freeRemaining: 3)
        model.accessGate = gate
        let a = try #require(Self.ask("Question A?", model, feed, at: 0))
        Self.deliverText(a, model)
        model.cancelGeneration(for: a.questionID)
        #expect(gate.freeRemaining == 2, "usable answer text had arrived: charged, not refunded by cancelling")

        let page = try #require(model.questions.first)
        model.generate(for: page)                                            // retry/regenerate the page
        Support.completeActiveRequest(model, feed)
        model.generate(action: Self.shorter, for: page, now: Date().addingTimeInterval(20))
        Support.completeActiveRequest(model, feed)
        #expect(gate.freeRemaining == 2, "still exactly one charge for page A")
        #expect(Set(feed.discussionRequests.compactMap(\.discussion.generationKey)).count == 1)
    }

    @Test
    func aFailureAfterUsableTextIsChargedOnce() throws {
        let (model, feed) = Support.make()
        let gate = FakeGate(allows: true, freeRemaining: 3)
        model.accessGate = gate
        let a = try #require(Self.ask("Question A?", model, feed, at: 0))
        Self.deliverText(a, model)
        model.handle(.answerFailed(requestID: a.requestID, message: "The connection was lost"))
        #expect(gate.freeRemaining == 2, "the reader received usable text before the failure")
        model.retry(questionID: a.questionID)
        Support.completeActiveRequest(model, feed)
        #expect(gate.freeRemaining == 2, "the retry is not charged again")
    }

    @Test
    func aClarificationOnlyReplyIsNotCharged() throws {
        let (model, feed) = Support.make()
        let gate = FakeGate(allows: true, freeRemaining: 3)
        model.accessGate = gate
        let a = try #require(Self.ask("Which one?", model, feed, at: 0))
        model.handle(.answerStarted(requestID: a.requestID, questionID: a.questionID))
        model.handle(.answerNeedsInput(requestID: a.requestID, need: .clarification))
        model.handle(.answerCompleted(requestID: a.requestID, blocks: [.prose("Which project do you mean?")], highlight: nil))
        #expect(gate.freeRemaining == 3)
    }

    @Test
    func pagesABAndCAreAnsweredAndDIsBlockedBeforeAnyPageExists() throws {
        let (model, feed) = Support.make()
        let gate = FakeGate(allows: true, freeRemaining: 3)
        model.accessGate = gate
        var keys: [String] = []
        for (n, text) in ["A?", "B?", "C?"].enumerated() {
            let request = try #require(Self.ask(text, model, feed, at: Double(n * 10)))
            keys.append(try #require(request.discussion.generationKey))
            Support.completeActiveRequest(model, feed)
        }
        #expect(Set(keys).count == 3, "each new page has its own key")
        #expect(gate.freeRemaining == 0)
        _ = Self.ask("D?", model, feed, at: 40)
        #expect(feed.discussionRequests.count == 3, "D is never sent")
        #expect(model.questions.count == 3, "and no empty page is created for it")
        #expect(gate.paywalls == [.generate])

        // A, B and C stay usable: Regenerate on one of them is allowed with none left.
        model.select(index: 1)
        model.regenerate()
        #expect(feed.discussionRequests.count == 4)
        #expect(feed.discussionRequests.last?.discussion.generationKey == keys[1])
        #expect(gate.paywalls == [.generate], "no paywall for an already-answered page")
    }

    @Test
    func proBypassesTheQuota() throws {
        let (model, feed) = Support.make()
        let gate = FakeGate(allows: true)                    // Pro: no free-answer counting
        model.accessGate = gate
        for n in 0..<5 {
            _ = Self.ask("Question \(n)?", model, feed, at: Double(n * 10))
            Support.completeActiveRequest(model, feed)
        }
        #expect(feed.discussionRequests.count == 5 && gate.paywalls.isEmpty)
    }

    @Test
    func aReopenedAnsweredPageKeepsItsKeyAndItsRegenerateIsFree() throws {
        let feed = Support.RecordingFeed()
        var question = InterviewQuestion(text: "Why Kafka?")
        question.answers = [InterviewAnswer(version: 1, blocks: [.prose("Replay and ordering.")], isComplete: true)]
        var restored = RestoredInterview()
        restored.questions = [question]
        var saved = DiscussionSnapshot(newInput: ["Why Kafka?"])
        saved.generationKey = "page-key-A"
        restored.retainedSnapshots = [question.id: saved]
        let model = InterviewScreenModel(mode: .live, feed: feed, restored: restored)
        let gate = FakeGate(allows: false, freeRemaining: 0)                 // none left
        model.accessGate = gate

        model.generate(for: question)                                         // Regenerate the saved page
        #expect(gate.paywalls.isEmpty, "an already-answered page is not charged again")
        #expect(feed.discussionRequests.last?.discussion.generationKey == "page-key-A", "the persisted key")
    }

    @Test
    func aLegacyPageWithoutASavedKeyGetsTheSameKeyEveryReopen() throws {
        var question = InterviewQuestion(text: "Why Kafka?")
        question.answers = [InterviewAnswer(version: 1, blocks: [.prose("Replay and ordering.")], isComplete: true)]
        var keys: [String?] = []
        for _ in 0..<2 {                                                     // reopened twice
            let feed = Support.RecordingFeed()
            var restored = RestoredInterview()
            restored.questions = [question]
            // A snapshot saved before pages kept their key: no generationKey in it.
            restored.retainedSnapshots = [question.id: DiscussionSnapshot(newInput: ["Why Kafka?"])]
            let model = InterviewScreenModel(mode: .live, feed: feed, restored: restored)
            model.accessGate = FakeGate(allows: true)
            model.generate(for: question)
            keys.append(feed.discussionRequests.last?.discussion.generationKey)
        }
        #expect(keys[0] != nil && keys[0] == keys[1], "derived from the page id, not new on every reopen")
        #expect(keys[0] == InterviewScreenModel.legacyPageKey(question.id))
    }
}
