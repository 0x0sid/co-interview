import Foundation

#if DEBUG
/// DEBUG-only launch arguments that force states the simulator cannot reach, for UI screenshots:
/// `-UITestsSubscriptionState pro|free|expired` and `-UITestsSpeechModel installed|needsDownload|failed|downloading|unsupported`.
/// Read-only presentation overrides: nothing is purchased, reserved, downloaded or stored.
enum UITestOverrides {
    static var subscriptionState: String? { value(after: "-UITestsSubscriptionState") }
    static var speechModel: String? { value(after: "-UITestsSpeechModel") }
    /// `-UITestsInterviewLanguage zh-TW`: screenshots with a long language name in Settings.
    static var interviewLanguage: String? { value(after: "-UITestsInterviewLanguage") }
    /// `-UITestsAnswerSample plain|structured`: the demo's first answer is a fixed Java-vs-Python
    /// answer, for before/after screenshots of answer presentation.
    static var answerSample: String? { value(after: "-UITestsAnswerSample") }

    private static func value(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
#endif
