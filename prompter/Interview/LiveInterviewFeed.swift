import Foundation

/// The live interview, behind the same `InterviewFeed` the demo uses.
///
/// **It is an adapter, not a second pipeline.** Every hard part already exists and is reused as-is:
/// `InterviewAudioInput` owns the one microphone session, `ConversationLog` reconciles revisions into
/// stable turns, `DetectionPolicy` + the configured provider decide what is a question, retrieval and
/// provider routing live in `CopilotSessionCoordinator` and the backend. This type translates that
/// coordinator's state into `InterviewFeedEvent`s and translates `requestAnswer` back into a
/// generation — and does nothing else.
///
/// The coordinator runs in `.manual` mode here, so detecting a question never starts answering it.
@MainActor
final class LiveInterviewFeed: InterviewFeed {
    let events: AsyncStream<InterviewFeedEvent>
    private let continuation: AsyncStream<InterviewFeedEvent>.Continuation

    let coordinator: CopilotSessionCoordinator
    private(set) var isPaused = false

    /// Interface question id ⇄ pipeline card id. Two identity spaces, one mapping, so a card can
    /// never be duplicated as a second question and a late event can always be traced to its page.
    private var questionIDByCard: [QuestionCardID: UUID] = [:]
    private var cardIDByQuestion: [UUID: QuestionCardID] = [:]
    /// Which request each card's in-flight generation belongs to, so streamed text is tagged with the
    /// request the screen is waiting for.
    private var requestByCard: [QuestionCardID: UUID] = [:]
    /// The version each request is writing into, and how much of its text has already been emitted.
    private var versionByRequest: [UUID: AnswerVersionID] = [:]
    private var emittedLengthByRequest: [UUID: Int] = [:]
    /// Transcript utterances already announced, so a revision does not re-announce a line.
    private var emittedUtteranceRevisions: [UtteranceID: Int] = [:]
    private var emittedUtteranceOrder: [UtteranceID] = []
    /// Entries created by Generate rather than by detection.
    private var discussionQuestionIDByRequest: [UUID: UUID] = [:]

    /// Real transcript deltas, for the screen's own reading alignment.
    ///
    /// **One microphone, one capture session.** This chains onto the coordinator's existing delta
    /// handler rather than starting a second transcription: the pipeline sees every delta first (so
    /// detection is unaffected), then the screen sees the same delta for answer-following.
    var onDelta: ((TranscriptDelta) -> Void)?

    init(coordinator: CopilotSessionCoordinator) {
        self.coordinator = coordinator
        (events, continuation) = AsyncStream<InterviewFeedEvent>.makeStream(bufferingPolicy: .unbounded)

        let pipelineHandler = coordinator.audio.onDelta
        coordinator.audio.onDelta = { [weak self] delta in
            pipelineHandler?(delta)
            self?.onDelta?(delta)
        }

        coordinator.onCardAppended = { [weak self] card in self?.announce(card) }
        coordinator.onTranscriptChanged = { [weak self] in self?.emitTranscriptChanges() }
        coordinator.onVersionChanged = { [weak self] versionID, cardID in
            self?.emitAnswerChanges(versionID: versionID, cardID: cardID)
        }
    }

    deinit {
        continuation.finish()
    }

    // MARK: - Lifecycle

    func start() {
        coordinator.startListening()
    }

    /// The user's listening pause. It releases the microphone; it does not end the session, and it
    /// never touches an answer already on screen.
    func pause() {
        isPaused = true
        coordinator.audio.pauseListening()
    }

    func resume() {
        isPaused = false
        coordinator.audio.resumeListening()
    }

    /// There is no such thing as replaying a live interview.
    func restart() {}

    /// Playback speed is a demo idea; live speech arrives at the speed it is spoken.
    func setSpeed(_ multiplier: Double) {}

    /// Ends the session: capture stops, generations are cancelled, and anything arriving afterwards
    /// is rejected by the coordinator's own `.ended` guard.
    func end() {
        coordinator.endSession()
        continuation.finish()
    }

    // MARK: - Generation, only when asked

    func requestAnswer(requestID: UUID, question: InterviewQuestion, isRegeneration: Bool) {
        guard let cardID = cardIDByQuestion[question.id] else {
            continuation.yield(.answerFailed(
                requestID: requestID,
                message: "That question is no longer part of this session."
            ))
            return
        }
        requestByCard[cardID] = requestID
        emittedLengthByRequest[requestID] = 0
        continuation.yield(.answerStarted(requestID: requestID, questionID: question.id))

        // The coordinator snapshots the question text, the conversation window and the retrieved
        // passages at this moment — later transcript changes cannot retarget a request already sent.
        if isRegeneration {
            coordinator.regenerate(cardID: cardID)
        } else {
            coordinator.startGeneration(for: cardID)
        }

        guard let version = currentVersion(forCard: cardID) else {
            continuation.yield(.answerFailed(requestID: requestID, message: "Could not start generating."))
            requestByCard[cardID] = nil
            return
        }
        versionByRequest[requestID] = version.id
    }

