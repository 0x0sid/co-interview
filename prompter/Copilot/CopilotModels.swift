import Foundation

/// Identifiers are **application-owned**, never derived from provider output or transcript text, so a
/// repeated or revised transcript event can never create a second identity for the same speech
/// (docs/CO_INTERVIEW_AI_PIPELINE.md §3).
typealias UtteranceID = UUID
typealias QuestionCardID = UUID
typealias AnswerVersionID = UUID
typealias InterviewSessionID = UUID

/// One stretch of speech heard by the microphone.
///
/// **This is not speaker identification.** `overlapsReading` records only that the words matched the
/// answer the user is currently reading, which is evidence about *text*, not about who spoke
/// (§5.3 of the copilot architecture). A legitimate follow-up question that repeats answer vocabulary
/// can overlap too, which is why overlap alone never suppresses a card — it is one input to the
/// detector, which also sees the active answer text.
struct Utterance: Identifiable, Equatable, Sendable {
    let id: UtteranceID
    /// Normalized-for-display text as last reported by the transcriber.
    var text: String
    /// True once the transcriber finalized this utterance; volatile text is still subject to revision.
    var isFinal: Bool
    /// Transcript-clock seconds (the same clock `TranscriptDelta.timestamp` uses).
    var startTime: TimeInterval
    var endTime: TimeInterval
    /// How many times volatile revisions rewrote this utterance before it finalized. Diagnostics only.
    var revision: Int
    var overlapsReading: Bool

    var wordCount: Int { Tokenizer.normalize(text).count }
}

/// What the detector concluded about the newest speech.
enum DetectionKind: String, Codable, Sendable, Equatable {
    /// Nothing that calls for an answer.
    case none
    /// A question or request that has started but is not finished being asked.
    case incomplete
    /// A new, complete question or request.
    case newQuestion
    /// More of, or a correction to, a question that already has a card.
    case continuation
}

struct DetectionResult: Equatable, Sendable {
    var kind: DetectionKind
    /// The question as the detector would put it to the model. Empty for `.none`.
    var questionText: String
    /// Set only for `.continuation`, and only to a card the application supplied.
    var relatedCardID: QuestionCardID?
    var confidence: Double
    var isDevelopmentFake: Bool = false
}

/// A source passage that supported an answer.
struct SourceReference: Identifiable, Equatable, Sendable {
    let id: String              // stable passage identifier, e.g. "cv#3"
    let documentTitle: String
    let documentVersion: String
    let locator: String         // "p. 2", "§ Experience"
    let excerpt: String
}

/// One generated suggestion for one question. **Completed text is immutable** (§7).
struct AnswerVersion: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case queued
        case streaming
        case complete
        case failed(String)
        case cancelled
        /// Replaced by a newer version for the same card before it finished.
        case superseded
    }

    let id: AnswerVersionID
    let cardID: QuestionCardID
    let number: Int
    var status: Status = .queued
    /// Whole sentences committed so far. Never rewritten — only appended to.
    var committedText: String = ""
    /// The tail still being written. Preview only; never handed to the reader.
    var pendingText: String = ""
    /// Immutable reading segments frozen out of `committedText` (§7 fallback).
    var readableSegments: [String] = []
    var sources: [SourceReference] = []
    var modelLabel: String = ""
    /// What actually served this version, once the backend reports it.
    var route: AnswerRoute?
    /// Set when generation stopped after text was already visible: the text stays readable and the
    /// card offers a retry, which creates a **new** version rather than replacing this one.
    var incompleteReason: String?
    var isDevelopmentFake: Bool = false
    var createdAt: Date = .now
    var firstDeltaAt: Date?
    var firstSentenceAt: Date?
    var completedAt: Date?

    var fullText: String { committedText + pendingText }
    var hasReadableText: Bool { !readableSegments.isEmpty }
    var isTerminal: Bool {
        switch status {
        case .complete, .failed, .cancelled, .superseded: true
        case .queued, .streaming: false
        }
    }
}

/// A detected question and everything generated for it.
struct QuestionCard: Identifiable, Equatable, Sendable {
    let id: QuestionCardID
    let sequence: Int
    var questionText: String
    enum Origin: String, Sendable { case detected, manual, typed }
    let origin: Origin
    /// The utterances this card was created from — used to keep card creation idempotent.
    var sourceUtteranceIDs: [UtteranceID]
    var versions: [AnswerVersion] = []
    var selectedVersionID: AnswerVersionID?
    /// Which frozen segment of the selected version is being read.
    var activeSegmentIndex: Int = 0
    /// Reading (voice-following) pause is per card and is **not** a listening pause.
    var isFollowingPaused: Bool = false
    var createdAt: Date = .now

    var selectedVersion: AnswerVersion? {
        guard let selectedVersionID else { return versions.last }
        return versions.first { $0.id == selectedVersionID }
    }

    var latestVersion: AnswerVersion? { versions.last }
}

/// Whether the microphone pipeline is actually running. Shown to the user as-is: the app never claims
/// to be listening when it is not (§3 — no claim of operation through suspension, calls, revoked
/// permission or audio interruptions).
enum ListeningState: Equatable, Sendable {
    case idle
    case starting
    case listening
    /// The user pressed pause. New interview speech is not processed.
    case pausedByUser
    /// An audio-session interruption (call, another app). Recovery is attempted where the system says it is safe.
    case interrupted
    case permissionDenied
    case failed(String)

    var isActive: Bool { self == .listening }

    var label: String {
        switch self {
        case .idle: "Not listening"
        case .starting: "Starting…"
        case .listening: "Listening"
        case .pausedByUser: "Listening paused"
        case .interrupted: "Interrupted"
        case .permissionDenied: "Microphone access denied"
        case .failed(let reason): "Audio error: \(reason)"
        }
    }
}

enum CopilotSessionState: String, Sendable {
    case active
    case ended
}

/// What an answer asked for instead of answering, as the model reported it.
enum AnswerNeed: String, Sendable, Equatable {
    /// A personal detail the note, instructions and documents do not contain.
    case context
    /// A clearer question: the request could not be read one way.
    case clarification
}
