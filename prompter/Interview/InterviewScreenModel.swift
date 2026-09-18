import Foundation
import Observation
import SwiftUI

/// Everything the v2.5 interview screen knows, with no view code in it.
///
/// It consumes an `InterviewFeed` and nothing else: no provider, no backend, no microphone. Swapping
/// `DemoInterviewFeed` for a live feed is the whole of the change when the pipeline is wired up.
///
/// **Detecting a question and answering it are two different actions.** Questions arrive on their
/// own, because that is what listening does. An answer is written only after `generate()` — a
/// deliberate tap. Nothing here answers a question by itself.
///
/// **Reading is the inherited engine, not a new one.** Each completed answer gets its own
/// `ReadingAlignment` over its prose (code cards are excluded by construction — `proseText` never
/// contains them), and each page has its own `ScrollOwnership`. The simulated reader in the demo
/// feeds synthetic `TranscriptDelta` values into exactly the same `ingest` call a real transcriber
/// would, so replacing it later changes the source of the deltas and nothing else.
@MainActor
@Observable
final class InterviewScreenModel {
    // MARK: Content

    private(set) var questions: [InterviewQuestion] = []
    private(set) var transcript: [TranscriptLine] = []
    /// The page on screen. Always a valid index once there is at least one question.
    private(set) var currentIndex = 0

    let mode: InterviewMode
    private let feed: any InterviewFeed

    // MARK: Chrome

    var isTranscriptExpanded = false
    /// The context panel lives inside the expanded transcript; its contents survive collapsing.
    var isContextPanelOpen = true
    var context = ContextState()
    private(set) var recording: RecordingState = .live
    /// Set when an answer becomes ready on a page the user is not looking at: "Q3 ready →".
    private(set) var readyQuestionNumber: Int?
    /// Said plainly under the answer when a generation produced nothing.
    private(set) var generationFailure: String?
    var isFollowUpsSheetPresented = false

    // MARK: Generation

    /// One in-flight generation. `answerID` is filled when the feed says it has started.
    private struct Generation {
        let questionID: UUID
        var answerID: UUID?
        let isRegeneration: Bool
    }

    /// Keyed by request id — the identity that makes a late event recognisable and discardable.
    private var generations: [UUID: Generation] = [:]
    /// questionID → the request currently running for it, so a second tap cannot start a second one.
    private var requestByQuestion: [UUID: UUID] = [:]
    /// Set when the user deliberately navigates. Generate targets this, not wherever the script got to.
    private var explicitlySelectedQuestionID: UUID?

    // MARK: Simulated reading (demo only)

    /// On by default in the demo, never in live mode. Turning it off stops the fading immediately.
    var isSimulatedReadingEnabled: Bool {
        didSet {
            guard oldValue != isSimulatedReadingEnabled else { return }
            if isSimulatedReadingEnabled { startSimulatedReadingIfNeeded() } else { stopSimulatedReading() }
        }
    }
    private(set) var isSimulatedReadingRunning = false

    /// One alignment per answer version, so regenerating does not disturb the reading of the old one.
    private var alignments: [UUID: ReadingAlignment] = [:]
    /// One ownership rule per question, so scrolling one page by hand does not detach the others.
    private var ownership: [UUID: ScrollOwnership] = [:]
    /// How far the simulated read has got in each answer, so returning to a page resumes where it was.
    private var simulatedWordIndex: [UUID: Int] = [:]
    private var simulatedClock: TimeInterval = 0
    /// The answer the running simulation belongs to. A step that no longer matches is stale and is
    /// dropped, so navigating away or regenerating can never move another page's text.
    private var simulatingAnswerID: UUID?
    private var simulationTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?

    /// In Live this is the real capture session, so the waveform reflects what the microphone is
    /// actually doing and reading is driven by real transcription. Nil in Demo, which has neither.
    private var liveFeed: LiveInterviewFeed? { feed as? LiveInterviewFeed }

    /// What the header mark shows. In Live it is the audio session's own state — never a decorative
    /// animation — so "listening" on screen means the microphone is genuinely open.
    var listeningState: ListeningState? { liveFeed?.coordinator.audio.state }

