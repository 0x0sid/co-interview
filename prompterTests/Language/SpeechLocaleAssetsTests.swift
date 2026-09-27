import Foundation
import Speech
import Testing
@testable import prompter

/// Speech-model reservations: the system allows `maximumReservedLocales` per app and the app used to
/// reserve implicitly and never release, so the sixth language tried failed with
/// "Too many allocated locales, 5 maximum". Driven by a fake system that enforces the same limit.
struct SpeechLocaleAssetsTests {
    /// Behaves like `AssetInventory` where it matters: reserving past the maximum throws.
    final class FakeSystem: SpeechAssetSystem, @unchecked Sendable {
        struct TooManyLocales: Error {}
        private let lock = NSLock()
        let maximumReservedLocales: Int
        private var _reserved: [Locale]
        private var _installed: Set<String>
        let supported: [String]
        private var _installs: [String] = []
        private var _releases: [String] = []

        init(maximum: Int = 5, reserved: [String] = [], installed: Set<String> = [],
             supported: [String] = ["en-US", "fr-FR", "zh-TW", "de-DE", "es-ES", "ja-JP", "it-IT", "pt-BR", "ko-KR"]) {
            maximumReservedLocales = maximum
            _reserved = reserved.map(Locale.init(identifier:))
            _installed = installed
            self.supported = supported
        }

        var reserved: [String] { lock.withLock { _reserved.map { $0.identifier(.bcp47) } } }
        var installs: [String] { lock.withLock { _installs } }
        var releases: [String] { lock.withLock { _releases } }

