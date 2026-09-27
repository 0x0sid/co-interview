import Foundation
import Testing
@testable import prompter

/// The home screen's red "1" on Settings: once per subscription state, cleared for good once seen,
/// never for an active subscription.
struct SettingsBadgeTests {
    static func state(isPro: Bool = false, verifying: Bool = false, server: Bool = true, expired: Date? = nil) -> SettingsBadge.State {
        SettingsBadge.state(isPro: isPro, needsVerification: verifying, usesServerAccess: server, expiredAt: expired)
    }

    @Test
    func anActiveSubscriptionNeverShowsTheBadge() {
        #expect(Self.state(isPro: true) == .pro)
        #expect(!SettingsBadge.shows(for: Self.state(isPro: true), seen: ""))
        #expect(SettingsBadge.seenValue(for: .pro) == nil, "seeing Settings as Pro stores nothing")
    }

    @Test
    func aFreeUserSeesItUntilTheSubscriptionSectionIsSeen() {
        let free = Self.state()
        #expect(free == .free)
        #expect(SettingsBadge.shows(for: free, seen: ""), "never seen: badge")
        let seen = SettingsBadge.seenValue(for: free) ?? ""
        #expect(!SettingsBadge.shows(for: free, seen: seen), "seen: cleared")
    }

    @Test
    func onceClearedItStaysClearedAcrossLaunches() throws {
        let defaults = try #require(UserDefaults(suiteName: "SettingsBadgeTests-\(UUID().uuidString)"))
        defaults.set(SettingsBadge.seenValue(for: .free), forKey: SettingsBadge.storageKey)
        // A later launch reads the stored value back: still free, still cleared.
        let stored = defaults.string(forKey: SettingsBadge.storageKey) ?? ""
        #expect(!SettingsBadge.shows(for: Self.state(), seen: stored))
    }

    @Test
    func anExpiryShowsItOnceMore() {
        let expiry = Date(timeIntervalSince1970: 1_790_000_000)
        let expired = Self.state(expired: expiry)
        let seenWhileFree = SettingsBadge.seenValue(for: .free) ?? ""
        #expect(SettingsBadge.shows(for: expired, seen: seenWhileFree), "a new expired state is worth one more look")
        let seenExpired = SettingsBadge.seenValue(for: expired) ?? ""
        #expect(!SettingsBadge.shows(for: expired, seen: seenExpired))
    }

    @Test
    func nothingWhileVerifyingOrWithoutInstallationAccess() {
        #expect(!SettingsBadge.shows(for: Self.state(verifying: true), seen: ""))
        #expect(!SettingsBadge.shows(for: Self.state(server: false), seen: ""))
    }
}