    init(mode: InterviewMode, feed: any InterviewFeed) {
        self.mode = mode
        self.feed = feed
        self.isSimulatedReadingEnabled = mode == .demo
        #if DEBUG
        // Screenshot support: a full context panel, filled with obviously-synthetic placeholders.
        let arguments = ProcessInfo.processInfo.arguments
        if mode == .demo, let flag = arguments.firstIndex(of: "-InterviewSyntheticContextImages"),
           flag + 1 < arguments.count, let count = Int(arguments[flag + 1]), count > 0 {
            context = .synthetic(imageCount: count, note: "Focus on Java 17")
            isTranscriptExpanded = true
        }
        #endif
    }

    // No `deinit` cancellation: a nonisolated deinit may not touch these main-actor properties, and
    // it does not need to — both tasks hold `weak self` and end on their next hop once the model is
    // gone. `stop()` is the deterministic teardown, called when the screen disappears.

    // MARK: - Lifecycle

    func start() {
        guard feedTask == nil else { return }
        // Live: real transcription drives reading, and the capture session drives the header mark.
        // Both come from the one session the coordinator already owns.
        liveFeed?.onDelta = { [weak self] delta in
            guard let self else { return }
            ingestLiveDelta(delta)
            refreshRecordingFromCapture()
        }
        feed.start()
        feedTask = Task { [weak self] in
            guard let events = self?.feed.events else { return }
            for await event in events {
                guard let self else { return }
                handle(event)
            }
        }
    }

    /// Ends the session: every in-flight generation is abandoned, and anything that arrives for one
    /// afterwards is ignored because its request is no longer known.
    func stop() {
        for requestID in generations.keys { feed.cancelAnswer(requestID: requestID) }
        generations = [:]
        requestByQuestion = [:]
        stopSimulatedReading()
        feedTask?.cancel()
        feedTask = nil
    }

    /// Applies one feed event. Not private: the tests drive the model through this directly, which
    /// keeps them free of timers.
    func handle(_ event: InterviewFeedEvent) {
        switch event {
        case .transcriptLine(let line):
            upsert(line)

        case .questionDetected(let question):
            appendQuestion(question)

        case .answerStarted(let requestID, let questionID):
            startAnswer(requestID: requestID, questionID: questionID)

        case .answerChunk(let requestID, let text):
            appendChunk(text, requestID: requestID)

        case .answerCompleted(let requestID, let blocks, let highlight):
            completeAnswer(requestID: requestID, blocks: blocks, highlight: highlight)

        case .answerFailed(let requestID, let message):
            failAnswer(requestID: requestID, message: message)
        }
    }

    // MARK: - Pages

    var currentQuestion: InterviewQuestion? {
        guard questions.indices.contains(currentIndex) else { return nil }
        return questions[currentIndex]
    }

    /// "2/3" — how many questions have actually been detected. Deliberately **not** a planned total:
    /// a real interview's length is unknown, and showing "2/8" would be a promise nothing can keep.
    var counterText: String {
        guard !questions.isEmpty else { return "0/0" }
        return counterText(forPage: currentIndex)
    }

    func counterText(forPage index: Int) -> String { "\(index + 1)/\(questions.count)" }

    var canGoToPrevious: Bool { currentIndex > 0 }
    var canGoToNext: Bool { currentIndex + 1 < questions.count }

    func goToPrevious() {
        guard canGoToPrevious else { return }
        select(index: currentIndex - 1)
    }

    func goToNext() {
        guard canGoToNext else { return }
        select(index: currentIndex + 1)
    }

    /// Every deliberate move through the pages comes here: the chevrons, a swipe, the chip and the
    /// transcript. Selecting is what makes a question the target of Generate.
    func select(index: Int) {
        guard questions.indices.contains(index) else { return }
        currentIndex = index
        explicitlySelectedQuestionID = questions[index].id
        if readyQuestionNumber == index + 1 { readyQuestionNumber = nil }
        generationFailure = nil
        restartSimulatedReadingForCurrentPage()
    }

    /// Tapping a detected question in the transcript jumps to its page.
    func select(questionID: UUID) {
        guard let index = questions.firstIndex(where: { $0.id == questionID }) else { return }
        select(index: index)
    }

    /// Dismisses the "Q3 ready →" chip by going to that page.
    func followReadyChip() {
        guard let number = readyQuestionNumber, questions.indices.contains(number - 1) else { return }
        select(index: number - 1)
    }

    // MARK: - Generate

    /// What Generate will answer: the question the user deliberately selected, otherwise the most
    /// recent detected question that has no answer yet, otherwise the most recent question.
    var generationTarget: InterviewQuestion? {
        if let explicitlySelectedQuestionID,
           let question = questions.first(where: { $0.id == explicitlySelectedQuestionID }) {
            return question
        }
        return questions.last(where: { $0.answers.isEmpty }) ?? questions.last
    }

