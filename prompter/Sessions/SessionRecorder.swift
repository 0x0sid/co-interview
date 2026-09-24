import Foundation
import SwiftData

/// Saves the running interview as it happens.
///
/// - **Incremental.** It remembers what it last wrote for every utterance, question and answer, and
///   touches only the rows that changed. A transcript revision rewrites one utterance row; a streamed
///   sentence rewrites one answer row; nothing rewrites the whole session.
/// - **Debounced where it is noisy.** Transcript revisions and streamed text are saved at most once
///   per `debounce`; state transitions — a new question, an answer starting, finishing or failing,
///   Resume, a language change — are saved at once.
/// - `flush()` saves immediately; the screen calls it when the app goes to the background and when
///   the session ends, so a termination loses at most the last debounce window of streamed text.
@MainActor
final class SessionRecorder {
    let session: InterviewSessionRecord
    private let context: ModelContext
    private let debounce: Duration
    private let clock: () -> Date
    private weak var model: InterviewScreenModel?
    private var pending: Task<Void, Never>?

    private var utteranceRecords: [UUID: SessionUtteranceRecord] = [:]
    private var utteranceSaved: [UUID: String] = [:]
    private var questionRecords: [UUID: SessionQuestionRecord] = [:]
    private var questionSaved: [UUID: String] = [:]
    private var answerRecords: [UUID: SessionAnswerRecord] = [:]
    private var answerSaved: [UUID: String] = [:]
    /// Foreground time accounting.
    private var runningSince: Date?

    /// How many rows each flush wrote — for tests and diagnostics.
    private(set) var lastWriteCount = 0
    private(set) var flushCount = 0

    init(session: InterviewSessionRecord, context: ModelContext, debounce: Duration = .milliseconds(1500),
         clock: @escaping () -> Date = Date.init) {
        self.session = session
        self.context = context
        self.debounce = debounce
        self.clock = clock
        for record in session.utterances {
            utteranceRecords[record.id] = record
            utteranceSaved[record.id] = Self.signature(record)
        }
        for record in session.questions {
            questionRecords[record.id] = record
            questionSaved[record.id] = Self.signature(record)
            for answer in record.answers {
                answerRecords[answer.id] = answer
                answerSaved[answer.id] = Self.signature(answer)
            }
        }
    }

    /// Starts following a model. Its changes are saved from now on.
    func attach(to model: InterviewScreenModel) {
        self.model = model
        model.onPersist = { [weak self] urgency in
            switch urgency {
            case .soon: self?.scheduleFlush()
            case .now: self?.flush()
            }
        }
    }

    /// The session is running in the foreground: its time counts.
    func setRunning(_ running: Bool) {
        let now = clock()
        if running {
            if runningSince == nil { runningSince = now }
        } else if let since = runningSince {
            session.activeSeconds += now.timeIntervalSince(since)
            runningSince = nil
        }
    }

