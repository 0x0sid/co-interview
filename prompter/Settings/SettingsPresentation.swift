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
enum SubscriptionCardState: Equatable {
    /// Recognised by the store, not yet confirmed by the backend.
    case verifying(plan: String?)
    case active(plan: String?, renewal: String)
    case expired(Date)
    case free

    static func make(status: EntitlementService.Status, needsVerification: Bool, expiredAt: Date?, plan: String?) -> SubscriptionCardState {
        if needsVerification { return .verifying(plan: plan) }
        if case .premium(let expiration, let willRenew) = status {
            return .active(plan: plan, renewal: SubscriptionSettingsView.renewalLine(expiration: expiration, willRenew: willRenew))
        }
        if let expiredAt { return .expired(expiredAt) }
        return .free
    }

    /// Everything the card says, for VoiceOver — the PRO badge is never the only signal.
    var accessibilitySummary: String {
        switch self {
        case .verifying(let plan): "Neverblank Pro\(plan.map { ", \($0)" } ?? ""). Subscription recognised, verifying access."
        case .active(let plan, let renewal): "Neverblank Pro, active\(plan.map { ", \($0) plan" } ?? ""). \(renewal)"
        case .expired(let date): "Neverblank Pro, expired on \(date.formatted(date: .abbreviated, time: .omitted))."
        case .free: "Neverblank Pro, not subscribed."
        }
    }
}