    /// True while a generation for that question is running.
    func isGenerating(questionID: UUID) -> Bool { requestByQuestion[questionID] != nil }

    /// True while the button should show it is busy — the target is generating.
    var isGeneratingForTarget: Bool {
        guard let target = generationTarget else { return false }
        return isGenerating(questionID: target.id)
    }

    var canGenerate: Bool { generationTarget != nil && !isGeneratingForTarget }

    /// Asks for an answer to the target question. **A second tap while one is running does nothing** —
    /// the question already has a request, and one question never has two in flight.
    func generate() {
        guard let target = generationTarget else { return }
        requestAnswer(for: target, isRegeneration: !target.answers.isEmpty)
    }

    /// Generate for one named question — what the button *on a page* does. The page is unambiguous
    /// about what it means, so it does not go through the target rule at all.
    func generate(for question: InterviewQuestion) {
        explicitlySelectedQuestionID = question.id
        requestAnswer(for: question, isRegeneration: !question.answers.isEmpty)
    }

    /// Produces a new version of the current answer. The previous version is kept, not replaced.
    func regenerate() {
        guard let question = currentQuestion else { return }
        requestAnswer(for: question, isRegeneration: true)
    }

    private func requestAnswer(for question: InterviewQuestion, isRegeneration: Bool) {
        guard requestByQuestion[question.id] == nil else { return }   // no duplicate requests
        syncSessionNote()
        let requestID = UUID()
        generations[requestID] = Generation(questionID: question.id, answerID: nil, isRegeneration: isRegeneration)
        requestByQuestion[question.id] = requestID
        generationFailure = nil
        feed.requestAnswer(requestID: requestID, question: question, isRegeneration: isRegeneration)
    }

    /// Abandons the generation running for a question, if any. Anything already in flight for it
    /// arrives with a request id this model no longer knows, and is dropped.
    func cancelGeneration(for questionID: UUID) {
        guard let requestID = requestByQuestion[questionID] else { return }
        feed.cancelAnswer(requestID: requestID)
        generations[requestID] = nil
        requestByQuestion[questionID] = nil
    }

    // MARK: - Recording

    /// In Live, the truth about listening lives in the audio session; this mirrors it so the mark
    /// cannot claim the microphone is open when it is not.
    func refreshRecordingFromCapture() {
        guard mode == .live, let state = listeningState else { return }
        switch state {
        case .listening: recording = .live
        case .starting: recording = .live
        case .pausedByUser, .interrupted: recording = .paused
        case .idle, .permissionDenied, .failed: recording = .off
        }
    }

    func setRecording(_ state: RecordingState) {
        recording = state
        switch state {
        case .live:
            feed.resume()
            startSimulatedReadingIfNeeded()
        case .paused, .off:
            feed.pause()
            stopSimulatedReading()
        }
    }

    func toggleRecordingPause() {
        setRecording(recording == .live ? .paused : .live)
    }

    // MARK: - Context

    /// Returns false when the limit is already reached, so the view can say so instead of dropping
    /// the image silently.
    @discardableResult
    func addContextImage(_ image: ContextImage) -> Bool {
        context.addImage(image)
    }

    func removeContextImage(id: UUID) {
        context.removeImage(id: id)
    }

    /// Collapsing the strip is a view state change only — the note and the images stay.
    func collapseTranscript() {
        isTranscriptExpanded = false
    }

    /// Hands the typed note to the pipeline, where it is snapshotted into the next request.
    func syncSessionNote() {
        liveFeed?.coordinator.sessionNote = context.note
    }

    /// **Attached images are not sent to the model in this increment.**
    ///
    /// The answer route is text-only: `AnswerRequest` carries text, and the backend's two adapters
    /// send text. Sending an image to a text-only model would mean it was silently ignored while the
    /// screen implied it had been read, so the images stay local and the panel says so before
    /// anything is generated. The note *is* sent.
    var contextLimitationMessage: String? {
        guard mode == .live, !context.images.isEmpty else { return nil }
        return context.images.count == 1
            ? "The attached image is not sent — the configured model is text-only. Your note is sent."
            : "The \(context.images.count) attached images are not sent — the configured model is text-only. Your note is sent."
    }

    // MARK: - Reading

