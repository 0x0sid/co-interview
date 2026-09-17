import Foundation

// MARK: - Requests

/// What the detector is asked. Compact by construction (§4): a bounded window of recent conversation,
/// the new speech, and the questions already on screen — never the whole transcript or the documents.
struct ClassificationRequest: Sendable, Encodable {
    struct KnownQuestion: Sendable, Encodable {
        let id: String
        let text: String
    }

    /// New speech since the last classification.
    let newSpeech: String
    /// Recent confirmed conversation, oldest first.
    let recentConversation: [String]
    /// The answer the user is currently reading aloud, if any, so the detector can tell a genuine
    /// follow-up from the user reading a suggestion. **Text evidence, not speaker identification.**
    let activeAnswerText: String?
    let knownQuestions: [KnownQuestion]
    let language: String
}

/// What the generator is given (§5). Whole documents are never sent — only the passages retrieval
/// selected, with their identifiers and versions.
struct AnswerRequest: Sendable, Encodable {
    struct Passage: Sendable, Encodable {
        let id: String
        let documentTitle: String
        let documentVersion: String
        let locator: String
        let text: String
    }

    let question: String
    let projectInstructions: String
    let recentConversation: [String]
    let passages: [Passage]
    let language: String
    let targetWordRange: [Int]
    /// Used only for prompt-cache affinity on the backend; never a credential.
    let projectID: String
}

// MARK: - Streaming events

/// What actually served an answer, as reported by the backend.
///
/// Recorded, never inferred: when the gateway does not say which provider served the request, this
/// carries "unknown" rather than the first requested preference.
struct AnswerRoute: Sendable, Equatable {
    var attempt: Int = 1
    var gateway: String = ""
    var requestedModel: String = ""
    var resolvedModel: String?
    var servingProvider: String = "unknown"
    var generationID: String?

    var summary: String {
        let model = resolvedModel ?? requestedModel
        return attempt > 1
            ? "\(model) via \(servingProvider) (attempt \(attempt))"
            : "\(model) via \(servingProvider)"
    }
}

enum AnswerStreamEvent: Sendable, Equatable {
    /// Newly generated text, in order.
    case delta(String)
    /// The route that served (or is serving) this answer.
    case route(AnswerRoute)
    /// An attempt failed before any visible text and the backend is trying the fallback route.
    case attemptFailed(detail: String, fallingBackTo: String)
    /// Source ids the model cited, validated by the backend against the passages it was sent.
    case sources([String])
    /// The generation finished normally.
    case completed(usageOutputTokens: Int?)
    /// Generation stopped after text had already been shown. What arrived stays readable.
    case incomplete(reason: String)
}

enum CopilotProviderError: Error, Sendable, Equatable {
    /// No backend configured. **The app must show an honest unavailable state; it must not fabricate.**
    case unconfigured(String)
    case unauthorized
    case rateLimited
    case timedOut
    case cancelled
    case transport(String)
    case provider(String)

    var userMessage: String {
        switch self {
        case .unconfigured: "Answer suggestions are not configured"
        case .unauthorized: "Backend rejected this app's credentials"
        case .rateLimited: "Too many requests — try again in a moment"
        case .timedOut: "The request timed out"
        case .cancelled: "Cancelled"
        case .transport(let detail): "Network problem: \(detail)"
        case .provider(let detail): "Provider error: \(detail)"
        }
    }
}

// MARK: - Provider

/// The backend's non-secret view of its own configuration. **Never contains a credential** — the
/// backend has no endpoint that returns one.
struct CopilotBackendConfiguration: Sendable, Equatable, Decodable {
    var text_provider: String = ""
    var profile: String = ""
    var detection_model_id: String = ""
    var answer_model_id: String = ""
    var answer_provider_order: [String] = []
    var fallback_model_id: String = ""
    var allow_fallbacks: Bool = true
    var reasoning_enabled: Bool = false
    var provider_configured: Bool = false
    var is_fake: Bool = false

    var summary: String {
        let route = answer_provider_order.isEmpty ? "" : " via \(answer_provider_order.joined(separator: " → "))"
        return "\(text_provider) · \(profile) · \(answer_model_id)\(route)"
    }
}

protocol CopilotProviding: Sendable {
    /// Human-readable label for what actually served the request, shown in the UI ("gpt-5.4-nano",
    /// "development fake").
    var detectionModelLabel: String { get }
    var answerModelLabel: String { get }
    /// True only for the development fake, so the UI can mark generated text as not a real answer.
    var isDevelopmentFake: Bool { get }

    func classify(_ request: ClassificationRequest) async throws -> DetectionResult
    func generate(_ request: AnswerRequest) -> AsyncThrowingStream<AnswerStreamEvent, Error>
    /// The backend's active configuration, for display. `nil` when the provider has none to report.
    func configuration() async -> CopilotBackendConfiguration?
}

extension CopilotProviding {
    func configuration() async -> CopilotBackendConfiguration? { nil }
}

// MARK: - Unconfigured

