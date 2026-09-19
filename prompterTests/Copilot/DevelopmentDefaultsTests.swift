import Testing
import Foundation
@testable import prompter

/// The precedence rule for finding the backend, and the line the development defaults must not cross.
///
/// Debug builds can carry a backend host and client token so Start live works without typing
/// anything. That convenience is only safe if two things hold: a value saved in the app always wins
/// (otherwise a stale baked-in URL would be unfixable from the device), and a Release build carries
/// none of it.
@MainActor
struct DevelopmentDefaultsTests {
    /// Stands in for the app bundle, so these run without a real Info.plist.
    final class StubBundle: Bundle, @unchecked Sendable {
        var values: [String: Any] = [:]
        override func object(forInfoDictionaryKey key: String) -> Any? { values[key] }
    }

    static func defaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "DevelopmentDefaultsTests.\(UUID().uuidString)")!
        return suite
    }

    @Test
    func aDebugBuildUsesTheBakedInBackendWhenNothingIsSaved() throws {
        let bundle = StubBundle()
        bundle.values = [
            "CopilotDevBackendHost": "example.ngrok-free.app",
            "CopilotDevBackendToken": "client-token",
        ]

        let configuration = ProviderConfiguration.resolve(bundle: bundle, defaults: Self.defaults(), isDebugBuild: true)

        guard case .backend(let url) = configuration.availability else {
            Issue.record("expected a configured backend, got \(configuration.availability)")
            return
        }
        // The scheme is added by the app: xcconfig cannot hold "//" without truncating it.
        #expect(url.absoluteString == "https://example.ngrok-free.app")
        #expect(configuration.token == "client-token")
    }

    /// The rule that keeps a stale default harmless.
    @Test
    func anExplicitlySavedSettingOverridesTheBakedInOne() throws {
        let bundle = StubBundle()
        bundle.values = [
            "CopilotDevBackendHost": "stale.ngrok-free.app",
            "CopilotDevBackendToken": "stale-token",
        ]
        let saved = Self.defaults()
        saved.set("https://chosen.example.com", forKey: ProviderConfiguration.backendURLDefaultsKey)
        saved.set("chosen-token", forKey: ProviderConfiguration.backendTokenDefaultsKey)

        let configuration = ProviderConfiguration.resolve(bundle: bundle, defaults: saved, isDebugBuild: true)

        guard case .backend(let url) = configuration.availability else {
            Issue.record("expected a configured backend, got \(configuration.availability)")
            return
        }
        #expect(url.absoluteString == "https://chosen.example.com")
        #expect(configuration.token == "chosen-token")
    }

    /// The line that must not be crossed: a Release build ignores development defaults entirely,
    /// even if some future build somehow carried the keys.
    @Test
    func aReleaseBuildIgnoresDevelopmentDefaults() {
        let bundle = StubBundle()
        bundle.values = [
            "CopilotDevBackendHost": "example.ngrok-free.app",
            "CopilotDevBackendToken": "client-token",
        ]

        let configuration = ProviderConfiguration.resolve(bundle: bundle, defaults: Self.defaults(), isDebugBuild: false)

        guard case .unavailable = configuration.availability else {
            Issue.record("a Release build used a development backend: \(configuration.availability)")
            return
        }
        #expect(configuration.token.isEmpty)
        #expect(ProviderConfiguration.developmentDefaults(bundle: bundle, isDebugBuild: false) == nil)
    }

    /// A half-filled template must not produce a half-configured backend.
    @Test
    func anIncompleteLocalConfigurationIsIgnored() {
        let bundle = StubBundle()
        bundle.values = ["CopilotDevBackendHost": "example.ngrok-free.app"]   // no token
        #expect(ProviderConfiguration.developmentDefaults(bundle: bundle, isDebugBuild: true) == nil)

        // Unsubstituted build settings, which is what an absent xcconfig leaves behind, are empty
        // strings rather than values — and empty is correctly treated as "not configured".
        let unsubstituted = StubBundle()
        unsubstituted.values = ["CopilotDevBackendHost": "", "CopilotDevBackendToken": ""]
        #expect(ProviderConfiguration.developmentDefaults(bundle: unsubstituted, isDebugBuild: true) == nil)
    }
}
