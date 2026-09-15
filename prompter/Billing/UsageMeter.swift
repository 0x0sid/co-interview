import Foundation

/// **Free-tier reading allowance (M5.13).** Pure value type: no SwiftData, no clock of its own, no
/// SwiftUI — every input is passed in, so every rule below is directly testable.
///
/// ### What is metered
///
/// Only **active prompting of a user script**. Specifically **not** metered:
/// editing, browsing the library, speech-model downloads, the bundled demo, explicit pause, and
/// background time while the session is suspended.
///
/// Ordinary speech pauses and off-script talking **are** part of an active session — the reader is
/// still in a take, and stopping the meter every time they drew breath would be both wrong and
/// impossible to explain. Manual scrolling changes nothing: it is not a session event.
///
/// ### Clock
///
/// Elapsed time comes from a **monotonic** source supplied by the caller (`ContinuousClock`
/// in production), never from `Date()`. A device that changes time zone, crosses the date line or
/// has its clock corrected mid-take must not gain or lose allowance.
///
/// ### Day boundary
///
/// The allowance resets at **local midnight in the device's current time zone**, matching
/// `UsageLedger.dayKey(for:calendar:)`. This is deliberate: "10 minutes a day" has to mean the
/// reader's own day. A reader who flies east may therefore see the allowance reset sooner, and one
/// who flies west later; usage already banked under a previous day key is never rewritten.
struct UsageMeter: Equatable {
    /// Free reading seconds per local day.
    static let freeSecondsPerDay = 600

    /// Seconds already banked for `dayKey`.
    private(set) var bankedSeconds: Int
    /// The local day these seconds belong to.
    private(set) var dayKey: String
    /// Monotonic reading at which the current take started, or `nil` when no take is running.
    private(set) var runningSince: Double?
    /// True once a take has been allowed to start; it is permitted to overrun the allowance.
    var isRunning: Bool { runningSince != nil }

    init(bankedSeconds: Int = 0, dayKey: String = UsageLedger.dayKey()) {
        self.bankedSeconds = bankedSeconds
        self.dayKey = dayKey
        self.runningSince = nil
    }

    /// Seconds left today. Never negative — an overrun take shows zero, not a debt.
    var remainingSeconds: Int { max(0, Self.freeSecondsPerDay - bankedSeconds) }

    /// Whether a *new* metered take may begin. An already-running take is unaffected by this.
    var canStartMeteredTake: Bool { remainingSeconds > 0 }

    /// Rolls the ledger over if the local day changed since the banked seconds were recorded.
    /// Called before any decision so a reader who crosses midnight mid-app sees a fresh allowance.
    mutating func rollOverIfNeeded(today: String = UsageLedger.dayKey()) {
        guard today != dayKey else { return }
        dayKey = today
        bankedSeconds = 0
        // A take running across midnight keeps running; its elapsed time simply banks into the new
        // day when it stops. Cutting a reader off mid-sentence at midnight would be worse than
        // letting a few seconds land on the new day's budget.
    }

    /// Begins metering. `monotonicNow` must come from a monotonic source.
    ///
    /// Returns `false` and changes nothing if the allowance is already exhausted — the caller shows
    /// the paywall instead of starting. **Premium and demo sessions never call this.**
    @discardableResult
    mutating func startTake(monotonicNow: Double, today: String = UsageLedger.dayKey()) -> Bool {
        rollOverIfNeeded(today: today)
        guard runningSince == nil else { return true }   // already running: idempotent
        guard canStartMeteredTake else { return false }
        runningSince = monotonicNow
        return true
    }

    /// Suspends metering without ending the take — explicit pause, or the app being backgrounded.
    /// Banks what has elapsed so far so nothing is lost if the process is terminated.
    mutating func suspend(monotonicNow: Double) {
        guard let started = runningSince else { return }
        bankedSeconds += max(0, Int((monotonicNow - started).rounded()))
        runningSince = nil
    }

    /// Resumes after `suspend`. Does **not** consult the allowance: a take that was allowed to start
    /// is allowed to finish, and pausing must not become a way to be locked out mid-take.
    mutating func resume(monotonicNow: Double) {
        guard runningSince == nil else { return }
        runningSince = monotonicNow
    }

    /// Ends the take and banks the remaining elapsed time. The **full** elapsed time is recorded
    /// even when it overruns the allowance, so the overrun is paid for out of today's budget.
    mutating func endTake(monotonicNow: Double) {
        suspend(monotonicNow: monotonicNow)
    }

    /// Seconds used so far including any take currently running — for the live display.
    func usedSeconds(monotonicNow: Double) -> Int {
        guard let started = runningSince else { return bankedSeconds }
        return bankedSeconds + max(0, Int((monotonicNow - started).rounded()))
    }

    /// Remaining seconds including a running take, floored at zero.
    func liveRemainingSeconds(monotonicNow: Double) -> Int {
        max(0, Self.freeSecondsPerDay - usedSeconds(monotonicNow: monotonicNow))
    }
}
