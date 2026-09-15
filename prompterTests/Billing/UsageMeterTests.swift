import Testing
import Foundation
@testable import prompter

/// **M5.13 — the free allowance rules, each asserted against the pure meter.**
struct UsageMeterTests {

    @Test
    func theFreeAllowanceIsTenMinutes() {
        #expect(UsageMeter.freeSecondsPerDay == 600)
        #expect(UsageMeter().remainingSeconds == 600)
        #expect(UsageMeter().canStartMeteredTake)
    }

    @Test
    func consumptionAccumulatesAcrossTakes() {
        var meter = UsageMeter()
        meter.startTake(monotonicNow: 0)
        meter.endTake(monotonicNow: 120)
        #expect(meter.remainingSeconds == 480)

        meter.startTake(monotonicNow: 500)
        meter.endTake(monotonicNow: 560)
        #expect(meter.remainingSeconds == 420, "a second take did not accumulate")
    }

    /// Pause must not consume allowance, and must not lock the reader out of their own take.
    @Test
    func pauseStopsTheMeterAndResumeDoesNotRecheckTheAllowance() {
        var meter = UsageMeter()
        meter.startTake(monotonicNow: 0)
        meter.suspend(monotonicNow: 60)          // 60s used
        #expect(meter.remainingSeconds == 540)

        // 10 minutes of real time pass while paused.
        meter.resume(monotonicNow: 660)
        meter.endTake(monotonicNow: 690)         // a further 30s of reading
        #expect(meter.remainingSeconds == 510, "paused time was metered")
    }

    /// Backgrounding suspends; nothing accrues while the session is not running.
    @Test
    func backgroundTimeIsNotMetered() {
        var meter = UsageMeter()
        meter.startTake(monotonicNow: 0)
        meter.suspend(monotonicNow: 30)          // app backgrounded
        let afterBackground = meter.remainingSeconds
        meter.resume(monotonicNow: 3_600)        // an hour later
        meter.endTake(monotonicNow: 3_610)
        #expect(afterBackground == 570)
        #expect(meter.remainingSeconds == 560, "background time was charged")
    }

    /// **A take that was allowed to start is allowed to finish**, and the full overrun is banked.
    @Test
    func aTakeStartedWithTimeLeftMayOverrunAndTheOverrunIsRecorded() {
        var meter = UsageMeter(bankedSeconds: 590)      // 10 seconds left
        #expect(meter.canStartMeteredTake)
        let started = meter.startTake(monotonicNow: 0)
        #expect(started)

        // The reader keeps going for five more minutes. Nothing interrupts them.
        meter.endTake(monotonicNow: 300)
        #expect(meter.remainingSeconds == 0)
        #expect(meter.bankedSeconds == 890, "the overrun was not fully recorded: \(meter.bankedSeconds)")
    }

    /// …and the next metered take is refused.
    @Test
    func theNextTakeIsBlockedOnceExhausted() {
        var meter = UsageMeter(bankedSeconds: 600)
        #expect(!meter.canStartMeteredTake)
        let started = meter.startTake(monotonicNow: 0)
        #expect(started == false, "a take began with no allowance left")
        #expect(meter.isRunning == false)
    }

    /// Local-day rollover resets the allowance; usage banked under the old key is not rewritten.
    @Test
    func theAllowanceResetsOnTheLocalDayBoundary() {
        var meter = UsageMeter(bankedSeconds: 600, dayKey: "2026-09-13")
        #expect(!meter.canStartMeteredTake)
        meter.rollOverIfNeeded(today: "2026-09-14")
        #expect(meter.remainingSeconds == 600, "the allowance did not reset at the day boundary")
        #expect(meter.dayKey == "2026-09-14")
        let started = meter.startTake(monotonicNow: 0, today: "2026-09-14")
        #expect(started)
    }

    /// A take running across midnight is not cut off; its time banks into the new day.
    @Test
    func aTakeRunningAcrossMidnightIsNotInterrupted() {
        var meter = UsageMeter(dayKey: "2026-09-13")
        meter.startTake(monotonicNow: 0, today: "2026-09-13")
        meter.rollOverIfNeeded(today: "2026-09-14")
        #expect(meter.isRunning, "the take was stopped at midnight")
        meter.endTake(monotonicNow: 60)
        #expect(meter.dayKey == "2026-09-14")
        #expect(meter.bankedSeconds == 60)
    }

    /// The day key follows the device's local calendar, which is what "10 minutes a day" means.
    @Test
    func theDayKeyUsesTheLocalCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Pacific/Kiritimati")!   // UTC+14
        let tokyo = UsageLedger.dayKey(for: Date(timeIntervalSince1970: 0), calendar: calendar)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let utcKey = UsageLedger.dayKey(for: Date(timeIntervalSince1970: 0), calendar: utc)
        #expect(tokyo != utcKey, "the day key ignored the device time zone")
    }

    /// Elapsed time never goes backwards even if a caller passes a smaller reading.
    @Test
    func negativeElapsedIsClamped() {
        var meter = UsageMeter()
        meter.startTake(monotonicNow: 100)
        meter.endTake(monotonicNow: 50)          // clock went backwards
        #expect(meter.bankedSeconds == 0, "a backwards clock consumed allowance")
    }

    @Test
    func remainingNeverGoesNegative() {
        let meter = UsageMeter(bankedSeconds: 5_000)
        #expect(meter.remainingSeconds == 0)
    }
}
