@preconcurrency import AVFoundation

/// §8's `AudioCapturing` protocol: raw microphone buffers in, no Speech-framework knowledge.
protocol AudioCapturing: Sendable {
    func start() throws -> AsyncStream<AVAudioPCMBuffer>
    func stop()
}

/// Captures microphone audio via `AVAudioEngine` (§11.3, §11.8). Deliberately not main-actor
/// isolated: `AVAudioEngine`'s start/stop/tap calls don't require the main thread, and keeping
/// this off the main actor matches §11.5's intent for the whole speech pipeline — the tap
/// callback itself fires on an engine-internal audio thread regardless, with buffers reaching
/// consumers through `AsyncStream` (safe to yield into from any thread).
///
/// Verified against the installed iOS 26.5 SDK headers (AVAudioNode.h, AVAudioSession.h/
/// AVAudioSessionTypes.h — see AGENT_PROGRESS.md): `installTap(onBus:bufferSize:format:block:)`,
/// `AVAudioSession.setCategory(_:mode:options:)`, `AVAudioSession.interruptionNotification` +
/// `AVAudioSessionInterruptionTypeKey` / `AVAudioSession.InterruptionType`.
///
/// `@unchecked Sendable`: mutable state (`continuation`, `interruptionObserver`), but only ever
/// set/read from whichever single task drives start()/stop() — never accessed concurrently.
final class AudioCaptureService: AudioCapturing, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var interruptionObserver: NSObjectProtocol?

    func start() throws -> AsyncStream<AVAudioPCMBuffer> {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.continuation = continuation

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            continuation.yield(buffer)
        }

        engine.prepare()
        try engine.start()

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        return stream
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil

        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// A phone-call-mid-take interruption (§11.8): stop cleanly and let the caller (the future
    /// session coordinator, M3/M4) decide whether and how to resume — this service's job is just
    /// to never leave the engine/session in a broken state.
    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            stop()
        case .ended:
            break
        @unknown default:
            break
        }
    }
}
