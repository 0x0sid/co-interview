import Testing
import Foundation
@testable import prompter

/// **M5.13 — entitlement state semantics.**
///
/// These cover the decision logic that governs access. They are **not** a substitute for Apple
/// sandbox validation: no real purchase, receipt or RevenueCat backend is exercised here.
@MainActor
struct EntitlementStateTests {

    /// Missing configuration must never grant Premium, and must never crash.
    @Test
    func unconfiguredGrantsNothing() {
        #expect(EntitlementService.Status.unconfigured.allowsUnlimitedReading == false)
        let service = EntitlementService()
        service.configure(cachedPremium: false, cachedAt: nil)
        #expect(service.status == .unconfigured || service.status == .loading)
        #expect(service.localizedPrice == nil, "a price appeared with no configuration")
    }

    /// **A cached entitlement survives a network failure** — a paying reader offline keeps access.
    @Test
    func cachedPremiumSurvivesAnUnavailableBackend() {
        #expect(EntitlementService.Status.unavailable(cachedPremium: true).allowsUnlimitedReading)
        #expect(EntitlementService.Status.unavailable(cachedPremium: false).allowsUnlimitedReading == false)
    }

    /// Verified-inactive must revoke. A local flag that only ever turns on would be trusted forever.
    @Test
    func verifiedFreeRevokesAccess() {
        #expect(EntitlementService.Status.free.allowsUnlimitedReading == false)
        #expect(EntitlementService.Status.loading.allowsUnlimitedReading == false,
                "access was granted while still loading")
    }

    @Test
    func activePremiumGrantsAccessRegardlessOfRenewalIntent() {
        #expect(EntitlementService.Status.premium(expiration: nil, willRenew: true).allowsUnlimitedReading)
        // Cancelled but not yet expired: still entitled until the period ends.
        #expect(EntitlementService.Status.premium(expiration: Date().addingTimeInterval(86_400), willRenew: false)
                    .allowsUnlimitedReading)
    }

    /// Cancellation is a normal outcome, not an error to shout about.
    @Test
    func purchaseOutcomesAreDistinct() {
        let outcomes: [EntitlementService.PurchaseOutcome] =
            [.purchased, .cancelled, .pending, .failed("x"), .notConfigured]
        #expect(Set(outcomes.map { String(describing: $0) }).count == outcomes.count)
        #expect(EntitlementService.PurchaseOutcome.pending != .purchased,
                "pending approval must not be treated as a completed purchase")
    }

    /// Neverblank's one entitlement, the same identifier the backend checks (`backend/access.mjs`).
    @Test
    func entitlementIdentifierMatchesTheBackend() {
        #expect(BillingEnvironment.entitlementIdentifier == "neverblank_pro")
    }

    /// Placeholder or empty values count as unconfigured rather than as a broken key.
    @Test
    func unsubstitutedOrEmptyValuesAreTreatedAsUnconfigured() {
        // Checked on explicit values: the host app's own key depends on a git-ignored local file.
        for raw in [nil, "", "   ", "$(REVENUECAT_API_KEY)"] as [String?] {
            #expect(BillingEnvironment.resolve(mode: "app-store", key: raw, isDebugBuild: false) == nil, "\(raw ?? "nil")")
            #expect(BillingEnvironment.resolve(mode: "test-store", key: raw, isDebugBuild: true) == nil, "\(raw ?? "nil")")
        }
        for mode in [nil, "", "$(BILLING_STORE_MODE)", "sandbox"] as [String?] {
            #expect(BillingEnvironment.resolve(mode: mode, key: "appl_abc", isDebugBuild: false) == nil, "\(mode ?? "nil")")
        }
        #expect(BillingEnvironment.resolve(mode: " app-store ", key: " appl_abc ", isDebugBuild: false)?.apiKey == "appl_abc")
    }

    /// The store is the declared mode, and the key has to agree with it.
    @Test
    func theModeAndTheKeyMustAgree() {
        #expect(BillingEnvironment.resolve(mode: "test-store", key: "appl_abc", isDebugBuild: true) == nil,
                "Test Store mode with an App Store key is a misconfiguration")
        #expect(BillingEnvironment.resolve(mode: "app-store", key: "appl_abc", isDebugBuild: true)?.store == .appStore,
                "a Debug build may be pointed at the App Store on purpose")
    }
}
