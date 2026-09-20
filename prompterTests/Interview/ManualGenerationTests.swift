import Testing
import Foundation
@testable import prompter

/// Generate as the user actually uses it: without waiting for detection, repeatedly, while speech
/// keeps arriving.
///
/// The rule these all protect: **detection succeeding is not a precondition for Generate.** In a real
/// room detection is unreliable, and a button that disables itself when detection fails is a button
/// that fails exactly when it is needed.
@MainActor
struct ManualGenerationTests {
    /// Records what the screen asked for, including discussion requests.
    @MainActor
    final class RecordingFeed: InterviewFeed {
        let events: AsyncStream<InterviewFeedEvent>
        private let continuation: AsyncStream<InterviewFeedEvent>.Continuation
        var isPaused = false
        private(set) var discussionRequests: [(requestID: UUID, discussion: DiscussionSnapshot, questionID: UUID)] = []
        private(set) var questionRequests: [(requestID: UUID, questionID: UUID, isRegeneration: Bool)] = []
        private(set) var cancellations: [UUID] = []

        init() { (events, continuation) = AsyncStream<InterviewFeedEvent>.makeStream() }

        func start() {}
        func pause() { isPaused = true }
        func resume() { isPaused = false }
        func restart() {}
        func setSpeed(_ multiplier: Double) {}
        func requestAnswer(requestID: UUID, question: InterviewQuestion, isRegeneration: Bool) {
            questionRequests.append((requestID, question.id, isRegeneration))
        }
        func requestAnswerForDiscussion(requestID: UUID, discussion: DiscussionSnapshot, questionID: UUID) {
            discussionRequests.append((requestID, discussion, questionID))
        }
        func cancelAnswer(requestID: UUID) { cancellations.append(requestID) }
    }

    static func make() -> (InterviewScreenModel, RecordingFeed) {
        let feed = RecordingFeed()
        return (InterviewScreenModel(mode: .live, feed: feed), feed)
    }

    static func speak(_ text: String, in model: InterviewScreenModel, final: Bool = true) {
        model.handle(.transcriptLine(TranscriptLine(text: text, isFinal: final)))
    }

    /// Staggered so the debounce never refuses a deliberate second tap.
    static func tap(_ model: InterviewScreenModel, at offset: TimeInterval) {
        model.generate(now: Date(timeIntervalSince1970: 1_000 + offset))
    }

    /// Completes whatever request is running, which is what lets the next queued one start.
    /// Only one request is in flight at a time, so a test that wants to see the second request
    /// must finish the first — exactly as the screen does.
    static func completeActiveRequest(_ model: InterviewScreenModel, _ feed: RecordingFeed) {
        guard let active = feed.discussionRequests.last else { return }
        model.handle(.answerStarted(requestID: active.requestID, questionID: active.questionID))
        model.handle(.answerCompleted(requestID: active.requestID, blocks: [.prose("Done.")], highlight: nil))
    }

    // MARK: The contract

    /// The headline case: speech exists, detection produced nothing, Generate still works.
    @Test
    func generateWorksWithNoDetectedQuestion() throws {
        let (model, feed) = Self.make()
        Self.speak("So tell me how you would handle backpressure in that service", in: model)
        #expect(model.questions.isEmpty, "no question was detected, which is the premise")

        Self.tap(model, at: 0)

        #expect(feed.discussionRequests.count == 1, "Generate did not ask for an answer")
        #expect(model.questions.count == 1, "Generate did not create a history entry")
        let request = try #require(feed.discussionRequests.first)
        #expect(request.discussion.allLines.contains { $0.contains("backpressure") })
    }

    @Test
    func theEntryIsLabelledWithWhatWasActuallyAnswered() throws {
        let (model, feed) = Self.make()
        Self.speak("How do you handle backpressure", in: model)
        Self.tap(model, at: 0)
        let request = try #require(feed.discussionRequests.first)

        model.handle(.answerTopicResolved(requestID: request.requestID, topic: "How do you handle backpressure"))

        #expect(model.questions.first?.text == "How do you handle backpressure")
    }

    /// Nothing to answer: the button stays usable and says what to do.
    @Test
    func anEmptyRequestIsNeverSent() {
        let (model, feed) = Self.make()
        #expect(model.canGenerate, "Generate must stay tappable")

        Self.tap(model, at: 0)

        #expect(feed.discussionRequests.isEmpty, "an empty request was sent")
        #expect(model.questions.isEmpty)
        #expect(model.emptyInputNotice == "Speak or add context first")
    }

    /// Context alone is enough to ask about.
    @Test
    func contextAloneIsEnoughToGenerate() {
        let (model, feed) = Self.make()
        model.context.note = "Focus on Java 17"

        Self.tap(model, at: 0)

        #expect(feed.discussionRequests.count == 1)
        #expect(model.emptyInputNotice == nil)
    }

