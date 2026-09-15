import Foundation
import Observation
import SwiftData

/// Persists the free-tier allowance (M5.13). Owns the monotonic clock and the `UsageLedger` row;
/// all the rules live in the pure `UsageMeter`.
@MainActor
@Observable
final class UsageTracker {
    private(set) var meter: UsageMeter
    private let clock = ContinuousClock()
    private var epoch: ContinuousClock.Instant
    private weak var context: ModelContext?

    init(context: ModelContext?) {
        self.context = context
        self.epoch = ContinuousClock().now
        let today = UsageLedger.dayKey()
        if let context, let row = try? context.fetch(FetchDescriptor<UsageLedger>()).first(where: { $0.dayKey == today }) {
            meter = UsageMeter(bankedSeconds: row.secondsUsed, dayKey: row.dayKey)
        } else {
            meter = UsageMeter(dayKey: today)
        }
    }

    /// Monotonic seconds since this tracker was created. Immune to wall-clock changes, time-zone
    /// moves and date-line crossings — `Date()` is never used for elapsed time.
    private var monotonicNow: Double {
        Double((clock.now - epoch).components.seconds)
            + Double((clock.now - epoch).components.attoseconds) / 1e18
    }

    var remainingSeconds: Int { meter.liveRemainingSeconds(monotonicNow: monotonicNow) }
    var canStartMeteredTake: Bool {
        var probe = meter
        probe.rollOverIfNeeded()
        return probe.canStartMeteredTake
    }

    /// Begins metering a user-script take. Returns `false` when the allowance is already spent, in
    /// which case the caller shows the paywall **instead of** starting.
    @discardableResult
    func startTake() -> Bool {
        let started = meter.startTake(monotonicNow: monotonicNow)
        persist()
        return started
    }

    /// Explicit pause, or the app leaving the foreground. Banks elapsed time immediately so nothing
    /// is lost if the process is terminated while suspended.
    func suspend() { meter.suspend(monotonicNow: monotonicNow); persist() }
    func resume() { meter.resume(monotonicNow: monotonicNow) }
    func endTake() { meter.endTake(monotonicNow: monotonicNow); persist() }

    private func persist() {
        guard let context else { return }
        let key = meter.dayKey
        let row: UsageLedger
        if let existing = try? context.fetch(FetchDescriptor<UsageLedger>()).first(where: { $0.dayKey == key }) {
            row = existing
        } else {
            row = UsageLedger(dayKey: key)
            context.insert(row)
        }
        row.secondsUsed = meter.usedSeconds(monotonicNow: monotonicNow)
        row.updatedAt = .now
        try? context.save()
    }
}
