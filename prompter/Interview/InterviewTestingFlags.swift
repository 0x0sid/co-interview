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
    /// Debug only: `-LiveScriptedSpeech "first line||second line||…"` replaces the microphone in
    /// **Live** with those lines, each finalized `-LiveScriptedSpeechInterval` seconds apart (4 by
    /// default). Everything after the transcriber is the real pipeline — real backend, real Generate
    /// — which is the point: the simulator has no usable microphone, and a real-provider regression
    /// needs real requests. Nil on an ordinary launch and in Release.
    static var scriptedLiveSpeech: [FakeTranscriptionService.ScriptedResult]? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let at = arguments.firstIndex(of: "-LiveScriptedSpeech"), at + 1 < arguments.count else { return nil }
        let interval = arguments.firstIndex(of: "-LiveScriptedSpeechInterval")
            .flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil } ?? 4
        let lines = arguments[at + 1].components(separatedBy: "||")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.enumerated().map { index, line in
            .init(text: line, isFinal: true, elapsed: 1 + Double(index) * interval)
        }
        #else
        return nil
        #endif
    }

    static var quietMotion: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-UITestsQuietMotion")
        #else
        false
        #endif
    }
}
