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

    /// Debug-only observation of what each Generate tap did. Never read back into a request.
    let diagnostics = GenerateDiagnostics.shared

    // MARK: Chrome

    var isTranscriptExpanded = false
    /// Incremented to ask the transcript strip to put the keyboard in the note field — the "Add
    /// context" recovery. A counter rather than a flag, so asking twice works twice.
    private(set) var noteFocusRequest = 0
    /// The context panel lives inside the expanded transcript; its contents survive collapsing.
    ///
    /// **Closed until the user opens it.** It opened itself with the transcript, which cost the
    /// answer most of the screen the moment anyone wanted to read two more lines of what was said.
    /// Expanding the transcript is not a request to see the note and the attachments.
    var isContextPanelOpen = false
    var context = ContextState()
    private(set) var recording: RecordingState = .live
    /// Set when an answer becomes ready on a page the user is not looking at: "Q3 ready →".
    private(set) var readyQuestionNumber: Int?
    /// Said plainly under the answer when a generation produced nothing.
    private(set) var generationFailure: String?
    /// What the backend said about this request — for example that attachments were not sent.
    private(set) var generationNotice: String?
    /// Attachments and their real states.
    private(set) var attachments: [ContextAttachment] = []
    private var preparationTasks: [Task<Void, Never>] = []
    /// Whether the configured answer model accepts images, as reported by the backend.
    private(set) var modelAcceptsImages = false
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
    /// The immutable transcript each accepted request is answering.
    private var pendingSnapshots: [UUID: DiscussionSnapshot] = [:]
    /// Transcript lines already covered by an accepted request, by identity and revision.
    ///
    /// **Identity, not text.** Deduplicating by wording alone would permanently silence a question
    /// genuinely asked twice later in the interview, and would treat a partial and its punctuated
    /// final as different questions. A line counts as covered when the same utterance id has been
    /// sent with the same meaningful wording; a material correction changes that wording and makes
    /// it eligible again.
    private var coveredLines: [UUID: String] = [:]
    /// The note and attachment state the last request carried, so editing either makes a new
    /// request eligible even when nothing new was said.
    private var lastRequestedContextFingerprint: String?
    /// Kept after a request finishes so Retry can re-send exactly what failed.
    private var retainedSnapshots: [UUID: DiscussionSnapshot] = [:]

    // MARK: Decisions (pipeline §18)

    /// Focused decisions about the newest speech, asked in the background. Live only; Generate never
    /// waits for one.
    let decisions = RequestDecisionTracker()
    /// Bumped whenever anything a decision depends on changes. Sent with each snapshot so a record can
    /// say which state it was made on; the cache key is the evidence itself, not this number.
    private var decisionRevision = 0
    /// Requests an applied decision said were corrected or withdrawn. Offered to later decisions as
    /// such; nothing is deleted.
    private var supersededRequestIDs: Set<UUID> = []
    /// The interview's language, for anything the interface has to write in it.
    ///
    /// Live takes it from the session's project; Demo is scripted in English.
    var interviewLanguage: InterviewLanguage { liveFeed?.coordinator.project.language ?? .english }

    /// What to offer next on the page being looked at, or nothing while it is still writing.
    var followUpActions: [FollowUpActions.Action] {
        guard let question = currentQuestion,
              let answer = question.selectedAnswer, answer.isComplete else { return [] }
        return FollowUpActions.actions(
            question: question.text,
            blocks: answer.blocks,
            need: answer.need,
            language: interviewLanguage
        )
    }

    /// The one request currently running. Queued requests wait behind it.
    private(set) var activeRequestID: UUID?
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
            // Context is closed by default now, so the screenshot fixture opens it deliberately —
            // which is also what a person has to do.
            isContextPanelOpen = true
        }
        #endif
    }

    // No `deinit` cancellation: a nonisolated deinit may not touch these main-actor properties, and
    // it does not need to — both tasks hold `weak self` and end on their next hop once the model is
    // gone. `stop()` is the deterministic teardown, called when the screen disappears.

    // MARK: - Lifecycle

    func start() {
        guard feedTask == nil else { return }
        #if DEBUG
        // A fresh diagnostics session per interview, so two sittings never share a report — and so
        // content capture starts off, whatever it was left as.
        diagnostics.startSession(
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            commit: Bundle.main.infoDictionary?["GitCommitHash"] as? String ?? "unknown"
        )
        #endif
        // Live: real transcription drives reading, and the capture session drives the header mark.
        // Both come from the one session the coordinator already owns.
        liveFeed?.onDelta = { [weak self] delta in
            guard let self else { return }
            ingestLiveDelta(delta)
            refreshRecordingFromCapture()
        }
        if let coordinator = liveFeed?.coordinator {
            decisions.decide = coordinator.decisionService()
            decisions.makeSnapshot = { [weak self] in self?.makeDecisionSnapshot() }
            decisions.onFinished = { [weak self] snapshot, result, elapsed in
                self?.recordDecisionCall(snapshot: snapshot, result: result, elapsed: elapsed)
            }
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
        queuedRequestIDs = []
        pendingSnapshots = [:]
        activeRequestID = nil
        stopSimulatedReading()
        feedTask?.cancel()
        feedTask = nil
        decisions.reset()
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
            diagnostics.recordFirstText(requestID: requestID)
            appendChunk(text, requestID: requestID)

        case .answerCompleted(let requestID, let blocks, let highlight):
            completeAnswer(requestID: requestID, blocks: blocks, highlight: highlight)
            diagnostics.recordAnswer(
                requestID: requestID,
                answerVersion: generations[requestID]
                    .flatMap { generation in questions.first { $0.id == generation.questionID } }?
                    .selectedAnswer?.version,
                text: blocks.compactMap { block in
                    if case .prose(let prose) = block { return prose }
                    if case .code(let code) = block { return code }
                    return nil
                }.joined(separator: "\n\n")
            )

        case .answerTopicResolved(let requestID, let topic):
            labelEntry(requestID: requestID, topic: topic)
            diagnostics.recordTitle(requestID: requestID, title: topic)

        case .answerNeedsInput(let requestID, let need):
            // It usually arrives with the title, before the answer exists; held until it does.
            pendingNeeds[requestID] = need
            applyPendingNeed(requestID: requestID)

        case .answerFailed(let requestID, let message):
            diagnostics.recordFailure(
                requestID: requestID,
                outcome: message.localizedCaseInsensitiveContains("timed out") ? .timedOut : .failed,
                detail: message,
                httpStatus: nil
            )
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

    #if DEBUG
    /// The request a page's answer is being generated by, for tests that drive the feed's events.
    func requestIDForTesting(questionID: UUID) -> UUID? { requestByQuestion[questionID] }
    #endif

    /// Waiting behind another request, rather than being written right now. Shown as "Queued" so a
    /// tab that is doing nothing yet does not look stalled.
    func isQueued(questionID: UUID) -> Bool {
        guard let requestID = requestByQuestion[questionID] else { return false }
        return queuedRequestIDs.contains(requestID)
    }

    /// True while the button should show it is busy — the target is generating.
    var isGeneratingForTarget: Bool {
        guard let target = generationTarget else { return false }
        return isGenerating(questionID: target.id)
    }

    /// **Generate is always available.** It no longer depends on a detected question, on a selection,
    /// or on nothing else being in flight: detection is unreliable in a real room, and a button that
    /// disables itself when detection fails is a button that fails exactly when it is needed.
    ///
    /// The only thing it needs is something to answer — speech, a note, or attachments.
    var canGenerate: Bool { true }

    /// Nothing to send yet. The button stays tappable and says this rather than going grey, because
    /// a disabled control explains nothing.
    var hasAnythingToAnswer: Bool {
        !transcript.isEmpty
            || !context.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
    }

    /// Transcript lines not yet covered by an accepted request.
    ///
    /// This is what makes a second tap during silence do nothing: the words are the same lines,
    /// already sent, so there is nothing new to ask about.
    var uncoveredLines: [TranscriptLine] {
        transcript.filter { coveredLines[$0.id] != Self.meaningfulWording($0.text) }
    }

    /// Whether a tap would produce a genuinely new request.
    var hasNewInputToAnswer: Bool {
        !uncoveredLines.isEmpty || contextFingerprint != lastRequestedContextFingerprint
    }

    /// Wording with the differences that are not meaning removed.
    ///
    /// Punctuation and case are exactly what changes between a partial and its final, so comparing
    /// raw text would treat one utterance as two questions. A real correction — different words —
    /// still differs here and is still actionable.
    static func meaningfulWording(_ text: String) -> String {
        Tokenizer.normalize(text).joined(separator: " ")
    }

    private var contextFingerprint: String {
        let note = context.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = attachments.map(\.id.uuidString).sorted().joined(separator: ",")
        return "\(note)|\(images)"
    }

    /// Said when Generate is tapped with nothing to work from.
    private(set) var emptyInputNotice: String?

    /// Requests accepted but not yet started, oldest first. One runs at a time.
    private(set) var queuedRequestIDs: [UUID] = []
    /// Small on purpose: a queue that grows without limit is a queue nobody can reason about.
    static let maximumQueuedRequests = 3
    /// Ignores a second tap within this window, so one press cannot become two entries. Long enough
    /// to absorb a double-tap, short enough that a deliberate second request is never refused.
    static let generateDebounce: TimeInterval = 0.4
    private var lastGenerateTapAt: Date?

    /// Asks for an answer to the target question. **A second tap while one is running does nothing** —
    /// the question already has a request, and one question never has two in flight.
    /// The ordinary Generate tap.
    ///
    /// It answers **the latest discussion**, not whatever page is on screen, so browsing history
    /// does not change what the next tap asks about. Every accepted tap creates its own entry with
    /// its own immutable snapshot, including repeated taps about the same discussion.
    func generate(now: Date = Date()) { generate(action: nil, now: now) }

    /// Generate, optionally carrying a follow-up action the speaker tapped.
    ///
    /// **A tapped action counts as new input.** It is a request the speaker just made, so the
    /// "nothing new was said" guard does not apply to it — otherwise the chips would be dead
    /// controls during the silence in which they are most useful. Everything else is identical:
    /// the same whole-session snapshot, the same new tab, the same queue and duplicate rules.
    ///
    /// The action never enters the transcript. The transcript records what was said in the room.
    func generate(action: FollowUpActions.Action?, for parent: InterviewQuestion? = nil, now: Date = Date()) {
        // A local recovery action is not a request: it opens the note, and nothing is sent.
        if action?.kind == .addContext {
            openContextNote()
            return
        }
        // Debounce: one press must not become two entries.
        if let last = lastGenerateTapAt, now.timeIntervalSince(last) < Self.generateDebounce {
            diagnostics.recordTap(requestID: nil, outcome: .debounced,
                                  reason: "within \(Self.generateDebounce)s of the previous tap")
            return
        }

        guard hasAnythingToAnswer || action != nil else {
            emptyInputNotice = "Speak or add context first"
            diagnostics.recordTap(requestID: nil, outcome: .rejectedNothingToAnswer, reason: emptyInputNotice)
            return
        }
        // Nothing new since the last request. Rather than answering the same words twice, offer the
        // action the user actually wants — another version of the answer they already have.
        guard hasNewInputToAnswer || action != nil else {
            emptyInputNotice = "No new question. Regenerate this answer?"
            diagnostics.recordTap(requestID: nil, outcome: .rejectedNothingNew, reason: emptyInputNotice)
            return
        }
        guard queuedRequestIDs.count < Self.maximumQueuedRequests else {
            emptyInputNotice = "Waiting on \(queuedRequestIDs.count) requests — wait or cancel one"
            diagnostics.recordTap(requestID: nil, outcome: .rejectedQueueFull, reason: emptyInputNotice)
            return
        }
        lastGenerateTapAt = now
        emptyInputNotice = nil
        syncSessionNote()

        // The snapshot is taken here, at the tap, and never re-read. Later speech belongs to the
        // next request, not this one.
        var snapshot = transcriptSnapshot()
        // A decision is used only if one is already here, made on exactly this speech and these
        // requests, and the backend said this session may apply it. Nothing is awaited: without one,
        // the request is built exactly as with decisions off.
        var decisionStatus = "not asked: action"
        var appliedParentID: String?
        if action == nil {
            if let key = makeDecisionSnapshot()?.key {
                let use = decisions.interpretation(forKey: key)
                snapshot.interpretation = use.interpretation
                appliedParentID = use.parentID
                decisionStatus = use.status
            } else {
                decisionStatus = "no new speech"
            }
        }
        snapshot.decisionStatus = decisionStatus
        if let action {
            snapshot.requestedAction = action.instruction
            // **An action answers a page, not the newest speech.** Everything said so far is context
            // for it, and nothing spoken is the request — so the whole conversation moves to
            // background and `newInput` is empty. Without this an action tapped while the room kept
            // talking would claim that speech as the thing it was answering.
            snapshot.background = snapshot.allLines
            snapshot.newInput = []
            snapshot.provisional = nil
            if let parent {
                snapshot.actionParentQuestion = parent.text
                snapshot.actionParentAnswer = parent.selectedAnswer?.proseText
                snapshot.actionParentAnswerVersion = parent.selectedAnswer?.version
            }
        }
        let requestID = UUID()
        let entry = InterviewQuestion(text: Self.pendingQuestionLabel)
        questions.append(entry)
        let index = questions.count - 1

        generations[requestID] = Generation(questionID: entry.id, answerID: nil, isRegeneration: false)
        requestByQuestion[entry.id] = requestID
        pendingSnapshots[requestID] = snapshot
        retainedSnapshots[entry.id] = snapshot
        generationFailure = nil

        // **Generate navigates.** The user asked for this answer, so the tab it lands in opens
        // immediately — including when it is not the first. Anything that arrives *later* (streaming,
        // completion, another request finishing) must never move them again: that is the difference
        // between following a tap and being yanked around.
        currentIndex = index
        explicitlySelectedQuestionID = entry.id
        readyQuestionNumber = nil

        // Reserve the input this request covers, so a second tap cannot enqueue the same snapshot.
        //
        // **An action reserves nothing.** It is not answering the speech, so speech that arrived
        // while the reader was browsing stays uncovered and is still there for the next ordinary
        // Generate. Reserving it here would silently swallow a question nobody had answered.
        if action == nil {
            for line in uncoveredLines { coveredLines[line.id] = Self.meaningfulWording(line.text) }
            lastRequestedContextFingerprint = contextFingerprint
        }

        if let relation = snapshot.interpretation?.relation, ["correction", "abandonment"].contains(relation),
           let parentID = appliedParentID.flatMap(UUID.init(uuidString:)) {
            supersededRequestIDs.insert(parentID)
        }

        // Recorded *after* the request is fully formed and *before* it is queued, so a diagnostic
        // can never be the reason a request looks different from the one that was sent.
        recordTapForDiagnostics(requestID: requestID, snapshot: snapshot, at: now)
        diagnostics.recordDecisionUse(requestID: requestID, status: decisionStatus)
        noteDecisionStateChanged()

        queuedRequestIDs.append(requestID)
        diagnostics.recordQueued(requestID: requestID, at: now)
        startNextQueuedRequestIfIdle()
    }

    /// Hands the recorder what this tap decided. Observation only — nothing here is read back.
    private func recordTapForDiagnostics(requestID: UUID, snapshot: DiscussionSnapshot, at now: Date) {
        let covered = Set(coveredLines.keys)
        let captureText = diagnostics.isContentCaptureEnabled
        let utterances = transcript.map { line in
            GenerateTrace.Utterance(
                id: line.id,
                revision: line.revision,
                isFinal: line.isFinal,
                isCovered: covered.contains(line.id),
                characterCount: line.text.count,
                text: captureText ? line.text : ""
            )
        }
        diagnostics.recordTap(requestID: requestID, outcome: .accepted, reason: nil, at: now)
        diagnostics.recordSnapshot(
            requestID: requestID,
            transcriptLineCount: transcript.count,
            transcriptCharacters: transcript.reduce(0) { $0 + $1.text.count },
            snapshot: snapshot,
            utterances: utterances,
            attachmentCount: attachments.count,
            preparedAttachmentCount: attachments.filter(\.state.isSendable).count
        )
    }

    /// The transcript as it stands, oldest first, split at the answered/new boundary.
    ///
    /// Both halves matter and they are not interchangeable. The new lines are what this tap is
    /// asking about. The answered ones behind them are what a fragment like "in Java" or a
    /// correction like "of France" refers to — discarding them was what turned those into standalone
    /// questions — but they are context, not questions to answer a second time.
    ///
    /// **The whole session travels, not a window of it.** There was a twelve-line cut here, and a
    /// six-line cut inside that for the answered half. A fact stated sixteen lines ago — the project
    /// the speaker actually worked on — was silently gone by the time it was asked about, and
    /// nothing on screen said so. Length is a budget question, and the budget is checked where the
    /// prompt is assembled and the model's context window is known; it is not something to
    /// approximate here by counting lines.
    private func transcriptSnapshot() -> DiscussionSnapshot {
        let uncovered = Set(uncoveredLines.map(\.id))
        // The line still being spoken is provisional: it travels, but apart, so that finalizing it
        // updates one line rather than adding a second copy of the same speech.
        let openLine = transcript.last.flatMap { $0.isFinal ? nil : $0 }
        let settled = transcript.filter { $0.isFinal }

        var background: [String] = []
        var newInput: [String] = []
        for line in settled {
            if uncovered.contains(line.id) {
                newInput.append(line.text)
            } else if newInput.isEmpty {
                background.append(line.text)
            } else {
                // An already-answered line *after* new speech — a revision arriving late, say. It is
                // still part of what this tap is about, so it travels as new input rather than being
                // dropped out of the middle of the discussion.
                newInput.append(line.text)
            }
        }
        return DiscussionSnapshot(
            background: background,
            newInput: newInput,
            provisional: openLine.map(\.text),
            priorSuggestions: priorSuggestionTexts(),
            note: context.note.trimmingCharacters(in: .whitespacesAndNewlines),
            attachmentIDs: attachments.map(\.id.uuidString)
        )
    }

    /// Answers already suggested this session, oldest first.
    ///
    /// They are sent so a follow-up that refers to one ("give me an example of that") has the thing
    /// it refers to, and they are labelled as suggestions so nothing in them is ever mistaken for
    /// something the speaker said about themselves.
    private func priorSuggestionTexts() -> [String] {
        questions.compactMap { question in
            guard let answer = question.selectedAnswer, answer.isComplete else { return nil }
            let text = answer.blocks.compactMap { block -> String? in
                if case .prose(let prose) = block { return prose }
                return nil
            }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }
    /// Shown while the feed works out what it is answering.
    static let pendingQuestionLabel = "Preparing answer…"

    /// Starts the oldest queued request, if nothing is running.
    private func startNextQueuedRequestIfIdle() {
        guard activeRequestID == nil, let next = queuedRequestIDs.first else { return }
        guard let generation = generations[next], let snapshot = pendingSnapshots[next] else {
            queuedRequestIDs.removeFirst()
            return
        }
        activeRequestID = next
        queuedRequestIDs.removeFirst()
        diagnostics.recordSent(requestID: next)
        feed.requestAnswerForDiscussion(requestID: next, discussion: snapshot, questionID: generation.questionID)
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
    /// Records what the backend says it can do, so the panel tells the truth about attachments.
    func applyBackendCapability(acceptsImages: Bool) {
        modelAcceptsImages = acceptsImages
        for index in attachments.indices {
            if !acceptsImages {
                attachments[index].state = .notSupported
            } else if attachments[index].state == .notSupported {
                attachments[index].state = attachments[index].preparedJPEG.map { .ready(bytes: $0.count) } ?? .preparing
            }
        }
    }

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

    /// Hands the typed note and the prepared attachments to the pipeline, where they are
    /// snapshotted into the next request.
    func syncSessionNote() {
        liveFeed?.coordinator.sessionNote = context.note
        liveFeed?.coordinator.sessionImages = sendableAttachments
    }

    /// Attachments that are genuinely ready to travel. Anything still preparing, failed, or
    /// unsupported is left out **and says so on screen**.
    var sendableAttachments: [AnswerRequest.ImageAttachment] {
        guard modelAcceptsImages else { return [] }
        return attachments.compactMap { attachment in
            guard attachment.state.isSendable, let jpeg = attachment.preparedJPEG else { return nil }
            return AnswerRequest.ImageAttachment(mime: "image/jpeg", data: jpeg.base64EncodedString())
        }
    }

    /// Adds an image and prepares it in the background, showing each state as it happens.
    @discardableResult
    func attachImage(_ data: Data) -> Bool {
        guard attachments.count < ContextState.imageLimit else { return false }
        let attachment = ContextAttachment(originalData: data)
        attachments.append(attachment)
        _ = context.addImage(ContextImage(id: attachment.id, data: data))
        let task = Task { [weak self] in
            let (state, jpeg) = await ContextAttachment.prepare(data)
            guard let self, let index = attachments.firstIndex(where: { $0.id == attachment.id }) else { return }
            attachments[index].state = modelAcceptsImages ? state : .notSupported
            attachments[index].preparedJPEG = jpeg
            syncSessionNote()
        }
        preparationTasks.append(task)
        return true
    }

    /// Waits for every in-flight preparation to settle.
    ///
    /// The view never needs this — it watches the states change — but a test does, and waiting on
    /// the actual work is honest where sleeping for an arbitrary interval is a race that passes on a
    /// quiet machine and fails on a busy one.
    func awaitAttachmentPreparation() async {
        let pending = preparationTasks
        preparationTasks = []
        for task in pending { _ = await task.value }
    }

    /// One short label per attachment, in order, for the panel to show under the thumbnails.
    var attachmentLabels: [UUID: String] {
        Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0.state.label) })
    }

    func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
        context.removeImage(id: id)
        syncSessionNote()
    }

    /// Said before anything is generated, when part of the attached context cannot be used.
    ///
    /// The capability is **asked of the backend**, never assumed: the speed profile's model is
    /// text-only while the balanced and smart ones read images, so a hardcoded answer would be wrong
    /// half the time.
    var contextLimitationMessage: String? {
        guard mode == .live, !attachments.isEmpty else { return nil }
        if !modelAcceptsImages {
            let count = attachments.count
            return count == 1
                ? "The attached image is not sent — the configured model reads text only. Your note is sent."
                : "The \(count) attached images are not sent — the configured model reads text only. Your note is sent."
        }
        let failed = attachments.filter { if case .failed = $0.state { true } else { false } }.count
        if failed > 0 {
            return failed == 1 ? "1 image could not be prepared and will not be sent."
                               : "\(failed) images could not be prepared and will not be sent."
        }
        let preparing = attachments.filter { $0.state == .preparing }.count
        return preparing > 0 ? "Preparing \(preparing) image\(preparing == 1 ? "" : "s")…" : nil
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
        defer { noteDecisionStateChanged() }
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

    // MARK: - Decision snapshots

    private func noteDecisionStateChanged() {
        decisionRevision += 1
        decisions.stateChanged()
    }

    /// The bounded state for one decision, or nil when nothing new has been said.
    ///
    /// New speech is every line not yet covered by a request — all of it, so coalescing never loses an
    /// utterance. Candidates are the most recent ordinary requests, by the words each was asked about,
    /// newest first. Titles, answers, the note and attachments are deliberately absent.
    func makeDecisionSnapshot() -> DecisionSnapshot? {
        let uncovered = Set(uncoveredLines.map(\.id))
        let newLines = transcript.filter { uncovered.contains($0.id) }
        guard !newLines.isEmpty, let firstNew = transcript.firstIndex(where: { uncovered.contains($0.id) }) else { return nil }
        let preceding = transcript[..<firstNew].suffix(6).map(\.text)
        var candidates: [DecisionSnapshot.Candidate] = []
        for question in questions.reversed() {
            guard candidates.count < 5, let source = retainedSnapshots[question.id],
                  source.requestedAction == nil, !source.newLines.isEmpty else { continue }
            let status: DecisionSnapshot.Candidate.Status = supersededRequestIDs.contains(question.id) ? .superseded
                : isGenerating(questionID: question.id) ? .pending : .answered
            candidates.append(.init(id: question.id.uuidString, sourceText: source.newLines.joined(separator: " "), status: status))
        }
        var snapshot = DecisionSnapshot(
            sessionID: liveFeed?.coordinator.sessionID.uuidString ?? "no-session",
            stateRevision: decisionRevision,
            snapshotID: UUID().uuidString,
            language: interviewLanguage.bcp47,
            newSpeech: newLines.map { .init(id: $0.id.uuidString, revision: $0.revision, isFinal: $0.isFinal, text: $0.text) },
            preceding: Array(preceding),
            candidates: candidates
        )
        #if DEBUG
        snapshot.requestActive = diagnostics.isDecisionApplyRequested
        snapshot.diagnosticsSessionID = diagnostics.sessionID.uuidString
        snapshot.captureContent = diagnostics.isContentCaptureEnabled
        #endif
        return snapshot
    }

    private func recordDecisionCall(snapshot: DecisionSnapshot, result: Result<DecisionOutcome, Error>, elapsed: Duration) {
        let ms = Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        switch result {
        case .success(let outcome):
            diagnostics.note("Decision rev \(snapshot.stateRevision) · \(outcome.relation?.choice ?? "-") \(outcome.relation?.confidence.map { String(format: "%.2f", $0) } ?? "") · parent \(outcome.parent?.choice ?? "-") · eligible \(outcome.eligible) · apply \(outcome.apply)\(outcome.fallbackReason.map { " · \($0)" } ?? "") · \(ms) ms")
        case .failure(let error):
            diagnostics.note("Decision rev \(snapshot.stateRevision) failed after \(ms) ms: \(error.localizedDescription)")
        }
    }

    /// Names the entry with what the feed actually decided it was answering.
    private func labelEntry(requestID: UUID, topic: String) {
        guard let generation = generations[requestID],
              let index = questions.firstIndex(where: { $0.id == generation.questionID }) else { return }
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        questions[index].text = trimmed
    }

    /// Frees the slot and starts whatever is waiting. Called on every terminal outcome, so a failure
    /// can never strand the queue.
    private func finishRequest(_ requestID: UUID) {
        pendingSnapshots[requestID] = nil
        if activeRequestID == requestID { activeRequestID = nil }
        startNextQueuedRequestIfIdle()
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
        applyPendingNeed(requestID: requestID)
    }

    /// What each request's answer asked for, until that answer exists.
    private var pendingNeeds: [UUID: AnswerNeed] = [:]

    private func applyPendingNeed(requestID: UUID) {
        guard let need = pendingNeeds[requestID], let generation = generations[requestID],
              let answerID = generation.answerID,
              let index = questions.firstIndex(where: { $0.id == generation.questionID }),
              let answerIndex = questions[index].answers.firstIndex(where: { $0.id == answerID }) else { return }
        questions[index].answers[answerIndex].need = need
        pendingNeeds[requestID] = nil
    }

    /// "Add context": opens the context panel with the keyboard in the note. Sends nothing, and
    /// changes no answer — the next Generate carries the note, because the note is part of what a
    /// tap snapshots.
    func openContextNote() {
        isTranscriptExpanded = true
        isContextPanelOpen = true
        noteFocusRequest += 1
    }

    /// Raw streamed text per answer, before it is split into prose and code.
    ///
    /// The blocks on screen are **derived** from this, never accumulated directly. Appending each
    /// chunk to the last prose block put the model's own fence markers in front of the reader —
    /// "```java" sat in the answer text for as long as the code took to arrive, and only the
    /// completion event cleaned it up. Re-parsing the buffer on every chunk means a code block
    /// becomes a code card as it streams and a control marker is never visible at all.
    private var streamedText: [UUID: String] = [:]

    private func appendChunk(_ text: String, requestID: UUID) {
        guard let generation = generations[requestID], let answerID = generation.answerID,
              let index = questions.firstIndex(where: { $0.id == generation.questionID }) else { return }
        var question = questions[index]
        guard let answerIndex = question.answers.firstIndex(where: { $0.id == answerID }),
              !question.answers[answerIndex].isComplete else { return }

        streamedText[answerID] = Self.joinedChunk(streamedText[answerID] ?? "", text)
        var answer = question.answers[answerIndex]
        answer.blocks = AnswerBlock.parsed(from: streamedText[answerID] ?? "")
        question.answers[answerIndex] = answer
        questions[index] = question
    }

    /// Appends a streamed chunk to what has arrived so far.
    ///
    /// Feeds differ in what a chunk is: live chunks are raw slices that carry their own spacing and
    /// newlines, while the demo reveals whole words. So a separator is added only when neither side
    /// already has one — never inside a word, never doubling a space, and never inside a code block
    /// where an inserted space would corrupt the sample.
    static func joinedChunk(_ existing: String, _ addition: String) -> String {
        guard !existing.isEmpty, !addition.isEmpty else { return existing + addition }
        let needsSpace = !existing.last!.isWhitespace && !addition.first!.isWhitespace
        return needsSpace ? existing + " " + addition : existing + addition
    }

    private func completeAnswer(requestID: UUID, blocks: [AnswerBlock], highlight: String?) {
        defer { noteDecisionStateChanged() }
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
        streamedText[answerID] = nil

        generations[requestID] = nil
        requestByQuestion[generation.questionID] = nil
        finishRequest(requestID)

        // Completion never navigates. Generate already opened this tab; if the user has moved on
        // since, finishing must not pull them back — it offers itself with a chip instead.
        if index == currentIndex {
            restartSimulatedReadingForCurrentPage()
        } else {
            readyQuestionNumber = index + 1
        }
    }

    /// A failure keeps everything that arrived. Whatever text was streamed stays readable and the
    /// entry is marked incomplete, so Retry adds to history rather than replacing it.
    private func failAnswer(requestID: UUID, message: String) {
        guard let generation = generations[requestID] else { return }
        if let answerID = generation.answerID,
           let index = questions.firstIndex(where: { $0.id == generation.questionID }),
           let answerIndex = questions[index].answers.firstIndex(where: { $0.id == answerID }) {
            questions[index].answers[answerIndex].isComplete = true
            questions[index].answers[answerIndex].isIncomplete = true
        }
        generations[requestID] = nil
        requestByQuestion[generation.questionID] = nil
        generationFailure = message
        finishRequest(requestID)
    }

    /// Re-sends a failed request's own snapshot.
    ///
    /// **Explicit only, and never automatic.** A failed request keeps its snapshot precisely so the
    /// user can try again without re-speaking; nothing re-sends it when connectivity returns, because
    /// an answer arriving minutes later, unasked, to a question that has moved on is worse than none.
    func retry(questionID: UUID) {
        guard let index = questions.firstIndex(where: { $0.id == questionID }),
              requestByQuestion[questionID] == nil,
              let snapshot = retainedSnapshots[questionID] else { return }
        let requestID = UUID()
        generations[requestID] = Generation(questionID: questionID, answerID: nil, isRegeneration: false)
        requestByQuestion[questionID] = requestID
        pendingSnapshots[requestID] = snapshot
        generationFailure = nil
        currentIndex = index
        queuedRequestIDs.append(requestID)
        startNextQueuedRequestIfIdle()
    }

    /// True when this entry failed and still has the snapshot needed to try again.
    func canRetry(questionID: UUID) -> Bool {
        requestByQuestion[questionID] == nil && retainedSnapshots[questionID] != nil
            && (questions.first { $0.id == questionID }?.selectedAnswer?.isIncomplete ?? false)
    }

    /// Abandons a queued request the user no longer wants. The entry stays, marked cancelled, rather
    /// than vanishing — an accepted request is never silently discarded.
    func cancelQueuedRequest(_ requestID: UUID) {
        guard queuedRequestIDs.contains(requestID) else { return }
        queuedRequestIDs.removeAll { $0 == requestID }
        feed.cancelAnswer(requestID: requestID)
        if let generation = generations[requestID] {
            requestByQuestion[generation.questionID] = nil
        }
        generations[requestID] = nil
        pendingSnapshots[requestID] = nil
    }
}
