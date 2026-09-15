// Developer-only. Compiled out of Release entirely (M5.11): these screens are unreachable from
// the app UI after the debug menu was removed, and must not exist in a shipping binary.
#if DEBUG
import SwiftUI
import Foundation

/// A small scripted sequence for the "Play Demo" button — lets the transcript UI (and its
/// latency measurement) be exercised in the Simulator, where real Speech does not work (§11.6).
private enum DebugTranscriptFixture {
    static let demo: [FakeTranscriptionService.ScriptedResult] = [
        .init(text: "so", isFinal: false, elapsed: 0.3),
        .init(text: "so today", isFinal: false, elapsed: 0.6),
        .init(text: "so today we", isFinal: false, elapsed: 0.9),
        .init(text: "so today we are", isFinal: false, elapsed: 1.2),
        .init(text: "so today we are going to talk about", isFinal: true, elapsed: 1.8),
        .init(text: "the", isFinal: false, elapsed: 2.1),
        .init(text: "the matching", isFinal: false, elapsed: 2.4),
        .init(text: "the matching engine", isFinal: true, elapsed: 2.8),
    ]
}

/// §16 M2's debug transcript screen: live volatile text in gray, finalized in black, and a
/// measurement of time-to-first-volatile-result (the M2 device gate is < 1s). Compiled out of
/// Release builds.
@MainActor
@Observable
final class DebugTranscriptViewModel {
    private(set) var volatileText = ""
    private(set) var finalizedText = ""
    private(set) var isRunning = false
    private(set) var firstVolatileResultLatency: TimeInterval?
    private(set) var errorMessage: String?

    private var service: Transcribing?
    private var consumeTask: Task<Void, Never>?

    func startLive() {
        start(using: TranscriptionService(audioCapture: AudioCaptureService()))
    }

    func startFakeDemo() {
        start(using: FakeTranscriptionService(results: DebugTranscriptFixture.demo))
    }

    func stop() {
        consumeTask?.cancel()
        consumeTask = nil
        let activeService = service
        service = nil
        isRunning = false
        Task { await activeService?.stop() }
    }

    private func start(using service: Transcribing) {
        stop()
        self.service = service
        volatileText = ""
        finalizedText = ""
        firstVolatileResultLatency = nil
        errorMessage = nil
        isRunning = true

        let sessionStart = Date()

        consumeTask = Task {
            do {
                // No script loaded on this debug screen (§16 M2, predates the real Prompt
                // screen), so nothing to bias toward — see PromptViewModel.distinctiveVocabulary
                // for the real use of this parameter (§11.7, M4 Step 3).
                let stream = try await service.start(locale: Locale.current, contextualStrings: [])
                for await delta in stream {
                    if delta.kind == .volatile, firstVolatileResultLatency == nil {
                        let latency = Date().timeIntervalSince(sessionStart)
                        firstVolatileResultLatency = latency
                        print("[M2] time to first volatile result: \(String(format: "%.3f", latency))s")
                    }
                    switch delta.kind {
                    case .volatile:
                        volatileText = delta.text
                    case .final:
                        volatileText = ""
                        finalizedText = finalizedText.isEmpty ? delta.text : "\(finalizedText) \(delta.text)"
                    }
                }
            } catch {
                errorMessage = "\(error)"
            }
            isRunning = false
        }
    }
}

struct DebugTranscriptScreen: View {
    @State private var viewModel = DebugTranscriptViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                transcriptText
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }

            latencyRow
                .padding(.horizontal, 20)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(Typography.mono(12))
                    .foregroundStyle(Theme.Color.error)
                    .padding(.horizontal, 20)
            }

            controls
                .padding(20)
        }
        .background(Theme.Color.paper)
        .navigationTitle("Debug: Live Transcript")
    }

    private var transcriptText: Text {
        let finalized = Text(viewModel.finalizedText)
            .foregroundStyle(Theme.Color.ink)
        let separator = viewModel.finalizedText.isEmpty || viewModel.volatileText.isEmpty ? "" : " "
        let volatileText = Text(viewModel.volatileText)
            .foregroundStyle(Theme.Color.spoken)
        return Text("\(finalized)\(separator)\(volatileText)")
            .font(Typography.body(20))
    }

    private var latencyRow: some View {
        HStack(spacing: 8) {
            Text("time to first volatile result:")
                .font(Typography.mono(13))
                .foregroundStyle(Theme.Color.spoken)
            if let latency = viewModel.firstVolatileResultLatency {
                Text(String(format: "%.3fs", latency))
                    .font(Typography.mono(13, weight: .medium))
                    .foregroundStyle(latency < 1.0 ? Theme.Color.action : Theme.Color.error)
            } else {
                Text("—")
                    .font(Typography.mono(13))
                    .foregroundStyle(Theme.Color.spoken)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button("Play Demo") { viewModel.startFakeDemo() }
                .buttonStyle(ReplayButtonStyle(prominent: false))
            Button("Start Live (Mic)") { viewModel.startLive() }
                .buttonStyle(ReplayButtonStyle(prominent: true))
            Button("Stop") { viewModel.stop() }
                .buttonStyle(ReplayButtonStyle(prominent: false))
                .disabled(!viewModel.isRunning)
        }
    }
}

#Preview {
    NavigationStack {
        DebugTranscriptScreen()
    }
}

#endif
