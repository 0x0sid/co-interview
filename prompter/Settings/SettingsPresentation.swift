import Foundation

/// What leaving Settings should do, given the selected language's speech model.
///
/// A missing model gets one clear warning per visit (Download or Cancel, both stay in Settings); after
/// that the user may leave — they are warned, never trapped. A running download gets its own question.
enum SettingsLeaveGuard {
    enum Decision: Equatable {
        case leave
        /// "Download <language> speech model?" — Download / Cancel.
        case offerDownload
        /// "<language> speech model is still downloading." — Keep downloading / Cancel download.
        case downloadInProgress
    }

    static func decision(for state: SpeechModelStatus.State, alreadyWarned: Bool) -> Decision {
        switch state {
        case .downloading: alreadyWarned ? .leave : .downloadInProgress
        case .needsDownload, .failed: alreadyWarned ? .leave : .offerDownload
        case .ready, .checking, .unsupported: .leave
        }
    }
}

/// The Neverblank Pro card in Settings.
///
/// Every date comes from RevenueCat (`EntitlementService.SubscriptionDetails`); the card only words
/// it. `willRenew` decides between "Renews …" and "Active until …" — a cancelled plan never says it
/// renews, and keeps Pro until its real end.
enum SubscriptionCardState: Equatable {
    /// Recognised by the store, not yet confirmed by the backend.
    case verifying(plan: String?)
    /// `plan` is "Weekly", "Monthly" or "Yearly" from the store product; `renewal` is "Renews Oct 6,
    /// 2026" or "Active until Oct 29, 2026"; `note` says what else is true (cancelled, billing issue).
    case active(plan: String?, renewal: String, note: Note?)
    /// `plan` is the last known plan, nil when unknown — never guessed.
    case expired(plan: String?, date: Date)
    case free

    enum Note: Equatable {
        /// Auto-renew is off; Pro continues to the end of the paid period.
        case cancelled
        /// Apple could not charge the renewal and is retrying; Pro is still active (grace period or
        /// billing retry while the entitlement holds).
        case billingIssue

        var text: String {
            switch self {
            case .cancelled: "Subscription cancelled"
            case .billingIssue: "Payment issue · update your payment method in Manage subscription"
            }
        }
    }

    static func make(status: EntitlementService.Status, needsVerification: Bool, expiredAt: Date?, plan: String?,
                     subscription: EntitlementService.SubscriptionDetails? = nil, expiredPlan: String? = nil,
                     now: Date = .now, locale: Locale = .autoupdatingCurrent) -> SubscriptionCardState {
        if needsVerification { return .verifying(plan: plan) }
        // The entitlement is authoritative: while it is active the card is active, whatever the
        // billing state — a grace period or billing retry is never shown as expired.
        if case .premium(let expiration, let willRenew) = status {
            let billingIssue = subscription?.billingIssueDetectedAt != nil
            // During a grace period RevenueCat's expiration is the grace period's end.
            let until = expiration ?? subscription?.gracePeriodExpiresDate
            let renews = willRenew && !billingIssue
            return .active(plan: plan,
                           renewal: renewalLine(expiration: until, willRenew: renews, now: now, locale: locale),
                           note: billingIssue ? .billingIssue : (willRenew ? nil : .cancelled))
        }
        if let expiredAt { return .expired(plan: expiredPlan, date: expiredAt) }
        return .free
    }

    /// "Renews Oct 6, 2026" / "Active until Oct 29, 2026", in the user's locale. Within a day (Test
    /// Store periods are minutes to hours) the time is added, because then it matters as much.
    static func renewalLine(expiration: Date?, willRenew: Bool, now: Date = .now, locale: Locale = .autoupdatingCurrent) -> String {
        guard let expiration else { return "Active" }
        let date = dateText(expiration, now: now, locale: locale)
        return willRenew ? "Renews \(date)" : "Active until \(date)"
    }

    /// `nearTime`: add the time when the date is within a day — for an upcoming renewal or end only;
    /// a date in the past ("Expired …") is always just the date.
    static func dateText(_ date: Date, now: Date = .now, locale: Locale = .autoupdatingCurrent, nearTime: Bool = true) -> String {
        let withTime = nearTime && date > now && date.timeIntervalSince(now) < 86_400
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: withTime ? .shortened : .omitted).locale(locale))
    }

    /// Everything the card says, for VoiceOver — the PRO badge is never the only signal.
    var accessibilitySummary: String {
        switch self {
        case .verifying(let plan): "Neverblank Pro\(plan.map { ", \($0)" } ?? ""). Subscription recognised, verifying access."
        case .active(let plan, let renewal, let note):
            "Neverblank Pro, active\(plan.map { ", \($0)" } ?? ""). \(renewal).\(note.map { " \($0.text)." } ?? "")"
        case .expired(let plan, let date):
            "Neverblank Pro\(plan.map { ", \($0) plan" } ?? ""), expired \(Self.dateText(date, nearTime: false))."
        case .free: "Neverblank Pro, not subscribed."
        }
    }
}
