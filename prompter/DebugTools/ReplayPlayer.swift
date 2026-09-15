// Developer-only. Compiled out of Release entirely (M5.11): these screens are unreachable from
// the app UI after the debug menu was removed, and must not exist in a shipping binary.
#if DEBUG
import Foundation
import Observation

/// Drives a `ReplayFixture` through a fresh `SlidingWindowMatcher` on a timer, publishing the
/// live cursor so `ReplayDebugScreen` can animate it. UI-facing, so explicitly `@MainActor`
/// (Matching/ itself stays off the main actor — see docs/DECISIONS.md).
@MainActor
@Observable
final class ReplayPlayer {
    let fixture: ReplayFixture
    let scriptIndex: ScriptIndex

    private(set) var cursor = PromptCursor(tokenIndex: 0, confidence: 0, state: .holding)
    private(set) var isPlaying = false
    private(set) var eventsPlayed = 0

    private var playTask: Task<Void, Never>?

    init(fixture: ReplayFixture) {
        self.fixture = fixture
        self.scriptIndex = ScriptIndex.build(from: fixture.scriptText)
    }

    func play() {
        stop()
        isPlaying = true
        eventsPlayed = 0
        cursor = PromptCursor(tokenIndex: 0, confidence: 0, state: .holding)

        let matcher = SlidingWindowMatcher(scriptIndex: scriptIndex)
        let events = fixture.events

        playTask = Task {
            var previousElapsed: TimeInterval = 0
            for event in events {
                let delay = event.elapsed - previousElapsed
                previousElapsed = event.elapsed
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                if Task.isCancelled { return }
                cursor = matcher.advance(spoken: event.tokens, now: event.elapsed)
                eventsPlayed += 1
            }
            isPlaying = false
        }
    }

    func stop() {
        playTask?.cancel()
        playTask = nil
        isPlaying = false
    }
}

#endif
