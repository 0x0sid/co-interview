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

/// The Neverblank Pro card in Settings: wording for `EntitlementService.SubscriptionPresentation`.
///
/// Nothing here reads RevenueCat. Every date is RevenueCat's (`SubscriptionPresentation`), the plan
/// is the store product's period, and `willRenew` decides between "Renews …" and "Active until …" —
/// a cancelled plan never says it renews, and keeps Pro until its real end.
enum SubscriptionCardState: Equatable {
    /// Recognised by the store, not yet confirmed by the backend.
    case verifying(plan: String?)
    /// `plan`: "Weekly", "Monthly", "Yearly", or "Subscription" for a period the app does not name.
    /// `detail`: "Renews Oct 6, 2026", "Active until Oct 29, 2026" or "Access remains active until …".
    case active(plan: String?, detail: String, notice: Notice?)
    /// `plan`: the last known plan, nil when unknown — never guessed.  
    case expired(plan: String?, date: Date?, billingIssue: Bool)
    case free

    enum Notice: Equatable {
        /// Auto-renew is off; Pro continues to the end of the paid period. Shown under the date.
        case cancelled
        /// Apple could not charge the renewal and access continues (grace period or billing retry
        /// while the entitlement holds). Shown above the date, in a restrained warning colour.
        case billingIssue

        var text: String {
            switch self {
            case .cancelled: "Cancelled"
            case .billingIssue: "Billing issue"
            }
        }
    }

    static func make(_ subscription: EntitlementService.SubscriptionPresentation, now: Date = .now,
                     locale: Locale = .autoupdatingCurrent) -> SubscriptionCardState {
        let plan = subscription.planPeriod?.title
        if subscription.needsVerification { return .verifying(plan: plan) }
        // The entitlement is authoritative: while it is active the card is active, whatever the
        // billing state — a grace period or billing retry is never shown as expired.
        if subscription.entitlementActive {
            if subscription.billingIssueDetected || subscription.gracePeriodActive {
                let until = subscription.gracePeriodActive
                    ? subscription.gracePeriodExpiresDate ?? subscription.expirationDate
                    : subscription.expirationDate
                return .active(plan: plan,
                               detail: until.map { "Access remains active until \(dateText($0, now: now, locale: locale))" } ?? "Access remains active",
                               notice: .billingIssue)
            }
            return .active(plan: plan,
                           detail: renewalLine(expiration: subscription.expirationDate, willRenew: subscription.willRenew,
                                               now: now, locale: locale),
                           notice: subscription.willRenew ? nil : .cancelled)
        }
        if subscription.hasLapsed || subscription.billingIssueDetected {
            let named = subscription.planPeriod?.isNamed == true ? plan : nil
            return .expired(plan: named, date: subscription.expirationDate, billingIssue: subscription.billingIssueDetected)
        }
        return .free
    }

    /// "Renews Oct 6, 2026" / "Active until Oct 29, 2026", in the user's locale.
    static func renewalLine(expiration: Date?, willRenew: Bool, now: Date = .now, locale: Locale = .autoupdatingCurrent) -> String {
        guard let expiration else { return "Active" }
        let date = dateText(expiration, now: now, locale: locale)
        return willRenew ? "Renews \(date)" : "Active until \(date)"
    }

    /// The user's locale's abbreviated date ("Sep 29, 2026", "29 sept. 2026"). `nearTime` adds the
    /// time when an upcoming date is within a day (Test Store periods are minutes to hours); a date
    /// in the past ("Expired …") is always just the date.
    static func dateText(_ date: Date, now: Date = .now, locale: Locale = .autoupdatingCurrent, nearTime: Bool = true) -> String {
        let withTime = nearTime && date > now && date.timeIntervalSince(now) < 86_400
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: withTime ? .shortened : .omitted).locale(locale))
    }

    /// Everything the card says, for VoiceOver — the PRO badge is never the only signal.
    var accessibilitySummary: String {
        switch self {
        case .verifying(let plan): "Neverblank Pro\(plan.map { ", \($0)" } ?? ""). Subscription recognised, verifying access."
        case .active(let plan, let detail, let notice):
            "Neverblank Pro, active\(plan.map { ", \($0)" } ?? "").\(notice.map { " \($0.text)." } ?? "") \(detail)."
        case .expired(let plan, let date, let billingIssue):
            "Neverblank Pro, expired\(plan.map { ", \($0)" } ?? "")\(billingIssue ? ", billing issue" : "")\(date.map { ", \(Self.dateText($0, nearTime: false))" } ?? "")."
        case .free: "Neverblank Pro, not subscribed."
        }
    }
}

/// Settings › Answer text size while it is being dragged.
///
/// **The drag never touches the stored preference.** `Slider` calls its binding at touch rate
/// (60–120 Hz), with the same snapped value over and over. Writing `AppSettings.fontScale` there
/// invalidated the app's root (`RootView` reads it into `\.answerTextScale`), re-rendered every live
/// answer page — each rebuilding its structured-answer parse and speech-following styling — and ran a
/// synchronous SwiftData save on the main thread, every tick; the cost grew with the meeting. Now the
/// drag moves only `displayed` (the percentage and the preview), and the preference is written once,
/// when the drag ends — or at once for a non-drag change such as a VoiceOver adjustment.
struct AnswerTextSizeEditor: Equatable {
    static let range: ClosedRange<Double> = 0.8...1.6
    /// 10% steps: each is a visible change at answer size, and the slider snaps to them natively.
    static let step = 0.1

    /// What the slider, the percentage and the preview show right now.
    private(set) var displayed: Double
    private(set) var isEditing = false
    /// The stored preference as last written (or read).
    private(set) var persisted: Double

    init(persisted: Double) {
        let value = Self.normalized(persisted)
        self.persisted = value
        displayed = value
    }

    static func normalized(_ value: Double) -> Double {
        (min(range.upperBound, max(range.lowerBound, value)) * 10).rounded() / 10
    }

    var percent: Int { Int((displayed * 100).rounded()) }

    /// The slider's editing state changed. Ending a drag returns the value to store, if it changed.
    mutating func setEditing(_ editing: Bool) -> Double? {
        isEditing = editing
        return editing ? nil : commitIfChanged()
    }

    /// The slider moved. During a drag nothing is returned (nothing is stored); outside one — an
    /// accessibility adjustment — the new value is returned to store at once.
    mutating func update(_ value: Double) -> Double? {
        displayed = Self.normalized(value)
        return isEditing ? nil : commitIfChanged()
    }

    /// The stored value changed elsewhere (another screen, a relaunch): follow it unless dragging.
    mutating func syncPersisted(_ value: Double) {
        guard !isEditing else { return }
        persisted = Self.normalized(value)
        displayed = persisted
    }

    private mutating func commitIfChanged() -> Double? {
        guard displayed != persisted else { return nil }
        persisted = displayed
        return displayed
    }
}
