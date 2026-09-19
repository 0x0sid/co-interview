import Foundation
import Observation

/// Orchestrates one interview: continuous listening, question detection, document-grounded generation,
/// and the cards the user reads from.
///
/// It is the only place that knows about all five lifecycles, and it keeps them separate:
///
/// | Lifecycle | Owner | Stopped by |
/// |---|---|---|
/// | Capture | `InterviewAudioInput` | listening pause, session end, interruption, failure |
/// | Transcript reconciliation | `ConversationLog` | nothing — it is pure state |
/// | Question detection | `detectionTask` | its own cancellation |
/// | Generation | `generationTasks` | cancel, supersede, session end |
/// | Active answer reading | `ReadingAlignment` per card/segment | reading pause, navigation |
///
/// **Cancelling generation never touches capture** (§8), and a provider failure leaves every existing
/// answer readable and the transcript pipeline running.
@MainActor
@Observable
final class CopilotSessionCoordinator {
    // MARK: Session

    let sessionID: InterviewSessionID
    private(set) var state: CopilotSessionState = .active
    private(set) var cards: [QuestionCard] = []
    /// Index into `cards`. **New cards never change this** (§7).
    private(set) var selectedCardIndex: Int = 0
    private(set) var conversation: ConversationLog
    private(set) var lastProviderError: String?
    /// The backend's most recent informational notice, such as attachments not being sent.
    private(set) var lastProviderNotice: String?
    private(set) var isClassifying = false
    /// Diagnostics for the pipeline report: events that arrived too late to matter.
    private(set) var droppedStaleEventCount = 0
    private(set) var measurements: [PipelineMeasurement] = []

    let project: any ProjectContextProviding
    let audio: InterviewAudioInput
    private let provider: any CopilotProviding
    private let policy: DetectionPolicy
    private let clock: @Sendable () -> Date

    /// Whether detecting a question also starts answering it.
    ///
    /// The diagnostic screen has always answered automatically, and still does. The v2.5 interview
    /// screen must not: there, **detection and generation are separate actions** and an answer is
    /// written only when someone taps Generate. This is a policy switch, not a second pipeline —
    /// detection, retrieval, routing and streaming are identical either way.
    enum GenerationMode: Sendable {
        case automatic
        case manual
    }
    let generationMode: GenerationMode

    /// Observation hooks, in the same idiom `InterviewAudioInput` already uses for `onDelta`.
    /// They exist so `LiveInterviewFeed` can translate this coordinator into `InterviewFeedEvent`s
    /// without polling and without owning any pipeline state of its own.
    var onCardAppended: ((QuestionCard) -> Void)?
    var onTranscriptChanged: (() -> Void)?
    /// Fired whenever a version's text, status or route changed.
    var onVersionChanged: ((AnswerVersionID, QuestionCardID) -> Void)?

    var providerIsDevelopmentFake: Bool { provider.isDevelopmentFake }
    var answerModelLabel: String { provider.answerModelLabel }

    // MARK: Detection state

    /// Transcript-clock time already consumed by detection.
    private var detectionCutoff: TimeInterval = 0
    private var lastPendingText = ""
    private var lastPendingChangeTime: TimeInterval = 0
    private var lastClassificationTime: TimeInterval?
    private var lastClassifiedText: String?
    private var detectionTask: Task<Void, Never>?
    /// Retrieval started before detection finished, keyed by the text it was started for (§4).
    private var prefetchedPassages: (text: String, passages: [ProjectPassage])?
    /// Utterance sets already turned into cards, so a repeated or revised event cannot duplicate one.
    private var consumedUtteranceIDs: Set<UtteranceID> = []
    /// The turn (or extended turns) handed to the current classification.
    private var pendingClassificationGroup: [Utterance] = []
    /// Where the cut-off moves to once that classification returns.
    private var pendingCutoffCandidate: TimeInterval = 0
    /// How many extra turns to include after an `.incomplete` verdict, so a question split by a pause
    /// is assembled rather than re-asked forever. Bounded: an unfinished thought cannot widen the
    /// window indefinitely.
    private var turnExtension = 0
    private static let maximumTurnExtension = 3

    // MARK: Generation state

    /// Small on purpose: a rapid exchange must not fan out into an unbounded backlog (§8).
    let maximumConcurrentGenerations = 2
    private var generationTasks: [AnswerVersionID: Task<Void, Never>] = [:]
    private var generationQueue: [AnswerVersionID] = []

    // MARK: Reading state

    /// One alignment per card, version and frozen segment, kept alive so returning to a card restores
    /// exactly where the reader was.
    private var alignments: [String: ReadingAlignment] = [:]
    private var activeAlignmentKey: String?

