#if DEBUG
import SwiftUI
import AVFoundation

/// The copilot's entry point in a development build: choose **Demo** or **Live**, see honestly what
/// each will do, and start it with a tap.
///
/// It exists because the copilot was previously reachable only through the `-copilotReplay` launch
/// argument and the debug menu, so a normal launch showed only the inherited teleprompter. Launch
/// arguments still work for automated verification; this is the path a person can actually navigate.
///
/// **Two honesty rules shape this screen.** The sample project is named as a sample — it is not the
/// owner's documents, and document import does not exist yet. And Live never quietly becomes Demo:
/// when the backend or the microphone is not ready, Live says so and stays disabled.
struct CopilotStartScreen: View {
    enum Mode: String, Identifiable {
        case demo, live
        var id: String { rawValue }

        var title: String { self == .demo ? "Demo interview" : "Live interview" }
        var badge: String { self == .demo ? "DEMO" : "LIVE" }
    }

    @State private var language: InterviewLanguage = .english
    @State private var startedMode: Mode?
    /// The previous pipeline screen, kept reachable so the provider work it exercises is not stranded.
    @State private var startedPipelineMode: Mode?
    @State private var microphonePermission = AVAudioApplication.shared.recordPermission
    @State private var backendConfiguration: CopilotBackendConfiguration?
    @State private var isCheckingBackend = false
    /// What Live can actually do right now — checked, not assumed.
    @State private var readiness = LiveReadiness(isChecking: true)

