import Testing
import Foundation
@testable import prompter

/// The rules of the v2.5 interview screen, tested through the model rather than through pixels.
///
/// Every test drives the model with feed events directly (`handle(_:)`) and steps the simulated
/// reader by hand, so nothing here waits on a timer.
@MainActor
struct InterviewScreenModelTests {
    // MARK: Support

    /// A feed that emits nothing on its own — the tests supply the events — and records what the
    /// model asked it for.
    @MainActor
    final class RecordingFeed: InterviewFeed {
        let events: AsyncStream<InterviewFeedEvent>
        private let continuation: AsyncStream<InterviewFeedEvent>.Continuation
        var isPaused = false
        private(set) var requests: [(requestID: UUID, questionID: UUID, isRegeneration: Bool)] = []
        private(set) var cancellations: [UUID] = []

        init() {
            (events, continuation) = AsyncStream<InterviewFeedEvent>.makeStream()
        }

        func start() {}
        func pause() { isPaused = true }
        func resume() { isPaused = false }
        func restart() {}
        func setSpeed(_ multiplier: Double) {}

        func requestAnswer(requestID: UUID, question: InterviewQuestion, isRegeneration: Bool) {
            requests.append((requestID, question.id, isRegeneration))
        }

        func cancelAnswer(requestID: UUID) {
            cancellations.append(requestID)
        }
    }

    static func makeModel(mode: InterviewMode = .demo) -> (InterviewScreenModel, RecordingFeed) {
        let feed = RecordingFeed()
        return (InterviewScreenModel(mode: mode, feed: feed), feed)
    }

    /// Detection only — no answer. This is what listening produces on its own.
    @discardableResult
    static func detect(_ text: String, in model: InterviewScreenModel) -> InterviewQuestion {
        let question = InterviewQuestion(text: text)
        model.handle(.questionDetected(question))
        return question
    }

    /// Plays a whole generation through, as the feed would after a Generate tap.
    static func completeGeneration(
        requestID: UUID,
        questionID: UUID,
        blocks: [AnswerBlock],
        in model: InterviewScreenModel
    ) {
        model.handle(.answerStarted(requestID: requestID, questionID: questionID))
        for case .prose(let text) in blocks {
            model.handle(.answerChunk(requestID: requestID, text: text))
        }
        model.handle(.answerCompleted(requestID: requestID, blocks: blocks, highlight: nil))
    }

    /// Detect a question and generate its answer — the two-step path a person actually takes.
    @discardableResult
    static func detectAndGenerate(
        _ text: String,
        answer: String,
        in model: InterviewScreenModel,
        feed: RecordingFeed
    ) -> InterviewQuestion {
        let question = detect(text, in: model)
        model.select(questionID: question.id)
        model.generate()
        guard let request = feed.requests.last else { return question }
        completeGeneration(requestID: request.requestID, questionID: question.id, blocks: [.prose(answer)], in: model)
        return question
    }

    // MARK: Detection does not generate

    @Test
    func detectingAQuestionDoesNotProduceAnAnswer() {
        let (model, feed) = Self.makeModel()
        Self.detect("How do you handle backpressure?", in: model)
        Self.detect("And retries?", in: model)

        #expect(model.questions.count == 2)
        #expect(model.questions.allSatisfy { $0.answers.isEmpty })
        #expect(feed.requests.isEmpty, "a question was answered without anyone asking")
    }

    @Test
    func aQuestionKeepsOneIdentityIfTheFeedRepeatsIt() {
        let (model, _) = Self.makeModel()
        let question = Self.detect("How do you handle backpressure?", in: model)
        model.handle(.questionDetected(question))       // same question announced twice

        #expect(model.questions.count == 1)
        #expect(model.questions.first?.id == question.id)
    }

    // MARK: Generate

    @Test
    func generateTargetsTheSelectedQuestionAndDoesNotDuplicateIt() throws {
        let (model, feed) = Self.makeModel()
        let first = Self.detect("First?", in: model)
        Self.detect("Second?", in: model)
        model.select(questionID: first.id)

        model.generate()
        let request = try #require(feed.requests.last)
        #expect(request.questionID == first.id)
        #expect(request.isRegeneration == false)

        Self.completeGeneration(requestID: request.requestID, questionID: first.id, blocks: [.prose("An answer.")], in: model)

        #expect(model.questions.count == 2, "generating an answer created another question")
        #expect(model.questions[0].id == first.id)
        #expect(model.questions[0].answers.count == 1)
        #expect(model.questions[0].selectedAnswer?.version == 1)
    }

