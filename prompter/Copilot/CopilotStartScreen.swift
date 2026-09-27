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
    @State private var isShowingSettings = false
    /// Settings opened from the Start guard, scrolled to Interview Language.
    @State private var settingsFocusesLanguage = false
    @State private var transcriptFor: InterviewSessionRecord?
    @State private var reviewFor: InterviewSessionRecord?
    /// The live interview's feed, made **once** when the interview opens. Built inside the cover it
    /// was rebuilt — with a new coordinator — every time this screen re-rendered, including on every
    /// purchase and entitlement change.
    @State private var liveFeed: LiveInterviewFeed?

    /// The previous pipeline screen, kept reachable so the provider work it exercises is not stranded.
    @State private var startedPipelineMode: Mode?
    @State private var microphonePermission = AVAudioApplication.shared.recordPermission
    @State private var backendConfiguration: CopilotBackendConfiguration?
    @State private var isCheckingBackend = false
    /// What Live can actually do right now — checked, not assumed.
    @State private var readiness = LiveReadiness(isChecking: true)
    @Environment(\.layoutMetrics) private var metrics
    /// Which subscription state's Settings badge has been seen (`SettingsBadge`).
    @AppStorage(SettingsBadge.storageKey) private var settingsBadgeSeen = ""

    private var providerConfiguration: ProviderConfiguration { ProviderConfiguration.resolve() }

    /// The stored preference — System language unless the user picked one.
    private var languagePreference: InterviewLanguagePreference {
        InterviewLanguagePreference.from(stored: settingsQuery.first?.interviewLanguageRaw)
    }
    /// What a session started now would use.
    private var language: InterviewLanguage { languagePreference.resolved() }
    private var project: SyntheticProject {
        language.isFrench ? SyntheticProjectFixture.hospitalReview : SyntheticProjectFixture.transportProgramme
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                header
                // Free or trial status stays here as a compact entry; an active subscription is shown
                // in Settings, not on the home screen.
                AccessStatusBadge(entitlements: entitlements, access: access, showsActivePro: false,
                                  onOpenPlans: { settingsPaywall = .init(trigger: .settings) })
                startInterview
                permissionHelp
                recentInterviews
                #if DEBUG
                if Self.showsDeveloperTools { developerSection }
                // Build identity for development only: small, quiet, centred. Release shows nothing.
                Text(BuildInfo.footer)
                    .font(Typography.mono(9))
                    .foregroundStyle(Theme.Color.secondary.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.top, metrics.sectionSpacing)
                #endif
            }
            .padding(.horizontal, metrics.screenPadding)
            .padding(.vertical, metrics.isCompact ? 8 : 12)
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
            Button("Delete", role: .destructive) {
                if let deleting {
                    InterviewReviewStore.standard.delete(deleting.id)
                    // Removes this session and the files only it owned; files other sessions use stay.
                    InterviewSessionStore.delete(deleting, in: modelContext)
                }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("This removes its saved transcript, answers and interview attachments from this iPhone.")
        }
        .sheet(item: $transcriptFor) { session in TranscriptViewer(session: session) }
        .sheet(item: $reviewFor) { session in InterviewReviewSheet(session: session) }
        .navigationTitle(navigationTitle)
        .toolbar(.hidden, for: .navigationBar)
        // The interview language and its speech model are chosen in Settings; what Start can do is
        // re-checked when it closes.
        .sheet(isPresented: $isShowingSettings, onDismiss: {
            settingsFocusesLanguage = false
            Task { await refreshReadiness() }
        }) {
            NeverblankSettingsView(previewApplies: providerConfiguration.usesInstallationAuth,
                                   focusesInterviewLanguage: settingsFocusesLanguage)
        }
        // The v2.5 interview screen. Demo plays a scripted interview through it; Live opens the
        // state that says what it would need, rather than quietly showing the script.
        .fullScreenCover(item: $launch, onDismiss: { liveFeed = nil }) { launch in
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
                            feed: liveFeed ?? makeLiveFeed(project: launch.fileContext),
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
                    open(.newLive(context: modelContext, preference: languagePreference))
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

    /// The subscription state the Settings badge is about.
    private var badgeState: SettingsBadge.State {
        SettingsBadge.state(isPro: access.isPro, needsVerification: access.needsVerification,
                            usesServerAccess: access.usesServerAccess, expiredAt: entitlements.expiredAt)
    }

    /// Just the Settings gear: no mark, name or tagline above the controls (owner decision, 2026-09-28).
    private var header: some View {
        HStack {
            Spacer()
            Button { settingsFocusesLanguage = false; isShowingSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Theme.Color.ink)
                    .frame(width: 44, height: 44)
                    .background(Theme.Color.card, in: Circle())
                    .overlay(alignment: .topTrailing) {
                        if SettingsBadge.shows(for: badgeState, seen: settingsBadgeSeen) {
                            Text("1")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Color.red, in: Circle())
                                .offset(x: 3, y: -3)
                                .accessibilityIdentifier("settings-badge")
                        }
                    }
            }
            .accessibilityLabel(SettingsBadge.shows(for: badgeState, seen: settingsBadgeSeen) ? "Settings, 1 new item" : "Settings")
            .accessibilityIdentifier("home-settings")
        }
    }

    #if DEBUG
    /// Development tools stay out of normal navigation in every build, including Debug builds on a
    /// phone. A Debug build launched with `-NeverblankDeveloperTools` (UI tests) shows them.
    static var showsDeveloperTools: Bool { ProcessInfo.processInfo.arguments.contains("-NeverblankDeveloperTools") }
    #endif

    // MARK: History

    /// The last few saved interviews, and an interrupted one called out first.
    @ViewBuilder
    private var recentInterviews: some View {
        if !savedSessions.isEmpty {
            VStack(alignment: .leading, spacing: metrics.listCardSpacing + 2) {
                if let interrupted = savedSessions.first(where: { $0.state == .interrupted }) {
                    Button {
                        open(.reopen(interrupted, context: modelContext))
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("An interview was interrupted")
                                .font(Typography.body(13, weight: .semibold))
                                .foregroundStyle(Theme.Color.ink)
                            Text("“\(interrupted.title)” — open it to see what was saved. The microphone starts only when you resume.")
                                .font(Typography.body(12))
                                .foregroundStyle(Theme.Color.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(metrics.cardPadding)
                        .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: metrics.cardCornerRadius))
                        .overlay(RoundedRectangle(cornerRadius: metrics.cardCornerRadius).stroke(Theme.Color.warm, lineWidth: 1))
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
                // Cards read summary fields only (title, dates, counts); nothing here loads a
                // transcript, an answer or a file until one is opened.
                VStack(spacing: metrics.listCardSpacing) {
                    ForEach(isShowingAllInterviews ? Array(savedSessions) : Array(savedSessions.prefix(3))) { session in
                        InterviewHistoryCard(session: session,
                                             onOpen: { open(.reopen(session, context: modelContext)) },
                                             onDelete: { deleting = session }) {
                            historyMenu(for: session)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The saved interview's actions. Transcript viewing and export are local; the review is Pro.
    private func historyMenu(for session: InterviewSessionRecord) -> some View {
        Menu {
            Button("Rename", systemImage: "pencil") {
                newTitle = session.title
                renaming = session
            }
            Button("View transcript", systemImage: "text.alignleft") { transcriptFor = session }
            if let url = TranscriptExport.file(for: session) {
                ShareLink(item: url) { Label("Export transcript", systemImage: "square.and.arrow.up") }
            }
            Button(InterviewReviewStore.standard.load(session.id) == nil ? "Score interview" : "View score",
                   systemImage: "gauge.with.dots.needle.50percent") { reviewFor = session }
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = session }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 19))
                .foregroundStyle(Theme.Color.secondary)
                .frame(width: 36, height: 36)
        }
        .accessibilityLabel("More actions for \(session.title)")
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

    /// The one primary action on the screen, with what Live can do right now under it.
    private var startInterview: some View {
        let title = readiness.isListenOnly ? "Start interview (listening only)" : "Start interview"
        let enabled = readiness.canListen && !readiness.isChecking
        return VStack(alignment: .leading, spacing: metrics.isCompact ? 5 : 7) {
            Button {
                if AIConsent.isGiven() {
                    open(.newLive(context: modelContext, preference: languagePreference))
                } else {
                    isAskingConsent = true
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                    Text(title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .font(Typography.body(metrics.isCompact ? 17 : 18, weight: .semibold))
                .foregroundStyle(Theme.Color.onDark)
                .frame(maxWidth: .infinity, minHeight: metrics.primaryControlHeight)
                .background(Theme.Color.action, in: RoundedRectangle(cornerRadius: metrics.cardCornerRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: metrics.cardCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            // The shared button style does not dim; a button that cannot start must look it.
            .opacity(enabled ? 1 : 0.45)
            .accessibilityLabel(title)
            .accessibilityIdentifier("start-interview")
            // Provider and model names are diagnostics, not customer information.
            Text(readiness.isChecking ? "Checking…" : readiness.canGenerate ? "Ready to start" : readiness.summary)
                .font(Typography.body(metrics.footnoteSize))
                .padding(.leading, 2)
                .foregroundStyle(enabled ? Theme.Color.secondary : Theme.Color.error)
                .accessibilityIdentifier("start-status")
            if readiness.needsSpeechDownload && !readiness.isChecking {
                // Start stays blocked: the selected language's model is prepared in Settings, never
                // replaced by English.
                Button {
                    settingsFocusesLanguage = true
                    isShowingSettings = true
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                        .font(Typography.body(metrics.bodySize + 1, weight: .semibold))
                        .frame(minHeight: 36)
                }
                .buttonStyle(.bordered)
                .tint(Theme.Color.action)
                .accessibilityLabel("Open Settings to download the \(language.speechModelName) speech model")
                .accessibilityIdentifier("speech-model-open-settings")
            }
        }
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
            .padding(metrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: metrics.cardCornerRadius))
        }
    }

    /// Language, subscription, and the help and legal pages.
    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(Typography.body(15, weight: .semibold))
                .foregroundStyle(Theme.Color.ink)
                .accessibilityAddTraits(.isHeader)
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

    /// Opens an interview; a live one gets its feed here, once.
    private func open(_ newLaunch: InterviewLaunch) {
        liveFeed = newLaunch.mode == .live ? makeLiveFeed(project: newLaunch.fileContext) : nil
        launch = newLaunch
    }

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
