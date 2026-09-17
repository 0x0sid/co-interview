import Foundation
import Observation
import SwiftUI
import AVFoundation

/// Owns one script-reading take: the audio/transcription session, the transport (start, pause,
/// resume, restart, stop), and interruption handling — and delegates every alignment decision to
/// `ReadingAlignment`.
///
/// **What moved and why (2026-09-16).** The alignment rules (volatile reconciliation, cursor
/// application, spoken-token marking and the pure `newlySpokenTokens` / `bridgedTokens` rules) now
/// live in `ReadingAlignment`, unchanged, because the interview copilot needs many independent
/// alignments — one per answer version — under a *single* continuous audio session. This type keeps
/// its previous public surface: `cursor`, `spokenTokenIndices`, `listeningText`, the transport, and
/// the static rules, which forward to `ReadingAlignment`.
///
/// Also runs a lightweight periodic tick (independent of the transcript stream) that calls
/// `alignment.tick(now:)` every 0.5s. Real silence produces no deltas at all — no volatile, no final —
/// so without this the matcher never gets a chance to notice a gap and trigger `.frozen` (§10.4, "the
/// eye contact feature"). The tick's `now` has to stay in the *same clock domain* the matcher's own
/// gap check uses internally: on-device `[PromptDebug]` logging (2026-08-13) showed a tick passing
/// wall-clock-since-`start()` running ~0.5-1s ahead of the transcriber's own clock (model/asset setup
/// happens *after* `start()` is called), so the freeze threshold fired early. It therefore tracks the
/// most recent delta of *either* kind and extrapolates from it, in the delta's own clock.
@MainActor
@Observable
final class PromptViewModel {
    let scriptText: String
    private let alignment: ReadingAlignment

    var scriptIndex: ScriptIndex { alignment.scriptIndex }
    var cursor: PromptCursor { alignment.cursor }
    var spokenTokenIndices: Set<Int> { alignment.spokenTokenIndices }
    var listeningText: String { alignment.listeningText }

    private(set) var isRunning = false
    private(set) var isPausedByInterruption = false
    /// User-initiated pause (the bottom bar's Pause button), distinct from `isPausedByInterruption`
    /// (a phone call etc.) — both resolve through the same `resume()`.
    private(set) var isManuallyPaused = false
    private(set) var errorMessage: String?
    private(set) var sessionStartedAt: Date?

    /// §12.4's end-of-session state: the cursor has reached the end of the script on a real
    /// (non-empty) advance, so the take is done.
    var isSessionComplete: Bool { isRunning && alignment.isComplete }

    private let makeService: () -> Transcribing
    private var service: Transcribing?
    private var consumeTask: Task<Void, Never>?
    private var silenceTickTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?

    /// The script's own language, used to choose the recognition locale (M5.12).
    let readingLanguage: ReadingLanguage

    init(scriptText: String, makeService: @escaping () -> Transcribing, readingLanguage: ReadingLanguage = .english) {
        self.scriptText = scriptText
        self.readingLanguage = readingLanguage
        self.alignment = ReadingAlignment(text: scriptText)
        self.makeService = makeService
    }

    /// User-initiated Start — and Restart, which just calls this again: always begins from the top of
    /// the script with a fresh matcher. For continuing an interrupted take with the cursor preserved
    /// instead, see `resume()`.
    func start() {
        isPausedByInterruption = false
        sessionStartedAt = nil
        alignment.restart()
        beginSession()
    }

    /// Continues the take with the *existing* matcher — cursor, ring buffer and confidence all
    /// untouched, unlike `start()`. Used both to auto-resume after a phone-call-style interruption
    /// ends with the system reporting it's safe to (§11.8), and as a manual "Resume" action otherwise.
    func resume() {
        isPausedByInterruption = false
        isManuallyPaused = false
        alignment.resumeKeepingProgress()
        beginSession()
    }

    /// User-initiated Pause: stops capture without resetting anything — cursor, matcher and ring
    /// buffer all stay put, same as an interruption pause, just triggered by the user instead of the
    /// system. `resume()` continues it either way.
    func pause() {
        guard isRunning else { return }
        consumeTask?.cancel()
        consumeTask = nil
        silenceTickTask?.cancel()
        silenceTickTask = nil
        let activeService = service
        service = nil
        isRunning = false
        isManuallyPaused = true
        Task { await activeService?.stop() }
    }