    /// With nothing explicitly selected, Generate answers the most recent question that has none.
    @Test
    func generateFallsBackToTheLatestUnansweredQuestion() throws {
        let (model, feed) = Self.makeModel()
        Self.detect("First?", in: model)
        let second = Self.detect("Second?", in: model)

        model.generate()

        let request = try #require(feed.requests.last)
        #expect(request.questionID == second.id)
    }

    /// The button on a page is unambiguous: it answers *that* question, not whatever the target rule
    /// would have picked.
    @Test
    func thePageButtonGeneratesForItsOwnQuestion() throws {
        let (model, feed) = Self.makeModel()
        let first = Self.detect("First?", in: model)
        Self.detect("Second?", in: model)

        model.generate(for: first)

        let request = try #require(feed.requests.last)
        #expect(request.questionID == first.id)
    }

    @Test
    func repeatedTapsWhileGeneratingDoNotCreateASecondRequest() {
        let (model, feed) = Self.makeModel()
        let question = Self.detect("First?", in: model)
        model.select(questionID: question.id)

        model.generate()
        model.generate()
        model.generate()

        #expect(feed.requests.count == 1, "a second request was sent while one was already running")
        #expect(model.isGenerating(questionID: question.id))
        #expect(model.canGenerate == false)
    }

    @Test
    func aReadyAnswerDoesNotInterruptThePageBeingRead() throws {
        let (model, feed) = Self.makeModel()
        let first = Self.detect("First?", in: model)
        let second = Self.detect("Second?", in: model)
        Self.detectAndGenerate("Third?", answer: "Third answer.", in: model, feed: feed)

        // The reader goes back to page 1 and asks for page 2's answer from there.
        model.select(questionID: first.id)
        model.generate()          // targets the selected question — page 1
        let firstRequest = try #require(feed.requests.last)
        Self.completeGeneration(requestID: firstRequest.requestID, questionID: first.id, blocks: [.prose("First answer.")], in: model)
        #expect(model.currentIndex == 0)
        #expect(model.readyQuestionNumber == nil, "an answer on the visible page should not raise a chip")

        // Now a real generation for another page finishes while page 1 is on screen.
        model.select(questionID: second.id)
        model.generate()
        let secondRequest = try #require(feed.requests.last)
        model.select(questionID: first.id)                    // back to what they were reading
        Self.completeGeneration(requestID: secondRequest.requestID, questionID: second.id, blocks: [.prose("Second answer.")], in: model)

        #expect(model.currentIndex == 0, "a finished background answer moved the page")
        #expect(model.currentQuestion?.selectedAnswer?.proseText == "First answer.")
        #expect(model.readyQuestionNumber == 2, "the finished answer did not offer itself")
    }

    @Test
    func theReadyChipPointsAtTheQuestionWhoseAnswerArrived() throws {
        let (model, feed) = Self.makeModel()
        let first = Self.detect("First?", in: model)
        let second = Self.detect("Second?", in: model)
        model.select(questionID: second.id)
        model.generate()
        let request = try #require(feed.requests.last)

        // The reader moves back to page 1 while it is being written.
        model.select(questionID: first.id)
        Self.completeGeneration(requestID: request.requestID, questionID: second.id, blocks: [.prose("Second answer.")], in: model)

        #expect(model.currentIndex == 0, "the finished answer stole the page")
        #expect(model.readyQuestionNumber == 2)

        model.followReadyChip()
        #expect(model.currentIndex == 1)
        #expect(model.currentQuestion?.id == second.id)
        #expect(model.readyQuestionNumber == nil)
    }

    // MARK: Regenerate

    @Test
    func regenerateAddsAVersionAndKeepsThePreviousOne() throws {
        let (model, feed) = Self.makeModel()
        let question = Self.detectAndGenerate("First?", answer: "The first attempt.", in: model, feed: feed)
        let firstAnswerID = try #require(model.currentQuestion?.selectedAnswer?.id)

        model.regenerate()
        let request = try #require(feed.requests.last)
        #expect(request.isRegeneration)
        Self.completeGeneration(requestID: request.requestID, questionID: question.id, blocks: [.prose("A second attempt.")], in: model)

        let updated = try #require(model.currentQuestion)
        #expect(updated.answers.count == 2)
        #expect(updated.answers.first?.id == firstAnswerID)          // the old one is still there
        #expect(updated.answers.first?.version == 1)
        #expect(updated.answers.first?.proseText == "The first attempt.")
        #expect(updated.selectedAnswer?.version == 2)                // the new one is on screen
        #expect(updated.hasEarlierVersions)
    }

