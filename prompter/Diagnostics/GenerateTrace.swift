import Foundation

/// Everything one Generate tap did, from the tap to the answer on screen.
///
/// Two halves, deliberately separated. The **always-recorded** half is identities, counts, timings
/// and outcomes: enough to say where a request went and what happened to it, and it contains no
/// conversation. The **captured** half is the text itself, and exists only when content capture was
/// switched on for the session.
struct GenerateTrace: Identifiable, Sendable {
    enum TapOutcome: String, Sendable {
        case accepted
        case queued
        case debounced
        case rejectedNothingToAnswer
        case rejectedNothingNew
        case rejectedQueueFull
    }

    enum StreamOutcome: String, Sendable {
        case running
        case completed
        case failed
        case timedOut
        case cancelled
    }

    /// One transcript utterance as it stood at the tap. Identity and revision are what prove a
    /// partial and its finalized form are one line rather than two.
    struct Utterance: Sendable {
        let id: UUID
        let revision: Int
        let isFinal: Bool
        /// Whether an earlier accepted request already covered this line.
        let isCovered: Bool
        let characterCount: Int
        /// Only populated when content capture is on.
        let text: String
    }

    struct Attempt: Sendable {
        let number: Int
        let gateway: String
        let requestedModel: String
        /// What actually served it, or "unknown". Never copied from `requestedModel`.
        let actualModel: String
        /// The serving provider as reported by the gateway, or "unknown".
        let servingProvider: String
        let generationID: String?
    }

    /// The text of the conversation and the answer. Present only with content capture on.
    struct Captured: Sendable {
        var transcriptAtTap: [String]
        var snapshotBackground: [String]
        var snapshotNewInput: [String]
        var snapshotProvisional: String?
        var priorSuggestions: [String]
        var note: String
        var requestJSON: String?
        var providerMessages: String?
        var answerText: String?

        var characterCount: Int {
            transcriptAtTap.reduce(0) { $0 + $1.count }
                + snapshotBackground.reduce(0) { $0 + $1.count }
                + snapshotNewInput.reduce(0) { $0 + $1.count }
                + (snapshotProvisional?.count ?? 0)
                + priorSuggestions.reduce(0) { $0 + $1.count }
                + note.count
        }
    }

    var id: UUID { requestID }

    let sessionID: UUID
    let requestID: UUID

    // Identity of the software under test.
    var appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    var appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    var commit = Bundle.main.infoDictionary?["CoInterviewCommit"] as? String ?? "unknown"
    var backendVersion: String?

    // The tap.
    var tappedAt: Date?
    var outcome: TapOutcome = .accepted
    var outcomeReason: String?

    // What the snapshot held.
    var transcriptLineCount = 0
    var transcriptCharacters = 0
    var sentLineCount = 0
    var sentCharacters = 0
    var backgroundLineCount = 0
    var newInputLineCount = 0
    var hasProvisionalLine = false
    var priorSuggestionCount = 0
    var noteCharacters = 0
    var attachmentCount = 0
    var preparedAttachmentCount = 0
    var utterances: [Utterance] = []
    /// Why anything was left out, when anything was.
    var omitted: String?

    // The request.
    var queuedAt: Date?
    var sentAt: Date?
    var firstTextAt: Date?
    var completedAt: Date?
    var attempts: [Attempt] = []
    var attemptFailures: [String] = []
    var httpStatus: Int?
    var streamOutcome: StreamOutcome = .running
    var failureDetail: String?

    // The result.
    var interpretedTitle: String?
    var answerVersion: Int?
    var answerCharacters = 0

    // The report.
    /// Whether a focused decision shaped this request, and why or why not ("applied: continuation",
    /// "shadow: … not applied", "stale: …", "decision still in flight"). Never content.
    var decision: String?
    var problemNote: String?
    var markedAt: Date?

    var captured: Captured?

    // MARK: Derived timings, in milliseconds

    private func milliseconds(_ from: Date?, _ to: Date?) -> Int? {
        guard let from, let to else { return nil }
        let interval = to.timeIntervalSince(from)
        // A negative duration means the two ends were stamped from different clocks — which happens
        // when a test injects one. A report that prints it as a number invites someone to believe
        // it, so it is reported as absent instead.
        guard interval >= 0 else { return nil }
        return Int(interval * 1000)
    }

    var queuedMs: Int? { milliseconds(tappedAt, queuedAt ?? sentAt) }
    var preparingMs: Int? { milliseconds(queuedAt, sentAt) }
    var toFirstTextMs: Int? { milliseconds(sentAt, firstTextAt) }
    var toCompleteMs: Int? { milliseconds(sentAt, completedAt) }
    var totalMs: Int? { milliseconds(tappedAt, completedAt) }
}

/// Removes anything credential-shaped from text on its way into a diagnostic.
///
/// Applied at every entry point that takes free text, rather than trusted to the caller: a report is
/// shared by definition, and the one place a token must never appear is the file someone sends to
/// someone else. Image bytes are never passed in at all — attachments are recorded as identity,
/// size and preparation state, which is what a lost-attachment question actually needs.
enum Redaction {
    private static let patterns: [(String, String)] = [
        // Bearer tokens and authorization headers, in any casing.
        ("(?i)(authorization\\s*:\\s*)(bearer\\s+)?[A-Za-z0-9._\\-]+", "$1***REDACTED***"),
        ("(?i)bearer\\s+[A-Za-z0-9._\\-]{8,}", "Bearer ***REDACTED***"),
        // Common key shapes.
        ("(?i)(sk-[A-Za-z0-9\\-]{8,})", "***REDACTED***"),
        ("(?i)(\"?(api[_-]?key|token|secret|password)\"?\\s*[:=]\\s*\"?)[^\"\\s,}]+", "$1***REDACTED***"),
        // Inline image payloads, if one ever reached here by mistake.
        ("data:image/[a-zA-Z]+;base64,[A-Za-z0-9+/=]+", "data:image/...;base64,***IMAGE BYTES EXCLUDED***"),
        ("(?i)(\"data\"\\s*:\\s*\")[A-Za-z0-9+/=]{100,}", "$1***IMAGE BYTES EXCLUDED***"),
    ]

    static func redact(_ text: String) -> String {
        var output = text
        for (pattern, replacement) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            output = expression.stringByReplacingMatches(
                in: output,
                range: NSRange(output.startIndex..., in: output),
                withTemplate: replacement
            )
        }
        return output
    }
}
