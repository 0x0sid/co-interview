import Foundation
import Observation
#if canImport(RevenueCat)
import RevenueCat
#endif

/// Premium entitlement state, backed by RevenueCat (M5.13).
///
/// Verified against the installed SDK **5.83.1**: `Purchases.configure(withAPIKey:)`,
/// `Purchases.shared.offerings()`, `purchase(package:)`, `restorePurchases()`,
/// `customerInfoStream`, `showManageSubscriptions()`, and `EntitlementInfo.isActive/willRenew/
/// expirationDate` (checked in the checked-out package sources, not assumed).
@MainActor
@Observable
final class EntitlementService {

    enum Status: Equatable {
        /// No key configured — Premium cannot be bought. Not an error, not an entitlement.
        case unconfigured
        case loading
        /// Verified inactive.
        case free
        /// Verified active, with the renewal facts needed to describe it honestly.
        case premium(expiration: Date?, willRenew: Bool)
        /// Network or backend failure. Carries whether cached access is being honoured meanwhile.
        case unavailable(cachedPremium: Bool)

        var allowsUnlimitedReading: Bool {
            switch self {
            case .premium: true
            case .unavailable(let cached): cached
            case .unconfigured, .loading, .free: false
            }
        }
    }

    enum PurchaseOutcome: Equatable {
        case purchased
        case cancelled
        /// Ask to Buy / Strong Customer Authentication — approval is pending, nothing is unlocked.
        case pending
        case failed(String)
        case notConfigured
    }

    private(set) var status: Status = .unconfigured
    /// Localized price straight from store product data. **Never a hardcoded dollar amount.**
    private(set) var localizedPrice: String?
    private(set) var localizedPeriod: String?
    private(set) var isPurchasing = false

    /// Last verified entitlement, persisted by the caller for offline continuity.
    var onVerifiedEntitlementChange: ((Bool, Date?) -> Void)?

    private var streamTask: Task<Void, Never>?

    init() {}

    /// Configures the SDK once. Safe to call when unconfigured — it simply stays `.unconfigured`.
    func configure(cachedPremium: Bool, cachedAt: Date?) {
        #if canImport(RevenueCat)
        guard let key = BillingConfiguration.publicAPIKey else {
            status = .unconfigured
            return
        }
        // Anonymous by design: no account requirement anywhere in the product.
        Purchases.configure(withAPIKey: key)
        // Honour the cached entitlement immediately so a premium reader opening the app offline is
        // not downgraded while the network call is in flight.
        status = cachedPremium ? .unavailable(cachedPremium: true) : .loading
        observeCustomerInfo()
        Task { await refresh() }
        #else
        status = .unconfigured
        #endif
    }

    #if canImport(RevenueCat)
    /// Reacts to entitlement changes pushed by the SDK. **Never interrupts a take** — this only
    /// updates state; nothing here touches the matcher, the session or the scroll.
    private func observeCustomerInfo() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                guard !Task.isCancelled else { return }
                await self?.apply(info)
            }
        }
    }

    private func apply(_ info: CustomerInfo) {
        let entitlement = info.entitlements[BillingConfiguration.entitlementIdentifier]
        if let entitlement, entitlement.isActive {
            status = .premium(expiration: entitlement.expirationDate, willRenew: entitlement.willRenew)
            onVerifiedEntitlementChange?(true, Date())
        } else {
            // **Confirmed inactive reconciles the cache.** Expiration and revocation must actually
            // revoke; a local premium flag that only ever turns on would be indefinitely trusted.
            status = .free
            onVerifiedEntitlementChange?(false, Date())
        }
    }
    #endif

    func refresh() async {
        #if canImport(RevenueCat)
        guard BillingConfiguration.isConfigured else { status = .unconfigured; return }
        do {
            let info = try await Purchases.shared.customerInfo()
            apply(info)
            await loadOffering()
        } catch {
            // Preserve whatever access was already verified; do not downgrade on a network blip.
            status = .unavailable(cachedPremium: status.allowsUnlimitedReading)
        }
        #endif
    }

    /// Loads the current offering so the paywall can show a real, localized price.
    func loadOffering() async {
        #if canImport(RevenueCat)
        guard BillingConfiguration.isConfigured else { return }
        do {
            let offerings = try await Purchases.shared.offerings()
            guard let package = offerings.current?.availablePackages.first else {
                localizedPrice = nil
                localizedPeriod = nil
                return
            }
            localizedPrice = package.storeProduct.localizedPriceString
            localizedPeriod = package.storeProduct.subscriptionPeriod.map(Self.describe)
        } catch {
            localizedPrice = nil
            localizedPeriod = nil
        }
        #endif
    }

    func purchase() async -> PurchaseOutcome {
        #if canImport(RevenueCat)
        guard BillingConfiguration.isConfigured else { return .notConfigured }
        guard let offerings = try? await Purchases.shared.offerings(),
              let package = offerings.current?.availablePackages.first else {
            return .failed("Subscriptions are unavailable right now. Please try again later.")
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled { return .cancelled }
            let entitlement = result.customerInfo.entitlements[BillingConfiguration.entitlementIdentifier]
            if entitlement?.isActive == true {
                apply(result.customerInfo)
                return .purchased
            }
            // Purchased but not yet entitled: Ask to Buy and similar deferred approvals.
            return .pending
        } catch {
            return .failed(error.localizedDescription)
        }
        #else
        return .notConfigured
        #endif
    }

    func restore() async -> PurchaseOutcome {
        #if canImport(RevenueCat)
        guard BillingConfiguration.isConfigured else { return .notConfigured }
        do {
            let info = try await Purchases.shared.restorePurchases()
            apply(info)
            return info.entitlements[BillingConfiguration.entitlementIdentifier]?.isActive == true
                ? .purchased
                : .failed("No previous purchase was found for this Apple Account.")
        } catch {
            return .failed(error.localizedDescription)
        }
        #else
        return .notConfigured
        #endif
    }

    /// Native manage-subscription sheet.
    func showManageSubscriptions() async {
        #if canImport(RevenueCat)
        guard BillingConfiguration.isConfigured else { return }
        try? await Purchases.shared.showManageSubscriptions()
        #endif
    }

    #if canImport(RevenueCat)
    private static func describe(_ period: SubscriptionPeriod) -> String {
        let n = period.value
        switch period.unit {
        case .day: return n == 1 ? "day" : "\(n) days"
        case .week: return n == 1 ? "week" : "\(n) weeks"
        case .month: return n == 1 ? "month" : "\(n) months"
        case .year: return n == 1 ? "year" : "\(n) years"
        @unknown default: return "period"
        }
    }
    #endif
}
