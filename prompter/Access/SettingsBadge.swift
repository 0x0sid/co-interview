import Foundation

/// The red "1" on the home screen's Settings gear: something about the subscription is worth a look.
///
/// Shown once per subscription state, and cleared for good when the subscription section in Settings
/// has been seen — never re-added merely because the user has not subscribed. An active subscription
/// never shows it. An expiry is a new state, so it shows once more, where Settings offers Become Pro.
///
/// Stored in UserDefaults as the key of the state last seen (the same "seen once" idea as
/// `AppSettings.hasSeenPremiumAnnouncement`, without adding a property to the SwiftData store).
enum SettingsBadge {
    enum State: Equatable {
        case pro
        case free
        case expired(Date)
        /// Verifying, or a build without installation access: nothing to point at.
        case none
    }

    static let storageKey = "neverblank.settingsBadgeSeenState"

    static func state(isPro: Bool, needsVerification: Bool, usesServerAccess: Bool, expiredAt: Date?) -> State {
        if isPro || needsVerification { return isPro ? .pro : .none }
        if let expiredAt { return .expired(expiredAt) }
        return usesServerAccess ? .free : .none
    }

    /// The identity of a state worth a badge; nil when there is nothing to show.
    static func key(for state: State) -> String? {
        switch state {
        case .pro, .none: nil
        case .free: "free"
        case .expired(let date): "expired-\(Int(date.timeIntervalSince1970))"
        }
    }

    static func shows(for state: State, seen: String) -> Bool {
        guard let key = key(for: state) else { return false }
        return key != seen
    }

    /// The value to store once the subscription section has been seen in `state`; nil to leave it.
    static func seenValue(for state: State) -> String? { key(for: state) }
}
