#if DEBUG
import SwiftUI

/// Launches the copilot screen against a **scripted synthetic interview** and the development fake
/// provider, with no microphone and no network — the copilot counterpart of `PromptReplayHarness`.
///
/// It exists for the same reason that one does: real speech recognition does not run in the Simulator
/// (§11.6), so without this every pipeline change would cost a device round to look at. Entered only
/// via the `-copilotReplay` launch argument, so it is not part of the product surface.
///
/// Everything it shows is synthetic and labelled: the questions come from `SyntheticInterview`, the
/// answers from `FakeCopilotProvider` (prefixed `[FAKE]` / `[FAUX]`), and the project from
/// `SyntheticProjectFixture`. **No screenshot taken here shows a real model's output.**
enum CopilotReplayHarness {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-copilotReplay") }

    /// `-copilotReplayFrench` switches the fixture project and script to the French pair.
    static var language: InterviewLanguage {
        ProcessInfo.processInfo.arguments.contains("-copilotReplayFrench") ? .french : .english
    }

    @MainActor
    static var screen: some View {
        let project = language == .french
            ? SyntheticProjectFixture.hospitalReview
            : SyntheticProjectFixture.transportProgramme
        let interview = SyntheticInterview.forLanguage(language)
        // Played back faster than real time so the whole interview can be watched in a few seconds —
        // but with the scripted **timestamps untouched**, so the pauses between turns are the ones a
        // real interview has, and detection behaves as it would live.
        let results = interview.scriptedResults()
        return NavigationStack {
            CopilotScreen(
                project: project,
                provider: FakeCopilotProvider(),
                audio: InterviewAudioInput(makeService: { FakeTranscriptionService(results: results, playbackRate: 8) }),
                modeBadge: "DEMO"
            )
        }
    }
}
#endif