    /// The alignment for a page's selected answer, created on first use. Only complete answers get
    /// one: `ReadingAlignment` captures its tokens at init, so aligning against growing text would
    /// invalidate every index.
    func alignment(for question: InterviewQuestion) -> ReadingAlignment? {
        guard let answer = question.selectedAnswer, answer.isComplete else { return nil }
        if let existing = alignments[answer.id] { return existing }
        let text = answer.proseText
        guard !text.isEmpty else { return nil }
        let alignment = ReadingAlignment(text: text)
        alignments[answer.id] = alignment
        return alignment
    }

    func scrollOwnership(for question: InterviewQuestion) -> ScrollOwnership {
        ownership[question.id] ?? ScrollOwnership()
    }

    /// True while the page may move itself. False as soon as the reader has taken the scroll.
    func isAutoScrolling(_ question: InterviewQuestion) -> Bool {
        !scrollOwnership(for: question).isManuallyDetached
    }

    func beginManualScroll(on question: InterviewQuestion) {
        var rule = scrollOwnership(for: question)
        rule.beginManualInteraction()
        ownership[question.id] = rule
    }

    func endManualScroll(on question: InterviewQuestion, visibleTokens: Range<Int>?) {
        var rule = scrollOwnership(for: question)
        rule.endManualInteraction(visibleTokens: visibleTokens)
        ownership[question.id] = rule
    }

    /// The reader tapped "Resume following".
    func resumeFollowing(on question: InterviewQuestion) {
        var rule = scrollOwnership(for: question)
        rule.resumeAutomatically()
        ownership[question.id] = rule
    }

    /// Feeds one delta into the page's alignment and lets the ownership rule see the cursor move.
    /// This is the single entry point for reading, simulated or real.
    func ingest(_ delta: TranscriptDelta, for question: InterviewQuestion, scrollIsIdle: Bool = true) {
        guard let alignment = alignment(for: question) else { return }
        let outcome = alignment.ingest(delta)
        guard outcome.cursorMoved else { return }
        var rule = scrollOwnership(for: question)
        _ = rule.observeCursor(
            token: alignment.cursor.tokenIndex,
            isAdvancing: alignment.cursor.state == .advancing,
            scrollIsIdle: scrollIsIdle
        )
        ownership[question.id] = rule
    }

    // MARK: - Simulated reading

    /// One step of the simulated read: the next word of the current answer, delivered as a `.final`
    /// delta exactly as the transcriber would. Not private — the tests step it directly.
    ///
    /// It refuses to do anything unless the answer it was started for is still the one on screen, so
    /// a step left over from a page the user has navigated away from cannot write anywhere.
    @discardableResult
    func stepSimulatedReading() -> Bool {
        guard isSimulatedReadingEnabled, mode == .demo, recording == .live else { return false }
        guard let question = currentQuestion,
              let answer = question.selectedAnswer,
              answer.id == simulatingAnswerID,
              let alignment = alignment(for: question) else { return false }
        let words = Tokenizer.normalize(alignment.text)
        let index = simulatedWordIndex[answer.id] ?? 0
        guard index < words.count else { return false }
        simulatedClock += Self.simulatedWordInterval
        let word = words[index]
        simulatedWordIndex[answer.id] = index + 1
        ingest(
            TranscriptDelta(
                text: word,
                tokens: [Token(word, at: simulatedClock)],
                kind: .final,
                timestamp: simulatedClock
            ),
            for: question
        )
        return true
    }

