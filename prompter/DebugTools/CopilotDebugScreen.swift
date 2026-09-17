#if DEBUG
import SwiftUI

/// Development entry point for the copilot prototype (§9, §12).
///
/// Lets a developer choose the fixture project, the transcript source (live microphone or a scripted
/// synthetic interview) and the provider (configured backend or the labelled development fake), then
/// opens `CopilotScreen`. Debug-only: the production surface is untouched.
struct CopilotDebugScreen: View {
    @AppStorage(ProviderConfiguration.backendURLDefaultsKey) private var backendURL = ""
    @AppStorage(ProviderConfiguration.backendTokenDefaultsKey) private var backendToken = ""
    @AppStorage(ProviderConfiguration.useFakeProviderDefaultsKey) private var useFakeProvider = false
    @State private var projectIndex = 0
    @State private var useSyntheticTranscript = true
    @State private var backendConfiguration: CopilotBackendConfiguration?

    private var configuration: ProviderConfiguration { ProviderConfiguration.resolve() }
    private var project: SyntheticProject { SyntheticProjectFixture.all[projectIndex] }

    var body: some View {
        Form {
            Section("Fixture project") {
                Picker("Project", selection: $projectIndex) {
                    ForEach(Array(SyntheticProjectFixture.all.enumerated()), id: \.offset) { index, project in
                        Text(project.projectName).tag(index)
                    }
                }
                Text("\(project.allPassages.count) synthetic passages · \(project.language.displayName)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Transcript source") {
                Toggle("Synthetic interview (no microphone)", isOn: $useSyntheticTranscript)
                Text(useSyntheticTranscript
                     ? "Replays a scripted interview through the same pipeline as live audio."
                     : "Uses the real microphone. Speech recognition does not run in the Simulator.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("Provider") {
                TextField("Backend URL (e.g. http://127.0.0.1:8787)", text: $backendURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Backend access token", text: $backendToken)
                Toggle("Use development fake provider", isOn: $useFakeProvider)
                statusRow
                activeRouteRow
            }

            Section {
                NavigationLink("Start interview session") {
                    CopilotScreen(
                        project: project,
                        provider: configuration.makeProvider(),
                        audio: InterviewAudioInput(makeService: makeService)
                    )
                }
            } footer: {
                Text("Development only. Nothing is recorded or saved; the transcript stays in memory for this session.")
            }
        }
        .task { backendConfiguration = await configuration.makeProvider().configuration() }
        .navigationTitle("Debug: Copilot")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The backend decides the gateway, model and route; the app only displays what it is told.
    @ViewBuilder
    private var activeRouteRow: some View {
        if let backendConfiguration {
            VStack(alignment: .leading, spacing: 2) {
                Text("Active route").font(.caption).foregroundStyle(.secondary)
                Text(backendConfiguration.summary).font(.footnote.monospaced())
                Text("fallback: \(backendConfiguration.fallback_model_id) · fallbacks \(backendConfiguration.allow_fallbacks ? "on" : "off") · reasoning \(backendConfiguration.reasoning_enabled ? "on" : "off")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            Button("Check active route") {
                Task { backendConfiguration = await configuration.makeProvider().configuration() }
            }
            .font(.footnote)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch configuration.availability {
        case .backend(let url):
            Label("Backend configured: \(url.absoluteString)", systemImage: "checkmark.circle")
                .font(.footnote).foregroundStyle(.green)
        case .developmentFake:
            Label("Development fake — answers are canned text, clearly marked", systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(.orange)
        case .unavailable(let reason):
            Label(reason, systemImage: "xmark.circle")
                .font(.footnote).foregroundStyle(.red)
        }
    }

    private func makeService() -> Transcribing {
        useSyntheticTranscript
            ? FakeTranscriptionService(results: SyntheticInterview.forLanguage(project.language).scriptedResults())
            : TranscriptionService(audioCapture: AudioCaptureService())
    }
}
#endif
