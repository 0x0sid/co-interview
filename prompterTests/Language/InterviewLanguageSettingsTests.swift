import AVFAudio
import Foundation
import Speech
import SwiftData
import Testing
@testable import prompter

/// One interview-language setting, chosen in Settings, snapshotted by each new interview; and the
/// speech-model states Settings shows, driven through the real `SpeechLocaleAssets`.
@MainActor
struct InterviewLanguageSettingsTests {
    typealias Fake = SpeechLocaleAssetsTests.FakeSystem

    static func assets(_ system: Fake) -> SpeechLocaleAssets {
        SpeechLocaleAssets(system: system, defaults: UserDefaults(suiteName: "InterviewLanguageSettingsTests-\(UUID().uuidString)")!)
    }

    // MARK: One setting, snapshotted per interview

    @Test
    func theChosenLanguagePersistsAndTheNextInterviewUsesIt() throws {
        let context = ModelContext(try SessionTestSupport.container())
        let settings = AppSettings.fetchOrCreate(in: context)
        settings.interviewLanguageRaw = InterviewLanguagePreference.language(InterviewLanguage(identifier: "es-CL")).rawValue
        try context.save()

        let stored = InterviewLanguagePreference.from(stored: AppSettings.fetchOrCreate(in: context).interviewLanguageRaw)
        #expect(stored.resolved() == InterviewLanguage(identifier: "es-CL"), "the choice is persisted, not reset")
        let launch = InterviewLaunch.newLive(context: context, preference: stored,
                                             store: FileStore(root: SessionTestSupport.temporaryDirectory()))
        #expect(launch.fileContext.language.identifier == "es-CL")
    }

    @Test
    func aRunningInterviewKeepsItsLanguageWhenSettingsChange() throws {
        let context = ModelContext(try SessionTestSupport.container())
        let settings = AppSettings.fetchOrCreate(in: context)
        settings.interviewLanguageRaw = InterviewLanguagePreference.language(InterviewLanguage(identifier: "es-CL")).rawValue
        let running = InterviewLaunch.newLive(context: context, preference: .from(stored: settings.interviewLanguageRaw),
                                              store: FileStore(root: SessionTestSupport.temporaryDirectory()))

        settings.interviewLanguageRaw = InterviewLanguagePreference.language(.french).rawValue   // changed mid-interview
        #expect(running.fileContext.language.identifier == "es-CL", "the running interview keeps its snapshot")
        let next = InterviewLaunch.newLive(context: context, preference: .from(stored: settings.interviewLanguageRaw),
                                           store: FileStore(root: SessionTestSupport.temporaryDirectory()))
        #expect(next.fileContext.language == .french, "the next interview uses the new setting")
    }

    // MARK: Speech model states in Settings

    @Test
    func anInstalledModelShowsReady() async {
        let status = SpeechModelStatus(assets: Self.assets(Fake(installed: ["es-CL"], supported: ["en-US", "es-CL"])))
        await status.refresh(for: InterviewLanguage(identifier: "es-CL"))
        #expect(status.state == .ready)
    }

    @Test
    func aMissingModelOffersDownloadAndBecomesReady() async {
        let system = Fake(installed: ["en-US"], supported: ["en-US", "es-CL"])
        let status = SpeechModelStatus(assets: Self.assets(system))
        await status.refresh(for: InterviewLanguage(identifier: "es-CL"))
        #expect(status.state == .needsDownload)
        #expect(system.installs.isEmpty, "nothing downloads before Download is tapped")

        await status.download()
        #expect(system.installs == ["es-CL"], "Download went through SpeechLocaleAssets")
        #expect(system.reserved.contains("es-CL"))
        #expect(status.state == .ready)
    }

    @Test
    func aDownloadAtTheReservationLimitStillSucceedsWithoutShowingIt() async {
        // Five slots already held — the state that produced "Too many allocated locales" on the phone.
        let system = Fake(reserved: ["fr-FR", "fr-BE", "en-US", "en-AU", "de-DE"], installed: ["en-US"],
                          supported: ["en-US", "fr-FR", "fr-BE", "en-AU", "de-DE", "es-CL"])
        let status = SpeechModelStatus(assets: Self.assets(system))
        await status.refresh(for: InterviewLanguage(identifier: "es-CL"))
        await status.download()
        #expect(status.state == .ready)
        #expect(system.reserved.count == 5, "reservations stay bounded")
        #expect(system.reserved.contains("es-CL") && system.reserved.contains("en-US"))
    }

    @Test
    func aFailedDownloadOffersRetry() async {
        struct Offline: Error {}
        let failing = LockedBox(true)
        let status = SpeechModelStatus(
            availability: { _ in failing.value ? .needsDownload(Locale(identifier: "es-CL")) : .installed(Locale(identifier: "es-CL")) },
            install: { _, _ in if failing.value { throw Offline() } }
        )
        await status.refresh(for: InterviewLanguage(identifier: "es-CL"))
        await status.download()
        #expect(status.state == .failed, "a failed download says so and offers Try again")
        failing.value = false
        await status.download()
        #expect(status.state == .ready)
    }

    @Test
    func anUnsupportedLanguageIsSaidPlainlyAndNeverReplacedByEnglish() async {
        let system = Fake(supported: ["en-US"])
        let status = SpeechModelStatus(assets: Self.assets(system))
        await status.refresh(for: InterviewLanguage(identifier: "es-CL"))
        #expect(status.state == .unsupported)
        await status.download()
        #expect(status.state == .unsupported)
        #expect(system.reserved.isEmpty && system.installs.isEmpty, "no English model is prepared in its place")
    }

    @Test
    func startIsBlockedUntilTheModelIsReady() async {
        for (model, canStart) in [(SpeechModelAvailability.needsDownload(Locale(identifier: "es-CL")), false),
                                  (.unsupported, false), (.installed(Locale(identifier: "es-CL")), true)] {
            let readiness = await LiveReadiness.check(
                configuration: ProviderConfiguration(availability: .backend(url: URL(string: "https://example.test")!), token: "t"),
                language: InterviewLanguage(identifier: "es-CL"),
                microphonePermission: .granted, speechAuthorization: .authorized,
                probe: { _ in .ok(summary: "ok", providerConfigured: true, acceptsImages: false) },
                speechModel: { _ in model }
            )
            #expect(readiness.canListen == canStart, "\(model): Start \(canStart ? "allowed" : "blocked")")
        }
    }
}