    // MARK: Stale events

    @Test
    func chunksFromAnUnknownRequestAreIgnored() {
        let (model, feed) = Self.makeModel()
        let question = Self.detectAndGenerate("First?", answer: "The real answer.", in: model, feed: feed)

        model.handle(.answerChunk(requestID: UUID(), text: "text from nowhere"))
        model.handle(.answerCompleted(requestID: UUID(), blocks: [.prose("an answer nobody asked for")], highlight: nil))

        #expect(model.questions.first(where: { $0.id == question.id })?.selectedAnswer?.proseText == "The real answer.")
    }

    @Test
    func eventsArrivingAfterCancellationAreIgnored() throws {
        let (model, feed) = Self.makeModel()
        let question = Self.detect("First?", in: model)
        model.select(questionID: question.id)
        model.generate()
        let request = try #require(feed.requests.last)
        model.handle(.answerStarted(requestID: request.requestID, questionID: question.id))

        model.cancelGeneration(for: question.id)
        #expect(feed.cancellations.contains(request.requestID))

        model.handle(.answerChunk(requestID: request.requestID, text: "late text"))
        model.handle(.answerCompleted(requestID: request.requestID, blocks: [.prose("late answer")], highlight: nil))

        let updated = try #require(model.questions.first)
        #expect(updated.answers.first?.isComplete == false)
        #expect(updated.answers.first?.proseText.isEmpty == true)
        #expect(model.isGenerating(questionID: question.id) == false)
    }

    @Test
    func endingTheSessionCancelsGenerationAndIgnoresWhatArrivesAfterwards() throws {
        let (model, feed) = Self.makeModel()
        let question = Self.detect("First?", in: model)
        model.select(questionID: question.id)
        model.generate()
        let request = try #require(feed.requests.last)
        model.handle(.answerStarted(requestID: request.requestID, questionID: question.id))

        model.stop()
        #expect(feed.cancellations.contains(request.requestID))

        model.handle(.answerCompleted(requestID: request.requestID, blocks: [.prose("after the end")], highlight: nil))
        #expect(model.questions.first?.selectedAnswer?.isComplete == false)
    }

    @Test
    func aFailedGenerationSaysSoAndReleasesTheQuestion() throws {
        let (model, feed) = Self.makeModel()
        let question = Self.detect("First?", in: model)
        model.select(questionID: question.id)
        model.generate()
        let request = try #require(feed.requests.last)

        model.handle(.answerFailed(requestID: request.requestID, message: "The demo script has no answer for this question."))

        #expect(model.generationFailure == "The demo script has no answer for this question.")
        #expect(model.isGenerating(questionID: question.id) == false)
        #expect(model.canGenerate)                     // and it can be tried again
    }

    // MARK: Page bounds and navigation

    @Test
    func navigationStopsAtBothEnds() {
        let (model, _) = Self.makeModel()
        Self.detect("First?", in: model)
        Self.detect("Second?", in: model)

        #expect(model.currentIndex == 0)
        #expect(model.canGoToPrevious == false)
        model.goToPrevious()
        #expect(model.currentIndex == 0)          // no wrap-around off the front

        model.goToNext()
        #expect(model.currentIndex == 1)
        #expect(model.canGoToNext == false)
        model.goToNext()
        #expect(model.currentIndex == 1)          // and none off the back
    }

    /// The chevrons and the swipe are two ways of moving the same index, so they cannot disagree.
    @Test
    func chevronsAndPagingShareOneIndex() {
        let (model, _) = Self.makeModel()
        Self.detect("First?", in: model)
        Self.detect("Second?", in: model)
        Self.detect("Third?", in: model)

        model.select(index: 2)                     // a swipe
        #expect(model.currentIndex == 2)
        #expect(model.counterText == "3/3")
        model.goToPrevious()                       // a chevron
        #expect(model.currentIndex == 1)
        #expect(model.counterText == "2/3")
    }

    @Test
    func tappingADetectedQuestionInTheTranscriptOpensItsPage() {
        let (model, _) = Self.makeModel()
        Self.detect("First?", in: model)
        let second = Self.detect("Second?", in: model)
        #expect(model.currentIndex == 0)

        model.select(questionID: second.id)
        #expect(model.currentIndex == 1)
    }