    /// Answers the discussion, with no detected question required.
    ///
    /// **One request, not two.** It does not classify first and generate second: a failed or slow
    /// classification was the single most common reason Generate did nothing useful in a real room.
    /// The question the backend was given is reported back as the entry's label, so the entry says
    /// truthfully what it answered.
    func requestAnswerForDiscussion(requestID: UUID, discussion: DiscussionSnapshot, questionID: UUID) {
        requestByCard[requestID] = requestID       // keyed by request: this entry has no card
        emittedLengthByRequest[requestID] = 0
        continuation.yield(.answerStarted(requestID: requestID, questionID: questionID))

        let question = Self.questionFromDiscussion(discussion)
        continuation.yield(.answerTopicResolved(requestID: requestID, topic: question))
        discussionQuestionIDByRequest[requestID] = questionID

        // The conversation window is the **whole** snapshot — answered discussion included — so a
        // fragment or a correction still reaches the model with what it refers to. Only `question`
        // says what to answer.
        let card = coordinator.beginDiscussionAnswer(question: question, conversation: discussion.allLines)
        requestByCard[card.id] = requestID
        questionIDByCard[card.id] = questionID
        cardIDByQuestion[questionID] = card.id
        if let version = coordinator.cards.first(where: { $0.id == card.id })?.versions.last {
            versionByRequest[requestID] = version.id
        }
    }