    // MARK: History

    /// **Rule changed.** A tap used to create an entry unconditionally. It now requires new input:
    /// repeated taps during silence must not answer the same words again. Each tap that *does* have
    /// something new still gets its own entry.
    @Test
    func tapsWithNewSpeechEachCreateTheirOwnEntry() {
        let (model, feed) = Self.make()
        Self.speak("Tell me about the ingestion project", in: model)
        Self.tap(model, at: 0)

        Self.speak("And what was hardest about it", in: model)
        Self.tap(model, at: 5)

        Self.speak("And how long did it take", in: model)
        Self.tap(model, at: 10)

        #expect(model.questions.count == 3, "taps with new speech collapsed into one entry")
        // One request runs at a time, so only the first has been sent; the others are queued and
        // each already has its own entry and its own id.
        #expect(feed.discussionRequests.count == 1)
        #expect(Set(model.queuedRequestIDs).count == 2, "queued requests shared an id")
    }

    /// One press must not become two entries.
    @Test
    func anAccidentalDoubleTapIsDebounced() {
        let (model, _) = Self.make()
        Self.speak("Tell me about the project", in: model)

        Self.tap(model, at: 0)
        model.generate(now: Date(timeIntervalSince1970: 1_000.1))   // within the debounce window

        #expect(model.questions.count == 1, "a double tap created two entries")
    }

