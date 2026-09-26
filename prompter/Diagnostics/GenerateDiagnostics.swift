import Foundation
import os

/// A Debug-only record of what each Generate tap actually did, for testing on a real phone.
///
/// **It observes; it never participates.** Nothing here is read back into a request, and no
/// diagnostic value can change what is sent, what is shown, or when. Every entry point swallows its
/// own failures: if recording breaks, the interview carries on, because an interview is not a thing
/// you can ask someone to repeat.
///
/// **Release builds keep nothing.** Every method below is `#if DEBUG` inside, so a shipping build
/// compiles them to empty bodies rather than carrying a store it never fills. The type still exists
/// in Release so callers need no conditional compilation at the call site.
///
/// **Content capture is off until it is switched on, per session.** Without it a trace records
/// sizes, identities, timings and outcomes — the shape of what happened — and no conversation text
/// and no answer text. With it on, the transcript, the snapshot, the outgoing request, the provider
/// messages and the answer are kept so a lost sentence can be traced to the exact step that lost it.
/// Credentials never travel either way: see `Redaction`.
@MainActor
@Observable
final class GenerateDiagnostics {
    static let shared = GenerateDiagnostics()

    /// One interview session. Regenerated whenever a session starts, so exports from two sittings
    /// are never mixed up.
    private(set) var sessionID = UUID()
    private(set) var startedAt = Date()

    /// Conversation and answer text are kept **only** while this is on.
    ///
    /// Deliberately not persisted: it returns to off for every new session, so a capture enabled to
    /// chase one problem cannot quietly stay on for an interview that matters.
    var isContentCaptureEnabled = false {
        didSet {
            guard oldValue != isContentCaptureEnabled else { return }
            #if DEBUG
            note(isContentCaptureEnabled
                 ? "Content capture switched ON — conversation and answers are being kept"
                 : "Content capture switched OFF")
            #endif
        }
    }

    /// The most recent traces, oldest first, bounded so a long session cannot grow without limit.
    private(set) var traces: [GenerateTrace] = []
    /// Session-level notes, including capture toggles and any recorder failure.
    private(set) var sessionNotes: [String] = []
    /// Set if recording itself ever failed. Surfaced in the export rather than hidden, so a thin
    /// report is never mistaken for a quiet session.
    private(set) var recorderFailure: String?

    static let maximumTraces = 40
    static let maximumCapturedCharacters = 200_000

    private var capturedCharacters = 0

    /// Reads the backend's decision comparisons for a diagnostics session (pipeline §15). Set by the
    /// session coordinator, which owns the provider; nil when there is no backend to ask.
    @ObservationIgnored
    var decisionRecordsFetcher: (@Sendable (String) async -> String?)?

    /// The decision comparisons for this session, as the backend's JSON, fetched at export time so
    /// they include every classification up to the moment of export. Nil whenever none are available.
    func fetchDecisionRecords() async -> String? {
        #if DEBUG
        guard let fetcher = decisionRecordsFetcher else { return nil }
        return await fetcher(sessionID.uuidString)
        #else
        return nil
        #endif
    }

    /// Limited-active for this session only: ask the backend to let accepted decisions shape requests.
    /// It has effect only when the backend operator allows per-session opt-in. Returns to off with
    /// every new session, like content capture.
    var isDecisionApplyRequested = false {
        didSet {
            guard oldValue != isDecisionApplyRequested else { return }
            #if DEBUG
            note(isDecisionApplyRequested ? "Jev decisions requested for this session" : "Jev decisions no longer requested")
            #endif
        }
    }

    func recordDecisionUse(requestID: UUID, status: String) {
        #if DEBUG
        update(requestID) { $0.decision = status }
        #endif
    }

    // MARK: - Session

    func startSession(appBuild: String, commit: String) {
        #if DEBUG
        sessionID = UUID()
        startedAt = Date()
        traces = []
        sessionNotes = []
        recorderFailure = nil
        capturedCharacters = 0
        // Off again for every new session. A capture turned on to chase one problem must not still
        // be running during the next interview.
        isContentCaptureEnabled = false
        isDecisionApplyRequested = false
        note("Session started · build \(appBuild) · commit \(commit)")
        #endif
    }

