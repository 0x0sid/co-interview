import Foundation

/// Where the **public** RevenueCat SDK key comes from, and what happens when it is absent (M5.13).
///
/// Only the *public* client key belongs in the app. RevenueCat secret keys and Apple private
/// credentials must never be embedded or committed — they live in the RevenueCat dashboard and App
/// Store Connect respectively.
///
/// The key is read from the `RevenueCatPublicKey` Info.plist entry, which is fed by a build setting
/// so it can differ per configuration without living in source.
///
/// **Absent configuration is a first-class state, not a crash and not free Premium.** With no key the
/// app runs fully: scripts, editing, the demo and the free daily allowance all work, and Premium is
/// simply unpurchasable. That is what makes it safe to ship this code before the dashboard exists.
enum BillingConfiguration {
    /// Neverblank's one entitlement. The backend checks the same identifier (`backend/access.mjs`).
    static let entitlementIdentifier = "neverblank_pro"

    /// RevenueCat Test Store keys start with this. They simulate purchases without Apple, so a
    /// **Release build refuses them**: it may only ever use the real App Store SDK key.
    static let testStoreKeyPrefix = "test_"

    static var publicAPIKey: String? {
        key(fromPlistValue: Bundle.main.object(forInfoDictionaryKey: "RevenueCatPublicKey") as? String,
            isDebugBuild: ProviderConfiguration.isDebug)
    }

    /// The key a build uses from its raw Info.plist value, or nil when there is none it may use.
    static func key(fromPlistValue raw: String?, isDebugBuild: Bool) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unsubstituted build setting (`$(REVENUECAT_PUBLIC_KEY)`) or an empty string both mean
        // "not configured" rather than a key that happens to be invalid.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return acceptedKey(trimmed, isDebugBuild: isDebugBuild)
    }

    /// The key a build may use: Debug takes a Test Store or App Store key; Release takes only an
    /// App Store key, so a Test Store configuration can never ship.
    static func acceptedKey(_ key: String, isDebugBuild: Bool) -> String? {
        if !isDebugBuild, key.hasPrefix(testStoreKeyPrefix) { return nil }
        return key
    }

    static var isConfigured: Bool { publicAPIKey != nil }
}
