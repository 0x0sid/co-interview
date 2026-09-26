import Foundation

/// The one-time free preview: **30 seconds of real Live listening**, once per installation.
///
/// It is a Neverblank feature, not an App Store subscription trial, and it is labelled that way.
///
/// **Only listening counts.** The meter runs only while the caller says every condition holds — the
/// microphone is actually listening, the app is in the foreground, AI consent was given, answers are
/// configured and no paywall is on screen. Permission dialogs, onboarding, connection setup, paywall
/// time and background time are therefore never charged. The rules are here; *when* the conditions
/// hold is decided by `AccessController` from the screen's real state.
///
/// Elapsed time comes from a monotonic clock supplied by the caller, never `Date()`, so a clock
/// change cannot give time back or take it away.
struct FreePreviewMeter: Equatable, Sendable {
    static let allowance: TimeInterval = 30

    /// Time already banked from earlier listening, including earlier launches.
    private(set) var usedSeconds: TimeInterval
    /// Monotonic time the current listening stretch began; nil while not counting.
    private(set) var countingSince: TimeInterval?

    init(usedSeconds: TimeInterval = 0) {
        self.usedSeconds = min(max(0, usedSeconds), Self.allowance)
    }

    var isCounting: Bool { countingSince != nil }
    var hasStarted: Bool { usedSeconds > 0 || countingSince != nil }

    func used(at now: TimeInterval) -> TimeInterval {
        let running = countingSince.map { max(0, now - $0) } ?? 0
        return min(Self.allowance, usedSeconds + running)
    }

    func remaining(at now: TimeInterval) -> TimeInterval { Self.allowance - used(at: now) }
    func isExhausted(at now: TimeInterval) -> Bool { remaining(at: now) <= 0 }

    /// Starts counting. Returns false (and does nothing) when already counting or exhausted.
    @discardableResult
    mutating func start(at now: TimeInterval) -> Bool {
        guard countingSince == nil, !isExhausted(at: now) else { return false }
        countingSince = now
        return true
    }

    /// Banks the stretch that just ended.
    mutating func stop(at now: TimeInterval) {
        usedSeconds = used(at: now)
        countingSince = nil
    }
}

/// The preview's durable record: seconds used, whether the end was reported to the backend, and
/// whether the end-of-preview paywall was already shown — so it is shown **once**, not on every launch.
///
/// Kept in the Keychain because it usually outlives a reinstall; the backend's own counters are the
/// real limit either way.
struct FreePreviewRecord: Codable, Equatable, Sendable {
    var usedSeconds: TimeInterval = 0
    var endReported = false
    var endPaywallShown = false
}

struct FreePreviewLedger: Sendable {
    var load: @Sendable () -> FreePreviewRecord
    var save: @Sendable (FreePreviewRecord) -> Void

    static let keychain = FreePreviewLedger(
        load: { AccessKeychain.data(for: "free-preview").flatMap { try? JSONDecoder().decode(FreePreviewRecord.self, from: $0) } ?? FreePreviewRecord() },
        save: { record in
            if let data = try? JSONEncoder().encode(record) { AccessKeychain.set(data, for: "free-preview") }
        }
    )

    static func inMemory(_ initial: FreePreviewRecord = FreePreviewRecord()) -> FreePreviewLedger {
        let box = LockedBox(initial)
        return FreePreviewLedger(load: { box.value }, save: { box.value = $0 })
    }
}

/// What opened the paywall. Sent with `paywall_viewed`, and it decides what a purchase resumes: only
/// a paywall opened *by Generate* ever sends anything afterwards.
enum PaywallTrigger: String, Codable, Sendable {
    case previewEnd = "preview_end"
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
