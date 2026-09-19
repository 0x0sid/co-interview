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
    func requestAnswerForDiscussion(requestID: UUID, transcript: [String], questionID: UUID) {
        requestByCard[requestID] = requestID       // keyed by request: this entry has no card
        emittedLengthByRequest[requestID] = 0
        continuation.yield(.answerStarted(requestID: requestID, questionID: questionID))

        let question = Self.questionFromDiscussion(transcript)
        continuation.yield(.answerTopicResolved(requestID: requestID, topic: question))
        discussionQuestionIDByRequest[requestID] = questionID

        let card = coordinator.beginDiscussionAnswer(question: question, conversation: transcript)
        requestByCard[card.id] = requestID
        questionIDByCard[card.id] = questionID
        cardIDByQuestion[questionID] = card.id
        if let version = coordinator.cards.first(where: { $0.id == card.id })?.versions.last {
            versionByRequest[requestID] = version.id
        }
    }

    /// The last thing that looks like a question, or the latest discussion if none does.
    ///
    /// Deliberately simple and local: it decides what to *ask about*, and the model decides what to
    /// say. When nothing is interrogative it hands over the recent discussion and lets the answer
    /// respond to that, rather than inventing a question that was never asked.
    static func questionFromDiscussion(_ transcript: [String]) -> String {
        let lines = transcript.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let interrogative = lines.reversed().first(where: { DetectionPolicy.looksInterrogative($0) }) {
            return interrogative
        }
        return lines.suffix(2).joined(separator: " ")
    }

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