/// Used when no backend is configured. Every call fails honestly; nothing is invented (§9).
struct UnconfiguredCopilotProvider: CopilotProviding {
    let reason: String
    var detectionModelLabel: String { "unavailable" }
    var answerModelLabel: String { "unavailable" }
    var isDevelopmentFake: Bool { false }

    func classify(_ request: ClassificationRequest) async throws -> DetectionResult {
        throw CopilotProviderError.unconfigured(reason)
    }

    func generate(_ request: AnswerRequest) -> AsyncThrowingStream<AnswerStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: CopilotProviderError.unconfigured(reason))
        }
    }
}

// MARK: - Backend client

/// Talks to the Co-Interview backend, which holds the provider key server-side (`backend/`).
///
/// The app carries a backend URL and, in development, a bearer token entered by the developer. **No
/// permanent provider credential is ever compiled into the app.**
final class BackendCopilotProvider: CopilotProviding, @unchecked Sendable {
    private let baseURL: URL
    private let token: String
    private let session: URLSession
    let detectionModelLabel: String
    let answerModelLabel: String
    let isDevelopmentFake = false

    init(baseURL: URL, token: String, detectionModelLabel: String, answerModelLabel: String, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.detectionModelLabel = detectionModelLabel
        self.answerModelLabel = answerModelLabel
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        self.session = session ?? URLSession(configuration: configuration)
    }

    private func makeRequest(path: String, body: Data) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return request
    }

    /// Reads the backend's non-secret configuration so the app can show which route is active.
    func configuration() async -> CopilotBackendConfiguration? {
        var request = URLRequest(url: baseURL.appending(path: "v1/copilot/config"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(CopilotBackendConfiguration.self, from: data)
    }

    private struct ClassificationPayload: Decodable {
        let kind: String
        let question_text: String?
        let related_question_id: String?
        let confidence: Double?
        let is_fake: Bool?
    }

    func classify(_ request: ClassificationRequest) async throws -> DetectionResult {
        let body = try JSONEncoder().encode(request)
        let (data, response) = try await session.data(for: makeRequest(path: "v1/copilot/classify", body: body))
        try Self.check(response: response, data: data)
        let payload = try JSONDecoder().decode(ClassificationPayload.self, from: data)
        return DetectionResult(
            kind: DetectionKind(rawValue: payload.kind) ?? .none,
            questionText: payload.question_text ?? "",
            relatedCardID: payload.related_question_id.flatMap(UUID.init(uuidString:)),
            confidence: payload.confidence ?? 0,
            isDevelopmentFake: payload.is_fake ?? false
        )
    }

    func generate(_ request: AnswerRequest) -> AsyncThrowingStream<AnswerStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try JSONEncoder().encode(request)
                    let (bytes, response) = try await session.bytes(for: makeRequest(path: "v1/copilot/answer", body: body))
                    try Self.check(response: response, data: nil)
                    // Server-sent events: `data:` lines carrying one JSON object each.
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        guard !json.isEmpty, json != "[DONE]", let data = json.data(using: .utf8) else { continue }
                        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = event["type"] as? String else { continue }
                        switch type {
                        case "delta":
                            if let text = event["text"] as? String, !text.isEmpty {
                                continuation.yield(.delta(text))
                            }
                        case "attempt":
                            continuation.yield(.route(AnswerRoute(
                                attempt: event["attempt"] as? Int ?? 1,
                                gateway: event["gateway"] as? String ?? "",
                                requestedModel: event["requested_model"] as? String ?? "",
                                resolvedModel: event["resolved_model"] as? String,
                                servingProvider: event["serving_provider"] as? String ?? "unknown",
                                generationID: event["generation_id"] as? String
                            )))
                        case "attempt_failed":
                            continuation.yield(.attemptFailed(
                                detail: event["detail"] as? String ?? "attempt failed",
                                fallingBackTo: event["falling_back_to"] as? String ?? ""
                            ))
                        case "sources":
                            continuation.yield(.sources(event["ids"] as? [String] ?? []))
                        case "done":
                            continuation.yield(.completed(usageOutputTokens: event["output_tokens"] as? Int))
                            continuation.finish()
                            return
                        case "error":
                            // `incomplete: true` means text was already delivered and the answer
                            // stopped part-way. The coordinator keeps that text readable.
                            if event["incomplete"] as? Bool == true {
                                continuation.yield(.incomplete(reason: event["message"] as? String ?? "generation stopped"))
                                continuation.finish()
                                return
                            }
                            throw CopilotProviderError.provider(event["message"] as? String ?? "unknown")
                        default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CopilotProviderError.cancelled)
                } catch let error as CopilotProviderError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: CopilotProviderError.transport(error.localizedDescription))
                }
            }
            // Cancelling generation cancels only this request. It never touches capture (§8).
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func check(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw CopilotProviderError.unauthorized
        case 408, 504: throw CopilotProviderError.timedOut
        case 429: throw CopilotProviderError.rateLimited
        case 503:
            let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw CopilotProviderError.unconfigured(detail.contains("provider_unconfigured")
                ? "The backend has no provider credentials configured"
                : "The backend is unavailable")
        default:
            throw CopilotProviderError.provider("HTTP \(http.statusCode)")
        }
    }
}
