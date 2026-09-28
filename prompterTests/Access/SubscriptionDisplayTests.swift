import Foundation
import Testing
@testable import prompter

/// Settings › Neverblank Pro: the plan's period and its renewal or end date, worded from RevenueCat's
/// own facts (`EntitlementService.SubscriptionDetails`). Nothing here adds a period to a purchase
/// date; every date in these tests is the one RevenueCat would report.
@MainActor
struct SubscriptionDisplayTests {
    static let us = Locale(identifier: "en_US")
    /// A fixed "now", far from every date below, so no line gains a time of day.
    static let now = date(2026, 9, 29)

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    static func details(_ id: String, _ period: PlanKind?, _ end: Date, renews: Bool,
                        billingIssue: Date? = nil, grace: Date? = nil) -> EntitlementService.SubscriptionDetails {
        .init(productIdentifier: id, period: period, expiration: end, willRenew: renews,
              billingIssueDetectedAt: billingIssue, gracePeriodExpiresDate: grace)
    }

    /// The card for an entitlement, through the service exactly as a purchase, restore or refresh
    /// delivers it.
    static func card(active: Bool, _ details: EntitlementService.SubscriptionDetails?,
                     locale: Locale = us) -> (SubscriptionCardState, EntitlementService) {
        let service = EntitlementService()
        service.update(isActive: active, details: details)
        let state = SubscriptionCardState.make(status: service.status, needsVerification: false,
                                               expiredAt: service.expiredAt, plan: service.activePlanName,
                                               subscription: service.subscription, expiredPlan: service.expiredPlanName,
                                               now: now, locale: locale)
        return (state, service)
    }

    @Test
    func weeklyActiveShowsWeeklyAndItsRenewalDate() {
        let (state, _) = Self.card(active: true, Self.details("talk.cointerview.pro.w1", .weekly, Self.date(2026, 10, 6), renews: true))
        #expect(state == .active(plan: "Weekly", renewal: "Renews Oct 6, 2026", note: nil))
    }

    @Test
    func monthlyActiveShowsMonthlyAndItsRenewalDate() {
        let (state, _) = Self.card(active: true, Self.details("pro_m", .monthly, Self.date(2026, 10, 29), renews: true))
        #expect(state == .active(plan: "Monthly", renewal: "Renews Oct 29, 2026", note: nil))
    }

    @Test
    func yearlyActiveShowsYearlyAndItsRenewalDate() {
        let (state, _) = Self.card(active: true, Self.details("pro_y", .yearly, Self.date(2027, 9, 29), renews: true))
        #expect(state == .active(plan: "Yearly", renewal: "Renews Sep 29, 2027", note: nil))
    }

    /// The period is the store product's, not the id's wording: an id that says nothing still gets
    /// its plan, and an id that says "monthly" is not believed over the store.
    @Test
    func thePeriodComesFromTheStoreProductNotTheIdentifier() {
        let (state, _) = Self.card(active: true, Self.details("monthly_promo", .yearly, Self.date(2027, 9, 29), renews: true))
        guard case .active(let plan, _, _) = state else { Issue.record("not active"); return }
        #expect(plan == "Yearly")
        let (unknown, _) = Self.card(active: true, Self.details("pro_x", nil, Self.date(2026, 10, 29), renews: true))
        guard case .active(let none, let renewal, _) = unknown else { Issue.record("not active"); return }
        #expect(none == nil, "no store metadata yet: no plan shown rather than a guess")
        #expect(renewal == "Renews Oct 29, 2026")
    }

    @Test
    func cancelledButActiveSaysActiveUntilNeverRenews() {
        let (state, service) = Self.card(active: true, Self.details("pro_m", .monthly, Self.date(2026, 10, 29), renews: false))
        #expect(state == .active(plan: "Monthly", renewal: "Active until Oct 29, 2026", note: .cancelled))
        #expect(service.hasActivePro, "Pro is kept until the real end")
        #expect(SubscriptionCardState.Note.cancelled.text == "Subscription cancelled")
        guard case .active(_, let renewal, _) = state else { return }
        #expect(!renewal.contains("Renews"))
    }