    func note(_ text: String) {
        #if DEBUG
        sessionNotes.append("[\(Self.stamp(Date()))] \(text)")
        if sessionNotes.count > 200 { sessionNotes.removeFirst(sessionNotes.count - 200) }
        #endif
    }

    // MARK: - A tap

    /// Records the outcome of a Generate tap, including the taps that produced no request.
    ///
    /// A rejected or debounced tap is exactly what a report needs to explain "I pressed it and
    /// nothing happened", so those are kept with their reason rather than dropped.
    func recordTap(
        requestID: UUID?,
        outcome: GenerateTrace.TapOutcome,
        reason: String?,
        at date: Date = Date()
    ) {
        #if DEBUG
        // Outcome and reason only — never transcript text. Lets a UI test or a device log show what a
        // Generate tap did when nothing appears on screen.
        Logger(subsystem: "talk.cointerview", category: "generate")
            .notice("[GenerateTap] outcome=\(String(describing: outcome), privacy: .public) reason=\(reason ?? "-", privacy: .public)")
        var trace = GenerateTrace(sessionID: sessionID, requestID: requestID ?? UUID())
        // The tap's own moment, not the recorder's: everything else on this trace is measured from
        // it, and stamping it here instead produced a "queued" duration that ran backwards.
        trace.tappedAt = date
        trace.outcome = outcome
        trace.outcomeReason = reason
        append(trace)
        #endif
    }

    /// What the snapshot held at the moment of the tap, and how much of the session it covers.
    func recordSnapshot(
        requestID: UUID,
        transcriptLineCount: Int,
        transcriptCharacters: Int,
        snapshot: DiscussionSnapshot,
        utterances: [GenerateTrace.Utterance],
        attachmentCount: Int,
        preparedAttachmentCount: Int
    ) {
        #if DEBUG
        update(requestID) { trace in
            trace.transcriptLineCount = transcriptLineCount
            trace.transcriptCharacters = transcriptCharacters
            trace.sentLineCount = snapshot.allLines.count
            trace.sentCharacters = snapshot.allLines.reduce(0) { $0 + $1.count }
            trace.backgroundLineCount = snapshot.background.count
            trace.newInputLineCount = snapshot.newLines.count
            trace.hasProvisionalLine = snapshot.provisional != nil
            trace.priorSuggestionCount = snapshot.priorSuggestions.count
            trace.noteCharacters = snapshot.note.count
            trace.attachmentCount = attachmentCount
            trace.preparedAttachmentCount = preparedAttachmentCount
            trace.utterances = utterances
            // Nothing is dropped for length on the device any more; if that ever changes this line
            // is what will say so in the report rather than leaving it to be inferred.
            trace.omitted = trace.transcriptLineCount > trace.sentLineCount
                ? "\(trace.transcriptLineCount - trace.sentLineCount) transcript line(s) not sent"
                : nil
            if self.isContentCaptureEnabled {
                trace.captured = GenerateTrace.Captured(
                    transcriptAtTap: utterances.map(\.text),
                    snapshotBackground: snapshot.background,
                    snapshotNewInput: snapshot.newInput,
                    snapshotProvisional: snapshot.provisional,
                    priorSuggestions: snapshot.priorSuggestions,
                    note: snapshot.note
                )
                self.chargeCapture(trace.captured?.characterCount ?? 0)
            }
        }
        #endif
    }

    /// The serialized request body, already redacted.
    func recordRequestBody(requestID: UUID, json: String) {
        #if DEBUG
        guard isContentCaptureEnabled else { return }
        update(requestID) { trace in
            trace.captured?.requestJSON = Redaction.redact(json)
            self.chargeCapture(json.count)
        }
        #endif
    }

    func recordQueued(requestID: UUID, at date: Date = Date()) {
        #if DEBUG
        update(requestID) { $0.queuedAt = date }
        #endif
    }

    func recordSent(requestID: UUID, at date: Date = Date()) {
        #if DEBUG
        update(requestID) { $0.sentAt = date }
        #endif
    }

    func recordFirstText(requestID: UUID, at date: Date = Date()) {
        #if DEBUG
        update(requestID) { if $0.firstTextAt == nil { $0.firstTextAt = date } }
        #endif
    }

