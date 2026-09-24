import UIKit

/// Keeps the screen on while an interview is running.
///
/// The answer is read from the phone without touching it, often for longer than Auto-Lock allows,
/// so the idle timer is disabled for exactly as long as the interview screen has an active session
/// **and** the app is in the foreground — listening, paused, generating or reading alike. Ending the
/// session, leaving the screen or backgrounding restores normal Auto-Lock; returning to a session
/// still in progress disables it again. The system Auto-Lock setting itself is never touched.
@MainActor
struct ScreenAwake {
    /// The one switch. Replaceable so tests can observe it without a real application.
    var setIdleTimerDisabled: (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }

    static func shouldKeepAwake(sessionActive: Bool, sceneActive: Bool) -> Bool {
        sessionActive && sceneActive
    }

    func apply(sessionActive: Bool, sceneActive: Bool) {
        setIdleTimerDisabled(Self.shouldKeepAwake(sessionActive: sessionActive, sceneActive: sceneActive))
    }
}
