import Testing
import Foundation
@testable import prompter

/// The configuration rules that keep a shipping build honest (§9): no credentials in the app, no
/// invented answers when the backend is missing, and no fake provider outside development.
struct ProviderConfigurationTests {
    /// A bundle with no keys at all.
    ///
    /// These tests are about what happens when configuration is **absent**, so they must not read
    /// the real app bundle: a Debug build carries the developer's local backend defaults, which
    /// would make "missing configuration" impossible to express and turned these assertions into
    /// assertions about whoever last edited Local-Debug.xcconfig.
    final class EmptyBundle: Bundle, @unchecked Sendable {
        override func object(forInfoDictionaryKey key: String) -> Any? { nil }
    }

    private let emptyBundle = EmptyBundle()

    private func defaults(_ values: [String: Any]) -> UserDefaults {
        let suite = UserDefaults(suiteName: "copilot-tests-\(UUID().uuidString)")!
        for (key, value) in values { suite.set(value, forKey: key) }
        return suite
    }

    @Test
    func missingConfigurationIsUnavailableNotFake() {
        let configuration = ProviderConfiguration.resolve(bundle: emptyBundle, defaults: defaults([:]), isDebugBuild: true)
        #expect(configuration.isUnavailable)
        let provider = configuration.makeProvider()
        #expect(!provider.isDevelopmentFake, "missing configuration must never produce fabricated answers")
        #expect(provider is UnconfiguredCopilotProvider)
    }

    @Test
    func anUnconfiguredProviderFailsHonestly() async {
        let provider = ProviderConfiguration.resolve(bundle: emptyBundle, defaults: defaults([:]), isDebugBuild: false).makeProvider()
        await #expect(throws: CopilotProviderError.self) {
            _ = try await provider.classify(ClassificationRequest(
                newSpeech: "anything", recentConversation: [], activeAnswerText: nil,
                knownQuestions: [], language: "en"
            ))
        }
    }

    @Test
    func aBackendURLWithoutATokenIsUnavailable() {
        let configuration = ProviderConfiguration.resolve(
            bundle: emptyBundle,
            defaults: defaults([ProviderConfiguration.backendURLDefaultsKey: "https://example.invalid"]),
            isDebugBuild: true
        )
        #expect(configuration.isUnavailable)
    }

    @Test
    func aConfiguredBackendIsUsed() {
        let configuration = ProviderConfiguration.resolve(
            bundle: emptyBundle,
            defaults: defaults([
                ProviderConfiguration.backendURLDefaultsKey: "https://example.invalid",
                ProviderConfiguration.backendTokenDefaultsKey: "dev-token",
            ]),
            isDebugBuild: true
        )
        #expect(configuration.availability == .backend(url: URL(string: "https://example.invalid")!))
        let provider = configuration.makeProvider()
        #expect(provider is BackendCopilotProvider)
        #expect(!provider.isDevelopmentFake)
        // The model labels are what the UI shows; the backend decides what it actually calls.
        #expect(provider.detectionModelLabel == "gpt-5.4-nano")
        #expect(provider.answerModelLabel == "gpt-5.4-mini")
    }

    /// The fake exists for development only, and never by default.
    @Test
    func theFakeProviderRequiresBothDebugAndAnExplicitOptIn() {
        let optedIn = defaults([ProviderConfiguration.useFakeProviderDefaultsKey: true])
        let inRelease = ProviderConfiguration.resolve(bundle: emptyBundle, defaults: optedIn, isDebugBuild: false)
        #expect(inRelease.isUnavailable, "a release build must not reach the fake provider")
        #expect(!inRelease.makeProvider().isDevelopmentFake)

        let inDebug = ProviderConfiguration.resolve(bundle: emptyBundle, defaults: optedIn, isDebugBuild: true)
        #expect(inDebug.availability == .developmentFake)
        #expect(inDebug.makeProvider().isDevelopmentFake, "development fake output must be identifiable")
    }
}
