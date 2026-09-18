import Foundation

/// Launch-argument switches used only by UI tests.
///
/// **Why this exists.** XCUITest waits for the app to be *idle* before every query, and an animation
/// that repeats forever means the app is never idle — the test hangs in the query rather than
/// failing, which looks exactly like a slow build. The v2.5 screen has two such animations: the
/// listening waveform, which moves for as long as it is listening, and the progress indicators shown
/// while an answer is being written.
///
/// So the UI tests launch with `-UITestsQuietMotion` and those animations hold a static frame. The
/// design is unchanged; only the perpetual motion is. Nothing here affects an ordinary launch.
enum InterviewTestingFlags {
    static var quietMotion: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-UITestsQuietMotion")
        #else
        false
        #endif
    }
}