    func scheduleFlush() {
        guard pending == nil else { return }
        let debounce = self.debounce
        pending = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.pending = nil
            self?.flush()
        }
    }

    /// Writes what changed since the last flush, and nothing else.
    func flush() {
        pending?.cancel()
        pending = nil
        guard let model else { return }
        var writes = 0

        for (order, line) in model.transcript.enumerated() {
            let covered = model.coveredWordingByLine[line.id]
            let signature = "\(order)|\(line.revision)|\(line.isFinal)|\(line.isDetectedQuestion)|\(line.questionID?.uuidString ?? "")|\(covered ?? "")|\(line.text)"
            guard utteranceSaved[line.id] != signature else { continue }
            let record = utteranceRecords[line.id] ?? {
                let created = SessionUtteranceRecord(line: line, order: order)
                created.session = session
                context.insert(created)
                utteranceRecords[line.id] = created
                return created
            }()
            record.order = order
            record.text = line.text
            record.isFinal = line.isFinal
            record.revision = line.revision
            record.isDetectedQuestion = line.isDetectedQuestion
            record.questionID = line.questionID
            record.coveredWording = covered
            utteranceSaved[line.id] = signature
            writes += 1
        }

        let encoder = JSONEncoder()
        for (order, question) in model.questions.enumerated() {
            let snapshot = model.retainedSnapshot(for: question.id)
            let signature = Self.questionSignature(order: order, text: question.text, selected: question.selectedAnswerID,
                                                   followUps: question.followUps.count, hasSnapshot: snapshot != nil)
            let record = questionRecords[question.id] ?? {
                let created = SessionQuestionRecord(id: question.id, order: order, text: question.text)
                created.session = session
                context.insert(created)
                questionRecords[question.id] = created
                return created
            }()
            if questionSaved[question.id] != signature {
                record.order = order
                record.text = question.text
                record.selectedAnswerID = question.selectedAnswerID
                record.followUpsData = try? encoder.encode(question.followUps.map { StoredFollowUp(likelihood: $0.likelihood.rawValue, text: $0.text) })
                if let snapshot, record.snapshotData == nil { record.snapshotData = try? encoder.encode(snapshot) }
                questionSaved[question.id] = signature
                writes += 1
            }

            for answer in question.answers {
                let state = Self.state(of: answer, streaming: model.isGenerating(questionID: question.id) && answer.id == question.answers.last?.id)
                let signature = Self.answerSignature(state: state, blocks: answer.blocks, need: answer.need, provenance: answer.provenance)
                guard answerSaved[answer.id] != signature else { continue }
                let stored = answerRecords[answer.id] ?? {
                    let created = SessionAnswerRecord(id: answer.id, version: answer.version, createdAt: answer.createdAt)
                    created.question = record
                    context.insert(created)
                    answerRecords[answer.id] = created
                    return created
                }()
                stored.blocksData = StoredBlock.encode(answer.blocks)
                stored.highlight = answer.highlight
                stored.stateRaw = state
                stored.failureMessage = answer.failureMessage
                stored.needRaw = answer.need?.rawValue
                stored.provenanceData = answer.provenance.flatMap { try? encoder.encode($0) }
                answerSaved[answer.id] = signature
                writes += 1
            }
        }

        let answered = model.questions.filter { !$0.answers.isEmpty }.count
        if session.answeredCount != answered { session.answeredCount = answered; writes += 1 }
        if session.note != model.context.note { session.note = model.context.note; writes += 1 }
        if let language = model.liveLanguage, session.languageRaw != language.rawValue {
            session.languageRaw = language.rawValue
            writes += 1
        }
        if !session.isTitleCustom, let first = model.questions.first(where: { $0.text != InterviewScreenModel.pendingQuestionLabel && !$0.answers.isEmpty }),
           session.title != first.text {
            session.title = first.text
            writes += 1
        }
        if let since = runningSince {
            let now = clock()
            session.activeSeconds += now.timeIntervalSince(since)
            runningSince = now
        }
        if writes > 0 { session.lastActivityAt = clock() }
        lastWriteCount = writes
        flushCount += 1
        try? context.save()
    }

    /// The session was closed normally.
    func end() {
        setRunning(false)
        flush()
        session.state = .ended
        try? context.save()
    }

    private static func state(of answer: InterviewAnswer, streaming: Bool) -> String {
        if answer.isInterrupted { return "interrupted" }
        if !answer.isComplete { return "streaming" }
        if answer.isIncomplete { return answer.failureMessage == nil ? "incomplete" : "failed" }
        return streaming ? "streaming" : "complete"
    }

    private static func signature(_ record: SessionUtteranceRecord) -> String {
        "\(record.order)|\(record.revision)|\(record.isFinal)|\(record.isDetectedQuestion)|\(record.questionID?.uuidString ?? "")|\(record.coveredWording ?? "")|\(record.text)"
    }

    private static func questionSignature(order: Int, text: String, selected: UUID?, followUps: Int, hasSnapshot: Bool) -> String {
        "\(order)|\(text)|\(selected?.uuidString ?? "")|\(followUps)|\(hasSnapshot ? 1 : 0)"
    }

    /// Stable across launches (no `hashValue`): the text's length and its tail change with every
    /// streamed addition.
    private static func answerSignature(state: String, blocks: [AnswerBlock], need: AnswerNeed?, provenance: AnswerProvenance?) -> String {
        let text = blocks.map(\.id).joined()
        return "\(state)|\(text.count)|\(text.suffix(48))|\(need?.rawValue ?? "")|\(provenance?.included.count ?? -1)|\(provenance?.citedPassageIDs.count ?? -1)"
    }

    private static func signature(_ record: SessionQuestionRecord) -> String {
        let followUps = record.followUpsData.flatMap { try? JSONDecoder().decode([StoredFollowUp].self, from: $0) }?.count ?? 0
        return questionSignature(order: record.order, text: record.text, selected: record.selectedAnswerID,
                                 followUps: followUps, hasSnapshot: record.snapshotData != nil)
    }

    private static func signature(_ record: SessionAnswerRecord) -> String {
        let provenance = record.provenanceData.flatMap { try? JSONDecoder().decode(AnswerProvenance.self, from: $0) }
        return answerSignature(state: record.stateRaw, blocks: StoredBlock.decode(record.blocksData),
                               need: record.needRaw.flatMap(AnswerNeed.init(rawValue:)), provenance: provenance)
    }
}