    /// Starts the simulated read of the page on screen — only once its answer has finished arriving.
    private func startSimulatedReadingIfNeeded() {
        guard isSimulatedReadingEnabled, mode == .demo, recording == .live else { return }
        guard let question = currentQuestion,
              let answer = question.selectedAnswer,
              answer.isComplete,
              alignment(for: question) != nil else { return }
        guard simulationTask == nil || simulatingAnswerID != answer.id else { return }
        stopSimulatedReading()
        simulatingAnswerID = answer.id
        isSimulatedReadingRunning = true
        simulationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.simulatedWordInterval))
                guard let self, !Task.isCancelled else { return }
                if !stepSimulatedReading() {
                    isSimulatedReadingRunning = false
                    return
                }
            }
        }
    }

    private func stopSimulatedReading() {
        simulationTask?.cancel()
        simulationTask = nil
        simulatingAnswerID = nil
        isSimulatedReadingRunning = false
    }

    /// Page changed: stop whatever was reading, then begin this page's answer if it has one. The
    /// word index is kept per answer, so returning to a page resumes where the reading was.
    private func restartSimulatedReadingForCurrentPage() {
        stopSimulatedReading()
        startSimulatedReadingIfNeeded()
    }

    /// Slow and steady — a comfortable reading pace, not a race.
    static let simulatedWordInterval: TimeInterval = 0.42

    // MARK: - Live reading

    /// One real transcript delta, routed to the page on screen.
    ///
    /// This is the same `ingest` the simulated reader uses, so Live and Demo share one reading path
    /// and one matcher. **Live never fabricates progress**: if the microphone hears nothing, nothing
    /// fades.
    func ingestLiveDelta(_ delta: TranscriptDelta) {
        guard mode == .live, let question = currentQuestion else { return }
        ingest(delta, for: question)
    }

    // MARK: - Event application

    /// Adds a line, or replaces the one with the same identity.
    ///
    /// Speech recognition revises what it heard several times before settling. A revision must
    /// update the line it belongs to — appending would show the same sentence three times, each
    /// slightly different, which is what a naive transcript view looks like. Finalized lines are
    /// never rewritten by a later partial.
    private func upsert(_ line: TranscriptLine) {
        if let index = transcript.firstIndex(where: { $0.id == line.id }) {
            guard !transcript[index].isFinal || line.isFinal else { return }
            transcript[index] = line
        } else {
            transcript.append(line)
        }
        // A line that announced a question gains its link when the question arrives, so tapping it
        // opens the right page.
        if let questionID = line.questionID {
            for index in transcript.indices where transcript[index].questionID == nil
                && transcript[index].id == line.id {
                transcript[index].questionID = questionID
            }
        }
    }

    private func appendQuestion(_ question: InterviewQuestion) {
        // A question keeps one identity: if the feed re-announces it, nothing is duplicated.
        guard !questions.contains(where: { $0.id == question.id }) else { return }
        questions.append(question)
        if questions.count == 1 {
            currentIndex = 0
        }
    }

    private func startAnswer(requestID: UUID, questionID: UUID) {
        guard var generation = generations[requestID], generation.questionID == questionID,
              let index = questions.firstIndex(where: { $0.id == questionID }) else { return }
        var question = questions[index]
        let version = (question.answers.map(\.version).max() ?? 0) + 1
        let answer = InterviewAnswer(version: version)
        question.answers.append(answer)          // append-only: earlier versions are kept
        question.selectedAnswerID = answer.id
        questions[index] = question
        generation.answerID = answer.id
        generations[requestID] = generation
    }

    private func appendChunk(_ text: String, requestID: UUID) {
        guard let generation = generations[requestID], let answerID = generation.answerID,
              let index = questions.firstIndex(where: { $0.id == generation.questionID }) else { return }
        var question = questions[index]
        guard let answerIndex = question.answers.firstIndex(where: { $0.id == answerID }),
              !question.answers[answerIndex].isComplete else { return }
        var answer = question.answers[answerIndex]
        if case .prose(let existing)? = answer.blocks.last {
            answer.blocks[answer.blocks.count - 1] = .prose(existing.isEmpty ? text : existing + " " + text)
        } else {
            answer.blocks.append(.prose(text))
        }
        question.answers[answerIndex] = answer
        questions[index] = question
    }

    private func completeAnswer(requestID: UUID, blocks: [AnswerBlock], highlight: String?) {
        guard let generation = generations[requestID], let answerID = generation.answerID,
              let index = questions.firstIndex(where: { $0.id == generation.questionID }) else { return }
        var question = questions[index]
        guard let answerIndex = question.answers.firstIndex(where: { $0.id == answerID }) else { return }
        var answer = question.answers[answerIndex]
        answer.blocks = blocks                   // in the order the feed gave them: prose and code interleaved
        answer.highlight = highlight
        answer.isComplete = true
        question.answers[answerIndex] = answer
        questions[index] = question

        generations[requestID] = nil
        requestByQuestion[generation.questionID] = nil

        if index == currentIndex {
            restartSimulatedReadingForCurrentPage()
        } else {
            // Ready, but not shown: the page being read is never taken away.
            readyQuestionNumber = index + 1
        }
    }

    private func failAnswer(requestID: UUID, message: String) {
        guard let generation = generations[requestID] else { return }
        generations[requestID] = nil
        requestByQuestion[generation.questionID] = nil
        generationFailure = message
    }
}