    /// Each request keeps the discussion it was created for.
    @Test
    func aQueuedRequestKeepsItsOwnSnapshot() throws {
        let (model, feed) = Self.make()
        Self.speak("First topic is backpressure", in: model)
        Self.tap(model, at: 0)

        // More speech arrives, then a second tap.
        Self.speak("Second topic is retries", in: model)
        Self.tap(model, at: 5)

        let first = try #require(feed.discussionRequests.first)
        #expect(first.discussion.allLines.contains { $0.contains("backpressure") })
        #expect(first.discussion.allLines.contains { $0.contains("retries") } == false,
                "later speech leaked into an earlier request's snapshot")
    }

    /// **Rule changed.** A later entry used to leave the reader where they were and offer a chip.
    /// Generate now navigates to the tab it creates, because the user asked for it. What must still
    /// never move them is anything arriving *afterwards* — streaming or completion.
    @Test
    func generateOpensTheTabItCreates() {
        let (model, feed) = Self.make()
        Self.speak("Something worth answering", in: model)
        Self.tap(model, at: 0)
        #expect(model.currentIndex == 0, "the first entry should open directly")

        Self.speak("A second thing worth answering", in: model)
        Self.tap(model, at: 5)
        #expect(model.currentIndex == 1, "Generate did not open the tab it created")
        #expect(model.readyQuestionNumber == nil, "the tab it opened should not also raise a chip")

        // The user moves away; a completion for the tab they left must not pull them back.
        model.select(index: 0)
        Self.completeActiveRequest(model, feed)
        #expect(model.currentIndex == 0, "completion navigated after the user moved elsewhere")
    }

    /// Browsing history must not change what the next ordinary tap asks about.
    @Test
    func browsingHistoryDoesNotChangeTheGenerateTarget() throws {
        let (model, feed) = Self.make()
        Self.speak("Older discussion", in: model)
        Self.tap(model, at: 0)
        Self.speak("Newest discussion about retries", in: model)
        Self.tap(model, at: 5)

        model.select(index: 0)                      // the user browses back
        Self.tap(model, at: 10)

        // Drain the queue so the request made after browsing is actually sent.
        Self.completeActiveRequest(model, feed)
        Self.completeActiveRequest(model, feed)
        let latest = try #require(feed.discussionRequests.last)
        #expect(latest.discussion.allLines.contains { $0.contains("retries") },
                "Generate answered the page being viewed rather than the latest discussion")
    }

    // MARK: Queue

    @Test
    func onlyOneRequestRunsAtATimeAndTheRestQueue() {
        let (model, feed) = Self.make()
        Self.speak("Something to answer", in: model)

        Self.tap(model, at: 0)
        Self.speak("A second thing to answer", in: model)
        Self.tap(model, at: 5)
        Self.speak("A third thing to answer", in: model)
        Self.tap(model, at: 10)

        #expect(feed.discussionRequests.count == 1, "more than one request was started at once")
        #expect(model.queuedRequestIDs.count == 2, "the rest should be queued, not lost")
        #expect(model.questions.count == 3, "every accepted tap still gets its entry immediately")
    }

    @Test
    func finishingOneRequestStartsTheNext() throws {
        let (model, feed) = Self.make()
        Self.speak("Something to answer", in: model)
        Self.tap(model, at: 0)
        Self.speak("Another thing to answer", in: model)
        Self.tap(model, at: 5)

        let first = try #require(feed.discussionRequests.first)
        model.handle(.answerStarted(requestID: first.requestID, questionID: first.questionID))
        model.handle(.answerCompleted(requestID: first.requestID, blocks: [.prose("Done.")], highlight: nil))

        #expect(feed.discussionRequests.count == 2, "the queued request never started")
        #expect(model.queuedRequestIDs.isEmpty)
    }

    /// A full queue explains itself; it never silently drops an accepted request.
    @Test
    func afullQueueSaysSoRatherThanDiscarding() {
        let (model, _) = Self.make()
        Self.speak("Something to answer", in: model)

        for index in 0...(InterviewScreenModel.maximumQueuedRequests + 2) {
            // New speech each time, so every tap is genuinely eligible and the limit is what stops
            // it — not the no-new-input rule.
            Self.speak("Another thing to answer number \(index)", in: model)
            Self.tap(model, at: Double(index) * 5)
        }

        #expect(model.queuedRequestIDs.count <= InterviewScreenModel.maximumQueuedRequests)
        let notice = model.emptyInputNotice ?? ""
        #expect(notice.contains("wait or cancel"), "a refused tap did not explain itself: \(notice)")
    }

    // MARK: Failure and late events

    /// A failure keeps what arrived and labels it incomplete.
    @Test
    func apartialAnswerSurvivesAFailure() throws {
        let (model, feed) = Self.make()
        Self.speak("Something to answer", in: model)
        Self.tap(model, at: 0)
        let request = try #require(feed.discussionRequests.first)

        model.handle(.answerStarted(requestID: request.requestID, questionID: request.questionID))
        model.handle(.answerChunk(requestID: request.requestID, text: "Half of an answer"))
        model.handle(.answerFailed(requestID: request.requestID, message: "The backend did not answer"))

        let answer = try #require(model.questions.first?.selectedAnswer)
        #expect(answer.proseText.contains("Half of an answer"), "streamed text was thrown away")
        #expect(answer.isIncomplete, "a truncated answer was presented as complete")
        #expect(model.generationFailure == "The backend did not answer")
    }

    /// A late event from one request must never write into another entry.
    @Test
    func alateEventCannotUpdateTheWrongEntry() throws {
        let (model, feed) = Self.make()
        Self.speak("First", in: model)
        Self.tap(model, at: 0)
        Self.speak("Second", in: model)
        Self.tap(model, at: 5)

        let first = try #require(feed.discussionRequests.first)
        model.handle(.answerStarted(requestID: first.requestID, questionID: first.questionID))
        model.handle(.answerCompleted(requestID: first.requestID, blocks: [.prose("First answer.")], highlight: nil))

        // A stale chunk for the finished request arrives afterwards.
        model.handle(.answerChunk(requestID: first.requestID, text: " and more"))

        #expect(model.questions[0].selectedAnswer?.proseText == "First answer.")
        #expect(model.questions[1].answers.isEmpty, "a late event wrote into the wrong entry")
    }

    /// Ending the session cancels queued work and ignores anything that arrives afterwards.
    @Test
    func endingTheSessionCancelsQueuedWork() throws {
        let (model, feed) = Self.make()
        Self.speak("Something to answer", in: model)
        Self.tap(model, at: 0)
        Self.speak("Another thing to answer", in: model)
        Self.tap(model, at: 5)
        let first = try #require(feed.discussionRequests.first)

        model.stop()

        #expect(model.queuedRequestIDs.isEmpty)
        model.handle(.answerCompleted(requestID: first.requestID, blocks: [.prose("Too late.")], highlight: nil))
        #expect(model.questions.first?.selectedAnswer?.isComplete != true,
                "an event after the session ended still updated an entry")
    }

    /// Speech keeps arriving while an answer is being generated, and is available to the next tap.
    @Test
    func speechContinuesDuringGeneration() throws {
        let (model, feed) = Self.make()
        Self.speak("First thing said", in: model)
        Self.tap(model, at: 0)
        let request = try #require(feed.discussionRequests.first)
        model.handle(.answerStarted(requestID: request.requestID, questionID: request.questionID))

        Self.speak("Said while the answer was streaming", in: model)

        #expect(model.transcript.count == 2, "transcription stopped during generation")
        Self.tap(model, at: 5)
        // Finish the first so the second is sent.
        model.handle(.answerCompleted(requestID: request.requestID, blocks: [.prose("Done.")], highlight: nil))
        let second = try #require(feed.discussionRequests.last)
        #expect(second.discussion.allLines.contains { $0.contains("while the answer was streaming") })
    }
}
