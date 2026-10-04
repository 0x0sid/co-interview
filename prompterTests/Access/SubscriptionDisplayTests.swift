import Foundation
import Testing
@testable import prompter

/// Settings › Neverblank Pro, from RevenueCat's facts through the one normalized state
/// (`EntitlementService.SubscriptionPresentation`) to the words on the card.
///
/// Every date here is one RevenueCat would report; nothing adds a period to a purchase date. Every
/// plan name comes from the store product's period (`record(productIdentifier:metadata:)`); the
/// product ids below are deliberately neutral or misleading, so a pass cannot come from reading them.
@MainActor
struct SubscriptionDisplayTests {
    typealias Period = EntitlementService.PlanPeriod
    static let us = Locale(identifier: "en_US")
    /// A fixed "now", far from every date below, so no line gains a time of day.
    static let now = date(2026, 9, 29)

    nonisolated static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    /// A service holding what RevenueCat and the store said, as purchase, restore and refresh leave it.
    static func service(active: Bool, id: String = "neverblank_pro_1", period: Period?, price: String? = "$9.99",
                        end: Date?, renews: Bool, billingIssue: Date? = nil, grace: Date? = nil) -> EntitlementService {
        let service = EntitlementService()
        if let period {
            service.record(productIdentifier: id, metadata: .init(period: period, localizedPrice: price ?? ""))
        }
        service.update(isActive: active, details: .init(productIdentifier: id, expiration: end, willRenew: renews,
                                                        billingIssueDetectedAt: billingIssue, gracePeriodExpiresDate: grace))
        return service
    }

    static func card(_ service: EntitlementService, locale: Locale = us) -> SubscriptionCardState {
        SubscriptionCardState.make(service.presentation(now: now), now: now, locale: locale)
    }

    // MARK: Weekly, monthly, yearly × renewing, cancelled

    @Test(arguments: [(Period.weekly, "Weekly", SubscriptionDisplayTests.date(2026, 10, 6), "Oct 6, 2026"),
                      (Period.monthly, "Monthly", SubscriptionDisplayTests.date(2026, 10, 29), "Oct 29, 2026"),
                      (Period.yearly, "Yearly", SubscriptionDisplayTests.date(2027, 9, 29), "Sep 29, 2027")])
    func activeRenewingShowsThePlanAndRenewsDate(period: Period, title: String, end: Date, shown: String) {
        let service = Self.service(active: true, period: period, end: end, renews: true)
        #expect(Self.card(service) == .active(plan: title, detail: "Renews \(shown)", notice: nil))
        #expect(service.hasActivePro)
    }

    @Test(arguments: [(Period.weekly, "Weekly", SubscriptionDisplayTests.date(2026, 10, 6), "Oct 6, 2026"),
                      (Period.monthly, "Monthly", SubscriptionDisplayTests.date(2026, 10, 29), "Oct 29, 2026"),
                      (Period.yearly, "Yearly", SubscriptionDisplayTests.date(2027, 9, 29), "Sep 29, 2027")])
    func activeCancelledSaysActiveUntilAndKeepsPro(period: Period, title: String, end: Date, shown: String) {
        let service = Self.service(active: true, period: period, end: end, renews: false)
        let state = Self.card(service)
        #expect(state == .active(plan: title, detail: "Active until \(shown)", notice: .cancelled))
        #expect(service.hasActivePro, "not expired yet: Pro stays until the real end")
        #expect(!state.accessibilitySummary.contains("Renews") && !state.accessibilitySummary.contains("expired"))
    }

    // MARK: Billing

