import Foundation
import Speech
@preconcurrency import AVFoundation
@preconcurrency import AVFAudio
import CoreMedia

/// §8's `Transcribing` protocol — implemented by the real `TranscriptionService` and by
/// `FakeTranscriptionService` (replays a recorded transcript with timing, so the rest of the app
/// is testable/demoable without a microphone — real Speech does not work in the Simulator, §11.6).
protocol Transcribing: Sendable {
    /// `contextualStrings`: distinctive script vocabulary to bias recognition toward (§11.7, M4
    /// Step 3) — proper nouns and unusual words general-purpose dictation otherwise struggles
    /// with. `FakeTranscriptionService` ignores it (nothing to bias, it's scripted playback).
    func start(locale: Locale, contextualStrings: [String]) async throws -> AsyncStream<TranscriptDelta>
    func stop() async
}

enum TranscriptionError: Error, Sendable {
    case noCompatibleAudioFormat
}

/// Real on-device transcription via `SpeechAnalyzer`/`SpeechTranscriber` (§11).
///
/// Consumes `transcriber.results` off the main actor deliberately: this type carries no actor
/// annotation, and its background work runs in a plain `Task`, not `Task { @MainActor in ... }`
/// — §11.5 documents forum reports of 14s first-result latency when results are consumed on the
/// main actor instead.
///
/// Verified against the installed iOS 26.5 SDK's Speech.swiftinterface (see AGENT_PROGRESS.md):
/// `SpeechTranscriber.init(locale:transcriptionOptions:reportingOptions:attributeOptions:)`,
/// `SpeechAnalyzer.init(modules:)`, `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`,
/// `SpeechAnalyzer.prepareToAnalyze(in:)`, `SpeechAnalyzer.analyzeSequence(_:)`,
/// `AnalyzerInput.init(buffer:)`, `SpeechTranscriber.results`, `SpeechModuleResult.isFinal`,
/// `AnalysisContext.init()`/`.contextualStrings`/`.ContextualStringsTag.general`,
/// `SpeechAnalyzer.setContext(_:)`.
final class TranscriptionService: Transcribing, @unchecked Sendable {
    private let audioCapture: AudioCapturing
    private let stream = TranscriptStream()
    private var workTask: Task<Void, Never>?

    init(audioCapture: AudioCapturing) {
        self.audioCapture = audioCapture
    }

    func start(locale: Locale, contextualStrings: [String]) async throws -> AsyncStream<TranscriptDelta> {
        let resolvedLocale = try await SpeechAssetManager.supportedLocale(for: locale)
        // Normally pre-warmed during onboarding/the demo screen (§11.2, M5); calling it here too
        // means this debug screen works standalone on a fresh device/locale with no onboarding
        // flow to depend on. A no-op if the model is already installed.
        try await SpeechAssetManager.ensureInstalled(locale: resolvedLocale)

        // `.fastResults` (confirmed to exist via the real iOS 26.5 SDK's Speech.swiftinterface,
        // not from memory — `SpeechTranscriber.ReportingOption` has `.volatileResults`,
        // `.alternativeTranscriptions`, `.fastResults`) was previously omitted; on-device logging
        // (`[PromptDebug]`, 2026-08-13) showed `.final` results arriving 3.7-15.4s apart even
        // during continuous reading, which is the dominant cause of the reported "a lot of delay"
        // — the cursor only moves on `.final`, so it sat frozen for up to 15s at a stretch. Not
        // yet confirmed this closes the gap (needs the same device re-test), but it's the
        // documented, sanctioned lever for exactly this.
        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )

