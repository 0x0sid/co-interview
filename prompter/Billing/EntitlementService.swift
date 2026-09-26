import Foundation
import Observation
import os
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
    /// Neverblank's plans from the current offering, with the store's localized prices. Empty until
    /// loaded, and whenever the store has none — the paywall then says subscriptions are unavailable.
    private(set) var plans: [PlanOffer] = []
    private(set) var offeringsError: String?
    private(set) var isLoadingOffering = false
    /// The store product behind the active entitlement, for "Neverblank Pro · Monthly".
    private(set) var activeProductIdentifier: String?

    /// How the active purchase is described. The product's name is used only when it agrees with what
    /// the entitlement actually does: a "lifetime" product that expires and renews is shown as the
    /// renewing subscription it is, under its real product id, not as Lifetime.
    var activePlanName: String? {
        guard let id = activeProductIdentifier else { return nil }
        let expires: Bool
        if case .premium(let expiration, _) = status { expires = expiration != nil } else { expires = false }
        guard let named = Self.planName(forProductIdentifier: id) else { return nil }
        let namedLifetime = named == PlanKind.lifetime.title
        if namedLifetime == expires { return "“\(id)” (renewing subscription — misconfigured product)" }
        return named
    }

    nonisolated static func planName(forProductIdentifier identifier: String) -> String? {
        let id = identifier.lowercased()
        for kind in [PlanKind.lifetime, .yearly, .monthly, .weekly] where id.contains(kind.rawValue) || id.contains(kind.periodNoun ?? kind.rawValue) {
            return kind.title
        }
        return nil
    }

    /// One plan as the store sells it. The price text is the store's own string, in the user's App
    /// Store currency; `price` and `currencyCode` exist only for the savings calculation.
    struct PlanOffer: Identifiable, Equatable {
        let kind: PlanKind
        let productIdentifier: String
        let localizedPrice: String
        let price: Decimal
        let currencyCode: String?
        var id: PlanKind { kind }
    }
    #if canImport(RevenueCat)
    private var packagesByPlan: [PlanKind: Package] = [:]
    #endif

    /// Last verified entitlement, persisted by the caller for offline continuity.
    var onVerifiedEntitlementChange: ((Bool, Date?) -> Void)?

    private var streamTask: Task<Void, Never>?

    init() {}

    /// Configures the SDK once. Safe to call when unconfigured — it simply stays `.unconfigured`.
    ///
    /// `appUserID` is the identity the **backend** issued to this installation. When it is not known
    /// yet (the very first launch, before registration answers), the SDK starts anonymous and
    /// `identify(appUserID:)` moves it — and anything bought meanwhile — onto the issued id.
    func configure(appUserID: String? = nil, cachedPremium: Bool, cachedAt: Date?) {
        #if canImport(RevenueCat)
        guard let key = BillingConfiguration.publicAPIKey else {
            status = .unconfigured
            return
        }
        guard !Purchases.isConfigured else { return }
        // No account screen anywhere: the identity is the server-issued installation's.
        if let appUserID {
            Purchases.configure(withAPIKey: key, appUserID: appUserID)
        } else {
            Purchases.configure(withAPIKey: key)
        }
        // Honour the cached entitlement immediately so a premium reader opening the app offline is
        // not downgraded while the network call is in flight.
        status = cachedPremium ? .unavailable(cachedPremium: true) : .loading
        observeCustomerInfo()
        Task { await refresh() }
        #else
        status = .unconfigured
        #endif
    }

    /// Moves RevenueCat onto the identity the backend bound to this installation, so a purchase
    /// lands on the customer the server checks. A no-op when already there or unconfigured.
    func identify(appUserID: String) async {
        #if canImport(RevenueCat)
        guard BillingConfiguration.isConfigured, Purchases.isConfigured,
              Purchases.shared.appUserID != appUserID else { return }
        if let result = try? await Purchases.shared.logIn(appUserID) {
            apply(result.customerInfo)
        }
        #endif
    }

    /// RevenueCat's current App User ID; nil before the SDK is configured.
    var currentAppUserID: String? {
        #if canImport(RevenueCat)
        guard Purchases.isConfigured else { return nil }
        return Purchases.shared.appUserID
        #else
        return nil
        #endif
    }

    /// The RevenueCat **Test Store**: simulated purchases, never billed or managed by Apple.
    var isTestStore: Bool { BillingConfiguration.publicAPIKey?.hasPrefix(BillingConfiguration.testStoreKeyPrefix) == true }

    /// True while RevenueCat says the entitlement is active — or, offline, while the last verified
    /// state was. The backend verifies again for every paid request; this only decides what to offer.
    var hasActivePro: Bool { status.allowsUnlimitedReading }

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
            activeProductIdentifier = entitlement.productIdentifier
            status = .premium(expiration: entitlement.expirationDate, willRenew: entitlement.willRenew)
            onVerifiedEntitlementChange?(true, Date())
        } else {
            // **Confirmed inactive reconciles the cache.** Expiration and revocation must actually
            // revoke; a local premium flag that only ever turns on would be indefinitely trusted.
            activeProductIdentifier = nil
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

    /// Loads the current offering so the paywall can show real, localized prices.
    func loadOffering() async {
        #if canImport(RevenueCat)
        guard BillingConfiguration.isConfigured else { return }
        isLoadingOffering = true
        defer { isLoadingOffering = false }
        do {
            let offerings = try await Purchases.shared.offerings()
            offeringsError = nil
            let current = offerings.current
            // Each package is classified by its store product (period, or one-time), not by its
            // package slot, so a mis-slotted product is still shown as what it is.
            var found: [PlanKind: Package] = [:]
            for package in current?.availablePackages ?? [] {
                let kind = Self.planKind(of: package.storeProduct)
                #if DEBUG
                // What the store says each package is — metadata only, for diagnosing the dashboard.
                let product = package.storeProduct
                Self.log.info("[Plans] package=\(package.identifier, privacy: .public) product=\(product.productIdentifier, privacy: .public) category=\(String(describing: product.productCategory), privacy: .public) type=\(String(describing: product.productType), privacy: .public) period=\(product.subscriptionPeriod.map { "\($0.value) \($0.unit)" } ?? "none", privacy: .public) → \(kind?.rawValue ?? "not sold", privacy: .public)")
                #endif
                // Offered only when the product's name and its store definition agree.
                if let kind, kind.agrees(withProductIdentifier: package.storeProduct.productIdentifier), found[kind] == nil {
                    found[kind] = package
                }
            }
            packagesByPlan = found
            plans = PlanKind.allCases.compactMap { kind in
                guard let package = found[kind] else { return nil }
                let product = package.storeProduct
                return PlanOffer(kind: kind, productIdentifier: product.productIdentifier,
                                 localizedPrice: product.localizedPriceString,
                                 price: product.price, currencyCode: product.currencyCode)
            }
            if plans.isEmpty {
                // Loaded, but the offering has no plan this app sells: say so, never spin.
                offeringsError = "No subscription plans are available right now."
            }
            guard let package = current?.availablePackages.first else {
                localizedPrice = nil
                localizedPeriod = nil
                return
            }
            localizedPrice = package.storeProduct.localizedPriceString
            localizedPeriod = package.storeProduct.subscriptionPeriod.map(Self.describe)
        } catch {
            plans = []
            packagesByPlan = [:]
            offeringsError = "Plans could not be loaded. Check your connection and try again."
            localizedPrice = nil
            localizedPeriod = nil
        }
        #endif
    }

    /// Buys one Neverblank plan. Unlocks only on a verified active entitlement in the result.
    func purchase(plan: PlanKind) async -> PurchaseOutcome {
        #if canImport(RevenueCat)
        guard BillingConfiguration.isConfigured else { return .notConfigured }
        if packagesByPlan[plan] == nil { await loadOffering() }
        guard let package = packagesByPlan[plan] else {
            return .failed("This plan is unavailable right now. Please try again later.")
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled { return .cancelled }
            if result.customerInfo.entitlements[BillingConfiguration.entitlementIdentifier]?.isActive == true {
                apply(result.customerInfo)
                return .purchased
            }
            return .pending
        } catch {
            if let code = error as? ErrorCode, code == .purchaseCancelledError { return .cancelled }
            if let code = error as? ErrorCode, code == .paymentPendingError { return .pending }
            return .failed(error.localizedDescription)
        }
        #else
        return .notConfigured
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

    #if DEBUG
    private static let log = Logger(subsystem: "talk.cointerview", category: "billing")
    #endif

    #if canImport(RevenueCat)
    static func planKind(of product: StoreProduct) -> PlanKind? {
        let unit: String? = product.subscriptionPeriod.map { period in
            switch period.unit {
            case .day: "day"
            case .week: "week"
            case .month: "month"
            case .year: "year"
            @unknown default: "unknown"
            }
        }
        return PlanKind.classify(isSubscription: product.productCategory == .subscription,
                                 periodUnit: unit, periodValue: product.subscriptionPeriod?.value ?? 0)
    }

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
