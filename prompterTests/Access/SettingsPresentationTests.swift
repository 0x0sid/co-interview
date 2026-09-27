import Foundation
import Testing
@testable import prompter

/// Settings' setup states: the leave warning for a missing speech model, the Neverblank Pro card, and
/// the download controls behind them.
@MainActor
struct SettingsPresentationTests {
    typealias Fake = SpeechLocaleAssetsTests.FakeSystem
    typealias Guard = SettingsLeaveGuard

    // MARK: Leaving Settings

    @Test
    func aMissingModelWarnsOnceBeforeLeaving() {
        #expect(Guard.decision(for: .needsDownload, alreadyWarned: false) == .offerDownload)
        #expect(Guard.decision(for: .failed, alreadyWarned: false) == .offerDownload)
        #expect(Guard.decision(for: .needsDownload, alreadyWarned: true) == .leave, "warned, never trapped")
    }

    @Test
    func aRunningDownloadAsksWhetherToKeepIt() {
        #expect(Guard.decision(for: .downloading(0.4), alreadyWarned: false) == .downloadInProgress)
    }

    @Test
    func noWarningWhenTheModelIsInstalledOrCannotBeDownloaded() {
        #expect(Guard.decision(for: .ready, alreadyWarned: false) == .leave)
        #expect(Guard.decision(for: .checking, alreadyWarned: false) == .leave)
        #expect(Guard.decision(for: .unsupported, alreadyWarned: false) == .leave, "nothing to download; the card says why")
    }

    @Test
    func choosingAnInstalledLanguageRemovesTheWarning() async {
        let status = SpeechModelStatus(assets: SpeechLocaleAssetsTests.assets(Fake(installed: ["en-US"], supported: ["en-US", "es-CL"])))
        await status.refresh(for: InterviewLanguage(identifier: "es-CL"))
        #expect(Guard.decision(for: status.state, alreadyWarned: false) == .offerDownload)
        await status.refresh(for: .english)
        #expect(status.state == .ready)
        #expect(Guard.decision(for: status.state, alreadyWarned: false) == .leave)
    }

    @Test
    func downloadFromTheWarningStaysInSettingsAndStartsOnce() async throws {
        let system = Fake(installed: ["en-US"], supported: ["en-US", "es-CL"])
        let status = SpeechModelStatus(assets: SpeechLocaleAssetsTests.assets(system))
        await status.refresh(for: InterviewLanguage(identifier: "es-CL"))
        #expect(status.needsAction)
        status.startDownload()
        status.startDownload()                                    // a second tap does nothing
        try await CopilotTestSupport.waitUntil("installed") { status.state == .ready }
        #expect(system.installs == ["es-CL"], "exactly one download")
        #expect(!status.needsAction)
        #expect(Guard.decision(for: status.state, alreadyWarned: false) == .leave, "no warning once it completed")
    }

    @Test
    func cancellingADownloadReturnsToTheDownloadState() async {
        let status = SpeechModelStatus(
            availability: { .needsDownload($0) },
            install: { _, _ in try await Task.sleep(for: .seconds(30)) }
        )
        await status.refresh(for: InterviewLanguage(identifier: "es-CL"))
        status.startDownload()
        await Task.yield()
        #expect(status.isDownloading)
        status.cancelDownload()
        #expect(status.state == .needsDownload, "Download is offered again; nothing claims to be installed")
    }

    @Test
    func modelNamesAreTheLanguageNotTheRegion() {
        #expect(InterviewLanguage(identifier: "es-CL").speechModelName == "Spanish")
        #expect(InterviewLanguage.french.speechModelName == "French")
        #expect(InterviewLanguage(identifier: "zh-TW").speechModelName == "Traditional Chinese")
        #expect(InterviewLanguage.english.speechModelName == "English")
    }

    // MARK: The Neverblank Pro card

    @Test
    func anActiveSubscriptionShowsItsPlanAndRenewal() {
        let renews = Date().addingTimeInterval(30 * 86_400)
        let state = SubscriptionCardState.make(status: .premium(expiration: renews, willRenew: true),
                                               needsVerification: false, expiredAt: nil, plan: "Monthly")
        guard case .active(let plan, let renewal) = state else { Issue.record("not active: \(state)"); return }
        #expect(plan == "Monthly")
        #expect(renewal.hasPrefix("Renews on"))
        #expect(state.accessibilitySummary.contains("active") && state.accessibilitySummary.contains("Monthly"),
                "VoiceOver hears the state, not only the PRO badge")
    }

    @Test
    func aCancelledSubscriptionSaysActiveUntil() {
        let state = SubscriptionCardState.make(status: .premium(expiration: Date().addingTimeInterval(9 * 86_400), willRenew: false),
                                               needsVerification: false, expiredAt: nil, plan: "Monthly")
        guard case .active(_, let renewal) = state else { Issue.record("not active"); return }
        #expect(renewal.hasPrefix("Active until"))
    }

    @Test
    func freeAndExpiredAreDistinct() {
        let expired = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(SubscriptionCardState.make(status: .free, needsVerification: false, expiredAt: nil, plan: nil) == .free)
        #expect(SubscriptionCardState.make(status: .free, needsVerification: false, expiredAt: expired, plan: nil) == .expired(expired))
        #expect(SubscriptionCardState.make(status: .free, needsVerification: true, expiredAt: nil, plan: "Monthly") == .verifying(plan: "Monthly"))
    }

    @Test
    func theGearBadgeFollowsTheCardState() {
        #expect(!SettingsBadge.shows(for: .pro, seen: ""), "active Pro: no red badge")
        #expect(SettingsBadge.shows(for: .free, seen: ""), "free, unseen: red 1")
        let expired = SettingsBadge.State.expired(Date(timeIntervalSince1970: 1_790_000_000))
        #expect(SettingsBadge.shows(for: expired, seen: SettingsBadge.seenValue(for: .free) ?? ""), "a new expiry: red 1 again")
    }
}