        // `.processLifetime` keeps the on-device model loaded for the life of the app process.
        // Without this, the default retention unloads the model between uses once idle for a
        // while, and reloading it shows up as multi-second time-to-first-volatile-result on a
        // later take — confirmed on-device: two takes in the same session came back
        // 0.437s/0.320s, then two later takes (after a pause) came back 4.235s/4.241s, near-
        // identical enough to indicate a real reload cost, not jitter. The M2 gate (<1s) has to
        // hold on every take a presenter might do mid-session, not just the first.
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )

        // §11.7 / M4 Step 3: `AnalysisContext.contextualStrings` — confirmed to exist in the real
        // iOS 26.5 SDK's Speech.swiftinterface (`AnalysisContext.contextualStrings: [Analysis
        // Context.ContextualStringsTag: [String]]`, `SpeechAnalyzer.setContext(_:) async throws`),
        // not assumed. §11.7 explicitly warns not to fake this if the SDK didn't expose it — it
        // does, so it's wired in directly rather than skipped. Empty list is a no-op rather than
        // an error, so callers with no script loaded yet (or `FakeTranscriptionService`, which
        // doesn't call this at all) don't need special-casing.
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try await analyzer.setContext(context)
        }

        guard let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.noCompatibleAudioFormat
        }
        try await analyzer.prepareToAnalyze(in: audioFormat)

        let micBufferStream = try audioCapture.start()

        let (analyzerInputs, analyzerContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let (deltaStream, deltaContinuation) = AsyncStream<TranscriptDelta>.makeStream()

        let startTime = Date()
        let transcriptStream = stream
        #if DEBUG
        // Which recognizer a `[ClockAudit]` line came from. Its `observed` clock restarts at each
        // recognizer's own start, so two interleaved timelines are either one recognizer restarted
        // (a resume, a new session) or two running at once — and only an identity tells them apart.
        let auditInstance = String(UUID().uuidString.prefix(6))
        let auditStarted = ISO8601DateFormatter().string(from: startTime)
        print("[ClockAudit] recognizer=\(auditInstance) started=\(auditStarted)")
        #endif

        workTask = Task {
            async let analyzing: Void = {
                _ = try? await analyzer.analyzeSequence(analyzerInputs)
            }()

            async let reporting: Void = {
                do {
                    for try await result in transcriber.results {
                        let elapsed = Date().timeIntervalSince(startTime)
                        let text = String(result.text.characters)

                        #if DEBUG
                        // `[ClockAudit]` — **behaviour-neutral instrumentation only** (M5.2,
                        // docs/MATCHING_ENGINE.md §M5.2.1). It logs; it changes nothing. `ingest`
                        // below still receives `elapsed`, exactly as before.
                        //
                        // Why it exists: `elapsed` is wall-clock time at the moment this app
                        // *observes* the result, and it is what every token timestamp and every
                        // time-based matcher rule ultimately consumes — yet
                        // `TranscriptDelta.timestamp` documents itself as audio-relative and
                        // `[PromptDebug]` labels it `audio_ts`. The analyzer's own audio timing is
                        // available via the `.audioTimeRange` attribute already requested in
                        // `attributeOptions`. Logging both is the only way to measure how far
                        // apart they actually run under real ASR lag; no capture in the project
                        // records both, which is why the divergence is so far unquantified rather
                        // than merely unfixed.
                        //
                        // Symbols verified against the installed iOS 26.5 SDK's
                        // Speech.swiftinterface (§24.1):
                        // `AttributeScopes.SpeechAttributes.TimeRangeAttribute`, `Value =
                        // CoreMedia.CMTimeRange`, reachable as `\.audioTimeRange` on a run.
                        if let audioRange = result.text.runs[\.audioTimeRange].compactMap(\.0).last {
                            let audioEnd = CMTimeGetSeconds(audioRange.end)
                            print(String(
                                format: "[ClockAudit] recognizer=%@ observed=%7.3fs audioEnd=%7.3fs lag=%+.3fs isFinal=%@ chars=%d",
                                auditInstance, elapsed, audioEnd, elapsed - audioEnd,
                                result.isFinal ? "Y" : "N", text.count))
                        }
                        #endif

                        if let delta = transcriptStream.ingest(text: text, isFinal: result.isFinal, at: elapsed) {
                            deltaContinuation.yield(delta)
                        }
                    }
                } catch {
                    // Results sequence ended with an error (e.g. cancellation); nothing more to report.
                }
                deltaContinuation.finish()
            }()

            // Runs directly in this task's body, not a child task: `micBufferStream`'s element
            // (AVAudioPCMBuffer) isn't Sendable, so it must be consumed in the same task that
            // created it rather than "sent" across an async-let boundary.
            var converter: AVAudioConverter?
            for await buffer in micBufferStream {
                if converter == nil {
                    converter = AVAudioConverter(from: buffer.format, to: audioFormat)
                }
                if let converter, let converted = Self.convert(buffer, using: converter, to: audioFormat) {
                    analyzerContinuation.yield(AnalyzerInput(buffer: converted))
                }
            }
            analyzerContinuation.finish()

            _ = await (analyzing, reporting)
        }

        return deltaStream
    }

    func stop() async {
        workTask?.cancel()
        workTask = nil
        audioCapture.stop()
    }

    /// One buffer in, one (resampled/reformatted) buffer out. Apple's header for
    /// `convertToBuffer:fromBuffer:error:` (the simple one-shot form) is explicit: "a conversion
    /// which does not involve codecs or sample rate conversion... If the conversion involves a
    /// codec or sample rate conversion, you instead must use convertToBuffer:error:
    /// withInputFromBlock:." Our mic buffer (device-native rate, e.g. 48kHz) to Speech's
    /// `bestAvailableAudioFormat` (16kHz) is exactly a sample-rate conversion — confirmed on-device
    /// (`AudioConverterConvertComplexBuffer: sample rate conversion not allowed`, error -50, no
    /// transcript output), so the block-based converter is required, not optional. The block
    /// supplies the whole input buffer on its first invocation and reports `.noDataNow` after,
    /// which makes one `convert(to:error:withInputFrom:)` call behave as a one-shot conversion of
    /// exactly this buffer (verified via a minimal compile check against the real SDK; see
    /// AGENT_PROGRESS.md).
    private static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let scaledEstimate = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        let capacity = max(scaledEstimate, buffer.frameLength) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        let input = SingleBufferInput(buffer: buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let buffer = input.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status == .haveData || status == .inputRanDry, error == nil, output.frameLength > 0 else {
            return nil
        }
        return output
    }

    /// `AVAudioConverterInputBlock` is `@Sendable`-typed even though Apple's documented usage
    /// calls it synchronously, within the same `convert(to:error:withInputFrom:)` call — so a
    /// plain captured `var` and a captured non-Sendable `AVAudioPCMBuffer` both trigger strict
    /// concurrency warnings despite being safe in practice. `@unchecked Sendable` here matches
    /// that actual (single-threaded, non-escaping) contract, same pattern as
    /// `AudioCaptureService`'s continuation handling.
    private final class SingleBufferInput: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }
}