        func reservedLocales() async -> [Locale] { lock.withLock { _reserved } }
        func reserve(_ locale: Locale) async throws -> Bool {
            try lock.withLock {
                if _reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) { return false }
                guard _reserved.count < maximumReservedLocales else { throw TooManyLocales() }
                _reserved.append(locale)
                return true
            }
        }
        func release(_ locale: Locale) async -> Bool {
            lock.withLock {
                _releases.append(locale.identifier(.bcp47))
                let before = _reserved.count
                _reserved.removeAll { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
                return _reserved.count < before
            }
        }
        func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
            let id = locale.identifier(.bcp47)
            return supported.contains(id) ? Locale(identifier: id) : nil
        }
        func installedLocales() async -> [Locale] { lock.withLock { _installed.map(Locale.init(identifier:)) } }
        func status(of locale: Locale) async -> AssetInventory.Status {
            let id = locale.identifier(.bcp47)
            guard supported.contains(id) else { return .unsupported }
            return lock.withLock { _installed.contains(id) } ? .installed : .supported
        }
        func install(_ locale: Locale, onProgress: @escaping @Sendable (Double) -> Void) async throws {
            // Apple's installation request reserves implicitly: past the maximum, it throws.
            _ = try await reserve(locale)
            lock.withLock {
                _installs.append(locale.identifier(.bcp47))
                _installed.insert(locale.identifier(.bcp47))
            }
            onProgress(1)
        }
    }

    static func assets(_ system: FakeSystem) -> SpeechLocaleAssets {
        let defaults = UserDefaults(suiteName: "SpeechLocaleAssetsTests-\(UUID().uuidString)")!
        return SpeechLocaleAssets(system: system, defaults: defaults)
    }

    // MARK: Reservations

    @Test
    func anAlreadyReservedLocaleIsReused() async throws {
        let system = FakeSystem(reserved: ["en-US", "fr-FR"], installed: ["en-US", "fr-FR"])
        try await Self.assets(system).prepare(Locale(identifier: "fr-FR"), allowDownload: false)
        #expect(system.reserved == ["en-US", "fr-FR"])
        #expect(system.releases.isEmpty)
        #expect(system.installs.isEmpty, "an installed locale is never downloaded again")
    }

    @Test
    func atTheMaximumAnInactiveReservationIsReleasedFirst() async throws {
        // Five experiments already hold every slot — the state the phone was in.
        let system = FakeSystem(reserved: ["de-DE", "es-ES", "ja-JP", "it-IT", "en-US"], installed: ["en-US"])
        try await Self.assets(system).prepare(Locale(identifier: "fr-FR"), allowDownload: true)
        #expect(system.reserved.contains("fr-FR"))
        #expect(system.reserved.count == 5, "never more than the system maximum")
        #expect(system.releases.count == 1, "only as many as needed are released")
        #expect(!system.releases.contains("en-US"), "English is kept while others can go")
        #expect(system.installs == ["fr-FR"])
    }

    @Test
    func theMaximumComesFromTheSystemNotAConstant() async throws {
        let system = FakeSystem(maximum: 2, reserved: ["de-DE", "en-US"], installed: ["en-US"])
        try await Self.assets(system).prepare(Locale(identifier: "zh-TW"), allowDownload: true)
        #expect(system.reserved.count == 2)
        #expect(system.reserved.contains("zh-TW"))
        #expect(system.releases == ["de-DE"])
    }

    @Test
    func theLocaleARunningSessionUsesIsNeverReleased() async throws {
        let system = FakeSystem(maximum: 2, reserved: [], installed: ["en-US", "fr-FR", "zh-TW"])
        let assets = Self.assets(system)
        let english = try await assets.acquire(Locale(identifier: "en-US"), allowDownload: false)
        let french = try await assets.acquire(Locale(identifier: "fr-FR"), allowDownload: false)
        // Both slots are held by running sessions: a third language must not take either.
        await #expect(throws: SpeechLocaleAssetError.reservationsInUse) {
            try await assets.prepare(Locale(identifier: "zh-TW"), allowDownload: true)
        }
        #expect(system.releases.isEmpty)
        #expect(system.reserved == ["en-US", "fr-FR"])

        // Once the French session ends, its reservation may go; English's may not.
        await assets.end(french)
        try await assets.prepare(Locale(identifier: "zh-TW"), allowDownload: true)
        #expect(system.releases == ["fr-FR"])
        #expect(system.reserved.contains("en-US"))
        await assets.end(english)
    }

    @Test
    func theLeastRecentlyUsedOtherLanguageGoesFirst() async throws {
        let system = FakeSystem(maximum: 3, reserved: [], installed: ["en-US", "fr-FR", "zh-TW", "de-DE"])
        let assets = Self.assets(system)
        for id in ["en-US", "de-DE", "fr-FR"] { try await assets.prepare(Locale(identifier: id), allowDownload: false) }
        try await assets.prepare(Locale(identifier: "zh-TW"), allowDownload: false)
        #expect(system.releases == ["de-DE"], "German was used least recently; English and French stay")
    }

    @Test
    func switchingLanguagesRepeatedlyNeverAccumulatesReservations() async throws {
        let system = FakeSystem(reserved: ["de-DE", "es-ES", "ja-JP", "it-IT", "pt-BR"], installed: [])
        let assets = Self.assets(system)
        for _ in 0..<4 {
            for id in ["en-US", "fr-FR", "zh-TW", "en-US"] {
                let lease = try await assets.acquire(Locale(identifier: id), allowDownload: true)
                #expect(system.reserved.count <= system.maximumReservedLocales)
                #expect(system.reserved.contains(id))
                await assets.end(lease)
            }
        }
        #expect(Set(system.installs) == ["en-US", "fr-FR", "zh-TW"], "each model is downloaded once")
        #expect(system.reserved.count == 5)
        #expect(Set(["en-US", "fr-FR", "zh-TW"]).isSubset(of: Set(system.reserved)))
    }

    // MARK: Availability and downloads

    @Test
    func anInstalledLocaleSkipsTheDownload() async throws {
        let system = FakeSystem(installed: ["zh-TW"])
        let assets = Self.assets(system)
        #expect(await assets.availability(for: Locale(identifier: "zh-TW")) == .installed(Locale(identifier: "zh-TW")))
        try await assets.prepare(Locale(identifier: "zh-TW"), allowDownload: false)
        #expect(system.installs.isEmpty)
    }

    @Test
    func aSupportedMissingLocaleNeedsAnExplicitDownload() async throws {
        let system = FakeSystem(installed: ["en-US"])
        let assets = Self.assets(system)
        let french = Locale(identifier: "fr-FR")
        #expect(await assets.availability(for: french) == .needsDownload(french))
        await #expect(throws: SpeechLocaleAssetError.needsDownload(french)) {
            try await assets.prepare(french, allowDownload: false)
        }
        #expect(system.installs.isEmpty, "nothing is downloaded without asking")
        try await assets.prepare(french, allowDownload: true)
        #expect(system.installs == ["fr-FR"])
        #expect(await assets.availability(for: french) == .installed(french))
    }

    @Test
    func anUnsupportedLocaleFailsExplicitly() async throws {
        let system = FakeSystem(supported: ["en-US"])
        let assets = Self.assets(system)
        let klingon = Locale(identifier: "tlh")
        #expect(await assets.availability(for: klingon) == .unsupported)
        await #expect(throws: SpeechLocaleAssetError.unsupported(klingon)) {
            try await assets.prepare(klingon, allowDownload: true)
        }
        #expect(system.reserved.isEmpty, "no English fallback is reserved in its place")
    }

    // MARK: Readiness

    @Test
    func readinessOffersTheDownloadInsteadOfAnAppleError() async {
        let readiness = await LiveReadiness.check(
            configuration: ProviderConfiguration(availability: .backend(url: URL(string: "https://example.test")!), token: "t"),
            language: InterviewLanguage(identifier: "zh-TW"),
            microphonePermission: .granted,
            speechAuthorization: .authorized,
            probe: { _ in .ok(summary: "ok", providerConfigured: true, acceptsImages: false) },
            speechModel: { .needsDownload($0) }
        )
        #expect(readiness.needsSpeechDownload)
        #expect(!readiness.canListen, "Start waits for the model")
        #expect(readiness.summary.hasSuffix("speech model required"))
    }

    @Test
    func readinessSaysAnUnsupportedLanguageIsUnsupported() async {
        let readiness = await LiveReadiness.check(
            configuration: ProviderConfiguration(availability: .backend(url: URL(string: "https://example.test")!), token: "t"),
            language: .french,
            microphonePermission: .granted,
            speechAuthorization: .authorized,
            probe: { _ in .ok(summary: "ok", providerConfigured: true, acceptsImages: false) },
            speechModel: { _ in .unsupported }
        )
        #expect(!readiness.needsSpeechDownload)
        #expect(readiness.summary.contains("not supported"))
    }
}

