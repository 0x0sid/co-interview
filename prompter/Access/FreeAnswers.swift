import Foundation

/// This device's record of its free answers, in the Keychain: how many it has seen complete and
/// whether the exhaustion event was sent. It usually outlives a reinstall; either way the backend's
/// ledger is the real limit (`backend/access.mjs`).
struct FreeAnswersRecord: Codable, Equatable, Sendable {
    /// The allowance the app assumes before the backend has answered.
    static let limit = 2
    var used = 0
    var exhaustionLogged = false
}

struct FreeAnswersLedger: Sendable {
    var load: @Sendable () -> FreeAnswersRecord
    var save: @Sendable (FreeAnswersRecord) -> Void

    static let keychain = FreeAnswersLedger(
        load: { AccessKeychain.data(for: "free-answers").flatMap { try? JSONDecoder().decode(FreeAnswersRecord.self, from: $0) } ?? FreeAnswersRecord() },
        save: { record in
            if let data = try? JSONEncoder().encode(record) { AccessKeychain.set(data, for: "free-answers") }
        }
    )

    static func inMemory(_ initial: FreeAnswersRecord = FreeAnswersRecord()) -> FreeAnswersLedger {
        let box = LockedBox(initial)
        return FreeAnswersLedger(load: { box.value }, save: { box.value = $0 })
    }
}

/// What opened the paywall. Sent with `paywall_viewed`, and it decides what a purchase resumes: only
/// a paywall opened *by Generate* ever sends anything afterwards.
enum PaywallTrigger: String, Codable, Sendable {
    /// The inline "Unlock Pro" shown once both free answers are used.
    case freeAnswersExhausted = "free_answers_exhausted"
    case generate
    case settings
    case retry
}

enum PlanKind: String, Codable, Sendable, CaseIterable {
    case weekly, monthly, yearly, lifetime

    var title: String {
        switch self {
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        case .lifetime: "Lifetime"
        }
    }

    /// "week", "month", "year"; nil for the one-time lifetime purchase.
    var periodNoun: String? {
        switch self {
        case .weekly: "week"
        case .monthly: "month"
        case .yearly: "year"
        case .lifetime: nil
        }
    }

    /// Weeks one payment covers, for comparing prices; nil for lifetime. A month is 52/12 weeks.
    var weeks: Decimal? {
        switch self {
        case .weekly: 1
        case .monthly: Decimal(52) / Decimal(12)
        case .yearly: 52
        case .lifetime: nil
        }
    }

    /// Which plan a store product is, from **the product itself** — a one-time purchase is lifetime,
    /// a subscription is known by its billing period — never from the package's name, so a product
    /// placed in the wrong package slot on the dashboard is still described truthfully.
    static func classify(isSubscription: Bool, periodUnit: String?, periodValue: Int) -> PlanKind? {
        guard isSubscription else { return .lifetime }
        switch (periodUnit, periodValue) {
        case ("week", 1), ("day", 7): return .weekly
        case ("month", 1): return .monthly
        case ("year", 1), ("month", 12): return .yearly
        default: return nil
        }
    }
}

extension PlanKind {
    /// Whether a product's **name** agrees with what the store says it is. A product named "yearly"
    /// that the store sells as a monthly subscription, or "lifetime" sold as a yearly subscription, is
    /// misconfigured on the dashboard and is not offered until it is corrected.
    func agrees(withProductIdentifier identifier: String) -> Bool {
        let id = identifier.lowercased()
        let names = [rawValue, periodNoun].compactMap { $0 }
        let others = PlanKind.allCases.filter { $0 != self }.flatMap { [$0.rawValue, $0.periodNoun].compactMap { $0 } }
        // Named for this plan, and not also named for another one.
        return names.contains { id.contains($0) } && !others.contains { other in id.contains(other) && !names.contains { $0.contains(other) } }
    }
}

/// Savings computed from the **store's** prices, per week of access.
///
/// A saving is shown only when it is real: same currency, positive prices, and genuinely cheaper per
/// week than the comparison plan. Rounded **down** to a whole percent, so the claim is never larger
/// than the arithmetic. Lifetime is a one-time purchase and is never given a percentage.
enum PlanSavings {
    struct Price: Equatable {
        let kind: PlanKind
        let amount: Decimal
        let currency: String?
    }

    static func savingPercent(_ plan: Price, comparedWith baseline: Price) -> Int? {
        guard let weeks = plan.kind.weeks, let baselineWeeks = baseline.kind.weeks,
              let currency = plan.currency, currency == baseline.currency,
              plan.amount > 0, baseline.amount > 0 else { return nil }
        let perWeek = plan.amount / weeks
        let baselinePerWeek = baseline.amount / baselineWeeks
        guard perWeek < baselinePerWeek else { return nil }
        let fraction = (baselinePerWeek - perWeek) / baselinePerWeek * 100
        let percent = NSDecimalNumber(decimal: fraction).doubleValue.rounded(.down)
        return percent >= 1 ? Int(percent) : nil
    }

    /// The subscription that costs most per week — what every saving is measured against.
    static func baseline(_ prices: [Price]) -> Price? {
        prices.filter { $0.kind.weeks != nil && $0.amount > 0 }
            .max { ($0.amount / $0.kind.weeks!) < ($1.amount / $1.kind.weeks!) }
    }

    /// The subscription with the largest real saving, if any plan saves anything at all.
    static func bestValue(_ prices: [Price]) -> PlanKind? {
        guard let baseline = baseline(prices) else { return nil }
        return prices.compactMap { price in savingPercent(price, comparedWith: baseline).map { (price.kind, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    /// Kept for the original weekly/monthly comparison.
    static func monthlySavingPercent(weekly: Decimal, monthly: Decimal, weeklyCurrency: String?, monthlyCurrency: String?) -> Int? {
        guard weeklyCurrency != nil else { return nil }
        return savingPercent(Price(kind: .monthly, amount: monthly, currency: monthlyCurrency),
                             comparedWith: Price(kind: .weekly, amount: weekly, currency: weeklyCurrency))
    }
}
