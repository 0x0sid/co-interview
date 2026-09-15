// Developer-only. Reachable only from the removed debug menu, so it is compiled out of
// Release entirely (M5.11) rather than shipping as dead, unreachable UI.
#if DEBUG
import SwiftUI

/// Lets you paste or type any script to test live-mic tracking against, instead of being locked
/// to a fixed fixture — replaces M3's original two separate debug entries ("Demo" and "Live Mic",
/// see docs/DECISIONS.md) now that the live-mic path itself is confirmed working on-device. A real
/// SwiftData-backed script list/editor is M5's job (§12.1); this is just enough to keep testing
/// unblocked with arbitrary text in the meantime.
struct PromptTextInputScreen: View {
    @State private var scriptText: String = PromptDemoFixture.defaultScriptText

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $scriptText)
                .font(Typography.body(16))
                .foregroundStyle(Theme.Color.ink)
                .scrollContentBackground(.hidden)
                .background(Theme.Color.paper)
                .padding(16)

            NavigationLink {
                PromptScreen(scriptText: scriptText) {
                    TranscriptionService(audioCapture: AudioCaptureService())
                }
            } label: {
                Text("Start")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ReplayButtonStyle(prominent: true))
            .disabled(scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(20)
        }
        .background(Theme.Color.paper)
        .navigationTitle("Prompt Script")
    }
}

#Preview {
    NavigationStack {
        PromptTextInputScreen()
    }
}

#endif
