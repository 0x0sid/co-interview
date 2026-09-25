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
    case weekly, monthly
}

/// The saving the monthly plan offers over paying weekly, computed from the **store's** prices.
///
/// A saving is shown only when it is real: both prices in the same currency, both positive, and
/// monthly genuinely cheaper than a month of weekly payments. A month is 52/12 weeks. The result is
/// rounded **down** to a whole percent, so the claim is never larger than the arithmetic.
enum PlanSavings {
    static let weeksPerMonth = Decimal(52) / Decimal(12)

    static func monthlySavingPercent(weekly: Decimal, monthly: Decimal, weeklyCurrency: String?, monthlyCurrency: String?) -> Int? {
        guard let weeklyCurrency, weeklyCurrency == monthlyCurrency, weekly > 0, monthly > 0 else { return nil }
        let monthOfWeekly = weekly * weeksPerMonth
        guard monthly < monthOfWeekly else { return nil }
        let fraction = (monthOfWeekly - monthly) / monthOfWeekly * 100
        let percent = NSDecimalNumber(decimal: fraction).doubleValue.rounded(.down)
        // "Save 0%" is not a saving worth a badge.
        return percent >= 1 ? Int(percent) : nil
    }
}
