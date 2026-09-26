import Foundation

/// Summary & feedback for one saved interview, as the backend returns it (`backend/review.mjs`).
struct InterviewReviewReport: Codable, Equatable, Sendable {
    struct Strength: Codable, Equatable, Sendable { let point: String; let evidence: String }
    struct Improvement: Codable, Equatable, Sendable { let point: String; let example: String }
    struct Scores: Codable, Equatable, Sendable {
        let relevance: Int
        let clarity: Int
        let structure: Int
        let examples: Int
    }

    let version: String
    let attributed: Bool
    let topics: [String]
    let questions: [String]
    let key_points: [String]
    let strengths: [Strength]
    let improvements: [Improvement]
    let practice_questions: [String]
    /// Nil when the evidence does not support a score.
    let scores: Scores?
    let score_note: String
    let disclaimer: String
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

/// Asks the backend for a review. Pro only; authenticated like every other request.
enum InterviewReviewClient {
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