    /// The counter counts what has actually been detected. It never promises a total for an
    /// interview whose length nobody knows.
    @Test
    func theCounterCountsDetectedQuestionsOnly() {
        let (model, _) = Self.makeModel()
        #expect(model.counterText == "0/0")
        Self.detect("First?", in: model)
        #expect(model.counterText == "1/1")
        Self.detect("Second?", in: model)
        #expect(model.counterText == "1/2")
    }

    // MARK: Context

    @Test
    func contextAcceptsFiveImagesAndRefusesTheSixth() {
        let (model, _) = Self.makeModel()
        for index in 0..<ContextState.imageLimit {
            #expect(model.addContextImage(ContextImage(data: Data([UInt8(index)]))))
        }
        #expect(model.context.images.count == 5)
        #expect(model.context.isFull)
        #expect(model.addContextImage(ContextImage(data: Data([99]))) == false)
        #expect(model.context.images.count == 5)
        #expect(model.context.counterText == "5/5 images")
    }

    @Test
    func collapsingTheTranscriptKeepsTheContextTheUserEntered() {
        let (model, _) = Self.makeModel()
        model.isTranscriptExpanded = true
        model.context.note = "Focus on Java 17"
        for index in 0..<3 { model.addContextImage(ContextImage(data: Data([UInt8(index)]))) }

        model.collapseTranscript()

        #expect(model.isTranscriptExpanded == false)
        #expect(model.context.note == "Focus on Java 17")
        #expect(model.context.images.count == 3)
    }

    // MARK: Recording / playback

    @Test
    func pausingStopsThePlaybackAndResumingStartsItAgain() {
        let (model, feed) = Self.makeModel()
        #expect(model.recording == .live)

        model.toggleRecordingPause()
        #expect(model.recording == .paused)
        #expect(feed.isPaused)

        model.toggleRecordingPause()
        #expect(model.recording == .live)
        #expect(feed.isPaused == false)

        model.setRecording(.off)
        #expect(model.recording == .off)
        #expect(model.recording.accessibilityLabel == nil)   // nothing is claimed when nothing listens
    }

    @Test
    func pausingStopsTheSimulatedReading() {
        let (model, feed) = Self.makeModel()
        Self.detectAndGenerate("First?", answer: "Bound the queue rather than the producer.", in: model, feed: feed)
        #expect(model.stepSimulatedReading())

        model.setRecording(.paused)
        #expect(model.stepSimulatedReading() == false)
        #expect(model.isSimulatedReadingRunning == false)
    }

    // MARK: Reading

    @Test
    func simulatedReadingGreysTheWordsItHasRead() throws {
        let (model, feed) = Self.makeModel()
        let question = Self.detectAndGenerate("First?", answer: "Bound the queue rather than the producer.", in: model, feed: feed)
        let page = try #require(model.currentQuestion)
        let alignment = try #require(model.alignment(for: page))
        #expect(question.id == model.currentQuestion?.id)

        for _ in 0..<4 { model.stepSimulatedReading() }

        #expect(alignment.spokenTokenIndices.count >= 3)
        #expect(alignment.cursor.tokenIndex >= 3)
    }

    /// Reading may only start once the answer has stopped growing — aligning against text that is
    /// still arriving would invalidate every token index.
    @Test
    func simulatedReadingDoesNotStartBeforeTheAnswerIsComplete() throws {
        let (model, feed) = Self.makeModel()
        let question = Self.detect("First?", in: model)
        model.select(questionID: question.id)
        model.generate()
        let request = try #require(feed.requests.last)
        model.handle(.answerStarted(requestID: request.requestID, questionID: question.id))
        model.handle(.answerChunk(requestID: request.requestID, text: "Half an answer"))

        let pendingPage = try #require(model.currentQuestion)
        #expect(model.alignment(for: pendingPage) == nil)
        #expect(model.stepSimulatedReading() == false)

        model.handle(.answerCompleted(requestID: request.requestID, blocks: [.prose("Half an answer so far.")], highlight: nil))
        let completedPage = try #require(model.currentQuestion)
        #expect(model.alignment(for: completedPage) != nil)
        #expect(model.stepSimulatedReading())
    }