    @Test
    func aGracePeriodKeepsProAndSaysBillingIssueUntilItsEnd() {
        let graceEnd = Self.date(2026, 10, 12)
        let service = Self.service(active: true, period: .monthly, end: graceEnd, renews: true,
                                   billingIssue: Self.date(2026, 9, 28), grace: graceEnd)
        let presentation = service.presentation(now: Self.now)
        #expect(presentation.entitlementActive && presentation.gracePeriodActive && presentation.billingIssueDetected)
        #expect(Self.card(service) == .active(plan: "Monthly", detail: "Access remains active until Oct 12, 2026", notice: .billingIssue))
        #expect(service.hasActivePro && service.expiredAt == nil, "never Expired while the entitlement holds")
    }

    @Test
    func aBillingIssueAfterTheEntitlementEndedIsExpiredWithTheIssue() {
        let service = Self.service(active: false, period: .monthly, end: Self.date(2026, 9, 27), renews: true,
                                   billingIssue: Self.date(2026, 9, 20))
        #expect(Self.card(service) == .expired(plan: "Monthly", date: Self.date(2026, 9, 27), billingIssue: true))
        #expect(!service.hasActivePro)
    }

    // MARK: Expired and free

    @Test
    func expiredRetainsTheLastKnownPlan() {
        let service = Self.service(active: false, period: .monthly, end: Self.date(2026, 9, 27), renews: false)
        #expect(Self.card(service) == .expired(plan: "Monthly", date: Self.date(2026, 9, 27), billingIssue: false))
    }

