import Foundation

/// What the backend says this installation may do (`GET /v1/access`). The server is authoritative:
/// the app uses this to decide what to *offer*, and every paid request is checked again server-side.
struct AccessSnapshot: Decodable, Equatable, Sendable {
    struct Pro: Decodable, Equatable, Sendable {
        let active: Bool
        let expires_at: String?
        /// False when RevenueCat could not be asked; `active` then reflects only an earlier verified expiry.
        let verified: Bool
    }
    struct Preview: Decodable, Equatable, Sendable {
        /// "available", "started" or "ended".
        let state: String
        let answers_left: Int
    }
    let entitlement: String
    let app_user_id: String
    let pro: Pro
    let preview: Preview
}

/// The access endpoints of the Neverblank backend. No content ever travels here.
protocol BackendAccessProviding: Sendable {
    func register() async throws -> InstallationCredential
    func access(_ credential: InstallationCredential, refresh: Bool) async throws -> AccessSnapshot
    func endPreview(_ credential: InstallationCredential) async throws
    func send(event: ProductEvent, credential: InstallationCredential) async
}

enum BackendAccessError: Error, Equatable {
    case http(Int)
    case malformed
}

struct BackendAccessClient: BackendAccessProviding {
    let baseURL: URL
    var session: URLSession = .shared

    func register() async throws -> InstallationCredential {
        var request = URLRequest(url: baseURL.appending(path: "v1/installations"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, expecting: 201)
        guard let credential = try? JSONDecoder().decode(InstallationCredential.self, from: data) else { throw BackendAccessError.malformed }
        return credential
    }

    func access(_ credential: InstallationCredential, refresh: Bool) async throws -> AccessSnapshot {
        var components = URLComponents(url: baseURL.appending(path: "v1/access"), resolvingAgainstBaseURL: false)
        if refresh { components?.queryItems = [URLQueryItem(name: "refresh", value: "1")] }
        var request = URLRequest(url: components?.url ?? baseURL)
        request.setValue(credential.authorizationHeader, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.check(response, expecting: 200)
        guard let snapshot = try? JSONDecoder().decode(AccessSnapshot.self, from: data) else { throw BackendAccessError.malformed }
        return snapshot
    }

    func endPreview(_ credential: InstallationCredential) async throws {
        var request = URLRequest(url: baseURL.appending(path: "v1/preview/end"))
        request.httpMethod = "POST"
        request.setValue(credential.authorizationHeader, forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        try Self.check(response, expecting: 200)
    }

    /// Fire-and-forget. An event that cannot be sent is dropped; it never delays or fails anything.
    func send(event: ProductEvent, credential: InstallationCredential) async {
        var request = URLRequest(url: baseURL.appending(path: "v1/events"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credential.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(event)
        _ = try? await session.data(for: request)
    }

    private static func check(_ response: URLResponse, expecting status: Int) throws {
        guard let http = response as? HTTPURLResponse else { throw BackendAccessError.malformed }
        guard http.statusCode == status else { throw BackendAccessError.http(http.statusCode) }
    }
}

/// The funnel events, and nothing else. Every field is an enumerated value, so no transcript, answer,
/// file, note or personal detail can be put in one; the backend refuses anything outside this list.
struct ProductEvent: Encodable, Equatable, Sendable {
    enum Name: String, Encodable, Sendable {
        case trialStarted = "trial_started"
        case trial30sConsumed = "trial_30s_consumed"
        case paywallViewed = "paywall_viewed"
        case weeklySelected = "weekly_selected"
        case monthlySelected = "monthly_selected"
        case purchaseStarted = "purchase_started"
        case purchaseCompleted = "purchase_completed"
        case purchaseFailed = "purchase_failed"
        case purchaseRestored = "purchase_restored"
        case paywallDismissed = "paywall_dismissed"
    }
    enum Reason: String, Encodable, Sendable {
        case cancelled, network, pending, unavailable
        case storeError = "store_error"
        case notEntitled = "not_entitled"
    }

    let name: Name
    var plan: PlanKind?
    var trigger: PaywallTrigger?
    var reason: Reason?
}