    /// Reconstructs the question this tap is asking, from the new speech and the discussion behind it.
    ///
    /// **A transcript line is not a question.** Speech arrives in whatever pieces the recogniser
    /// finalizes, and three shapes have to survive that:
    ///
    /// - *Several questions at once.* "How do I remove duplicates in Java? And how do I preserve
    ///   insertion order?" is one request with two requirements; answering only the second would be
    ///   worse than useless, so every interrogative line in the new input travels together and the
    ///   prompt tells the model to answer all of them.
    /// - *A fragment.* "In Java", spoken after "could you tell me more about what's an Ash map and
    ///   how to make it", asks nothing on its own — and on its own is exactly how it reached the
    ///   model before, producing a standalone answer with an invented introduction. A short new
    ///   input that is not itself a question continues the line before it, across the answered/new
    ///   boundary if need be.
    /// - *A correction.* "Of France", after "is it better to invest in France or Indonesia", narrows
    ///   the question already asked rather than starting a new one. It takes the same path as a
    ///   fragment: it is carried back to the question it modifies, and the prompt's mis-transcription
    ///   rules let the model read it as the correction it is.
    ///
    /// **Only `newInput` can contribute a question.** Background is discussion an earlier request
    /// already answered; re-harvesting its interrogatives would make every tap re-answer the session.
    /// It is drawn on only to complete a fragment.
    ///
    /// Deliberately simple, local and free: it decides what to *ask about* inside the one streaming
    /// request, without a second sequential model call. No hardcoded phrases, no minimum-word gate —
    /// a short input is attached to its context, never discarded.
    static func questionFromDiscussion(_ discussion: DiscussionSnapshot) -> String {
        let clean = { (lines: [String]) in
            lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let background = clean(discussion.background)
        let newInput = clean(discussion.newInput)

        // Nothing new: the tap is about the discussion itself, so hand over its tail.
        guard !newInput.isEmpty else { return background.suffix(2).joined(separator: " ") }

        let questions = newInput.filter { DetectionPolicy.looksInterrogative($0) }

        // A lone short question ("And performance?") depends on what came before it.
        if questions.count == 1, let only = questions.first, Tokenizer.normalize(only).count <= 3 {
            return joinWithPrecedingLine(only, newInput: newInput, background: background)
        }
        if !questions.isEmpty { return questions.joined(separator: " ") }

        // No question mark and no interrogative opener anywhere in the new speech. If it is short it
        // is a fragment of, or a correction to, what came before; if it is substantial it stands on
        // its own — an imperative request ("walk me through your approach") looks like this too.
        let combined = newInput.joined(separator: " ")
        if Tokenizer.normalize(combined).count <= fragmentWordLimit {
            return joinWithPrecedingLine(newInput[newInput.count - 1], newInput: newInput, background: background)
        }
        return combined
    }

    /// The line before `line`, plus `line` — looking into the background when the new input has no
    /// earlier line of its own. That lookup is the point: the question a fragment continues has
    /// usually already been answered, which is precisely why it is no longer in the new input.
    private static func joinWithPrecedingLine(_ line: String, newInput: [String], background: [String]) -> String {
        if let index = newInput.firstIndex(of: line), index > 0 {
            return newInput[(index - 1)...index].joined(separator: " ")
        }
        guard let preceding = background.last else { return line }
        return "\(preceding) \(line)"
    }

    /// How short new speech has to be, in words, to be read as a fragment of the line before it
    /// rather than as a question in its own right. Generous enough for "in Java", "of France" or
    /// "actually, for Postgres"; short enough that a real short question is never swallowed.
    static let fragmentWordLimit = 5

    func cancelAnswer(requestID: UUID) {
        guard let versionID = versionByRequest[requestID] else { return }
        coordinator.cancelGeneration(versionID: versionID)
        versionByRequest[requestID] = nil
        emittedLengthByRequest[requestID] = nil
        requestByCard = requestByCard.filter { $0.value != requestID }
    }

    // MARK: - Translating the pipeline into interface events

    private func announce(_ card: QuestionCard) {
        let questionID = UUID()
        questionIDByCard[card.id] = questionID
        cardIDByQuestion[questionID] = card.id
        continuation.yield(.questionDetected(InterviewQuestion(id: questionID, text: card.questionText)))
    }

    /// Emits transcript lines for finalized turns, and replaces the in-progress line in place.
    ///
    /// A revision updates the line it belongs to rather than appending a second copy — that is what
    /// `ConversationLog`'s stable utterance identities are for.
    private func emitTranscriptChanges() {
        for utterance in coordinator.conversation.utterances {
            let known = emittedUtteranceRevisions[utterance.id]
            guard known != utterance.revision else { continue }
            emittedUtteranceRevisions[utterance.id] = utterance.revision
            if known == nil { emittedUtteranceOrder.append(utterance.id) }
            continuation.yield(.transcriptLine(TranscriptLine(
                id: utterance.id,
                text: utterance.text,
                isDetectedQuestion: isDetectedQuestion(utterance.id),
                questionID: questionID(forUtterance: utterance.id),
                isFinal: true
            )))
        }

        if let open = coordinator.conversation.openUtterance {
            let known = emittedUtteranceRevisions[open.id]
            guard known != open.revision else { return }
            emittedUtteranceRevisions[open.id] = open.revision
            continuation.yield(.transcriptLine(TranscriptLine(
                id: open.id,
                text: open.text,
                isDetectedQuestion: false,
                questionID: nil,
                isFinal: false
            )))
        }
    }

    private func isDetectedQuestion(_ utteranceID: UtteranceID) -> Bool {
        coordinator.cards.contains { $0.sourceUtteranceIDs.contains(utteranceID) }
    }

    private func questionID(forUtterance utteranceID: UtteranceID) -> UUID? {
        guard let card = coordinator.cards.first(where: { $0.sourceUtteranceIDs.contains(utteranceID) }) else {
            return nil
        }
        return questionIDByCard[card.id]
    }

    /// Streams the *newly added* text of a version, so the screen appends rather than redraws. The
    /// answer the user may already be reading is never rewritten beneath them.
    private func emitAnswerChanges(versionID: AnswerVersionID, cardID: QuestionCardID) {
        guard let requestID = requestByCard[cardID] else { return }
        guard versionByRequest[requestID] == nil || versionByRequest[requestID] == versionID else {
            return          // a superseded version: not what this request is waiting for
        }
        versionByRequest[requestID] = versionID
        guard let card = coordinator.cards.first(where: { $0.id == cardID }),
              let version = card.versions.first(where: { $0.id == versionID }) else { return }

        let visible = version.committedText
        let alreadyEmitted = emittedLengthByRequest[requestID] ?? 0
        if visible.count > alreadyEmitted {
            let start = visible.index(visible.startIndex, offsetBy: alreadyEmitted)
            let addition = String(visible[start...])
            emittedLengthByRequest[requestID] = visible.count
            if !addition.isEmpty {
                continuation.yield(.answerChunk(requestID: requestID, text: addition))
            }
        }

        switch version.status {
        case .streaming, .queued:
            break
        case .complete:
            continuation.yield(.answerCompleted(
                requestID: requestID,
                blocks: AnswerBlock.parsed(from: visible),
                highlight: nil
            ))
            finish(requestID: requestID, cardID: cardID)
        case .failed(let message):
            // Whatever arrived stays on screen; the message says what stopped.
            continuation.yield(.answerFailed(requestID: requestID, message: message))
            finish(requestID: requestID, cardID: cardID)
        case .cancelled, .superseded:
            // The user cancelled, or a newer version replaced this one. Either way the screen is no
            // longer waiting for it, and whatever text arrived stays where it is.
            finish(requestID: requestID, cardID: cardID)
        }
    }

    private func finish(requestID: UUID, cardID: QuestionCardID) {
        requestByCard[cardID] = nil
        versionByRequest[requestID] = nil
        emittedLengthByRequest[requestID] = nil
    }

    #if DEBUG
    /// Registers the interface⇄pipeline mapping directly.
    ///
    /// The mapping is normally created when a card is announced through the event stream. A test
    /// that drives the coordinator synchronously has the card before it has consumed the stream, so
    /// this lets it address that card without racing delivery. Debug-only, and it creates no state
    /// the production path does not create for itself.
    func registerForTesting(questionID: UUID, cardID: QuestionCardID) {
        questionIDByCard[cardID] = questionID
        cardIDByQuestion[questionID] = cardID
    }
    #endif

    private func currentVersion(forCard cardID: QuestionCardID) -> AnswerVersion? {
        coordinator.cards.first(where: { $0.id == cardID })?.versions.last
    }
}
