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
    /// Debug: authenticate as this installation (free preview and `pro`) instead of with the
    /// developer's bearer token. Also `-CopilotInstallationAuth`. Release always does.
    static let useInstallationAuthDefaultsKey = "CopilotUseInstallationAuth"

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
    /// Set when requests authenticate as this installation — always in Release. Access (the free
    /// preview and `pro`) is then enforced by the backend, and the app gates what it offers.
    var installation: InstallationCredential?
    var usesInstallationAuth: Bool { installation != nil }
    /// The `Authorization` value every backend request carries.
    var authorizationHeader: String { installation?.authorizationHeader ?? "Bearer \(token)" }
    /// Where the base URL came from. Shown in the debug screen so there is never a question about
    /// which of the three possible sources is actually in effect.
    var source: Source = .none

    /// The one place a base URL can come from, in precedence order.
    enum Source: String, Equatable, Sendable {
        /// Typed and saved in the debug screen. Highest precedence — an explicit human choice.
        case savedSetting = "saved setting"
        /// `CopilotBackendURL` in the build's Info.plist. How a real build is pointed at a service.
        case buildConfiguration = "build configuration"
        /// The git-ignored `Local-Debug.xcconfig` baked into a Debug build.
        case developmentDefault = "development default"
        case none = "none"
    }

    /// A saved development URL that has certainly stopped working.
    ///
    /// ngrok's free tunnels get a new hostname every restart, so a URL saved from a previous session
    /// is dead the moment the agent restarts — and because a saved setting outranks the build's own
    /// configuration, that dead URL silently wins over the endpoint the build was made to talk to.
    /// That is how the app ends up "unreachable" while the backend is healthy.
    ///
    /// Only *superseded* ephemeral hosts are ignored: a saved ngrok URL is honoured when the build
    /// carries no development default, or when it is the same host the build already points at. A
    /// saved URL for any other host — a real service, a LAN address — is always honoured, because
    /// that is a deliberate choice this must not second-guess.
    static func isSupersededDevelopmentURL(_ saved: String, developmentURL: String?) -> Bool {
        guard let developmentURL, !developmentURL.isEmpty,
              let savedHost = URL(string: saved)?.host,
              let developmentHost = URL(string: developmentURL)?.host,
              savedHost != developmentHost else { return false }
        let ephemeral = ["ngrok-free.app", "ngrok.io", "ngrok.app", "trycloudflare.com"]
        return ephemeral.contains { savedHost.hasSuffix($0) }
    }

    static func resolve(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        isDebugBuild: Bool = ProviderConfiguration.isDebug,
        installation: @autoclosure () -> InstallationCredential? = InstallationCredentialStore.keychain.load(),
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> ProviderConfiguration {
        // **Release: the backend URL from the build, authenticated as this installation, and nothing
        // else.** No saved override, no development default and no bearer token can apply to a
        // shipping build, so no shared secret is ever needed in the app.
        if !isDebugBuild {
            let raw = (bundle.object(forInfoDictionaryKey: backendURLPlistKey) as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw), url.scheme == "https" else {
                return ProviderConfiguration(availability: .unavailable(reason: "No backend is configured — answer suggestions are unavailable"), token: "")
            }
            guard let credential = installation() else {
                return ProviderConfiguration(availability: .unavailable(reason: "Connecting to Neverblank…"), token: "", source: .buildConfiguration)
            }
            return ProviderConfiguration(availability: .backend(url: url), token: "", installation: credential, source: .buildConfiguration)
        }
        let wantsInstallation = arguments.contains("-CopilotInstallationAuth") || defaults.bool(forKey: useInstallationAuthDefaultsKey)
        // Precedence, highest first: what the developer explicitly saved in the debug screen, then
        // the build's own configuration, then the local development defaults. Saving a value in the
        // app therefore wins over the checked-out configuration, which is what makes a stale
        // *default* harmless — you can always override it from the screen.
        //
        // The one exception is a stale *saved* value: see `isSupersededDevelopmentURL`. A dead
        // ngrok hostname saved in a previous session is not a choice anyone is still making, and
        // letting it outrank the build made the app unreachable while the backend was healthy.
        let development = developmentDefaults(bundle: bundle, isDebugBuild: isDebugBuild)
        let token = firstNonEmpty(
            defaults.string(forKey: backendTokenDefaultsKey),
            development?.token
        )
        // A saved setting still wins — it is an explicit choice — *unless* it is a development
        // tunnel the build has since moved on from, which is a stale value rather than a choice.
        let savedURL = (defaults.string(forKey: backendURLDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let savedIsSuperseded = isSupersededDevelopmentURL(savedURL, developmentURL: development?.url)
        let effectiveSaved = savedIsSuperseded ? "" : savedURL

        let urlString = firstNonEmpty(
            effectiveSaved,
            bundle.object(forInfoDictionaryKey: backendURLPlistKey) as? String,
            development?.url
        )
        let source: Source
        if !effectiveSaved.isEmpty {
            source = .savedSetting
        } else if let plist = bundle.object(forInfoDictionaryKey: backendURLPlistKey) as? String,
                  !plist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = .buildConfiguration
        } else if development?.url.isEmpty == false {
            source = .developmentDefault
        } else {
            source = .none
        }

        if !urlString.isEmpty, let url = URL(string: urlString), url.scheme != nil {
            if wantsInstallation {
                guard let credential = installation() else {
                    return ProviderConfiguration(availability: .unavailable(reason: "Connecting to Neverblank…"), token: "", source: source)
                }
                return ProviderConfiguration(availability: .backend(url: url), token: "", installation: credential, source: source)
            }
            guard !token.isEmpty else {
                return ProviderConfiguration(
                    availability: .unavailable(reason: "A backend URL is set but no access token — suggestions are unavailable"),
                    token: ""
                )
            }
            return ProviderConfiguration(availability: .backend(url: url), token: token, source: source)
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
        // A UI test asserting the *unconfigured* state cannot do so on a machine whose Debug build
        // has a local backend baked in — and whether one is baked in depends on a git-ignored file,
        // so the same test passed or failed depending on whose machine it ran on. This makes the
        // empty state reachable deliberately. Debug-only, like the keys it suppresses.
        if ProcessInfo.processInfo.arguments.contains("-CopilotIgnoreDevelopmentDefaults") { return nil }
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

    /// The backend this build registers an installation with, or nil when it does not use
    /// installation access: Release always does; Debug only with `-CopilotInstallationAuth` (or the
    /// saved setting), so ordinary development runs and the test host never register.
    static func installationBackendURL(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        isDebugBuild: Bool = ProviderConfiguration.isDebug,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> URL? {
        let placeholder = InstallationCredential(installationID: "-", secret: "-", appUserID: "-")
        let resolved = resolve(bundle: bundle, defaults: defaults, isDebugBuild: isDebugBuild,
                               installation: placeholder, arguments: arguments)
        guard resolved.usesInstallationAuth, case .backend(let url) = resolved.availability else { return nil }
        return url
    }

    /// Builds the provider this configuration describes.
    func makeProvider() -> CopilotProviding {
        switch availability {
        case .backend(let url):
            return BackendCopilotProvider(
                baseURL: url,
                authorization: authorizationHeader,
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