    @Test
    func expiredWithAnUnknownPlanNamesNone() {
        let unknown = Self.service(active: false, period: nil, end: Self.date(2026, 9, 27), renews: false)
        #expect(Self.card(unknown) == .expired(plan: nil, date: Self.date(2026, 9, 27), billingIssue: false))
        let unnamed = Self.service(active: false, period: .other, end: Self.date(2026, 9, 27), renews: false)
        #expect(Self.card(unnamed) == .expired(plan: nil, date: Self.date(2026, 9, 27), billingIssue: false),
                "a period the app does not name is not a plan worth naming after it lapsed")
    }

    @Test
    func neverSubscribedIsTheUpgradeState() {
        let service = EntitlementService()
        service.update(isActive: false, details: nil)
        #expect(Self.card(service) == .free)
        #expect(service.presentation() == .none)
    }

    // MARK: Refresh paths

    /// Restore lands through the same update as a purchase: the whole state comes back, not only "Pro".
    @Test
    func restoreBringsBackPlanDateRenewalAndPrice() {
        let service = EntitlementService()
        service.record(productIdentifier: "neverblank_pro_1", metadata: .init(period: .yearly, localizedPrice: "$79.99"))
        #expect(Self.card(service) == .free, "before the restore")
        service.update(isActive: true, details: .init(productIdentifier: "neverblank_pro_1", expiration: Self.date(2027, 9, 29),
                                                      willRenew: false))
        let restored = service.presentation(now: Self.now)
        #expect(restored.entitlementActive && restored.planPeriod == .yearly && !restored.willRenew)
        #expect(restored.expirationDate == Self.date(2027, 9, 29))
        #expect(restored.localizedPrice == "$79.99" && restored.localizedPricePerPeriod == "$79.99 / year")
        #expect(Self.card(service) == .active(plan: "Yearly", detail: "Active until Sep 29, 2027", notice: .cancelled))
    }

    /// A purchase refreshes the state in place; the product's metadata may arrive after the
    /// entitlement (a plan bought before the offering loaded) and fills the same state.
    @Test
    func aPurchaseRefreshUpdatesTheStateAndLateMetadataFillsThePlan() {
        let service = EntitlementService()
        service.update(isActive: false, details: .init(productIdentifier: "neverblank_pro_1", expiration: Self.date(2026, 9, 1),
                                                       willRenew: false))
        #expect(Self.card(service) == .expired(plan: nil, date: Self.date(2026, 9, 1), billingIssue: false))
        service.update(isActive: true, details: .init(productIdentifier: "neverblank_pro_1", expiration: Self.date(2026, 10, 6),
                                                      willRenew: true))
        #expect(Self.card(service) == .active(plan: nil, detail: "Renews Oct 6, 2026", notice: nil), "plan unknown until the store says")
        service.record(productIdentifier: "neverblank_pro_1", metadata: .init(period: .weekly, localizedPrice: "$4.99"))
        #expect(Self.card(service) == .active(plan: "Weekly", detail: "Renews Oct 6, 2026", notice: nil))
        #expect(service.activePlanName == "Weekly")
        #expect(service.presentation().localizedPricePerPeriod == "$4.99 / week")
    }

    // MARK: Metadata, not ids

    /// An id that names another plan does not change what the store says the product is.
    @Test
    func thePlanComesFromStoreMetadataNotTheProductIdentifier() {
        let service = Self.service(active: true, id: "io.neverblank.pro.monthly", period: .yearly,
                                   end: Self.date(2027, 9, 29), renews: true)
        #expect(Self.card(service) == .active(plan: "Yearly", detail: "Renews Sep 29, 2027", notice: nil))
        let unlabelled = Self.service(active: true, id: "io.neverblank.pro.weekly", period: nil,
                                      end: Self.date(2026, 10, 6), renews: true)
        #expect(unlabelled.activePlanName == nil, "no store metadata: the id's 'weekly' is not read")
    }

    @Test
    func anUnexpectedPeriodIsTheGenericSubscription() {
        #expect(Period.of(isSubscription: true, unit: "month", value: 3) == .other)
        #expect(Period.of(isSubscription: true, unit: "month", value: 6) == .other)
        #expect(Period.of(isSubscription: true, unit: "week", value: 1) == .weekly)
        #expect(Period.of(isSubscription: true, unit: "month", value: 1) == .monthly)
        #expect(Period.of(isSubscription: true, unit: "year", value: 1) == .yearly)
        #expect(Period.of(isSubscription: false, unit: nil, value: 0) == .lifetime)
        let service = Self.service(active: true, period: .other, end: Self.date(2026, 12, 29), renews: true)
        #expect(Self.card(service) == .active(plan: "Subscription", detail: "Renews Dec 29, 2026", notice: nil))
        #expect(service.presentation().localizedPricePerPeriod == nil, "no invented '/ period' for an unnamed period")
    }

    // MARK: Prices and dates

    /// The store's own strings, whatever the currency and locale; the app adds only "/ week".
    @Test
    func localizedStorePricesAreUsedAsGiven() {
        let euro = EntitlementService.PlanOffer(kind: .weekly, productIdentifier: "p1", localizedPrice: "4,99 €",
                                                price: Decimal(string: "4.99")!, currencyCode: "EUR")
        #expect(euro.pricePerPeriod == "4,99 € / week")
        let yearly = EntitlementService.PlanOffer(kind: .yearly, productIdentifier: "p2", localizedPrice: "NT$2,490",
                                                  price: 2490, currencyCode: "TWD", storePricePerMonth: "NT$207.50")
        #expect(yearly.pricePerPeriod == "NT$2,490 / year")
        #expect(yearly.monthlyEquivalent == "NT$207.50", "the store's own per-month string for the yearly product")
        let monthly = EntitlementService.PlanOffer(kind: .monthly, productIdentifier: "p3", localizedPrice: "9,99 US$",
                                                   price: Decimal(string: "9.99")!, currencyCode: "USD", storePricePerMonth: "9,99 US$")
        #expect(monthly.monthlyEquivalent == nil, "only a yearly plan shows a monthly equivalent")
    }

    @Test
    func datesFollowTheUsersLocale() {
        let end = Self.date(2026, 10, 29)
        #expect(SubscriptionCardState.dateText(end, now: Self.now, locale: Self.us) == "Oct 29, 2026")
        let french = SubscriptionCardState.dateText(end, now: Self.now, locale: Locale(identifier: "fr_FR"))
        #expect(french == "29 oct. 2026", "\(french)")
        let german = SubscriptionCardState.dateText(end, now: Self.now, locale: Locale(identifier: "de_DE"))
        #expect(german.hasPrefix("29.") && german.contains("2026"), "\(german)")
        let chinese = SubscriptionCardState.dateText(end, now: Self.now, locale: Locale(identifier: "zh_Hant_TW"))
        #expect(chinese.contains("2026") && chinese.contains("10") && chinese.contains("29"), "\(chinese)")
        #expect(!french.contains("T12:") && !french.contains("-10-"), "never an ISO timestamp")
    }

    /// An upcoming end within a day (Test Store periods) gains its time; a past expiry never does.
    @Test
    func onlyAnUpcomingDateWithinADayShowsATime() {
        #expect(SubscriptionCardState.dateText(Self.now.addingTimeInterval(3 * 3_600), now: Self.now, locale: Self.us).contains(":"))
        let justExpired = Self.now.addingTimeInterval(-3 * 3_600)
        #expect(!SubscriptionCardState.dateText(justExpired, now: Self.now, locale: Self.us, nearTime: false).contains(":"))
        #expect(!SubscriptionCardState.dateText(justExpired, now: Self.now, locale: Self.us).contains(":"))
    }

    // MARK: Paywall while subscribed

    static let offers = [
        EntitlementService.PlanOffer(kind: .monthly, productIdentifier: "io.neverblank.pro.monthly", localizedPrice: "$9.99",
                                     price: Decimal(string: "9.99")!, currencyCode: "USD"),
        EntitlementService.PlanOffer(kind: .yearly, productIdentifier: "io.neverblank.pro.yearly", localizedPrice: "$79.99",
                                     price: Decimal(string: "79.99")!, currencyCode: "USD"),
    ]

    static func availability(activeProduct: String?, active: Bool, end: Date = date(2026, 10, 29)) -> [PlanKind: EntitlementService.PlanAvailability] {
        let service = EntitlementService()
        if let activeProduct {
            service.update(isActive: active, details: .init(productIdentifier: activeProduct, expiration: end, willRenew: true))
        }
        return EntitlementService.planAvailability(for: offers, subscription: service.presentation(now: now))
    }

    @Test
    func notSubscribedEveryPlanIsPurchasable() {
        #expect(Self.availability(activeProduct: nil, active: false) == [.monthly: .purchasable, .yearly: .purchasable])
    }

    /// Monthly active: Monthly is the current plan and is never bought again; Yearly is an upgrade.
    @Test
    func monthlyActiveMarksMonthlyCurrentAndKeepsYearlyAsAnUpgrade() {
        #expect(Self.availability(activeProduct: "io.neverblank.pro.monthly", active: true)
                == [.monthly: .current, .yearly: .purchasable])
    }

    /// Yearly active: Yearly is current; Monthly is a downgrade left to Apple's subscription settings.
    @Test
    func yearlyActiveMarksYearlyCurrentAndMonthlyManagedByApple() {
        #expect(Self.availability(activeProduct: "io.neverblank.pro.yearly", active: true)
                == [.monthly: .managedByApple, .yearly: .current])
    }

    /// A lapsed subscription (a Sandbox period ending, say) makes every plan purchasable again once
    /// CustomerInfo says the entitlement is inactive — no duration is assumed anywhere.
    @Test
    func anExpiredSubscriptionMakesEveryPlanPurchasableAgain() {
        #expect(Self.availability(activeProduct: "io.neverblank.pro.monthly", active: false, end: Self.date(2026, 9, 1))
                == [.monthly: .purchasable, .yearly: .purchasable])
    }

    /// The current plan is matched by the store product id, not by reading the id's wording: an active
    /// product the offering does not contain (a Test Store `monthly`) marks nothing current.
    @Test
    func theCurrentPlanIsMatchedByStoreProductIDOnly() {
        #expect(Self.availability(activeProduct: "monthly", active: true) == [.monthly: .purchasable, .yearly: .purchasable])
    }

    /// Monthly, then a change to Yearly: the next CustomerInfo moves "current" to Yearly and Monthly
    /// stops being current. Nothing keeps the first product.
    @Test
    func aPlanChangeMovesTheCurrentPlan() {
        let service = EntitlementService()
        service.update(isActive: true, details: .init(productIdentifier: "io.neverblank.pro.monthly",
                                                      expiration: Self.date(2026, 10, 29), willRenew: true))
        #expect(EntitlementService.planAvailability(for: Self.offers, subscription: service.presentation(now: Self.now))
                == [.monthly: .current, .yearly: .purchasable])
        service.update(isActive: true, details: .init(productIdentifier: "io.neverblank.pro.yearly",
                                                      expiration: Self.date(2027, 9, 29), willRenew: false))
        #expect(EntitlementService.planAvailability(for: Self.offers, subscription: service.presentation(now: Self.now))
                == [.monthly: .managedByApple, .yearly: .current])
        service.update(isActive: false, details: .init(productIdentifier: "io.neverblank.pro.yearly",
                                                       expiration: Self.date(2026, 9, 1), willRenew: false))
        #expect(EntitlementService.planAvailability(for: Self.offers, subscription: service.presentation(now: Self.now))
                == [.monthly: .purchasable, .yearly: .purchasable])
    }

    // MARK: Paywall main button

    static func action(selected: PlanKind, activeProduct: String?, active: Bool,
                       end: Date = date(2026, 10, 29)) -> EntitlementService.PaywallAction {
        let service = EntitlementService()
        if let activeProduct {
            service.update(isActive: active, details: .init(productIdentifier: activeProduct, expiration: end, willRenew: true))
        }
        let subscription = service.presentation(now: now)
        return EntitlementService.paywallAction(selected: selected,
                                                availability: EntitlementService.planAvailability(for: offers, subscription: subscription),
                                                subscription: subscription)
    }

    /// Never subscribed: every plan is sold as new, and the button says "Become Pro".
    @Test(arguments: [PlanKind.monthly, .yearly])
    func neverSubscribedIsBecomePro(selected: PlanKind) {
        #expect(Self.action(selected: selected, activeProduct: nil, active: false) == .becomePro)
    }

    /// Expired (the entitlement inactive, a past plan on record): "Become Pro" too — never "Renew".
    @Test(arguments: [PlanKind.monthly, .yearly])
    func anExpiredSubscriptionIsBecomePro(selected: PlanKind) {
        #expect(Self.action(selected: selected, activeProduct: "io.neverblank.pro.monthly", active: false,
                            end: Self.date(2026, 9, 1)) == .becomePro)
        #expect(Self.action(selected: selected, activeProduct: "io.neverblank.pro.yearly", active: false,
                            end: Self.date(2026, 9, 1)) == .becomePro)
    }

    /// Monthly active with Yearly selected: an upgrade. The current plan itself is only managed.
    @Test
    func activeMonthlyUpgradesToYearly() {
        #expect(Self.action(selected: .yearly, activeProduct: "io.neverblank.pro.monthly", active: true) == .upgrade(.yearly))
        #expect(Self.action(selected: .monthly, activeProduct: "io.neverblank.pro.monthly", active: true) == .manageSubscription)
    }

    /// Yearly active: nothing to buy here, whichever plan is selected.
    @Test(arguments: [PlanKind.monthly, .yearly])
    func activeYearlyIsManageSubscription(selected: PlanKind) {
        #expect(Self.action(selected: selected, activeProduct: "io.neverblank.pro.yearly", active: true) == .manageSubscription)
    }

    /// Active on a product the offering does not contain: subscribed, so managed — never "Become Pro".
    @Test(arguments: [PlanKind.monthly, .yearly])
    func activeOnAnUnofferedProductIsManageSubscription(selected: PlanKind) {
        #expect(Self.action(selected: selected, activeProduct: "monthly", active: true) == .manageSubscription)
    }
}