/// The interview language reaches the transcriber unchanged: English, French and Traditional Chinese.
@MainActor
struct InterviewLocalePropagationTests {
    final class RecordingTranscriber: Transcribing, @unchecked Sendable {
        let locales = LockedBox<[String]>([])
        func start(locale: Locale, contextualStrings: [String]) async throws -> AsyncStream<TranscriptDelta> {
            locales.mutate { $0.append(locale.identifier(.bcp47)) }
            return AsyncStream { _ in }
        }
        func stop() async {}
    }

    @Test(arguments: ["en-US", "fr-FR", "zh-TW"])
    func theInterviewLanguageIsTheTranscriberLocale(_ identifier: String) async throws {
        let transcriber = RecordingTranscriber()
        let coordinator = CopilotSessionCoordinator(
            project: SessionFileContext(language: InterviewLanguage(identifier: identifier)),
            provider: CopilotTestSupport.StubProvider(),
            audio: InterviewAudioInput(makeService: { transcriber }),
            generationMode: .manual
        )
        coordinator.startListening()
        try await CopilotTestSupport.waitUntil("started") { !transcriber.locales.value.isEmpty }
        #expect(transcriber.locales.value == [identifier])
        coordinator.endSession()
    }

    @Test
    func changingLanguageMidInterviewRestartsInTheNewLocale() async throws {
        let transcriber = RecordingTranscriber()
        let coordinator = CopilotSessionCoordinator(
            project: SessionFileContext(language: .english),
            provider: CopilotTestSupport.StubProvider(),
            audio: InterviewAudioInput(makeService: { transcriber }),
            generationMode: .manual
        )
        coordinator.startListening()
        try await CopilotTestSupport.waitUntil("listening") { coordinator.audio.state == .listening }
        coordinator.changeLanguage(.french)
        try await CopilotTestSupport.waitUntil("restarted") { transcriber.locales.value.count == 2 }
        coordinator.changeLanguage(InterviewLanguage(identifier: "zh-TW"))
        try await CopilotTestSupport.waitUntil("restarted again") { transcriber.locales.value.count == 3 }
        #expect(transcriber.locales.value == ["en-US", "fr-FR", "zh-TW"])
        coordinator.endSession()
    }
}
