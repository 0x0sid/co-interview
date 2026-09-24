import Foundation
import Observation
import SwiftUI
import AVFoundation

/// The interview's **single, continuous** capture and transcription session (§3).
///
/// One session runs for the whole interview. It is deliberately ignorant of questions, answers,
/// providers and reading: nothing in detection or generation can stop it, because nothing in detection
/// or generation can reach it. The only things that stop it are the user's explicit listening pause,
/// the end of the session, a system interruption, or a failure — each of which is reported as a
/// `ListeningState` the UI shows verbatim.
///
/// **What "continuous" does not mean.** It does not survive app suspension, a phone call taking the
/// microphone, revoked permission, or an audio-session interruption. Those produce `.interrupted`,
/// `.permissionDenied` or `.failed`, and recovery is attempted only where the system says it is safe
/// (`AVAudioSession.InterruptionOptions.shouldResume`).
@MainActor
@Observable
final class InterviewAudioInput {
    private(set) var state: ListeningState = .idle
    /// Transcript-clock time of the most recent delta of either kind.
    private(set) var lastActivityTime: TimeInterval = 0
    /// Wall clock at that same moment, so a caller can extrapolate "now" in the transcript's clock.
    private(set) var lastActivityWallClock = Date()
    /// Counts sessions started. A restart after an interruption increments it; per-question work never does.
    private(set) var startCount = 0

    /// Consumers. Set by the coordinator; the audio layer knows nothing about what they do.
    var onDelta: ((TranscriptDelta) -> Void)?
    var onSilenceTick: ((TimeInterval) -> Void)?

    private let makeService: () -> Transcribing
    private var service: Transcribing?
    private var consumeTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var language: InterviewLanguage = .english
    /// Vocabulary bias handed to the transcriber once per session (§11.7): project terms, not script terms.
    private var contextualStrings: [String] = []

    init(makeService: @escaping () -> Transcribing) {
        self.makeService = makeService
    }

    func start(language: InterviewLanguage, contextualStrings: [String] = []) {
        self.language = language
        self.contextualStrings = contextualStrings
        beginSession(resetActivityClock: true)
    }

    /// A new recognition language. A running session restarts in it at once; a paused or idle one
    /// uses it when it next starts.
    func setLanguage(_ language: InterviewLanguage, contextualStrings: [String]) {
        guard language != self.language else { return }
        self.language = language
        self.contextualStrings = contextualStrings
        guard state == .listening || state == .starting else { return }
        teardown()
        beginSession(resetActivityClock: false)
    }

    /// The user's explicit listening pause: new interview speech stops being processed and the
    /// microphone is released. **Distinct from pausing voice-following**, which only stops the reader
    /// from following and leaves listening untouched (§3).
    func pauseListening() {
        guard state == .listening || state == .starting || state == .interrupted else { return }
        teardown()
        state = .pausedByUser
    }

    func resumeListening() {
        guard state == .pausedByUser || state == .interrupted || state == .failed("") || state == .idle else {
            if case .failed = state {} else { return }
            beginSession(resetActivityClock: false)
            return
        }
        beginSession(resetActivityClock: false)
    }

    func stop() {
        teardown()
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil
        state = .idle
    }

    private func beginSession(resetActivityClock: Bool) {
        let newService = makeService()
        let outgoing = service
        consumeTask?.cancel()
        tickTask?.cancel()
        service = newService
        state = .starting
        startCount += 1
        if resetActivityClock {
            lastActivityTime = 0
            lastActivityWallClock = Date()
        }
        registerInterruptionObserverIfNeeded()

        let locale = language.readingLanguage.requestedLocale
        let strings = contextualStrings

        consumeTask = Task { [weak self] in
            // Fully await the outgoing session's teardown before the new one activates its audio
            // session — the two race otherwise and `engine.start()` can silently fail (M4).
            await outgoing?.stop()
            guard let self else { return }
            do {
                let stream = try await newService.start(locale: locale, contextualStrings: strings)
                self.state = .listening
                for await delta in stream {
                    if Task.isCancelled { break }
                    self.lastActivityTime = delta.timestamp
                    self.lastActivityWallClock = Date()
                    self.onDelta?(delta)
                }
                // The stream ended on its own (service stopped, or the analyzer finished).
                if self.state == .listening { self.state = .idle }
            } catch {
                self.state = Self.failureState(for: error)
            }
        }

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.state == .listening else { continue }
                let estimatedNow = self.lastActivityTime + Date().timeIntervalSince(self.lastActivityWallClock)
                self.onSilenceTick?(estimatedNow)
            }
        }
    }

    private func teardown() {
        consumeTask?.cancel()
        consumeTask = nil
        tickTask?.cancel()
        tickTask = nil
        let outgoing = service
        service = nil
        Task { await outgoing?.stop() }
    }

    private static func failureState(for error: Error) -> ListeningState {
        if let assetError = error as? SpeechAssetManager.AssetError {
            switch assetError {
            case .localeNotSupported(let locale):
                return .failed("no on-device model for \(locale.identifier)")
            }
        }
        return .failed(error.localizedDescription)
    }

    private func registerInterruptionObserverIfNeeded() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
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

    private func handleInterruption(type: AVAudioSession.InterruptionType, shouldResume: Bool) {
        switch type {
        case .began:
            guard state == .listening || state == .starting else { return }
            teardown()
            state = .interrupted
        case .ended:
            guard state == .interrupted else { return }
            // Only the system can say it is safe to take the microphone back. Otherwise the user
            // resumes explicitly, and the UI keeps saying "Interrupted" until they do.
            if shouldResume { beginSession(resetActivityClock: false) }
        @unknown default:
            break
        }
    }
}
