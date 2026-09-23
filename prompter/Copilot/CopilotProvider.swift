import Foundation

// MARK: - Requests

/// What the detector is asked. Compact by construction (§4): a bounded window of recent conversation,
/// the new speech, and the questions already on screen — never the whole transcript or the documents.
struct ClassificationRequest: Sendable, Encodable {
    struct KnownQuestion: Sendable, Encodable {
        let id: String
        let text: String
        /// Whether an answer has been generated for it. Lets a decision tell a pending question from
        /// an answered one; nil from callers that do not know.
        var answered: Bool? = nil
    }

    /// One utterance that makes up `newSpeech`, by identity and revision — never its text.
    struct UtteranceRef: Sendable, Encodable, Equatable {
        let id: String
        let revision: Int
        let isFinal: Bool
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

    // Identity for the backend's decision comparison (docs/CO_INTERVIEW_AI_PIPELINE.md §15). All
    // optional and omitted when nil, so an older backend receives exactly the body it always did.
    // None of these change what the detector is asked or what it answers.

    /// The interview session, so a newer snapshot can supersede an older one.
    var sessionID: String? = nil
    /// This classification, so its verdict and its comparison can be matched up afterwards.
    var snapshotID: String? = nil
    /// The utterances classified, with their revisions, so a verdict about since-corrected speech is
    /// recognised as stale.
    var utterances: [UtteranceRef]? = nil
    /// How many answers had been requested when the snapshot was taken; a verdict from before a later
    /// generation is stale.
    var generationEpoch: Int? = nil
    /// Debug-only diagnostics correlation, and the same content opt-in as the answer path.
    var diagnosticsSessionID: String? = nil
    var captureContent: Bool? = nil
}

/// What the generator is given (§5). Whole documents are never sent — only the passages retrieval
/// selected, with their identifiers and versions.
struct AnswerRequest: Sendable, Encodable {
    struct ImageAttachment: Sendable, Encodable, Equatable {
        let mime: String
        /// Base64, without a data: prefix — the backend builds the data URL.
        let data: String
    }

    struct Passage: Sendable, Encodable {
        let id: String
        let documentTitle: String
        let documentVersion: String
        let locator: String
        let text: String
    }

    let question: String
    let projectInstructions: String
    /// A note the speaker typed for this session, sent as reference material. Empty when there is
    /// none. **Never** an instruction channel: the backend frames it as reference, so uploaded or
    /// typed content cannot override the answer rules.
    var extraContext: String = ""
    /// Image attachments, already downscaled and JPEG-encoded by the app.
    ///
    /// Sent **only** when the backend reports the answer model accepts image input; otherwise the
    /// backend replies with a `notice` saying they were not sent, which the screen shows. An
    /// attachment is never dropped in silence.
    var images: [ImageAttachment] = []
    /// The whole conversation this request was snapshotted with, oldest first.
    ///
    /// Not a window. A twelve-line cut here meant a fact stated earlier in the same session was
    /// silently absent from the request that asked about it.
    let recentConversation: [String]
    /// What this request is being asked to resolve: speech not covered by an earlier request,
    /// oldest first, with the still-in-progress utterance last when there is one.
    ///
    /// Sent apart from `recentConversation` because "what is new" and "what was said" are different
    /// questions. Everything in here also appears, in order, in `recentConversation`.
    var newInput: [String] = []
    /// Whether the last element of `newInput` was still being spoken when the request was made.
    var lastNewInputIsProvisional: Bool = false
    /// Answers already suggested this session, oldest first, labelled to the model as its own
    /// suggestions — never as something the speaker said about themselves.
    var priorSuggestions: [String] = []
    /// A follow-up the speaker tapped rather than said ("give an example"). Never speech, so it is
    /// never presented to the model as something the speaker uttered.
    var requestedAction: String?
    /// The question and answer the tapped action refers to, so it is applied to the page the chip
    /// was on rather than to whatever was answered most recently.
    var actionParentQuestion: String?
    var actionParentAnswer: String?
    var actionParentAnswerVersion: Int?
    let passages: [Passage]
    let language: String
    let targetWordRange: [Int]
    /// Used only for prompt-cache affinity on the backend; never a credential.
    let projectID: String