    @Test
    func theCodeCardIsNeverPartOfTheTextBeingRead() throws {
        let (model, feed) = Self.makeModel()
        let question = Self.detect("How?", in: model)
        model.select(questionID: question.id)
        model.generate()
        let request = try #require(feed.requests.last)
        Self.completeGeneration(
            requestID: request.requestID,
            questionID: question.id,
            blocks: [.prose("We bound the queue."), .code("let q = Queue()"), .prose("That is the whole trick.")],
            in: model
        )

        let answer = try #require(model.currentQuestion?.selectedAnswer)
        let page = try #require(model.currentQuestion)
        let alignment = try #require(model.alignment(for: page))
        #expect(alignment.text.contains("bound the queue"))
        #expect(alignment.text.contains("Queue()") == false)

        // And the card keeps its place between the paragraphs rather than being moved to the end.
        #expect(answer.blocks.count == 3)
        if case .code = answer.blocks[1] {} else { Issue.record("the code block left its original position") }
        #expect(answer.proseText == "We bound the queue.\n\nThat is the whole trick.")
    }

    /// The rule the reader relies on: touching the page hands them the scroll, and nothing moves it
    /// back until they say so. Simulated reading keeps feeding words — it just stops driving the page.
    @Test
    func aManualScrollTakesTheScrollFromTheSimulatedReaderUntilTheUserResumes() throws {
        let (model, feed) = Self.makeModel()
        let question = Self.detectAndGenerate(
            "First?",
            answer: "We bound the queue rather than the producer so memory stays flat under load.",
            in: model,
            feed: feed
        )
        let page = try #require(model.currentQuestion)
        let alignment = try #require(model.alignment(for: page))

        model.stepSimulatedReading()
        #expect(model.isAutoScrolling(question))               // following, as it starts

        model.beginManualScroll(on: question)
        model.endManualScroll(on: question, visibleTokens: 0..<alignment.scriptIndex.tokens.count)
        #expect(model.isAutoScrolling(question) == false)      // the reader owns the scroll now

        // Reading continues; the page still does not move itself.
        let before = alignment.cursor.tokenIndex
        for _ in 0..<3 { model.stepSimulatedReading() }
        #expect(alignment.cursor.tokenIndex > before)
        #expect(model.isAutoScrolling(question) == false)

        model.resumeFollowing(on: question)
        #expect(model.isAutoScrolling(question))
    }

    /// Navigating away must leave the other page's reading exactly where it was, and the simulation
    /// must not write into whichever page is now on screen.
    @Test
    func navigatingAwayPreservesEachPagesReadingPosition() throws {
        let (model, feed) = Self.makeModel()
        let first = Self.detectAndGenerate("First?", answer: "Bound the queue rather than the producer.", in: model, feed: feed)
        let second = Self.detectAndGenerate("Second?", answer: "Every record carries an idempotency key.", in: model, feed: feed)

        model.select(questionID: first.id)
        for _ in 0..<3 { model.stepSimulatedReading() }
        let firstPage = try #require(model.currentQuestion)
        let firstAlignment = try #require(model.alignment(for: firstPage))
        let firstPosition = firstAlignment.cursor.tokenIndex
        #expect(firstPosition > 0)

        model.select(questionID: second.id)
        let secondPage = try #require(model.currentQuestion)
        let secondAlignment = try #require(model.alignment(for: secondPage))
        #expect(secondAlignment.cursor.tokenIndex == 0, "the other page's reading leaked into this one")

        for _ in 0..<2 { model.stepSimulatedReading() }
        #expect(secondAlignment.cursor.tokenIndex > 0)

        model.select(questionID: first.id)
        #expect(firstAlignment.cursor.tokenIndex == firstPosition, "returning to a page lost its reading position")
    }

    @Test
    func turningSimulatedReadingOffStopsIt() {
        let (model, feed) = Self.makeModel()
        Self.detectAndGenerate("First?", answer: "Bound the queue rather than the producer.", in: model, feed: feed)
        model.stepSimulatedReading()

        model.isSimulatedReadingEnabled = false
        #expect(model.stepSimulatedReading() == false)
        #expect(model.isSimulatedReadingRunning == false)
    }

    /// Live mode must never fade words nobody is reading.
    @Test
    func liveModeNeverSimulatesReading() {
        let (model, feed) = Self.makeModel(mode: .live)
        Self.detectAndGenerate("First?", answer: "Bound the queue rather than the producer.", in: model, feed: feed)

        #expect(model.isSimulatedReadingEnabled == false)
        #expect(model.stepSimulatedReading() == false)
    }
}