    /// M4's session coordinator.
    ///
    /// Has to fully await the outgoing service's `stop()` — including its
    /// `AVAudioSession.setActive(false)` — before the incoming service's `start()` calls
    /// `setActive(true)` on a brand-new `AVAudioEngine`, otherwise the two sessions race and
    /// `engine.start()` can silently fail (this was the cause of "Restart doesn't work" on-device).
    private func beginSession() {
        let newService = makeService()
        let outgoingService = service
        consumeTask?.cancel()
        silenceTickTask?.cancel()

        errorMessage = nil
        service = newService
        isRunning = true
        if sessionStartedAt == nil {
            sessionStartedAt = Date()
        }

        registerInterruptionObserverIfNeeded()

        let sessionStart = Date()

        // Temporary `[PromptDebug]` instrumentation (owner-requested, 2026-08-13) to diagnose reported
        // delay/instability on-device. **Gated for real as of M5.11** — a Release build previously
        // shipped this whole stream, including transcript text, to the device console.
        func debugLog(_ message: String) {
            #if DEBUG
            let elapsed = Date().timeIntervalSince(sessionStart)
            print(String(format: "[PromptDebug %7.3fs] %@", elapsed, message))
            #endif
        }

        let config = MatcherConfig.default
        debugLog("SESSION START — \(alignment.scriptIndex.tokens.count) tokens, \(alignment.scriptIndex.sentences.count) sentences — advanceThreshold=\(config.advanceThreshold) recoveryTriggerThreshold=\(config.recoveryTriggerThreshold) recoveryJumpThreshold=\(config.recoveryJumpThreshold)")

        // Anchors the transcriber's own audio-relative clock to wall-clock time, updated on every
        // delta (volatile *or* final) so the silence tick can extrapolate "now" in that same clock
        // domain and treat ongoing volatile speech as activity, not silence.
        var lastActivityAudioTimestamp: TimeInterval = 0
        var lastActivityWallClock = Date()
        let alignment = alignment

        consumeTask = Task {
            await outgoingService?.stop()
            do {
                // **The script's language, not the device's (M5.12).** `SpeechAssetManager.supportedLocale`
                // resolves this to a locale the installed transcriber actually supports and **throws**
                // if none is close enough — there is no silent substitution.
                let stream = try await newService.start(
                    locale: readingLanguage.requestedLocale,
                    contextualStrings: alignment.distinctiveVocabulary
                )
                for await delta in stream {
                    lastActivityAudioTimestamp = delta.timestamp
                    lastActivityWallClock = Date()
                    let before = alignment.cursor
                    alignment.ingest(delta)
                    switch delta.kind {
                    case .volatile:
                        debugLog("VOLATILE  audio_ts=\(String(format: "%7.3f", delta.timestamp))s  text=\"\(delta.text)\"")
                    case .final:
                        let after = alignment.cursor
                        debugLog("CURSOR    (final, \(delta.tokens.count) tokens) token \(before.tokenIndex) -> \(after.tokenIndex) (Δ\(after.tokenIndex - before.tokenIndex))  confidence=\(String(format: "%.2f", after.confidence))  state=\(after.state)")
                    }
                }
            } catch {
                errorMessage = "\(error)"
                debugLog("ERROR     \(error)")
            }
            isRunning = false
            debugLog("SESSION END")
        }

        silenceTickTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { break }
                let estimatedNow = lastActivityAudioTimestamp + Date().timeIntervalSince(lastActivityWallClock)
                let before = alignment.cursor
                alignment.tick(now: estimatedNow)
                if alignment.cursor.state != before.state {
                    debugLog("TICK      state \(before.state) -> \(alignment.cursor.state) (silence check, estimated_audio_now=\(String(format: "%.3f", estimatedNow))s)")
                }
            }
        }
    }

    private func registerInterruptionObserverIfNeeded() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // `Notification` itself isn't `Sendable` (its `userInfo` is `[AnyHashable: Any]`), so it
            // can't cross into the `@MainActor` `Task` below directly — parse out just the two plain,
            // Sendable values `handleInterruption` actually needs right here instead.
            guard let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            Task { @MainActor in
                self?.handleInterruption(type: type, shouldResume: shouldResume)
            }
        }
    }

    /// The session-level counterpart to `AudioCaptureService`'s own interruption handling: that
    /// component already stops its engine/session immediately on `.began` (releasing the mic for the
    /// call) and unregisters its *own* observer — so nothing is left listening for the matching
    /// `.ended` event. This observer lives for the whole session instead (§11.8).
    private func handleInterruption(type: AVAudioSession.InterruptionType, shouldResume: Bool) {
        switch type {
        case .began:
            guard isRunning else { return }
            isPausedByInterruption = true
        case .ended:
            guard isPausedByInterruption else { return }
            if shouldResume {
                resume()
            }
            // else: stay paused. The matcher/cursor are untouched either way, and `resume()` is still
            // reachable from the UI's "Resume" action.
        @unknown default:
            break
        }
    }

    func stop() {
        consumeTask?.cancel()
        consumeTask = nil
        silenceTickTask?.cancel()
        silenceTickTask = nil
        isPausedByInterruption = false
        isManuallyPaused = false
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil
        let activeService = service
        service = nil
        isRunning = false
        Task { await activeService?.stop() }
    }

    // MARK: - Alignment rules (forwarded, so existing call sites and tests are unchanged)

    nonisolated static func newlySpokenTokens(
        fedWords: [String],
        from previousIndex: Int,
        to newIndex: Int,
        state: PromptCursor.State,
        scriptTokens: [String]
    ) -> Set<Int> {
        ReadingAlignment.newlySpokenTokens(
            fedWords: fedWords, from: previousIndex, to: newIndex, state: state, scriptTokens: scriptTokens
        )
    }

    nonisolated static func bridgedTokens(
        directlySpoken: Set<Int>,
        continuityBreaks: Set<Int>,
        maximumGap: Int
    ) -> Set<Int> {
        ReadingAlignment.bridgedTokens(
            directlySpoken: directlySpoken, continuityBreaks: continuityBreaks, maximumGap: maximumGap
        )
    }

    nonisolated static var maximumBridgedTokens: Int { ReadingAlignment.maximumBridgedTokens }
    nonisolated static var shiftedPairMinSimilarity: Double { ReadingAlignment.shiftedPairMinSimilarity }
    nonisolated static var fedHistoryLimit: Int { ReadingAlignment.fedHistoryLimit }
    nonisolated static var spokenWordMinSimilarity: Double { ReadingAlignment.spokenWordMinSimilarity }
}