    init(
        project: any ProjectContextProviding,
        provider: any CopilotProviding,
        audio: InterviewAudioInput,
        policy: DetectionPolicy = DetectionPolicy(),
        generationMode: GenerationMode = .automatic,
        sessionID: InterviewSessionID = UUID(),
        conversation: ConversationLog = ConversationLog(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.project = project
        self.provider = provider
        self.audio = audio
        self.policy = policy
        self.generationMode = generationMode
        self.sessionID = sessionID
        self.conversation = conversation
        self.clock = clock

        audio.onDelta = { [weak self] delta in self?.ingest(delta) }
        audio.onSilenceTick = { [weak self] now in self?.tick(now: now) }
    }

    // MARK: - Session lifecycle

    func startListening() {
        guard state == .active else { return }
        audio.start(language: project.language, contextualStrings: projectVocabulary())
    }

    /// Ends the session. Everything later is rejected — a late provider response can never reopen it (§8).
    func endSession() {
        state = .ended
        detectionTask?.cancel()
        detectionTask = nil
        for task in generationTasks.values { task.cancel() }
        generationTasks.removeAll()
        generationQueue.removeAll()
        audio.stop()
    }

    /// Distinctive project vocabulary biases recognition toward the terms this interview will use.
    private func projectVocabulary() -> [String] {
        guard let synthetic = project as? SyntheticProject else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for passage in synthetic.allPassages {
            for word in Tokenizer.normalize(passage.text) where word.count > 4 {
                guard !MatcherConfig.default.commonWords.contains(word), seen.insert(word).inserted else { continue }
                result.append(word)
                if result.count >= 100 { return result }
            }
        }
        return result
    }

    // MARK: - Transcript intake

    /// One transcript delta. This is the only entry point for interview speech.
    func ingest(_ delta: TranscriptDelta) {
        guard state == .active else { return }

        // 1. Reading first, so the utterance can be tagged with whether the reader confirmed those
        //    words against the answer being read. This is text evidence, never speaker identification.
        var overlapsReading = false
        if let alignment = activeAlignment(), !(selectedCard?.isFollowingPaused ?? true) {
            let outcome = alignment.ingest(delta)
            overlapsReading = outcome.newlySpokenCount > 0 || (outcome.didAdvance && outcome.cursorMoved)
        }

        // 2. Conversation log: stable identities, dedupe, bounded window.
        guard let (_, didFinalize) = conversation.ingest(delta, overlapsReading: overlapsReading) else { return }
        onTranscriptChanged?()

        // 3. Detection policy.
        let pendingText = conversation.pendingText(after: detectionCutoff)
        if pendingText != lastPendingText {
            lastPendingText = pendingText
            lastPendingChangeTime = delta.timestamp
        }
        evaluateDetection(now: delta.timestamp, didFinalize: didFinalize)
    }

    /// Silence tick from the audio layer, in the transcript's own clock.
    func tick(now: TimeInterval) {
        guard state == .active else { return }
        if let alignment = activeAlignment(), !(selectedCard?.isFollowingPaused ?? true) {
            alignment.tick(now: now)
        }
        evaluateDetection(now: now, didFinalize: false)
    }

    private func evaluateDetection(now: TimeInterval, didFinalize: Bool, manual: Bool = false, isDrain: Bool = false) {
        // **One turn at a time.** Everything unconsumed used to be classified as a single block, so two
        // questions that finalized back to back became one card and the second was swallowed by the
        // cut-off. `turnExtension` widens the window only when the detector said the question was
        // unfinished, so a question spoken across a pause still assembles.
        skipUnclassifiableHeadTurns(now: now)
        let turns = conversation.pendingTurns(after: detectionCutoff, gapSeconds: policy.turnGapSeconds)
        let group = Array(turns.prefix(1 + turnExtension).joined())
        let hasBacklog = turns.count > (1 + turnExtension)

        let pending: String
        if group.isEmpty {
            // Nothing finalized yet: the in-flight tail is all there is (the stable-pause trigger).
            pending = conversation.pendingText(after: detectionCutoff)
            // **The open utterance is the group.** Classifying with an empty group meant `apply`
            // discarded a `new_question` verdict for want of anything to mark consumed — while
            // `lastClassifiedText` was recorded anyway, so the same words could never be classified
            // again once they finalized. A question detected from still-volatile speech was lost for
            // good. The open utterance already has the stable identity this needs, and keeping that
            // identity is what stops finalization producing a second card for the same speech.
            pendingClassificationGroup = conversation.openUtterance.map { [$0] } ?? []
        } else {
            pending = group.map(\.text).joined(separator: " ")
            pendingClassificationGroup = group
        }
        let allOverlap = !group.isEmpty && group.allSatisfy(\.overlapsReading)

        // A turn counts as closed — the same stable signal a freshly finalized utterance gives — when
        // speech has moved on past it: either more turns are already waiting behind it, or enough
        // silence has followed it. Without this, draining a backlog after a slow classification had no
        // trigger of its own and stalled until the next delta happened to arrive, which is how
        // questions went missing when several finalized while one classification was in flight.
        // A drained turn made entirely of finalized utterances is closed by definition: the speech is
        // complete, and anything said later is separated by at least the turn gap, so it would form a
        // new turn rather than extend this one. Without this, a question that arrived while an earlier
        // classification was in flight waited for a silence tick that may never come — which is how a
        // rapid second question went unanswered.
        let turnIsClosed = !group.isEmpty
            && (didFinalize
                || hasBacklog
                || (isDrain && group.allSatisfy(\.isFinal))
                || now - (group.last?.endTime ?? now) >= policy.turnGapSeconds)

        #if DEBUG
        if CopilotTrace.isEnabled {
            print("TRACE eval now=\(String(format: "%.2f", now)) cutoff=\(String(format: "%.2f", detectionCutoff)) turns=\(turns.count) group=\(group.count) backlog=\(hasBacklog) closed=\(turnIsClosed) classifying=\(isClassifying) text=\"\(pending.prefix(40))\"")
        }
        #endif
        let decision = policy.decide(.init(
            pendingText: pending,
            didFinalize: didFinalize || turnIsClosed,
            now: now,
            lastChangeTime: lastPendingChangeTime,
            lastClassificationTime: lastClassificationTime,
            lastClassifiedText: lastClassifiedText,
            isClassificationInFlight: isClassifying,
            allPendingOverlapsReading: allOverlap,
            isManualRequest: manual,
            hasUnclassifiedBacklog: hasBacklog
        ))

        // Retrieval is local and produces nothing visible, so starting it on a maybe costs nothing and
        // removes it from the critical path once a question is confirmed (§4).
        if decision.shouldStartRetrieval, prefetchedPassages?.text != decision.text {
            prefetchedPassages = (decision.text, project.passages(forQuestion: decision.text, limit: 3))
        }

        #if DEBUG
        if CopilotTrace.isEnabled {
            print("TRACE   -> classify=\(decision.shouldClassify) trigger=\(String(describing: decision.trigger))")
        }
        #endif
        guard decision.shouldClassify, let trigger = decision.trigger else { return }
        classify(text: decision.text, trigger: trigger, transcriptNow: now)
    }

    /// Drops turns at the head of the queue that the policy can never classify, once they are closed.
    ///
    /// **Detection is a queue, and an unclassifiable turn at its head blocks everything behind it.**
    /// Two kinds do this, and both were found by tracing a replay where questions simply stopped
    /// appearing:
    ///
    /// - *Too short.* A backchannel — "Right. Understood." — never reaches `minimumNewWords`, so it is
    ///   never classified, so the cut-off never moves past it, so no later question is ever examined.
    /// - *Entirely the user reading.* Speech the reader confirmed against the answer being read is
    ///   deliberately not a question signal, so it is never classified either — and would block the
    ///   queue in exactly the same way.
    ///
    /// A turn is only skipped once speech has moved on past it (another turn is waiting, or the turn
    /// gap has elapsed), so the opening words of a question still being spoken are never discarded.
    /// Skipped speech stays in the conversation log and is still sent as context; it simply does not
    /// get a classification of its own.
    private func skipUnclassifiableHeadTurns(now: TimeInterval) {
        while true {
            let turns = conversation.pendingTurns(after: detectionCutoff, gapSeconds: policy.turnGapSeconds)
            guard let head = turns.first, let last = head.last else { return }
            let isClosed = turns.count > 1 || now - last.endTime >= policy.turnGapSeconds
            guard isClosed else { return }

            let headText = head.map(\.text).joined(separator: " ")
            let wordCount = Tokenizer.normalize(headText).count
            // Short *and* not shaped like a question. "Why?" stays in the queue; "Right. Understood."
            // does not.
            let isTooShort = wordCount < policy.minimumNewWords && !DetectionPolicy.looksInterrogative(headText)
            let isEntirelyReading = head.allSatisfy(\.overlapsReading)
            // *Already classified.* A turn whose utterances have all been consumed has had its
            // decision; `apply` would reject a second card for them anyway. Left at the head it can
            // only block everything behind it — which is what happened once a question detected from
            // still-volatile speech finalized: the finalized copy sat at the head of the queue and no
            // later question was ever examined again.
            let isAlreadyClassified = head.allSatisfy { consumedUtteranceIDs.contains($0.id) }
            guard isTooShort || isEntirelyReading || isAlreadyClassified else { return }

            detectionCutoff = max(detectionCutoff, last.endTime)
            head.forEach { consumedUtteranceIDs.insert($0.id) }
            turnExtension = 0
        }
    }

    // MARK: - Detection

    private func classify(text: String, trigger: DetectionPolicy.Trigger, transcriptNow: TimeInterval) {
        isClassifying = true
        lastClassificationTime = transcriptNow
        lastClassifiedText = text
        // Consume exactly the utterances that were classified — not "everything up to now", which is
        // what allowed a second question to disappear.
        let classifiedGroup = pendingClassificationGroup
        let consumed = classifiedGroup.map(\.id)
        pendingCutoffCandidate = classifiedGroup.last?.endTime ?? transcriptNow
        let requestedAt = clock()

        let request = ClassificationRequest(
            newSpeech: text,
            recentConversation: conversation.recentContext().map(\.text),
            activeAnswerText: activeAlignment()?.text,
            knownQuestions: cards.suffix(3).map { .init(id: $0.id.uuidString, text: $0.questionText) },
            language: project.language.bcp47
        )

        let provider = self.provider
        detectionTask?.cancel()
        detectionTask = Task { [weak self] in
            do {
                let result = try await provider.classify(request)
                guard let self, self.state == .active else { return }
                // Cleared **synchronously on the main actor**, before anything else runs: if this were
                // deferred to a later hop, the next utterance could arrive while the gate still said
                // "in flight" and its classification would be skipped with nothing scheduled to retry
                // it. (Found by `aDistinctQuestionIsNeverDiscardedWhenBusy`.)
                self.isClassifying = false
                self.apply(result, consumedUtteranceIDs: consumed, text: text, trigger: trigger,
                           transcriptNow: transcriptNow, requestedAt: requestedAt)
                // Speech that arrived *while* this classification was in flight has not been
                // considered yet, and no further delta may be coming. Re-evaluate now so a question
                // asked during a slow classification is never stranded.
                self.evaluateDetection(
                    now: max(transcriptNow, self.conversation.lastActivityTime),
                    didFinalize: false,
                    isDrain: true
                )
            } catch is CancellationError {
                await MainActor.run { self?.isClassifying = false }
            } catch {
                guard let self else { return }
                self.isClassifying = false
                // A detection failure must never stop listening. It is surfaced, and the next stable
                // update tries again.
                self.lastProviderError = (error as? CopilotProviderError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func apply(
        _ result: DetectionResult,
        consumedUtteranceIDs consumed: [UtteranceID],
        text: String,
        trigger: DetectionPolicy.Trigger,
        transcriptNow: TimeInterval,
        requestedAt: Date
    ) {
        let detectionLatency = clock().timeIntervalSince(requestedAt)
        #if DEBUG
        if CopilotTrace.isEnabled {
            print("TRACE apply kind=\(result.kind.rawValue) consumed=\(consumed.count) cutoffCandidate=\(String(format: "%.2f", pendingCutoffCandidate)) cards=\(cards.count)")
        }
        #endif

        switch result.kind {
        case .none:
            // Considered and not a question. Do not reconsider it.
            detectionCutoff = max(detectionCutoff, pendingCutoffCandidate)
            turnExtension = 0
            consumed.forEach { self.consumedUtteranceIDs.insert($0) }

        case .incomplete:
            // Leave the cut-off alone: the rest of the question is still coming, and the detector needs
            // the beginning of it when it arrives. Widen the window by one turn so speech that follows
            // a pause is offered together with it.
            turnExtension = min(turnExtension + 1, Self.maximumTurnExtension)

        case .newQuestion:
            guard !consumed.isEmpty || trigger == .manual else { return }
            // Idempotence: the same utterances can never produce a second card.
            guard !consumed.allSatisfy(self.consumedUtteranceIDs.contains) || trigger == .manual else { return }
            detectionCutoff = max(detectionCutoff, pendingCutoffCandidate)
            turnExtension = 0
            consumed.forEach { self.consumedUtteranceIDs.insert($0) }
            let card = appendCard(
                questionText: result.questionText.isEmpty ? text : result.questionText,
                origin: trigger == .manual ? .manual : .detected,
                utteranceIDs: consumed
            )
            // Manual mode stops here: the question exists, and answering it is the user's move.
            if generationMode == .automatic {
                startGeneration(for: card.id, detectionLatency: detectionLatency, questionEndTranscriptTime: transcriptNow)
            }

        case .continuation:
            detectionCutoff = max(detectionCutoff, pendingCutoffCandidate)
            turnExtension = 0
            consumed.forEach { self.consumedUtteranceIDs.insert($0) }
            guard let cardID = result.relatedCardID, let index = cards.firstIndex(where: { $0.id == cardID }) else {
                // The detector pointed at a card we do not have; treat it as a new question rather than
                // dropping a distinct question on the floor (§8).
                let card = appendCard(questionText: result.questionText.isEmpty ? text : result.questionText,
                                      origin: .detected, utteranceIDs: consumed)
                if generationMode == .automatic {
                    startGeneration(for: card.id, detectionLatency: detectionLatency, questionEndTranscriptTime: transcriptNow)
                }
                return
            }
            if !result.questionText.isEmpty {
                cards[index].questionText = result.questionText
            }
            // A correction supersedes the in-flight version for that card instead of queueing a second
            // answer to the same question. In manual mode there is nothing in flight to supersede
            // unless the user asked for one, and a corrected question is never silently re-answered.
            if generationMode == .automatic {
                supersedeInFlightVersion(cardID: cardID)
                startGeneration(for: cardID, detectionLatency: detectionLatency, questionEndTranscriptTime: transcriptNow)
            } else {
                onVersionChanged?(UUID(), cardID)     // the question text changed; the page should redraw
            }
        }
    }

    // MARK: - Cards

    @discardableResult
    private func appendCard(questionText: String, origin: QuestionCard.Origin, utteranceIDs: [UtteranceID]) -> QuestionCard {
        let card = QuestionCard(
            id: UUID(),
            sequence: cards.count + 1,
            questionText: questionText,
            origin: origin,
            sourceUtteranceIDs: utteranceIDs,
            createdAt: clock()
        )
        cards.append(card)
        // Focus is deliberately untouched: a new question must never pull the reader off the answer
        // they are in the middle of (§7).
        onCardAppended?(card)
        return card
    }

    /// The user asked for an answer to speech detection did not pick up (§4).
    func answerLastSpeech() {
        guard state == .active else { return }
        let text = conversation.pendingText(after: detectionCutoff).isEmpty
            ? conversation.recentContext(maximumUtterances: 1).map(\.text).joined()
            : conversation.pendingText(after: detectionCutoff)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        evaluateDetection(now: conversation.lastActivityTime, didFinalize: true, manual: true)
    }

    /// Creates an entry for a question derived from the discussion and starts answering it.
    ///
    /// This is the manual path: it exists so Generate never depends on detection having succeeded.
    /// The conversation snapshot is supplied by the caller and used as-is, so the request answers
    /// what was on screen when the user tapped, not whatever has been said since.
    @discardableResult
    func beginDiscussionAnswer(question: String, conversation snapshot: [String]) -> QuestionCard {
        let card = appendCard(questionText: question, origin: .manual, utteranceIDs: [])
        startGeneration(for: card.id, conversationOverride: snapshot)
        return card
    }

    /// A typed question — works with no audio at all.
    func askTyped(_ question: String) {
        guard state == .active else { return }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let card = appendCard(questionText: trimmed, origin: .typed, utteranceIDs: [])
        if generationMode == .automatic {
            startGeneration(for: card.id, detectionLatency: 0, questionEndTranscriptTime: conversation.lastActivityTime)
        }
    }

    func select(cardIndex: Int) {
        guard cards.indices.contains(cardIndex) else { return }
        selectedCardIndex = cardIndex
        activeAlignmentKey = nil          // recomputed lazily; stored alignments keep their state
    }

    func selectLatestCard() {
        guard !cards.isEmpty else { return }
        select(cardIndex: cards.count - 1)
    }

    var selectedCard: QuestionCard? {
        cards.indices.contains(selectedCardIndex) ? cards[selectedCardIndex] : nil
    }

    var hasNewerCardThanSelected: Bool {
        !cards.isEmpty && selectedCardIndex < cards.count - 1
    }

    // MARK: - Generation

    /// Creates a new version for a card and starts or queues it.
    func startGeneration(
        for cardID: QuestionCardID,
        detectionLatency: TimeInterval = 0,
        questionEndTranscriptTime: TimeInterval = 0,
        conversationOverride: [String]? = nil
    ) {
        guard state == .active, let index = cards.firstIndex(where: { $0.id == cardID }) else { return }

        let retrievalStart = clock()
        let question = cards[index].questionText
        let passages: [ProjectPassage]
        if let prefetched = prefetchedPassages, !prefetched.passages.isEmpty,
           Self.isRelated(prefetched.text, question) {
            passages = prefetched.passages
        } else {
            passages = project.passages(forQuestion: question, limit: 3)
        }
        let retrievalSeconds = clock().timeIntervalSince(retrievalStart)

        let version = AnswerVersion(
            id: UUID(),
            cardID: cardID,
            number: (cards[index].versions.last?.number ?? 0) + 1,
            status: .queued,
            modelLabel: provider.answerModelLabel,
            isDevelopmentFake: provider.isDevelopmentFake,
            createdAt: clock()
        )
        cards[index].versions.append(version)
        if cards[index].selectedVersionID == nil {
            cards[index].selectedVersionID = version.id
        }

        measurements.append(PipelineMeasurement(
            versionID: version.id,
            cardID: cardID,
            questionEndTranscriptTime: questionEndTranscriptTime,
            detectionSeconds: detectionLatency,
            retrievalSeconds: retrievalSeconds,
            requestedAt: clock()
        ))

        let request = AnswerRequest(
            question: question,
            projectInstructions: project.instructions,
            // Snapshotted here, with the question and the retrieved passages: what the request
            // carries is what the note said **at the moment Generate was pressed**. Editing the
            // note afterwards cannot change an answer already being written.
            extraContext: sessionNote,
            images: sessionImages,
            // The caller's snapshot when there is one, so a queued request still answers the
            // discussion it was created for rather than the newest speech.
            recentConversation: conversationOverride ?? conversation.recentContext(maximumUtterances: 6).map(\.text),
            passages: passages.map {
                .init(id: $0.id, documentTitle: $0.documentTitle, documentVersion: $0.documentVersion,
                      locator: $0.locator, text: $0.text)
            },
            language: project.language.bcp47,
            targetWordRange: [Self.targetMinimumWords, Self.targetMaximumWords],
            projectID: project.projectID
        )

        generationQueue.append(version.id)
        pumpQueue(request: request, versionID: version.id, passages: passages)
    }

    /// A note the user typed for this session, included as reference material in every answer
    /// request. Set by the screen; empty by default.
    var sessionNote: String = ""

    /// Prepared image attachments for this session, snapshotted into each request alongside the
    /// note. Empty unless the backend reports the answer model accepts images.
    var sessionImages: [AnswerRequest.ImageAttachment] = []

    /// Default answer length. A tunable prototype setting (§6), not a product rule.
    static let targetMinimumWords = 60
    static let targetMaximumWords = 120

    private var pendingRequests: [AnswerVersionID: (AnswerRequest, [ProjectPassage])] = [:]

    private func pumpQueue(request: AnswerRequest? = nil, versionID: AnswerVersionID? = nil, passages: [ProjectPassage] = []) {
        if let request, let versionID {
            pendingRequests[versionID] = (request, passages)
        }
        while generationTasks.count < maximumConcurrentGenerations, !generationQueue.isEmpty {
            let next = generationQueue.removeFirst()
            guard let (nextRequest, nextPassages) = pendingRequests.removeValue(forKey: next) else { continue }
            guard let location = locate(versionID: next), cards[location.card].versions[location.version].status == .queued else { continue }
            run(versionID: next, request: nextRequest, passages: nextPassages)
        }
    }

    private func run(versionID: AnswerVersionID, request: AnswerRequest, passages: [ProjectPassage]) {
        guard let location = locate(versionID: versionID) else { return }
        cards[location.card].versions[location.version].status = .streaming

        let stream = provider.generate(request)
        generationTasks[versionID] = Task { [weak self] in
            var assembler = StreamingAnswerAssembler()
            var citedIDs: [String] = []
            do {
                for try await event in stream {
                    guard let self, self.state == .active else { break }
                    switch event {
                    case .delta(let text):
                        let didCommit = assembler.append(text)
                        self.applyStreamUpdate(versionID: versionID, assembler: assembler, didCommit: didCommit)
                    case .route(let route):
                        // What actually served this version. Recorded on the version so a card can
                        // show it and a benchmark can attribute a measurement to a real route.
                        self.recordRoute(route, versionID: versionID)
                    case .attemptFailed(let detail, let fallingBackTo):
                        // The backend is retrying on the fallback route; nothing visible has been
                        // shown yet, so there is nothing for the reader to lose.
                        self.lastProviderError = "\(detail) — trying \(fallingBackTo)"
                    case .notice(let message):
                        // Shown to the user; it is information, not a failure. The answer continues.
                        lastProviderNotice = message
                    case .sources(let ids):
                        citedIDs = ids
                    case .incomplete(let reason):
                        // Text already shown stays readable; the version is marked incomplete and the
                        // card offers Retry, which creates a **new** version rather than replacing it.
                        assembler.finish()
                        self.applyStreamUpdate(versionID: versionID, assembler: assembler, didCommit: true)
                        self.markIncomplete(versionID: versionID, reason: reason, citedIDs: citedIDs, passages: passages)
                    case .completed:
                        assembler.finish()
                        self.applyStreamUpdate(versionID: versionID, assembler: assembler, didCommit: true)
                        self.complete(versionID: versionID, citedIDs: citedIDs, passages: passages)
                    }
                }
                if let self, self.state == .active, !assembler.committedText.isEmpty,
                   self.statusOf(versionID) == .streaming {
                    assembler.finish()
                    self.applyStreamUpdate(versionID: versionID, assembler: assembler, didCommit: true)
                    self.complete(versionID: versionID, citedIDs: citedIDs, passages: passages)
                }
            } catch {
                self?.fail(versionID: versionID, error: error)
            }
            self?.finishTask(versionID: versionID)
        }
    }

    /// Applies streamed text. **A stale or out-of-order event can only ever reach the version that
    /// requested it**, and only while that version is still streaming (§8).
    private func applyStreamUpdate(versionID: AnswerVersionID, assembler: StreamingAnswerAssembler, didCommit: Bool) {
        guard state == .active, let location = locate(versionID: versionID) else {
            droppedStaleEventCount += 1
            return
        }
        guard cards[location.card].versions[location.version].status == .streaming else {
            droppedStaleEventCount += 1
            return
        }
        var version = cards[location.card].versions[location.version]
        if version.firstDeltaAt == nil {
            version.firstDeltaAt = clock()
            recordMeasurement(versionID: versionID) { $0.firstDeltaAt = self.clock() }
        }
        version.committedText = assembler.committedText
        version.pendingText = assembler.pendingText
        if didCommit, version.firstSentenceAt == nil, !assembler.committedText.isEmpty {
            version.firstSentenceAt = clock()
            recordMeasurement(versionID: versionID) { $0.firstSentenceAt = self.clock() }
        }
        cards[location.card].versions[location.version] = version
        onVersionChanged?(versionID, cards[location.card].id)
    }

    private func complete(versionID: AnswerVersionID, citedIDs: [String], passages: [ProjectPassage]) {
        guard let location = locate(versionID: versionID),
              cards[location.card].versions[location.version].status == .streaming else {
            droppedStaleEventCount += 1
            return
        }
        var version = cards[location.card].versions[location.version]
        version.status = .complete
        version.completedAt = clock()
        // Only ids the model was actually given can become sources. An unknown id is dropped rather
        // than shown, so a citation can never point at something that was not sent.
        let byID = Dictionary(uniqueKeysWithValues: passages.map { ($0.id, $0) })
        version.sources = citedIDs.compactMap { id in
            guard let passage = byID[id] else { return nil }
            return SourceReference(
                id: passage.id,
                documentTitle: passage.documentTitle,
                documentVersion: passage.documentVersion,
                locator: passage.locator,
                excerpt: String(passage.text.prefix(200))
            )
        }
        // Everything not yet frozen for reading becomes the next readable segment.
        version.readableSegments = Self.segments(for: version)
        cards[location.card].versions[location.version] = version
        recordMeasurement(versionID: versionID) { $0.completedAt = self.clock() }
        onVersionChanged?(versionID, cards[location.card].id)
    }

    private func recordRoute(_ route: AnswerRoute, versionID: AnswerVersionID) {
        guard let location = locate(versionID: versionID) else { return }
        cards[location.card].versions[location.version].route = route
    }

    /// Generation stopped after text was already visible. The text stays exactly as it is — the
    /// reader may be part-way through it — and the card is marked incomplete so Retry is offered.
    private func markIncomplete(versionID: AnswerVersionID, reason: String, citedIDs: [String], passages: [ProjectPassage]) {
        guard let location = locate(versionID: versionID) else { return }
        var version = cards[location.card].versions[location.version]
        guard !version.isTerminal else { return }
        version.status = .complete
        version.incompleteReason = reason
        version.completedAt = clock()
        version.readableSegments = Self.segments(for: version)
        let byID = Dictionary(uniqueKeysWithValues: passages.map { ($0.id, $0) })
        version.sources = citedIDs.compactMap { id in
            guard let passage = byID[id] else { return nil }
            return SourceReference(id: passage.id, documentTitle: passage.documentTitle,
                                   documentVersion: passage.documentVersion, locator: passage.locator,
                                   excerpt: String(passage.text.prefix(200)))
        }
        cards[location.card].versions[location.version] = version
        lastProviderError = reason
        onVersionChanged?(versionID, cards[location.card].id)
    }

    private func fail(versionID: AnswerVersionID, error: Error) {
        guard let location = locate(versionID: versionID) else { return }
        let message = (error as? CopilotProviderError)?.userMessage ?? error.localizedDescription
        var version = cards[location.card].versions[location.version]
        guard !version.isTerminal else { return }
        if case CopilotProviderError.cancelled = error {
            version.status = .cancelled
        } else {
            version.status = .failed(message)
            lastProviderError = message
        }
        // Whatever was already committed stays readable: a failure halfway through must not take away
        // text the user may already be reading (§8).
        version.readableSegments = Self.segments(for: version)
        cards[location.card].versions[location.version] = version
        recordMeasurement(versionID: versionID) { $0.failure = message }
        onVersionChanged?(versionID, cards[location.card].id)
    }

    private func finishTask(versionID: AnswerVersionID) {
        generationTasks[versionID] = nil
        pumpQueue()
    }

    /// Cancels generation for one version. **Listening continues** (§8).
    func cancelGeneration(versionID: AnswerVersionID) {
        generationTasks[versionID]?.cancel()
        generationTasks[versionID] = nil
        generationQueue.removeAll { $0 == versionID }
        pendingRequests[versionID] = nil
        guard let location = locate(versionID: versionID) else { return }
        var version = cards[location.card].versions[location.version]
        guard !version.isTerminal else { return }
        version.status = .cancelled
        version.readableSegments = Self.segments(for: version)
        cards[location.card].versions[location.version] = version
        pumpQueue()
    }

    func regenerate(cardID: QuestionCardID) {
        supersedeInFlightVersion(cardID: cardID)
        startGeneration(for: cardID)
    }

    private func supersedeInFlightVersion(cardID: QuestionCardID) {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
        for versionIndex in cards[index].versions.indices where !cards[index].versions[versionIndex].isTerminal {
            let id = cards[index].versions[versionIndex].id
            generationTasks[id]?.cancel()
            generationTasks[id] = nil
            generationQueue.removeAll { $0 == id }
            pendingRequests[id] = nil
            var version = cards[index].versions[versionIndex]
            version.status = .superseded
            // The previous answer is kept, not deleted (§7).
            version.readableSegments = Self.segments(for: version)
            cards[index].versions[versionIndex] = version
        }
    }

    private func statusOf(_ versionID: AnswerVersionID) -> AnswerVersion.Status? {
        guard let location = locate(versionID: versionID) else { return nil }
        return cards[location.card].versions[location.version].status
    }

    private func locate(versionID: AnswerVersionID) -> (card: Int, version: Int)? {
        for (cardIndex, card) in cards.enumerated() {
            if let versionIndex = card.versions.firstIndex(where: { $0.id == versionID }) {
                return (cardIndex, versionIndex)
            }
        }
        return nil
    }

    /// Committed text, split into the segments already frozen for reading plus whatever came after.
    private static func segments(for version: AnswerVersion) -> [String] {
        let frozen = version.readableSegments
        let frozenLength = frozen.joined(separator: " ").count
        let committed = version.committedText
        guard committed.count > frozenLength else { return frozen.isEmpty && !committed.isEmpty ? [committed] : frozen }
        let remainder = String(committed.dropFirst(frozenLength)).trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return frozen }
        return frozen + [remainder]
    }

    private static func isRelated(_ prefetchText: String, _ question: String) -> Bool {
        let a = Set(Tokenizer.normalize(prefetchText))
        let b = Set(Tokenizer.normalize(question))
        guard !b.isEmpty else { return false }
        return Double(a.intersection(b).count) / Double(b.count) >= 0.6
    }

    // MARK: - Reading

    /// Freezes the opening segment of the selected version and starts following it (§7 fallback:
    /// readable text is immutable; the continuation is queued as a later segment).
    @discardableResult
    func beginReadingSelectedCard() -> Bool {
        guard let card = selectedCard, let version = card.selectedVersion else { return false }
        guard let location = locate(versionID: version.id) else { return false }
        if cards[location.card].versions[location.version].readableSegments.isEmpty {
            let committed = cards[location.card].versions[location.version].committedText
            guard !committed.isEmpty else { return false }
            cards[location.card].versions[location.version].readableSegments = [committed]
        }
        cards[location.card].isFollowingPaused = false
        _ = activeAlignment()
        return true
    }

    /// Moves to the next frozen segment of the selected version, if one exists.
    func continueToNextSegment() {
        guard let card = selectedCard, let version = card.selectedVersion,
              let index = cards.firstIndex(where: { $0.id == card.id }) else { return }
        let next = card.activeSegmentIndex + 1
        guard next < version.readableSegments.count else { return }
        cards[index].activeSegmentIndex = next
        activeAlignmentKey = nil
        _ = activeAlignment()
    }

    var selectedCardHasNextSegment: Bool {
        guard let card = selectedCard, let version = card.selectedVersion else { return false }
        return card.activeSegmentIndex + 1 < version.readableSegments.count
    }

    /// Pauses **voice-following only**. Listening is untouched (§3).
    func setReadingPaused(_ paused: Bool) {
        guard let card = selectedCard, let index = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cards[index].isFollowingPaused = paused
    }

    func selectVersion(_ versionID: AnswerVersionID, cardID: QuestionCardID) {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
        cards[index].selectedVersionID = versionID
        cards[index].activeSegmentIndex = 0
        activeAlignmentKey = nil
    }

    /// The alignment for the selected card's active segment, created on first use and then kept, so
    /// navigating away and back restores the cursor and every spoken-word marker.
    @discardableResult
    func activeAlignment() -> ReadingAlignment? {
        guard let card = selectedCard,
              let version = card.selectedVersion,
              card.activeSegmentIndex < version.readableSegments.count else { return nil }
        let key = "\(version.id.uuidString)#\(card.activeSegmentIndex)"
        activeAlignmentKey = key
        if let existing = alignments[key] { return existing }
        let alignment = ReadingAlignment(text: version.readableSegments[card.activeSegmentIndex])
        alignments[key] = alignment
        return alignment
    }

    // MARK: - Measurements

    private func recordMeasurement(versionID: AnswerVersionID, _ mutate: (inout PipelineMeasurement) -> Void) {
        guard let index = measurements.firstIndex(where: { $0.versionID == versionID }) else { return }
        mutate(&measurements[index])
    }
}

/// One question's journey through the pipeline, in wall-clock seconds. Collected in memory for the
/// prototype's report; nothing is written to disk and no transcript text is included.
struct PipelineMeasurement: Identifiable, Sendable {
    var id: AnswerVersionID { versionID }
    let versionID: AnswerVersionID
    let cardID: QuestionCardID
    /// Transcript-clock time of the end of the question that triggered this.
    let questionEndTranscriptTime: TimeInterval
    /// Time the detector took to answer.
    var detectionSeconds: TimeInterval
    /// Time local retrieval took.
    var retrievalSeconds: TimeInterval
    let requestedAt: Date
    var firstDeltaAt: Date?
    var firstSentenceAt: Date?
    var completedAt: Date?
    var failure: String?

    var timeToFirstText: TimeInterval? { firstDeltaAt.map { $0.timeIntervalSince(requestedAt) } }
    var timeToFirstSentence: TimeInterval? { firstSentenceAt.map { $0.timeIntervalSince(requestedAt) } }
    var timeToComplete: TimeInterval? { completedAt.map { $0.timeIntervalSince(requestedAt) } }
}