    @Test
    func expiredShowsTheLastKnownPlanAndItsDate() {
        let (state, service) = Self.card(active: false, Self.details("pro_m", .monthly, Self.date(2026, 10, 29), renews: false))
        #expect(state == .expired(plan: "Monthly", date: Self.date(2026, 10, 29)))
        #expect(!service.hasActivePro)
        #expect(SubscriptionCardState.dateText(Self.date(2026, 10, 29), now: Self.now, locale: Self.us) == "Oct 29, 2026")
    }

    @Test
    func anExpiredPlanWithoutStoreMetadataIsNotGuessed() {
        let (state, _) = Self.card(active: false, Self.details("pro_x", nil, Self.date(2026, 10, 29), renews: false))
        #expect(state == .expired(plan: nil, date: Self.date(2026, 10, 29)))
    }

    @Test
    func neverSubscribedIsTheUpgradeState() {
        let (state, service) = Self.card(active: false, nil)
        #expect(state == .free)
        #expect(service.subscription == nil && service.expiredAt == nil)
    }

    /// Apple is retrying the charge, the entitlement still holds: active, never "Expired", and not
    /// promising a renewal that is in doubt.
    @Test
    func aGracePeriodWhileTheEntitlementIsActiveIsNotExpired() {
        let graceEnd = Self.date(2026, 10, 12)
        let (state, service) = Self.card(active: true, Self.details("pro_m", .monthly, graceEnd, renews: true,
                                                                    billingIssue: Self.date(2026, 9, 28), grace: graceEnd))
        #expect(state == .active(plan: "Monthly", renewal: "Active until Oct 12, 2026", note: .billingIssue))
        #expect(service.hasActivePro && service.expiredAt == nil)
    }

    /// Restore lands through the same update as a purchase: plan, period, date and renewal state all
    /// come back, not only "Pro".
    @Test
    func restoreBringsBackThePlanItsDateAndItsRenewalState() {
        let service = EntitlementService()
        service.update(isActive: false, details: nil)                                  // fresh install
        #expect(SubscriptionCardState.make(status: service.status, needsVerification: false, expiredAt: service.expiredAt,
                                           plan: service.activePlanName) == .free)
        service.update(isActive: true, details: Self.details("pro_y", .yearly, Self.date(2027, 9, 29), renews: false))
        let state = SubscriptionCardState.make(status: service.status, needsVerification: false, expiredAt: service.expiredAt,
                                               plan: service.activePlanName, subscription: service.subscription,
                                               now: Self.now, locale: Self.us)
        #expect(state == .active(plan: "Yearly", renewal: "Active until Sep 29, 2027", note: .cancelled))
        #expect(service.activeProductIdentifier == "pro_y")
    }

    /// An upcoming end within a day (Test Store periods) gains its time; a past expiry never does.
    @Test
    func onlyAnUpcomingDateWithinADayShowsATime() {
        let soon = Self.now.addingTimeInterval(3 * 3_600)
        #expect(SubscriptionCardState.dateText(soon, now: Self.now, locale: Self.us).contains(":"))
        let justExpired = Self.now.addingTimeInterval(-3 * 3_600)
        #expect(!SubscriptionCardState.dateText(justExpired, now: Self.now, locale: Self.us, nearTime: false).contains(":"))
        #expect(!SubscriptionCardState.dateText(justExpired, now: Self.now, locale: Self.us).contains(":"))
    }

    @Test
    func datesFollowTheUsersLocale() {
        let end = Self.date(2026, 10, 29)
        #expect(SubscriptionCardState.renewalLine(expiration: end, willRenew: true, now: Self.now, locale: Self.us) == "Renews Oct 29, 2026")
        let french = SubscriptionCardState.dateText(end, now: Self.now, locale: Locale(identifier: "fr_FR"))
        #expect(french.contains("29") && french.contains("oct") && french.contains("2026"), "\(french)")
        let german = SubscriptionCardState.dateText(end, now: Self.now, locale: Locale(identifier: "de_DE"))
        #expect(german.hasPrefix("29.") && german.contains("2026"), "\(german)")
        let chinese = SubscriptionCardState.dateText(end, now: Self.now, locale: Locale(identifier: "zh_Hant_TW"))
        #expect(chinese.contains("2026") && chinese.contains("10") && chinese.contains("29"), "\(chinese)")
        #expect(!SubscriptionCardState.renewalLine(expiration: end, willRenew: true, now: Self.now, locale: Self.us).contains("T12:"),
                "never a raw ISO timestamp")
    }
}