    /// Debug-only correlation ids, so one Generate tap can be followed from the phone into the
    /// backend's own log and back. **Not credentials and not content** — two UUIDs the backend
    /// echoes; it stores nothing extra unless `captureProviderMessages` is also set and the operator
    /// has switched diagnostics on server-side.
    var diagnosticsSessionID: String?
    var diagnosticsRequestID: String?
    /// Asks the backend to keep this request's assembled provider messages briefly, so the app can
    /// fetch exactly what the model was sent. Only ever true in a Debug build with content capture
    /// switched on for the session.
    var captureProviderMessages: Bool = false
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
    /// The backend build that served this, as it reported itself. "unknown" when it did not.
    var backendVersion: String = "unknown"

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
    /// Something the backend wants the user told — for example that attachments were not sent
    /// because the configured model reads text only. Never a failure; the answer still arrives.
    case notice(String)
    /// Source ids the model cited, validated by the backend against the passages it was sent.
    case sources([String])
    /// What the model understood the request to be, as a short phrase for the entry's label.
    ///
    /// It arrives before any answer text. The client used to name the entry itself, by joining
    /// transcript fragments, which is how a three-way comparison ended up titled "And Java 7."
    case title(String)
    /// The generation finished normally.
    case completed(usageOutputTokens: Int?)
    /// Generation stopped after text had already been shown. What arrived stays readable.
    case incomplete(reason: String)
}

extension CopilotProviding {
    /// Most providers keep nothing: there is no backend to ask.
    func diagnosticsProviderMessages(requestID: String) async -> String? { nil }
    func decisionRecords(diagnosticsSessionID: String) async -> String? { nil }
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
    /// Whether the configured answer model accepts images, from the backend's verified registry.
    /// Asked, never assumed: the speed profile's model is text-only while balanced and smart are not.
    var answer_accepts_images: Bool = false

    var summary: String {
        let route = answer_provider_order.isEmpty ? "" : " via \(answer_provider_order.joined(separator: " → "))"
        return "\(text_provider) · \(profile) · \(answer_model_id)\(route)"
    }
}

protocol CopilotProviding: Sendable {
    /// Debug-only: the provider messages the backend kept for this request, when it kept any.
    ///
    /// Returns nil whenever diagnostics are not enabled server-side, the request did not ask, or the
    /// trace has expired — all ordinary, none of them an error worth surfacing to a reader.
    func diagnosticsProviderMessages(requestID: String) async -> String?

    /// Debug-only: the backend's decision comparisons for one diagnostics session, as JSON — the
    /// existing detector's verdict beside Jev's for each classification (pipeline §15). Nil when
    /// decisions are off on the backend or nothing was recorded; never an error worth surfacing.
    func decisionRecords(diagnosticsSessionID: String) async -> String?

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

    /// Fetches the provider messages the backend kept for this request, if it kept any.
    ///
    /// Every failure is silent on purpose: diagnostics being unavailable is the normal case, and an
    /// error here must never reach a reader who is in the middle of an interview.
    func diagnosticsProviderMessages(requestID: String) async -> String? {
        guard let encoded = requestID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        var request = URLRequest(url: baseURL.appending(path: "/v1/copilot/diagnostics/\(encoded)"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return payload["provider_messages"] as? String
    }

    /// Fetches the decision comparisons the backend recorded for this diagnostics session.
    ///
    /// Silent on every failure, like `diagnosticsProviderMessages`: decisions off (404), an older
    /// backend without the route, or no network are all ordinary.
    func decisionRecords(diagnosticsSessionID: String) async -> String? {
        var components = URLComponents(url: baseURL.appending(path: "v1/copilot/diagnostics/decisions"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "session", value: diagnosticsSessionID)]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
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
                    #if DEBUG
                    // The bytes actually sent, recorded before the request leaves. Redacted inside
                    // the recorder; image payloads are replaced rather than stored.
                    if request.captureProviderMessages,
                       let id = request.diagnosticsRequestID, let uuid = UUID(uuidString: id),
                       let json = String(data: body, encoding: .utf8) {
                        await MainActor.run {
                            GenerateDiagnostics.shared.recordRequestBody(requestID: uuid, json: json)
                        }
                    }
                    #endif
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
                                generationID: event["generation_id"] as? String,
                                backendVersion: event["backend_version"] as? String ?? "unknown"
                            )))
                        case "attempt_failed":
                            continuation.yield(.attemptFailed(
                                detail: event["detail"] as? String ?? "attempt failed",
                                fallingBackTo: event["falling_back_to"] as? String ?? ""
                            ))
                        case "notice":
                            if let message = event["message"] as? String, !message.isEmpty {
                                continuation.yield(.notice(message))
                            }
                        case "sources":
                            continuation.yield(.sources(event["ids"] as? [String] ?? []))
                        case "title":
                            if let text = event["text"] as? String, !text.isEmpty {
                                continuation.yield(.title(text))
                            }
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