/// Replays a recorded transcript with timing (§8, §11.6) — this is how the rest of the app is
/// tested/demoed without a microphone, since real Speech does not work in the Simulator.
final class FakeTranscriptionService: Transcribing, @unchecked Sendable {
    struct ScriptedResult: Sendable {
        let text: String
        let isFinal: Bool
        /// Seconds from the start of playback.
        let elapsed: TimeInterval
    }

    private let results: [ScriptedResult]
    private let playbackRate: Double
    private var playTask: Task<Void, Never>?

    /// `playbackRate` shortens the *waiting* between scripted results without touching their
    /// timestamps. That distinction matters: `elapsed` is audio time, and everything downstream —
    /// turn segmentation, the detector's cooldown, the matcher's silence freeze — reasons in that
    /// clock. Compressing the timestamps instead would fabricate an interview whose speakers never
    /// pause, which is not a faster test but a different (and unrealistic) one.
    init(results: [ScriptedResult], playbackRate: Double = 1) {
        self.results = results
        self.playbackRate = max(0.0001, playbackRate)
    }

    func start(locale: Locale, contextualStrings: [String]) async throws -> AsyncStream<TranscriptDelta> {
        let stream = TranscriptStream()
        let (deltaStream, continuation) = AsyncStream<TranscriptDelta>.makeStream()
        let scripted = results
        let rate = playbackRate

        playTask = Task {
            var previousElapsed: TimeInterval = 0
            for result in scripted {
                let delay = (result.elapsed - previousElapsed) / rate
                previousElapsed = result.elapsed
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                if Task.isCancelled { break }
                if let delta = stream.ingest(text: result.text, isFinal: result.isFinal, at: result.elapsed) {
                    continuation.yield(delta)
                }
            }
            continuation.finish()
        }

        return deltaStream
    }

    func stop() async {
        playTask?.cancel()
        playTask = nil
    }
}
