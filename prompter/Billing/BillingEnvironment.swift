import Foundation

/// Which store Neverblank sells through, and with which **public** RevenueCat SDK key — the one
/// place the app decides it.
///
/// Set per build configuration, never in source: `BILLING_STORE_MODE` and `REVENUECAT_API_KEY` in
/// `prompter/Config/Debug.xcconfig` / `Release.xcconfig`, expanded into the `BillingStoreMode` and
/// `RevenueCatPublicKey` Info.plist entries.
/// - Debug: `test-store` with the RevenueCat Test Store key (`test_…`) — simulated purchases.
/// - Release: `app-store` with the App Store key (`appl_…`) — real purchases. The Release build fails
///   otherwise (`scripts/release-guard.sh`), and this type refuses a Test Store key or mode in a
///   Release binary regardless.
///
/// Only the public client key belongs in the app; RevenueCat secret keys and Apple credentials never
/// do. **Absent configuration is a state, not a crash and not free Pro:** with no usable key the app
/// runs and Pro is simply unpurchasable.
enum BillingEnvironment {
    /// Neverblank's one entitlement. The backend checks the same identifier (`backend/access.mjs`).
    static let entitlementIdentifier = "neverblank_pro"

    enum Store: String, Equatable, Sendable {
        /// RevenueCat Test Store: purchases are simulated, never billed or managed by Apple.
        case testStore = "test-store"
        /// The App Store: real purchases.
        case appStore = "app-store"
    }

    struct Configuration: Equatable, Sendable {
        let store: Store
        let apiKey: String
    }

    static let testStoreKeyPrefix = "test_"

    /// This build's billing, or nil when it has none it may use.
    static var current: Configuration? {
        resolve(mode: Bundle.main.object(forInfoDictionaryKey: "BillingStoreMode") as? String,
                key: Bundle.main.object(forInfoDictionaryKey: "RevenueCatPublicKey") as? String,
                isDebugBuild: ProviderConfiguration.isDebug)
    }

    static var isConfigured: Bool { current != nil }
    static var apiKey: String? { current?.apiKey }
    /// The only condition under which any Test Store wording may appear on screen.
    static var isTestStore: Bool { current?.store == .testStore }

    /// Where Test Store wording may be shown.
    enum TestStoreNotice { case settings, paywall, restore }

    /// The Test Store wording for a place, when this build sells through the Test Store. **Compiled
    /// into Debug only**: a Release binary contains none of these strings, whatever its configuration.
    static func testStoreNotice(_ place: TestStoreNotice) -> String? {
        #if DEBUG
        guard isTestStore else { return nil }
        switch place {
        case .settings: return "Test Store · simulated purchases"
        case .paywall: return "Test Store · simulated purchases, not billed by Apple"
        case .restore: return "Test Store restore: this reflects RevenueCat's simulated purchases, not an Apple restore."
        }
        #else
        return nil
        #endif
    }

    /// The mode and the key must agree: a Test Store key only in `test-store`, never in a Release
    /// binary; `app-store` never with a Test Store key. Unsubstituted or empty values count as absent.
    static func resolve(mode rawMode: String?, key rawKey: String?, isDebugBuild: Bool) -> Configuration? {
        guard let mode = cleaned(rawMode).flatMap(Store.init(rawValue:)),
              let key = cleaned(rawKey) else { return nil }
        let isTestKey = key.hasPrefix(testStoreKeyPrefix)
        switch mode {
        case .testStore:
            guard isDebugBuild, isTestKey else { return nil }
        case .appStore:
            guard !isTestKey else { return nil }
        }
        return Configuration(store: mode, apiKey: key)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}
