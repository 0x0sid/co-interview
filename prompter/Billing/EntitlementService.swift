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
    /// When a subscription this customer had has lapsed — for "Expired on …". Nil if never subscribed.
    private(set) var expiredAt: Date?
    /// RevenueCat's facts about the Pro subscription — the active one, or the last one after it lapsed.
    /// Nil for a customer who never subscribed.
    private(set) var subscription: SubscriptionDetails?
    /// Each product's billing period and price, **from the store product itself** (offering packages,
    /// or a product lookup for one no longer offered). Never from the product id, never from dates.
    private var metadataByProduct: [String: ProductMetadata] = [:]

    /// What the store says one product is.
    struct ProductMetadata: Equatable {
        var period: PlanPeriod
        /// The store's own price string ("$9.99", "9,99 US$").
        var localizedPrice: String
    }

    /// A plan's billing period, from the product's subscription period only.
    enum PlanPeriod: Equatable {
        case weekly, monthly, yearly
        /// A one-time (non-subscription) purchase.
        case lifetime
        /// A subscription period this app does not name (3 months, 6 months…). Shown as the generic
        /// "Subscription" — never guessed from the product id.
        case other

        init(kind: PlanKind?) {
            switch kind {
            case .weekly: self = .weekly
            case .monthly: self = .monthly
            case .yearly: self = .yearly
            case .lifetime: self = .lifetime
            case nil: self = .other
            }
        }

        /// From the store product's category and subscription period.
        static func of(isSubscription: Bool, unit: String?, value: Int) -> PlanPeriod {
            PlanPeriod(kind: PlanKind.classify(isSubscription: isSubscription, periodUnit: unit, periodValue: value))
        }

        var title: String {
            switch self {
            case .weekly: "Weekly"
            case .monthly: "Monthly"
            case .yearly: "Yearly"
            case .lifetime: "Lifetime"
            case .other: "Subscription"
            }
        }

        /// "week", "month", "year" for a price line; nil when the period has no one-word name.
        var noun: String? {
            switch self {
            case .weekly: "week"
            case .monthly: "month"
            case .yearly: "year"
            case .lifetime, .other: nil
            }
        }

        /// A specific plan worth naming after it lapsed; `.other` is not.
        var isNamed: Bool { self != .other }
    }

    /// What RevenueCat says about one subscription. Every date here is RevenueCat's own — nothing is
    /// computed from a purchase date plus a period, which trials, intro offers, billing retries,
    /// grace periods and plan changes would all make wrong.
    struct SubscriptionDetails: Equatable {
        var productIdentifier: String
        /// From the product's subscription period. Nil until the store has described the product.
        var period: PlanPeriod?
        /// The entitlement's expiration: the renewal date while it renews, the end date once cancelled.
        var expiration: Date?
        var willRenew: Bool
        /// The store could not charge the renewal (RevenueCat `billingIssueDetectedAt`).
        var billingIssueDetectedAt: Date?
        /// Apple's billing grace period, while access continues despite the billing issue.
        var gracePeriodExpiresDate: Date?
        /// The store's price string for this product, when known.
        var localizedPrice: String?
    }

    /// The one normalized subscription state every screen reads. RevenueCat's fields are mapped in
    /// `apply(_:)` and nowhere else; views only word this.
    struct SubscriptionPresentation: Equatable {
        var entitlementActive: Bool
        /// Store-recognised, not yet confirmed by the backend.
        var needsVerification: Bool
        var planPeriod: PlanPeriod?
        var expirationDate: Date?
        var willRenew: Bool
        var billingIssueDetected: Bool
        /// Active only while RevenueCat's grace period has not ended.
        var gracePeriodActive: Bool
        var gracePeriodExpiresDate: Date?
        var productIdentifier: String?
        var localizedPrice: String?
        /// "$9.99 / month", from the store's price and the product's own period.
        var localizedPricePerPeriod: String?
        /// A subscription existed and lapsed (Expired), as opposed to never subscribed (Free).
        var hasLapsed: Bool

        static let none = SubscriptionPresentation(entitlementActive: false, needsVerification: false, planPeriod: nil,
                                                   expirationDate: nil, willRenew: false, billingIssueDetected: false,
                                                   gracePeriodActive: false, gracePeriodExpiresDate: nil,
                                                   productIdentifier: nil, localizedPrice: nil,
                                                   localizedPricePerPeriod: nil, hasLapsed: false)
    }

    /// The subscription as the UI should describe it right now.
    func presentation(needsVerification: Bool = false, now: Date = .now) -> SubscriptionPresentation {
        var result = SubscriptionPresentation.none
        result.needsVerification = needsVerification
        if case .premium = status { result.entitlementActive = true }
        guard let details = subscription else { return result }
        let price = details.localizedPrice ?? metadataByProduct[details.productIdentifier]?.localizedPrice
        let period = details.period ?? metadataByProduct[details.productIdentifier]?.period
        result.planPeriod = period
        result.productIdentifier = details.productIdentifier
        result.expirationDate = details.expiration
        result.willRenew = details.willRenew
        result.billingIssueDetected = details.billingIssueDetectedAt != nil
        result.gracePeriodExpiresDate = details.gracePeriodExpiresDate
        result.gracePeriodActive = result.entitlementActive && (details.gracePeriodExpiresDate.map { $0 > now } ?? false)
        result.localizedPrice = price
        result.localizedPricePerPeriod = price.flatMap { price in period?.noun.map { "\(price) / \($0)" } }
        result.hasLapsed = !result.entitlementActive && details.expiration != nil
        return result
    }

    /// Whether a plan can be bought from the paywall right now.
    enum PlanAvailability: Equatable {
        case purchasable
        /// The plan the active `neverblank_pro` entitlement comes from: never bought twice.
        case current
        /// A shorter plan while a longer one is active: changed in Apple's subscription settings,
        /// not bought on top of it.
        case managedByApple
    }

    /// Which plans the paywall may sell, from RevenueCat's CustomerInfo (never a local flag).
    ///
    /// The current plan is the offered product whose **store product id equals the entitlement's
    /// `productIdentifier`** — no id parsing. A longer plan than the current one is an upgrade and
    /// stays purchasable (StoreKit changes the subscription within the group); a shorter one is left
    /// to Apple's subscription management. Inactive — including a Sandbox period that has lapsed —
    /// everything is purchasable again. An active entitlement from a product the offering does not
    /// contain cannot be placed, so nothing is marked current.
    static func planAvailability(for plans: [PlanOffer], subscription: SubscriptionPresentation) -> [PlanKind: PlanAvailability] {
        var result = Dictionary(uniqueKeysWithValues: plans.map { ($0.kind, PlanAvailability.purchasable) })
        guard subscription.entitlementActive, let activeID = subscription.productIdentifier,
              let current = plans.first(where: { $0.productIdentifier == activeID }) else { return result }
        let currentWeeks = current.kind.weeks ?? .greatestFiniteMagnitude
        for plan in plans {
            if plan.kind == current.kind {
                result[plan.kind] = .current
            } else if let weeks = plan.kind.weeks, weeks > currentWeeks {
                result[plan.kind] = .purchasable
            } else {
                result[plan.kind] = .managedByApple
            }
        }
        return result
    }

    /// What the paywall's main button does. Two modes, from the entitlement alone:
    /// **not subscribed** (never subscribed, expired, lapsed — `neverblank_pro` inactive) sells every
    /// plan as new; **subscribed** (`neverblank_pro` active) never sells the active plan again.
    enum PaywallAction: Equatable {
        /// Not subscribed: buy the selected plan. "Become Pro" — never "Renew".
        case becomePro
        /// Subscribed, and the selected plan is a longer one than the current plan: StoreKit changes
        /// the subscription within the group.
        case upgrade(PlanKind)
        /// Subscribed with nothing to buy here: the longest plan is active, or the active product is
        /// not one the offering contains. Apple's subscription management.
        case manageSubscription
    }

    static func paywallAction(selected: PlanKind, availability: [PlanKind: PlanAvailability],
                              subscription: SubscriptionPresentation) -> PaywallAction {
        guard subscription.entitlementActive else { return .becomePro }
        // Upgrading needs a placed current plan: an active product the offering does not contain
        // cannot be compared, so it is only ever managed.
        if availability[selected] == .purchasable, availability.values.contains(.current) {
            return .upgrade(selected)
        }
        return .manageSubscription
    }

    /// "Monthly" for the active plan (the Home badge); nil when inactive or not yet described.
    var activePlanName: String? {
        let current = presentation()
        guard current.entitlementActive else { return nil }
        return current.planPeriod?.title
    }

    /// The one place a verified entitlement lands — purchase, restore, refresh and the SDK's
    /// customer-info stream all come through here, so each of them updates the plan, its period, its
    /// dates, its billing state and its price together, never only the Pro boolean.
    func update(isActive: Bool, details: SubscriptionDetails?) {
        var details = details
        if let id = details?.productIdentifier, let metadata = metadataByProduct[id] {
            if details?.period == nil { details?.period = metadata.period }
            if details?.localizedPrice == nil { details?.localizedPrice = metadata.localizedPrice }
        }
        subscription = details
        if isActive {
            activeProductIdentifier = details?.productIdentifier
            expiredAt = nil
            status = .premium(expiration: details?.expiration, willRenew: details?.willRenew ?? false)
        } else {
            // **Confirmed inactive reconciles the cache.** Expiration and revocation must actually
            // revoke; a local premium flag that only ever turns on would be indefinitely trusted.
            activeProductIdentifier = nil
            expiredAt = details?.expiration
            status = .free
        }
        onVerifiedEntitlementChange?(isActive, Date())
    }

    /// Records what the store says a product is, and fills it into the current subscription.
    func record(productIdentifier id: String, metadata: ProductMetadata) {
        metadataByProduct[id] = metadata
        guard subscription?.productIdentifier == id else { return }
        if subscription?.period == nil { subscription?.period = metadata.period }
        if subscription?.localizedPrice == nil { subscription?.localizedPrice = metadata.localizedPrice }
    }

    /// One plan as the store sells it. The price text is the store's own string, in the user's App
    /// Store currency; `price` and `currencyCode` exist only for the savings calculation.
    struct PlanOffer: Identifiable, Equatable {
        let kind: PlanKind
        let productIdentifier: String
        let localizedPrice: String
        let price: Decimal
        let currencyCode: String?
        /// The store's own per-month price for this product (RevenueCat `localizedPricePerMonth`,
        /// computed from the product's price with its own formatter).
        var storePricePerMonth: String? = nil
        var id: PlanKind { kind }

        /// A yearly plan's price per month, from the yearly product's own price: the store's per-month
        /// string when it gives one, otherwise that price over 12 in its own currency. Nil for other
        /// plans. Shown beside the annual total, never instead of it.
        var monthlyEquivalent: String? {
            guard kind == .yearly, price > 0 else { return nil }
            if let storePricePerMonth { return storePricePerMonth }
            guard let currencyCode else { return nil }
            return Self.format(price / 12, currencyCode: currencyCode)
        }

        /// "$9.99 / week" — the store's price and the plan's period.
        var pricePerPeriod: String {
            kind.periodNoun.map { "\(localizedPrice) / \($0)" } ?? localizedPrice
        }

        static func format(_ amount: Decimal, currencyCode: String, locale: Locale = .current) -> String {
            var rounded = Decimal()
            var value = amount
            NSDecimalRound(&rounded, &value, 2, .plain)
            return rounded.formatted(.currency(code: currencyCode).locale(locale))
        }
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
        guard let key = BillingEnvironment.apiKey else {
            status = .unconfigured
            return
        }
        guard !Purchases.isConfigured else { return }
        #if !DEBUG
        // Release: RevenueCat's own warnings and errors only, no informational logging.
        Purchases.logLevel = .warn
        #endif
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
        guard BillingEnvironment.isConfigured, Purchases.isConfigured,
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
        let entitlement = info.entitlements[BillingEnvironment.entitlementIdentifier]
        let details = entitlement.map { entitlement in
            // The per-product subscription record carries the grace period; the entitlement does not.
            let record = info.subscriptionsByProductIdentifier[entitlement.productIdentifier]
            return SubscriptionDetails(
                productIdentifier: entitlement.productIdentifier,
                expiration: entitlement.expirationDate,
                willRenew: entitlement.willRenew,
                billingIssueDetectedAt: entitlement.billingIssueDetectedAt ?? record?.billingIssuesDetectedAt,
                gracePeriodExpiresDate: record?.gracePeriodExpiresDate
            )
        }
        update(isActive: entitlement?.isActive == true, details: details)
        if let id = details?.productIdentifier, metadataByProduct[id] == nil {
            Task { await resolveMetadata(ofProduct: id) }
        }
    }

    /// Asks the store what the entitled product is when the offering did not say — a plan no longer
    /// offered, or a customer who bought before the offering loaded. No answer leaves the period
    /// unknown: an active plan is then "Subscription", a lapsed one names no plan.
    private func resolveMetadata(ofProduct id: String) async {
        guard let product = await Purchases.shared.products([id]).first else { return }
        record(product)
    }

    private func record(_ product: StoreProduct) {
        record(productIdentifier: product.productIdentifier,
               metadata: ProductMetadata(period: Self.planPeriod(of: product), localizedPrice: product.localizedPriceString))
    }
    #endif

    /// Current CustomerInfo from RevenueCat's server, applied. Never the SDK's cache: a cached
    /// CustomerInfo judges "active" against its own request date, so a plan that has changed or ended
    /// since keeps reading as the old plan, still active (Monthly after a change to Yearly), for up to
    /// the cache's five minutes — a whole Sandbox month. False when the fetch failed; nothing changes.
    @discardableResult
    private func fetchCurrentCustomerInfo() async -> Bool {
        #if canImport(RevenueCat)
        Purchases.shared.invalidateCustomerInfoCache()
        do {
            apply(try await Purchases.shared.customerInfo(fetchPolicy: .fetchCurrent))
            return true
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    func refresh() async {
        #if canImport(RevenueCat)
        guard BillingEnvironment.isConfigured else { status = .unconfigured; return }
        if await fetchCurrentCustomerInfo() {
            await loadOffering()
        } else {
            // Preserve whatever access was already verified; do not downgrade on a network blip.
            status = .unavailable(cachedPremium: status.allowsUnlimitedReading)
        }
        #endif
    }

    /// Loads the current offering so the paywall can show real, localized prices.
    func loadOffering() async {
        #if canImport(RevenueCat)
        guard BillingEnvironment.isConfigured else { return }
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
                record(package.storeProduct)
                let kind = Self.planKind(of: package.storeProduct)
                #if DEBUG
                // What the store says each package is — metadata only, for diagnosing the dashboard.
                let product = package.storeProduct
                Self.log.info("[Plans] package=\(package.identifier, privacy: .public) product=\(product.productIdentifier, privacy: .public) category=\(String(describing: product.productCategory), privacy: .public) type=\(String(describing: product.productType), privacy: .public) period=\(product.subscriptionPeriod.map { "\($0.value) \($0.unit)" } ?? "none", privacy: .public) → \(kind?.rawValue ?? "not sold", privacy: .public)")
                #endif
                // The plan is what the store product is (its category and subscription period) —
                // never what its package or product id is called. Lifetime is not sold to new
                // customers; an existing lifetime entitlement is unaffected.
                if let kind, kind != .lifetime, found[kind] == nil {
                    found[kind] = package
                }
            }
            packagesByPlan = found
            plans = PlanKind.allCases.compactMap { kind in
                guard let package = found[kind] else { return nil }
                let product = package.storeProduct
                return PlanOffer(kind: kind, productIdentifier: product.productIdentifier,
                                 localizedPrice: product.localizedPriceString,
                                 price: product.price, currencyCode: product.currencyCode,
                                 storePricePerMonth: kind == .yearly ? product.localizedPricePerMonth : nil)
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
        guard BillingEnvironment.isConfigured else { return .notConfigured }
        if packagesByPlan[plan] == nil { await loadOffering() }
        guard let package = packagesByPlan[plan] else {
            return .failed("This plan is unavailable right now. Please try again later.")
        }
        isPurchasing = true
        defer { isPurchasing = false }
        // Never start a StoreKit purchase for the product the active entitlement already comes from —
        // judged on current CustomerInfo, so a plan changed in Apple's settings is already known.
        await fetchCurrentCustomerInfo()
        if case .premium = status, subscription?.productIdentifier == package.storeProduct.productIdentifier {
            return .failed("This is already your current plan.")
        }
        let outcome: PurchaseOutcome
        do {
            let result = try await Purchases.shared.purchase(package: package)
            apply(result.customerInfo)
            if result.userCancelled {
                outcome = .cancelled
            } else {
                outcome = result.customerInfo.entitlements[BillingEnvironment.entitlementIdentifier]?.isActive == true
                    ? .purchased : .pending
            }
        } catch {
            if let code = error as? ErrorCode, code == .purchaseCancelledError { outcome = .cancelled }
            else if let code = error as? ErrorCode, code == .paymentPendingError { outcome = .pending }
            else { outcome = .failed(error.localizedDescription) }
        }
        // Whatever StoreKit answered — bought, pending, "already subscribed", cancelled — the plan
        // shown afterwards is RevenueCat's current one.
        await fetchCurrentCustomerInfo()
        return outcome
        #else
        return .notConfigured
        #endif
    }

    func purchase() async -> PurchaseOutcome {
        #if canImport(RevenueCat)
        guard BillingEnvironment.isConfigured else { return .notConfigured }
        guard let offerings = try? await Purchases.shared.offerings(),
              let package = offerings.current?.availablePackages.first else {
            return .failed("Subscriptions are unavailable right now. Please try again later.")
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled { return .cancelled }
            let entitlement = result.customerInfo.entitlements[BillingEnvironment.entitlementIdentifier]
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
        guard BillingEnvironment.isConfigured else { return .notConfigured }
        do {
            let info = try await Purchases.shared.restorePurchases()
            apply(info)
            return info.entitlements[BillingEnvironment.entitlementIdentifier]?.isActive == true
                ? .purchased
                : .failed("No previous purchase was found for this Apple Account.")
        } catch {
            return .failed(error.localizedDescription)
        }
        #else
        return .notConfigured
        #endif
    }

    /// Native manage-subscription sheet. A plan changed or cancelled there is read back when the
    /// sheet closes, and once more a few seconds later, when Apple has usually delivered the change.
    func showManageSubscriptions() async {
        #if canImport(RevenueCat)
        guard BillingEnvironment.isConfigured else { return }
        try? await Purchases.shared.showManageSubscriptions()
        await fetchCurrentCustomerInfo()
        try? await Task.sleep(for: .seconds(5))
        await fetchCurrentCustomerInfo()
        #endif
    }

    #if DEBUG
    private static let log = Logger(subsystem: "io.neverblank.app", category: "billing")
    #endif

    #if canImport(RevenueCat)
    static func planPeriod(of product: StoreProduct) -> PlanPeriod {
        PlanPeriod(kind: planKind(of: product))
    }

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