    private var providerConfiguration: ProviderConfiguration { ProviderConfiguration.resolve() }
    private var project: SyntheticProject {
        language == .french ? SyntheticProjectFixture.hospitalReview : SyntheticProjectFixture.transportProgramme
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                intro
                languagePicker
                demoCard
                liveCard
                pipelinePrototypeNote
                sampleProjectNote
                Text(BuildInfo.footer)
                    .font(Typography.mono(11))
                    .foregroundStyle(Theme.Color.secondary)
            }
            .padding(20)
        }
        .background(Theme.Color.paper)
        .navigationTitle("Interview Copilot")
        .navigationBarTitleDisplayMode(.inline)
        // The v2.5 interview screen. Demo plays a scripted interview through it; Live opens the
        // state that says what it would need, rather than quietly showing the script.
        .fullScreenCover(item: $startedMode) { mode in
            NavigationStack {
                switch mode {
                case .demo:
                    InterviewScreen(mode: .demo, title: "Technical interview")
                case .live:
                    if readiness.canListen {
                        InterviewScreen(
                            mode: .live,
                            title: "Live interview",
                            feed: makeLiveFeed(),
                            readiness: readiness
                        )
                    } else {
                        InterviewLiveUnavailableView(readiness: readiness)
                    }
                }
            }
        }
        .fullScreenCover(item: $startedPipelineMode) { mode in
            NavigationStack {
                CopilotScreen(
                    project: project,
                    provider: mode == .demo ? FakeCopilotProvider() : providerConfiguration.makeProvider(),
                    audio: InterviewAudioInput(makeService: { makeTranscriptionService(for: mode) }),
                    modeBadge: mode.badge
                )
            }
        }
        .task {
            microphonePermission = AVAudioApplication.shared.recordPermission
            await refreshBackend()
            await refreshReadiness()
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Listen to an interview, suggest answers, read them aloud")
                .font(Typography.display(20))
                .foregroundStyle(Theme.Color.ink)
            Text("Detected questions become cards. Swipe between them; the text follows your voice as you read, exactly as a script does.")
                .font(Typography.body(14))
                .foregroundStyle(Theme.Color.secondary)
        }
    }

    private var languagePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Interview language").font(Typography.body(12, weight: .medium)).foregroundStyle(Theme.Color.secondary)
            Picker("Interview language", selection: $language) {
                ForEach(InterviewLanguage.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: Demo

    private var demoCard: some View {
        card(
            badge: Mode.demo.badge,
            badgeColor: Theme.Color.action,
            title: Mode.demo.title,
            body: "A scripted interview plays through the v2.5 interview screen — no microphone, no network. Questions appear as they are detected; answers are written only when you tap Generate. The content is invented development text, clearly marked.",
            footnote: "Works with no setup.",
            actionTitle: "Start demo",
            isEnabled: true,
            action: { startedMode = .demo }
        )
    }

    // MARK: Live

    private var liveCard: some View {
        card(
            badge: Mode.live.badge,
            badgeColor: Theme.Color.warm,
            title: Mode.live.title,
            body: "The microphone listens to the conversation in the room and the configured backend writes the answers. Questions are detected as they are asked; answers are written only when you tap Generate.",
            footnote: readiness.summary,
            actionTitle: readiness.isListenOnly ? "Start live (listening only)" : "Start live",
            isEnabled: readiness.canListen && !readiness.isChecking,
            action: { startedMode = .live }
        )
    }

    /// The previous copilot screen — the one the OpenRouter/OpenAI pipeline work runs through. It is
    /// superseded by `InterviewScreen` for the interface, but it is still the only path that talks to
    /// a provider, so it stays reachable and honest about what it needs.
    private var pipelinePrototypeNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pipeline prototype — previous screen")
                .font(Typography.body(13, weight: .semibold))
                .foregroundStyle(Theme.Color.ink)
            Text("The earlier copilot screen, kept for measuring the detection and answer pipeline. It looks nothing like the v2.5 design.")
                .font(Typography.body(12))
                .foregroundStyle(Theme.Color.secondary)
            Text(liveFootnote)
                .font(Typography.body(12))
                .foregroundStyle(liveBlockers.isEmpty ? Theme.Color.secondary : Theme.Color.error)
            HStack(spacing: 10) {
                Button("Open with the script") { startedPipelineMode = .demo }
                    .font(Typography.body(12, weight: .medium))
                Button("Open live") { startedPipelineMode = .live }
                    .font(Typography.body(12, weight: .medium))
                    .disabled(!liveBlockers.isEmpty)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Color.hairline, lineWidth: 0.5))
    }

    /// Everything that would stop Live from working, said plainly. Live is never quietly downgraded
    /// to canned answers — if this list is non-empty, the button stays disabled.
    private var liveBlockers: [String] {
        var blockers: [String] = []
        switch providerConfiguration.availability {
        case .unavailable(let reason):
            blockers.append(reason)
        case .developmentFake:
            blockers.append("The development fake provider is switched on — turn it off in Debug: Copilot for a live run")
        case .backend:
            if let backendConfiguration, !backendConfiguration.provider_configured {
                blockers.append("The backend is reachable but has no provider credentials")
            } else if backendConfiguration == nil, !isCheckingBackend {
                blockers.append("The backend did not answer — check it is running and reachable from this device")
            }
        }
        if microphonePermission == .denied {
            blockers.append("Microphone access is denied — enable it in Settings")
        }
        return blockers
    }

    private var liveFootnote: String {
        if let blocker = liveBlockers.first { return blocker }
        let route = backendConfiguration?.summary ?? "backend configured"
        return "Ready · \(route)"
    }

    /// Demo replays a scripted interview; Live opens the microphone. The scripted timestamps are
    /// untouched — only the waiting between them is shortened — so turn gaps stay realistic and
    /// detection behaves as it would live.
    private func makeTranscriptionService(for mode: Mode) -> Transcribing {
        switch mode {
        case .demo:
            return FakeTranscriptionService(
                results: SyntheticInterview.forLanguage(language).scriptedResults(),
                playbackRate: 6
            )
        case .live:
            return TranscriptionService(audioCapture: AudioCaptureService())
        }
    }

    /// Builds the live session from the components that already exist: one audio input, the
    /// configured provider, the sample project, and the coordinator in **manual** generation mode.
    private func makeLiveFeed() -> LiveInterviewFeed {
        let coordinator = CopilotSessionCoordinator(
            project: project,
            provider: providerConfiguration.makeProvider(),
            audio: InterviewAudioInput(makeService: { TranscriptionService(audioCapture: AudioCaptureService()) }),
            generationMode: .manual
        )
        return LiveInterviewFeed(coordinator: coordinator)
    }

    private func refreshReadiness() async {
        readiness.isChecking = true
        _ = await LiveReadiness.requestPermissions()
        readiness = await LiveReadiness.check(configuration: providerConfiguration, language: language)
        microphonePermission = AVAudioApplication.shared.recordPermission
    }

    private func refreshBackend() async {
        guard case .backend = providerConfiguration.availability else {
            backendConfiguration = nil
            return
        }
        isCheckingBackend = true
        backendConfiguration = await providerConfiguration.makeProvider().configuration()
        isCheckingBackend = false
    }

    // MARK: Sample project

    private var sampleProjectNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sample project — not your documents")
                .font(Typography.body(13, weight: .semibold))
                .foregroundStyle(Theme.Color.ink)
            Text("\(project.projectName) · \(project.allPassages.count) fictional passages. Document import is not built yet, so both modes answer from this sample.")
                .font(Typography.body(12))
                .foregroundStyle(Theme.Color.secondary)
            NavigationLink("Provider diagnostics") { CopilotDebugScreen() }
                .font(Typography.body(12, weight: .medium))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Color.hairline, lineWidth: 0.5))
    }

    // MARK: Shared card

    private func card(
        badge: String,
        badgeColor: Color,
        title: String,
        body: String,
        footnote: String,
        actionTitle: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(badge)
                    .font(Typography.mono(10, weight: .medium))
                    .foregroundStyle(Theme.Color.onDark)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(badgeColor, in: Capsule())
                Text(title)
                    .font(Typography.body(17, weight: .semibold))
                    .foregroundStyle(Theme.Color.ink)
            }
            Text(body)
                .font(Typography.body(13))
                .foregroundStyle(Theme.Color.secondary)
            Text(footnote)
                .font(Typography.body(12))
                .foregroundStyle(isEnabled ? Theme.Color.secondary : Theme.Color.error)
            Button(actionTitle, action: action)
                .buttonStyle(.prompterPrimary)
                .disabled(!isEnabled)
                .accessibilityLabel("\(actionTitle), \(badge) mode")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.Color.hairline, lineWidth: 0.5))
    }
}
#endif
