import SwiftUI
import SwiftData
import AVFAudio

/// §12.2 Demo: one tap → friendly pre-permission explainer → system mic permission → bundled
/// demo script live-follows the user's voice. Never metered (no `PromptSession` is ever written
/// for it — nothing meters yet in M5 either way, but this stays true once M6's `UsageMeter`
/// exists). While the explainer shows, the speech asset pre-downloads with a small progress hint
/// (closing the M2 deviation — see docs/ARCHITECTURE.md — `TranscriptionService.start()` keeps
/// its own `ensureInstalled` call as a no-op safety net for callers that reach it without going
/// through here, e.g. the debug screens).
struct DemoScreen: View {
    private enum Phase {
        case explainer
        case preparing
        case permissionDenied
        case reading
        case complete
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var settingsQuery: [AppSettings]

    @State private var phase: Phase = .explainer
    @State private var downloadProgress: Double = 0

    /// Called after the user taps "Create your first script" on the closing screen — `Script
    /// ListScreen` uses this to navigate straight into a new script once the demo sheet closes,
    /// rather than DemoScreen knowing anything about Home's navigation state.
    var onCreateScript: (() -> Void)?

    var body: some View {
        NavigationStack {
            content
                .background(Theme.Color.paper)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .explainer:
            explainerView
        case .preparing:
            preparingView
        case .permissionDenied:
            permissionDeniedView
        case .reading:
            PromptScreen(scriptText: DemoScript.text, makeService: {
                TranscriptionService(audioCapture: AudioCaptureService())
            }, onSessionComplete: {
                phase = .complete
            })
        case .complete:
            completeView
        }
    }

    private var explainerView: some View {
        VStack(spacing: 20) {
            Spacer()
            MascotView(expression: .idle, size: 72)
            Text("See the magic — 30 seconds")
                .font(Typography.display(26))
                .foregroundStyle(Theme.Color.ink)
                .multilineTextAlignment(.center)
            Text("Prompter listens to your voice so the script can follow you as you speak. Everything happens on your iPhone — audio is never recorded or sent anywhere.")
                .font(Typography.body(15))
                .foregroundStyle(Theme.Color.spoken)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button("Continue") {
                phase = .preparing
                Task { await prepareAndRequestPermission() }
            }
            .buttonStyle(.prompterPrimary)
            Button("Not now") { dismiss() }
                .buttonStyle(.prompterSecondary)
        }
        .padding(24)
    }

    private var preparingView: some View {
        VStack(spacing: 16) {
            Spacer()
            MascotView(expression: .loading, size: 72)
            Text("Getting ready…")
                .font(Typography.body(17, weight: .medium))
                .foregroundStyle(Theme.Color.ink)
            ProgressView(value: downloadProgress)
                .tint(Theme.Color.action)
                .padding(.horizontal, 48)
            Spacer()
        }
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("Microphone access is off")
                .font(Typography.body(19, weight: .semibold))
                .foregroundStyle(Theme.Color.ink)
            Text("Prompter needs the microphone to follow your voice. You can turn it on in Settings.")
                .font(Typography.body(15))
                .foregroundStyle(Theme.Color.spoken)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.prompterPrimary)
            Button("Not now") { dismiss() }
                .buttonStyle(.prompterSecondary)
        }
        .padding(24)
    }

    private var completeView: some View {
        VStack(spacing: 20) {
            Spacer()
            MascotView(expression: .success, size: 72)
            Text("That's Prompter.")
                .font(Typography.display(28))
                .foregroundStyle(Theme.Color.ink)
            Spacer()
            Button("Create your first script") {
                AppSettings.fetchOrCreate(in: modelContext).hasCompletedDemo = true
                try? modelContext.save()
                dismiss()
                onCreateScript?()
            }
            .buttonStyle(.prompterPrimary)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }

    private func prepareAndRequestPermission() async {
        async let assetInstall: Void = {
            try? await SpeechAssetManager.ensureInstalled(locale: .current) { progress in
                downloadProgress = progress
            }
        }()
        async let permission = requestMicrophonePermission()

        let (_, granted) = await (assetInstall, permission)
        phase = granted ? .reading : .permissionDenied
    }

    /// Verified against the real iOS 26 SDK (AVAudioApplication.h): `AVAudioApplication.shared
    /// .recordPermission` / `requestRecordPermissionWithCompletionHandler(_:)` — the modern
    /// replacement for the deprecated `AVAudioSession.requestRecordPermission`.
    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
}

#Preview {
    DemoScreen()
        .modelContainer(for: [Script.self, PromptSession.self, UsageLedger.self, AppSettings.self], inMemory: true)
}