    /// What actually served the request. **Never inferred from what was requested** — when the
    /// gateway does not say, this records "unknown", because a guess in a diagnostic is worse than
    /// a gap.
    func recordRoute(
        requestID: UUID,
        attempt: Int,
        gateway: String,
        requestedModel: String,
        resolvedModel: String?,
        servingProvider: String?,
        generationID: String?,
        backendVersion: String?
    ) {
        #if DEBUG
        update(requestID) { trace in
            trace.attempts.append(GenerateTrace.Attempt(
                number: attempt,
                gateway: gateway,
                requestedModel: requestedModel,
                actualModel: resolvedModel ?? "unknown",
                servingProvider: servingProvider?.isEmpty == false ? servingProvider! : "unknown",
                generationID: generationID
            ))
            if let backendVersion { trace.backendVersion = backendVersion }
        }
        #endif
    }

    func recordAttemptFailed(requestID: UUID, detail: String, fallingBackTo: String) {
        #if DEBUG
        update(requestID) { $0.attemptFailures.append("\(Redaction.redact(detail)) → \(fallingBackTo)") }
        #endif
    }

    func recordTitle(requestID: UUID, title: String) {
        #if DEBUG
        update(requestID) { $0.interpretedTitle = title }
        #endif
    }

    func recordAnswer(requestID: UUID, answerVersion: Int?, text: String, at date: Date = Date()) {
        #if DEBUG
        update(requestID) { trace in
            trace.completedAt = date
            trace.streamOutcome = .completed
            trace.answerVersion = answerVersion
            trace.answerCharacters = text.count
            if self.isContentCaptureEnabled {
                trace.captured?.answerText = text
                self.chargeCapture(text.count)
            }
        }
        #endif
    }

    func recordFailure(requestID: UUID, outcome: GenerateTrace.StreamOutcome, detail: String, httpStatus: Int?) {
        #if DEBUG
        update(requestID) { trace in
            trace.completedAt = Date()
            trace.streamOutcome = outcome
            trace.failureDetail = Redaction.redact(detail)
            trace.httpStatus = httpStatus
        }
        #endif
    }

    /// The provider messages, fetched from the backend's own bounded diagnostics store.
    func recordProviderMessages(requestID: UUID, messages: String) {
        #if DEBUG
        guard isContentCaptureEnabled else { return }
        update(requestID) { trace in
            trace.captured?.providerMessages = Redaction.redact(messages)
            self.chargeCapture(messages.count)
        }
        #endif
    }

    /// The user pressed "Mark a problem" on an answer.
    func markProblem(requestID: UUID?, note: String) {
        #if DEBUG
        guard let requestID else {
            self.note("Problem marked, with no request on screen: \(note)")
            return
        }
        update(requestID) { trace in
            trace.problemNote = note.isEmpty ? "(no note)" : note
            trace.markedAt = Date()
        }
        #endif
    }

    func clear() {
        #if DEBUG
        traces = []
        sessionNotes = []
        recorderFailure = nil
        capturedCharacters = 0
        note("Diagnostics cleared")
        #endif
    }

    var hasCapturedContent: Bool { traces.contains { $0.captured != nil } }
    var lastTrace: GenerateTrace? { traces.last }

    func trace(requestID: UUID) -> GenerateTrace? {
        traces.first { $0.requestID == requestID }
    }

    // MARK: - Internals

    private func append(_ trace: GenerateTrace) {
        traces.append(trace)
        if traces.count > Self.maximumTraces { traces.removeFirst(traces.count - Self.maximumTraces) }
    }

    /// Updating an unknown request is not an error worth interrupting anything for — a late event
    /// for a trace already evicted by the bound is ordinary. It is counted, not thrown.
    private func update(_ requestID: UUID, _ change: (inout GenerateTrace) -> Void) {
        guard let index = traces.firstIndex(where: { $0.requestID == requestID }) else { return }
        change(&traces[index])
    }

    /// Stops content capture growing without limit. When the budget is spent, capture stops and the
    /// report says so — it does not quietly keep the first half and imply the rest was empty.
    private func chargeCapture(_ characters: Int) {
        capturedCharacters += characters
        guard capturedCharacters > Self.maximumCapturedCharacters, isContentCaptureEnabled else { return }
        isContentCaptureEnabled = false
        note("Content capture stopped: the \(Self.maximumCapturedCharacters)-character budget was reached")
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}
