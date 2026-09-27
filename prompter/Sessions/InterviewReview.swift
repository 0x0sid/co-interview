import Foundation

/// An interview's score, as the backend returns it (`backend/review.mjs`).
///
/// **A score, not a report** (owner decision, 2026-09-27). Reviews saved before then also carried a
/// narrative summary; those keys are simply not decoded, so an old review still opens — and shows its
/// score — without rewriting its file.
struct InterviewReviewReport: Codable, Equatable, Sendable {
    struct Scores: Codable, Equatable, Sendable {
        let relevance: Int
        let clarity: Int
        let structure: Int
        let examples: Int

        /// The mean of the four, to one decimal.
        var overall: Double { (Double(relevance + clarity + structure + examples) / 4 * 10).rounded() / 10 }
    }

    /// A short quote from the candidate's marked lines per criterion; empty when none was verifiable.
    struct Evidence: Codable, Equatable, Sendable {
        let relevance: String
        let clarity: String
        let structure: String
        let examples: String
    }

    let version: String
    let attributed: Bool
    /// Nil when the evidence does not support a score.
    let scores: Scores?
    /// Sent by the backend since 2026-09-27; computed from `scores` for older reviews.
    let overall: Double?
    let evidence: Evidence?
    let score_note: String
    let disclaimer: String

    init(version: String, attributed: Bool, scores: Scores?, overall: Double? = nil, evidence: Evidence? = nil,
         score_note: String, disclaimer: String) {
        self.version = version
        self.attributed = attributed
        self.scores = scores
        self.overall = overall
        self.evidence = evidence
        self.score_note = score_note
        self.disclaimer = disclaimer
    }

    var overallScore: Double? { overall ?? scores?.overall }
}

/// A saved report with the transcript snapshot it covers. Stored beside — never over — the
/// interview: its own file, so the transcript is never rewritten.
struct InterviewReviewRecord: Codable, Equatable, Sendable {
    let sessionID: UUID
    let createdAt: Date
    /// How many transcript lines the report covered, and the interview's last activity then. If the
    /// interview has continued since, the report is marked as covering an earlier snapshot.
    let sourceLineCount: Int
    let sourceLastActivity: Date
    /// The lines (by order) the candidate marked as theirs.
    let candidateLineOrders: [Int]
    let report: InterviewReviewReport

    func coversEarlierSnapshot(of session: InterviewSessionRecord) -> Bool {
        TranscriptExport.lines(of: session).count != sourceLineCount || session.lastActivityAt > sourceLastActivity
    }
}

/// Reviews on disk: Application Support/Reviews/<session id>.json.
struct InterviewReviewStore: Sendable {
    var folder: URL

    static let standard = InterviewReviewStore(folder: URL.applicationSupportDirectory.appending(path: "Reviews"))

    private func url(_ sessionID: UUID) -> URL { folder.appending(path: "\(sessionID.uuidString).json") }

    func load(_ sessionID: UUID) -> InterviewReviewRecord? {
        guard let data = try? Data(contentsOf: url(sessionID)) else { return nil }
        // Default (precise) date coding: ISO-8601 drops fractional seconds, and the snapshot check
        // compares the interview's last activity exactly.
        return try? JSONDecoder().decode(InterviewReviewRecord.self, from: data)
    }

    func save(_ record: InterviewReviewRecord) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: url(record.sessionID), options: .atomic)
    }

    /// With the interview: a deleted interview leaves no report behind.
    func delete(_ sessionID: UUID) {
        try? FileManager.default.removeItem(at: url(sessionID))
    }
}

/// Asks the backend for a score. Pro only; authenticated like every other request.
enum InterviewReviewClient {
    /// Mirrors `MIN_SCORED_LINES` / `MIN_SCORED_WORDS` in `backend/review.mjs`: less marked speech than
    /// this cannot be scored, so the app says so instead of sending a request.
    static let minimumMarkedLines = 3
    static let minimumMarkedWords = 60

    static func canScore(markedLines: [String]) -> Bool {
        let words = markedLines.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count }
        return markedLines.count >= minimumMarkedLines && words >= minimumMarkedWords
    }

    /// Three different situations, each with its own message and remedy.
    enum Failure: Error, Equatable {
        /// The server says this needs Pro (none, or it has expired).
        case proRequired
        /// Neverblank's service could not be reached, or does not offer reviews yet.
        case backendUnavailable
        /// The service answered but the review could not be produced; Retry may work.
        case generationFailed
    }

    struct Line: Encodable { let text: String; let candidate: Bool }
    struct Body: Encodable { let title: String; let language: String; let lines: [Line] }

    static func request(_ body: Body, configuration: ProviderConfiguration = .resolve(),
                        session: URLSession = .shared) async throws -> InterviewReviewReport {
        guard case .backend(let url) = configuration.availability else { throw Failure.backendUnavailable }
        var request = URLRequest(url: url.appending(path: "v1/copilot/review"))
        request.httpMethod = "POST"
        request.timeoutInterval = 75
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.backendUnavailable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            guard let report = try? JSONDecoder().decode(InterviewReviewReport.self, from: data) else { throw Failure.generationFailed }
            return report
        case 402: throw Failure.proRequired
        // Not reachable, no such route (an older service), or reviews not configured there.
        case 0, 404, 503: throw Failure.backendUnavailable
        default: throw Failure.generationFailed
        }
    }
}
