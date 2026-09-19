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
        // Precedence, highest first: what the developer explicitly saved in the debug screen, then
        // the build's own configuration, then the local development defaults. Saving a value in the
        // app therefore always wins over the checked-out configuration, which is what makes a stale
        // default harmless — you can always override it from the screen.
        let development = developmentDefaults(bundle: bundle, isDebugBuild: isDebugBuild)
        let token = firstNonEmpty(
            defaults.string(forKey: backendTokenDefaultsKey),
            development?.token
        )
        let urlString = firstNonEmpty(
            defaults.string(forKey: backendURLDefaultsKey),
            bundle.object(forInfoDictionaryKey: backendURLPlistKey) as? String,
            development?.url
        )

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

    /// Backend host and client token baked into a **Debug** build from the git-ignored
    /// `prompter/Config/Local-Debug.xcconfig`, so Start live works without typing anything.
    ///
    /// Three properties make this safe:
    /// - The keys live only in `Info-Debug.plist`, which only the Debug configuration uses, so a
    ///   Release build has neither key and this returns nil there.
    /// - The value is a **client access token**, the credential the app is meant to hold. The
    ///   provider key (`OPENROUTER_API_KEY`) stays in `backend/.env` and never reaches the app.
    /// - The host is stored without a scheme because xcconfig treats `//` as a comment and would
    ///   silently truncate `https://…`. The scheme is added here, and it is always `https`.
    static func developmentDefaults(bundle: Bundle, isDebugBuild: Bool) -> (url: String, token: String)? {
        guard isDebugBuild else { return nil }
        let host = (bundle.object(forInfoDictionaryKey: "CopilotDevBackendHost") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (bundle.object(forInfoDictionaryKey: "CopilotDevBackendToken") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !token.isEmpty else { return nil }
        return ("https://" + host, token)
    }

    private static func firstNonEmpty(_ candidates: String?...) -> String {
        for candidate in candidates {
            let trimmed = (candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
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
