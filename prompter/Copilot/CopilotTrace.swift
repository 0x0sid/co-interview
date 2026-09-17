#if DEBUG
import Foundation

/// Opt-in tracing of the detection path, for diagnosing why a question did or did not become a card.
/// Off unless a test or a launch argument turns it on, and it prints only lengths, times and a short
/// text prefix — never a full transcript.
enum CopilotTrace {
    nonisolated(unsafe) static var isEnabled = ProcessInfo.processInfo.arguments.contains("-copilotTrace")
}
#endif
