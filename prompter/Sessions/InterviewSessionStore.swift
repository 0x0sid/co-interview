import Foundation
import SwiftData

/// What a saved session gives back to the interview screen: its content, never its activity.
///
/// Restoring shows what was there. It does not start the microphone and does not re-send anything:
/// an answer that was still being written is shown as far as it got and labelled interrupted, with
/// Retry offered; resuming the interview is a separate, explicit tap.
struct RestoredInterview {
    var transcript: [TranscriptLine] = []
    var questions: [InterviewQuestion] = []
    var coveredLines: [UUID: String] = [:]
    var retainedSnapshots: [UUID: DiscussionSnapshot] = [:]
    var note: String = ""
    var wasInterrupted = false
}

@MainActor
enum InterviewSessionStore {
    static func create(in context: ModelContext, language: InterviewLanguage, preference: InterviewLanguagePreference,
                       mode: String = "live", now: Date = .now) -> InterviewSessionRecord {
        let session = InterviewSessionRecord(title: InterviewSessionRecord.defaultTitle(for: now), createdAt: now,
                                             mode: mode, language: language, preference: preference)
        context.insert(session)
        try? context.save()
        return session
    }

    /// On launch: any session still marked open was not closed — the app was terminated, crashed or
    /// was killed in the background. It becomes interrupted, and so does any answer that was still
    /// streaming. Nothing is re-sent.
    @discardableResult
    static func markInterruptedSessions(in context: ModelContext) -> Int {
        let open = InterviewSessionRecord.State.open.rawValue
        guard let sessions = try? context.fetch(FetchDescriptor<InterviewSessionRecord>(predicate: #Predicate { $0.stateRaw == open })) else { return 0 }
        for session in sessions {
            session.state = .interrupted
            for question in session.questions {
                for answer in question.answers where answer.stateRaw == "streaming" {
                    answer.stateRaw = "interrupted"
                }
            }
        }
        try? context.save()
        return sessions.count
    }

    static func history(in context: ModelContext, limit: Int? = nil) -> [InterviewSessionRecord] {
        let live = "live"
        var descriptor = FetchDescriptor<InterviewSessionRecord>(
            predicate: #Predicate { $0.modeRaw == live },
            sortBy: [SortDescriptor(\.lastActivityAt, order: .reverse)]
        )
        if let limit { descriptor.fetchLimit = limit }
        return (try? context.fetch(descriptor)) ?? []
    }

    static func rename(_ session: InterviewSessionRecord, to title: String, in context: ModelContext) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.title = trimmed
        session.isTitleCustom = true
        try? context.save()
    }

    /// Deletes the session with everything in it. Its stored files go too, unless another session
    /// still has the same content.
    static func delete(_ session: InterviewSessionRecord, in context: ModelContext, store: FileStore = .standard) {
        let files = session.attachments.map { ($0.contentHash, $0.storedFileName) }
        context.delete(session)
        try? context.save()
        for (hash, name) in files {
            FileReferences.releaseIfUnreferenced(hash: hash, storedName: name, context: context, store: store)
        }
    }

    /// The saved content, in order, ready for the screen.
    static func restore(_ session: InterviewSessionRecord) -> RestoredInterview {
        var restored = RestoredInterview()
        restored.note = session.note
        restored.wasInterrupted = session.state == .interrupted

        for record in session.utterances.sorted(by: { $0.order < $1.order }) {
            restored.transcript.append(TranscriptLine(id: record.id, text: record.text, isDetectedQuestion: record.isDetectedQuestion,
                                                      questionID: record.questionID, isFinal: record.isFinal, revision: record.revision))
            if let covered = record.coveredWording { restored.coveredLines[record.id] = covered }
        }

        let decoder = JSONDecoder()
        for record in session.questions.sorted(by: { $0.order < $1.order }) {
            let answers = record.answers.sorted { $0.version < $1.version }.map { stored -> InterviewAnswer in
                var answer = InterviewAnswer(id: stored.id, version: stored.version, blocks: StoredBlock.decode(stored.blocksData),
                                             highlight: stored.highlight, isComplete: true,
                                             isIncomplete: stored.stateRaw != "complete", createdAt: stored.createdAt)
                answer.isInterrupted = stored.stateRaw == "interrupted" || stored.stateRaw == "streaming"
                answer.need = stored.needRaw.flatMap(AnswerNeed.init(rawValue:))
                answer.provenance = stored.provenanceData.flatMap { try? decoder.decode(AnswerProvenance.self, from: $0) }
                answer.failureMessage = stored.failureMessage
                return answer
            }
            let followUps = record.followUpsData.flatMap { try? decoder.decode([StoredFollowUp].self, from: $0) }?
                .map { FollowUp(likelihood: FollowUp.Likelihood(rawValue: $0.likelihood) ?? .possible, text: $0.text) } ?? []
            var text = record.text
            if answers.isEmpty, text == InterviewScreenModel.pendingQuestionLabel {
                // The request was accepted but no answer ever arrived before the app stopped.
                text = "Not answered — interrupted"
            }
            restored.questions.append(InterviewQuestion(id: record.id, text: text, answers: answers,
                                                        followUps: followUps, selectedAnswerID: record.selectedAnswerID))
            if let data = record.snapshotData, let snapshot = try? decoder.decode(DiscussionSnapshot.self, from: data) {
                restored.retainedSnapshots[record.id] = snapshot
            }
        }
        return restored
    }
}

#if DEBUG
extension InterviewSessionStore {
    /// `-UITestsSeedHistory`: four plainly synthetic sessions for screenshots — one interrupted with
    /// a partial answer. Only when history is empty; debug builds only; never real content.
    static func seedForScreenshotsIfRequested(in context: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains("-UITestsSeedHistory"), history(in: context).isEmpty else { return }
        let now = Date.now
        let samples: [(String, InterviewLanguage, TimeInterval, Double, Bool)] = [
            ("Demo · Backend platform interview", .english, -3_600, 1_680, true),
            ("Demo · Entretien architecte cloud", .french, -86_400, 2_400, false),
            ("Demo · System design practice", .english, -3 * 86_400, 900, false),
            ("Demo · Behavioural round", .english, -6 * 86_400, 1_200, false),
        ]
        for (title, language, offset, seconds, interrupted) in samples {
            let session = create(in: context, language: language, preference: .system, now: now.addingTimeInterval(offset))
            session.title = title
            session.isTitleCustom = true
            session.activeSeconds = seconds
            session.state = interrupted ? .interrupted : .ended
            let line = SessionUtteranceRecord(line: TranscriptLine(text: "How would you design an idempotent payment API?"), order: 0)
            line.session = session
            line.coveredWording = InterviewScreenModel.meaningfulWording(line.text)
            context.insert(line)
            let question = SessionQuestionRecord(id: UUID(), order: 0, text: "Designing an idempotent payment API")
            question.session = session
            question.snapshotData = try? JSONEncoder().encode(DiscussionSnapshot(newInput: [line.text]))
            context.insert(question)
            let answer = SessionAnswerRecord(id: UUID(), version: 1, createdAt: session.createdAt)
            answer.blocksData = StoredBlock.encode([.prose("I would require a client-generated idempotency key on every write, store it with the result, and return the stored result on a retry.")])
            answer.stateRaw = interrupted ? "interrupted" : "complete"
            answer.question = question
            context.insert(answer)
            session.lastActivityAt = session.createdAt
            session.answeredCount = 1
        }
        try? context.save()
    }
}
#endif
