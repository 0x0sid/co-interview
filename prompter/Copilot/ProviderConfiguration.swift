import Foundation

/// How the app finds its backend — and what it does when it cannot (§9).
///
/// **Three rules this type exists to enforce:**
/// 1. No permanent provider credential is ever compiled into the app. Only a backend URL and, during
///    development, a bearer token the developer sets themselves.
/// 2. Missing configuration produces an honest *unavailable* state. It never falls back to invented
///    answers.
/// 3. The development fake is `#if DEBUG` only **and** opt-in, and everything it produces is labelled.
struct ProviderConfiguration: Equatable, Sendable {
    /// Info.plist key, so a real build can be configured without touching code.
    static let backendURLPlistKey = "CopilotBackendURL"
    /// Development overrides, set from the debug screen or `-CopilotBackendURL` launch arguments.
    static let backendURLDefaultsKey = "CopilotBackendURL"
    static let backendTokenDefaultsKey = "CopilotBackendToken"
    static let useFakeProviderDefaultsKey = "CopilotUseFakeProvider"

    /// Documented in docs/CO_INTERVIEW_AI_PIPELINE.md §2 and verified against OpenAI documentation on
    /// 2026-09-16. The app only *labels* these; the backend decides what it actually calls.
    static let detectionModel = "gpt-5.4-nano"
    static let answerModel = "gpt-5.4-mini"

    enum Availability: Equatable, Sendable {
        case backend(url: URL)
        case developmentFake
        case unavailable(reason: String)
    }

    var availability: Availability
    var token: String

    static func resolve(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        isDebugBuild: Bool = ProviderConfiguration.isDebug
    ) -> ProviderConfiguration {
        let token = defaults.string(forKey: backendTokenDefaultsKey) ?? ""
        let urlString = (defaults.string(forKey: backendURLDefaultsKey)
            ?? bundle.object(forInfoDictionaryKey: backendURLPlistKey) as? String
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !urlString.isEmpty, let url = URL(string: urlString), url.scheme != nil {
            guard !token.isEmpty else {
                return ProviderConfiguration(
                    availability: .unavailable(reason: "A backend URL is set but no access token — suggestions are unavailable"),
                    token: ""
                )
            }
            return ProviderConfiguration(availability: .backend(url: url), token: token)
        }

        // The fake is available only in a debug build **and** only when explicitly switched on. A
        // release build with missing configuration can never reach it.
        if isDebugBuild, defaults.bool(forKey: useFakeProviderDefaultsKey) {
            return ProviderConfiguration(availability: .developmentFake, token: "")
        }

        return ProviderConfiguration(
            availability: .unavailable(reason: "No backend is configured — answer suggestions are unavailable"),
            token: ""
        )
    }

    static var isDebug: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Builds the provider this configuration describes.
    func makeProvider() -> CopilotProviding {
        switch availability {
        case .backend(let url):
            return BackendCopilotProvider(
                baseURL: url,
                token: token,
                detectionModelLabel: Self.detectionModel,
                answerModelLabel: Self.answerModel
            )
        case .developmentFake:
            #if DEBUG
            return FakeCopilotProvider()
            #else
            // Unreachable: `resolve` never returns `.developmentFake` outside a debug build. Kept as a
            // second, compile-time guarantee that no shipping build can serve fabricated answers.
            return UnconfiguredCopilotProvider(reason: "No backend is configured")
            #endif
        case .unavailable(let reason):
            return UnconfiguredCopilotProvider(reason: reason)
        }
    }

    var isUnavailable: Bool {
        if case .unavailable = availability { return true }
        return false
    }
}
