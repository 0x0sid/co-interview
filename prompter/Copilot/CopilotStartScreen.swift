import SwiftUI
import SwiftData
import AVFoundation
import Speech

/// Neverblank's home: the interview language, saved interviews and **Live**. A Release build opens
/// here directly (`RootView`); Demo, the pipeline prototype, the sample project and provider
/// diagnostics are development tools and are compiled into Debug builds only.
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

    @Environment(\.modelContext) private var modelContext
    @Environment(AccessController.self) private var access
    @Environment(EntitlementService.self) private var entitlements
    @Query private var settingsQuery: [AppSettings]
    @Query(filter: #Predicate<InterviewSessionRecord> { $0.modeRaw == "live" },
           sort: \InterviewSessionRecord.lastActivityAt, order: .reverse)
    private var savedSessions: [InterviewSessionRecord]
    /// The interview on screen, with its record, files and recorder.
    @State private var launch: InterviewLaunch?
    /// Every saved interview is listed, not only the latest three.
    @State private var isShowingAllInterviews = false
    @State private var renaming: InterviewSessionRecord?
    @State private var newTitle = ""
    @State private var deleting: InterviewSessionRecord?
    /// Consent to AI processing is asked once, before the first Live interview.
    @State private var isAskingConsent = false
    /// The paywall opened from here. Buying here never generates anything: no interview is open.
    @State private var settingsPaywall: AccessController.PaywallRequest?

    /// The previous pipeline screen, kept reachable so the provider work it exercises is not stranded.
    @State private var startedPipelineMode: Mode?
    @State private var microphonePermission = AVAudioApplication.shared.recordPermission
    @State private var backendConfiguration: CopilotBackendConfiguration?
    @State private var isCheckingBackend = false
    /// What Live can actually do right now — checked, not assumed.
    @State private var readiness = LiveReadiness(isChecking: true)

    private var providerConfiguration: ProviderConfiguration { ProviderConfiguration.resolve() }

    /// The stored preference — System language unless the user picked one.
    private var languagePreference: InterviewLanguagePreference {
        InterviewLanguagePreference.from(stored: settingsQuery.first?.interviewLanguageRaw)
    }
    /// What a session started now would use.
    private var language: InterviewLanguage { languagePreference.resolved() }
    private var project: SyntheticProject {
        language == .french ? SyntheticProjectFixture.hospitalReview : SyntheticProjectFixture.transportProgramme
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                intro
                liveCard
                permissionHelp
                recentInterviews
                settingsSection
                #if DEBUG
                developerSection
                #endif
                Text(footer)
                    .font(Typography.mono(11))
                    .foregroundStyle(Theme.Color.secondary)
            }
            .padding(20)
        }
        .background(Theme.Color.paper)
        .alert("Rename interview", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Save") {
                if let renaming { InterviewSessionStore.rename(renaming, to: newTitle, in: modelContext) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete this interview?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete interview and its files", role: .destructive) {
                if let deleting { InterviewSessionStore.delete(deleting, in: modelContext) }
                deleting = nil
            }
        } message: {
            Text("The transcript, answers and attached files are removed from this device. This can't be undone.")
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        // The v2.5 interview screen. Demo plays a scripted interview through it; Live opens the
        // state that says what it would need, rather than quietly showing the script.
        .fullScreenCover(item: $launch) { launch in
            NavigationStack {
                switch launch.mode {
                case .demo:
                    InterviewScreen(mode: .demo, title: "Technical interview", files: launch.files)
                case .live:
                    // A reopened session always opens, whatever the readiness: its content is local.
                    // Resume and Generate then say for themselves whether they can work.
                    if readiness.canListen || launch.restored != nil {
                        InterviewScreen(
                            mode: .live,
                            title: launch.restored == nil ? "Live interview" : launch.session.title,
                            feed: makeLiveFeed(project: launch.fileContext),
                            readiness: readiness,
                            recheckReadiness: {
                                await LiveReadiness.check(configuration: ProviderConfiguration.resolve(), language: launch.language)
                            },
                            files: launch.files,
                            recorder: launch.recorder,
                            restored: launch.restored,
                            enforcesAccess: providerConfiguration.usesInstallationAuth
                        )
                    } else {
                        InterviewLiveUnavailableView(readiness: readiness)
                    }
                }
            }
        }
        #if DEBUG
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
        #endif
        .sheet(isPresented: $isAskingConsent) {
            AIConsentView(
                onAgree: {
                    AIConsent.record()
                    isAskingConsent = false
                    launch = .newLive(context: modelContext, preference: languagePreference)
                },
                onCancel: { isAskingConsent = false }
            )
        }
        .sheet(item: $settingsPaywall) { request in
            NeverblankPaywallView(trigger: request.trigger, entitlements: entitlements, access: access) { _ in
                settingsPaywall = nil
            }
        }
        // Registration finishing (or failing) changes what Live can do.
        .onChange(of: access.connection) { _, _ in
            Task { await refreshReadiness() }
        }
        .task {
            microphonePermission = AVAudioApplication.shared.recordPermission
            #if DEBUG
            await refreshBackend()
            #endif
            await refreshReadiness()
        }
    }

    /// Debug keeps the development title the UI tests navigate by; Release shows the product name.
    private var navigationTitle: String { "Neverblank" }

    private var footer: String {
        #if DEBUG
        BuildInfo.footer
        #else
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
        #endif
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Listen to an interview, suggest answers, read them aloud")
                .font(Typography.display(20))
                .foregroundStyle(Theme.Color.ink)
            Text("Detected questions become cards. Swipe between them; the text follows your voice as you read it aloud.")
                .font(Typography.body(14))
                .foregroundStyle(Theme.Color.secondary)
        }
    }

    /// The interview language: System language by default, showing what it resolves to.
    private var languagePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Interview language").font(Typography.body(12, weight: .medium)).foregroundStyle(Theme.Color.secondary)
            Picker("Interview language", selection: Binding(
                get: { languagePreference },
                set: { newValue in
                    let settings = AppSettings.fetchOrCreate(in: modelContext)
                    settings.interviewLanguageRaw = newValue.rawValue
                    try? modelContext.save()
                    Task { await refreshReadiness() }
                }
            )) {
                ForEach(InterviewLanguagePreference.allCases) { option in
                    Text(option.label()).tag(option)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("interview-language")
            Text(InterviewLanguagePreference.explanation + " Saved interviews keep the language they used.")
                .font(Typography.body(12))
                .foregroundStyle(Theme.Color.secondary)
            if languagePreference == .system, let note = InterviewLanguagePreference.resolveSystem().fallbackNote {
                Text(note)
                    .font(Typography.body(12))
                    .foregroundStyle(Theme.Color.warm)
            }
        }
    }

    // MARK: History

    /// The last few saved interviews, and an interrupted one called out first.
    @ViewBuilder
    private var recentInterviews: some View {
        if !savedSessions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let interrupted = savedSessions.first(where: { $0.state == .interrupted }) {
                    Button {
                        launch = .reopen(interrupted, context: modelContext)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("An interview was interrupted")
                                .font(Typography.body(13, weight: .semibold))
                                .foregroundStyle(Theme.Color.ink)
                            Text("“\(interrupted.title)” — open it to see what was saved. Nothing is sent again unless you choose Retry, and the microphone starts only when you resume.")
                                .font(Typography.body(12))
                                .foregroundStyle(Theme.Color.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Color.warm, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                HStack {
                    Text(isShowingAllInterviews ? "All saved interviews" : "Saved interviews")
                        .font(Typography.body(13, weight: .semibold))
                        .foregroundStyle(Theme.Color.ink)
                    Spacer()
                    if savedSessions.count > 3 || isShowingAllInterviews {
                        Button(isShowingAllInterviews ? "Show recent" : "All saved interviews (\(savedSessions.count))") {
                            isShowingAllInterviews.toggle()
                        }
                        .font(Typography.body(12, weight: .medium))
                    }
                }
                // Rows read summary fields only (title, dates, counts); nothing here loads a
                // transcript, an answer or a file.
                ForEach(isShowingAllInterviews ? Array(savedSessions) : Array(savedSessions.prefix(3))) { session in
                    HStack(alignment: .top, spacing: 8) {
                        Button { launch = .reopen(session, context: modelContext) } label: { SessionRow(session: session) }
                            .buttonStyle(.plain)
                        Menu {
                            Button("Rename", systemImage: "pencil") {
                                newTitle = session.title
                                renaming = session
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = session }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.Color.secondary)
                                .frame(width: 32, height: 32)
                        }
                        .accessibilityLabel("More actions for \(session.title)")
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Color.hairline, lineWidth: 0.5))
        }
    }

    // MARK: Demo

    #if DEBUG
    private var demoCard: some View {
        card(
            badge: Mode.demo.badge,
            badgeColor: Theme.Color.action,
            title: Mode.demo.title,
            body: "A scripted interview plays through the v2.5 interview screen — no microphone, no network. Questions appear as they are detected; answers are written only when you tap Generate. The content is invented development text, clearly marked.",
            footnote: "Works with no setup.",
            actionTitle: "Start demo",
            isEnabled: true,
            action: { launch = .demo() }
        )
    }
    #endif

    // MARK: Live

    private var liveCard: some View {
        card(
            badge: Mode.live.badge,
            badgeColor: Theme.Color.warm,
            title: "Start interview",
            body: "Neverblank listens while your interview runs, spots the questions as they are asked, and writes an answer when you tap Generate.",
            footnote: readiness.summary,
            actionTitle: readiness.isListenOnly ? "Start interview (listening only)" : "Start interview",
            isEnabled: readiness.canListen && !readiness.isChecking,
            action: {
                if AIConsent.isGiven() {
                    launch = .newLive(context: modelContext, preference: languagePreference)
                } else {
                    isAskingConsent = true
                }
            }
        )
    }

    // MARK: Help and settings

    /// When the microphone or speech recognition was refused, the one place to fix it.
    @ViewBuilder
    private var permissionHelp: some View {
        if microphonePermission == .denied || SFSpeechRecognizer.authorizationStatus() == .denied {
            VStack(alignment: .leading, spacing: 6) {
                Text("Neverblank needs the microphone and speech recognition to listen. You can allow them in iPhone Settings.")
                    .font(Typography.body(13))
                    .foregroundStyle(Theme.Color.ink)
                Button("Open iPhone Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(Typography.body(13, weight: .semibold))
                .accessibilityIdentifier("open-settings")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// Language, subscription, and the help and legal pages.
    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(Typography.body(15, weight: .semibold))
                .foregroundStyle(Theme.Color.ink)
                .accessibilityAddTraits(.isHeader)
            languagePicker
            subscriptionCard
            HStack(spacing: 16) {
                if let support = LegalLinks.support { Link("Support", destination: support) }
                if let terms = LegalLinks.terms { Link("Terms of Use", destination: terms) }
                if let privacy = LegalLinks.privacy { Link("Privacy Policy", destination: privacy) }
            }
            .font(Typography.body(12, weight: .medium))
        }
    }

    #if DEBUG
    /// Development tools. Compiled into Debug builds only; a Release build has none of this.
    private var developerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Developer · Debug builds only")
                .font(Typography.body(13, weight: .semibold))
                .foregroundStyle(Theme.Color.secondary)
            demoCard
            pipelinePrototypeNote
            sampleProjectNote
            NavigationLink("Prompter teleprompter (development)") { ScriptListScreen() }
                .font(Typography.body(12, weight: .medium))
            NavigationLink("Debug menu") { DebugMenuScreen() }
                .font(Typography.body(12, weight: .medium))
        }
    }
    #endif

    // MARK: Subscription

    /// Settings › Subscription, always on the start screen. Nothing bought here generates an answer.
    private var subscriptionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subscription")
                .font(Typography.body(13, weight: .semibold))
                .foregroundStyle(Theme.Color.secondary)
            SubscriptionSettingsView(
                entitlements: entitlements,
                access: access,
                previewApplies: providerConfiguration.usesInstallationAuth,
                onViewPlans: { settingsPaywall = .init(trigger: .settings) }
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Color.hairline, lineWidth: 0.5))
    }

    #if DEBUG
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

    #endif

    /// Builds the live session from the components that already exist: one audio input, the
    /// configured provider, the sample project, and the coordinator in **manual** generation mode.
    private func makeLiveFeed(project: SessionFileContext) -> LiveInterviewFeed {
        let coordinator = CopilotSessionCoordinator(
            // **Never the sample project.** A live session carries no fabricated instructions and no
            // fictional passages — only the files the user attached to *this* session, as excerpts.
            project: project,
            provider: providerConfiguration.makeProvider(),
            audio: InterviewAudioInput(makeService: {
                if let script = InterviewTestingFlags.scriptedLiveSpeech {
                    return FakeTranscriptionService(results: script)
                }
                return TranscriptionService(audioCapture: AudioCaptureService())
            }),
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

    #if DEBUG
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
            Text("Sample project — Demo only")
                .font(Typography.body(13, weight: .semibold))
                .foregroundStyle(Theme.Color.ink)
            Text("\(project.projectName) · \(project.allPassages.count) fictional passages, used by Demo and the pipeline prototype. Live carries none of it: a live session uses only the files you attach to it, and answers general questions from the model's knowledge.")
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

    #endif

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
