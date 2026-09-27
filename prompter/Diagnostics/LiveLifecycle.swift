import Foundation
import os

/// Debug-only lifecycle instrumentation for the live interview pipeline: events and live-resource
/// counts, so "no active interview = no live resources" can be demonstrated, in tests and on a phone.
///
/// Logs **lifecycle and state only — never transcript text.** Lines go to stderr (unbuffered, so a
/// device console capture sees them at once) as `[Lifecycle] <event> <detail> | <counts>`. In Release
/// every call compiles to nothing.
enum LiveLifecycle {
    struct Counts: Equatable, Sendable, CustomStringConvertible {
        var coordinators = 0
        var liveSessions = 0
        var transcribers = 0
        var consumeTasks = 0
        var tickers = 0
        var engines = 0
        var taps = 0
        var audioSessions = 0

        var description: String {
            "coordinators=\(coordinators) sessions=\(liveSessions) transcribers=\(transcribers) consumers=\(consumeTasks) tickers=\(tickers) engines=\(engines) taps=\(taps) audioSessions=\(audioSessions)"
        }

        /// True when nothing expensive is live.
        var isQuiet: Bool {
            liveSessions == 0 && transcribers == 0 && consumeTasks == 0
                && tickers == 0 && engines == 0 && taps == 0 && audioSessions == 0
        }
    }

    #if DEBUG
    private static let state = LockedBox((counts: Counts(), events: [String]()))
    private static let logger = Logger(subsystem: "talk.cointerview", category: "lifecycle")
    /// On a phone, lines go to stderr (so a console capture shows them at once) and to the unified log.
    /// Neither in the unit-test host unless asked (`TEST_RUNNER_LIFECYCLE_TRACE=1`): Xcode mirrors the
    /// unified log into the runner's pipe too, and a synchronous write per event across hundreds of
    /// tests stalls the main actor whenever that pipe backs up.
    private static let emits: Bool = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] != nil else { return true }
        return environment["LIFECYCLE_TRACE"] == "1"
    }()
    #endif

    static var counts: Counts {
        #if DEBUG
        state.value.counts
        #else
        Counts()
        #endif
    }

    static func adjust(_ key: WritableKeyPath<Counts, Int>, by delta: Int) {
        #if DEBUG
        state.mutate { $0.counts[keyPath: key] += delta }
        #endif
    }

    static func event(_ name: String, _ detail: String = "") {
        #if DEBUG
        let line = state.mutate { value -> String in
            let line = "[Lifecycle] \(name)\(detail.isEmpty ? "" : " " + detail) | \(value.counts)"
            value.events.append(line)
            if value.events.count > 1000 { value.events.removeFirst(value.events.count - 1000) }
            return line
        }
        guard emits else { return }
        FileHandle.standardError.write(Data((line + "\n").utf8))
        logger.notice("\(line, privacy: .public)")
        #endif
    }

    /// A free-form debug line with no counts (speech-asset diagnostics). Never transcript text.
    static func note(_ line: String) {
        #if DEBUG
        state.mutate { value in
            value.events.append(line)
            if value.events.count > 1000 { value.events.removeFirst(value.events.count - 1000) }
        }
        guard emits else { return }
        FileHandle.standardError.write(Data((line + "\n").utf8))
        logger.notice("\(line, privacy: .public)")
        #endif
    }

    /// Recent events, oldest first (tests read these).
    static var events: [String] {
        #if DEBUG
        state.value.events
        #else
        []
        #endif
    }

    static func resetForTesting() {
        #if DEBUG
        state.value = (Counts(), [])
        #endif
    }
}
