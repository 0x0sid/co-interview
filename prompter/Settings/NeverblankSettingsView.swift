import SwiftUI
import SwiftData

/// Neverblank's settings, one sheet from the home screen's gear or an interview's gear. Presenting it
/// never interrupts a running interview; every preference is stored and applies app-wide.
struct NeverblankSettingsView: View {
    /// Present when Settings is opened from a running interview: the language it is running in. The
    /// Interview Language row always sets the one persisted preference, which the **next** interview
    /// snapshots when it starts; a running interview keeps its own language.
    struct InterviewLanguageControl {
        let current: InterviewLanguage
    }

    var interview: InterviewLanguageControl?
    /// True when this build's Live uses installation access (the free answers and Pro apply).
    let previewApplies: Bool
    /// Opens scrolled to Interview Language — from Start, when the selected language's model is missing.
    var focusesInterviewLanguage = false

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(EntitlementService.self) private var entitlements: EntitlementService?
    @Environment(AccessController.self) private var access: AccessController?
    @Query private var settingsQuery: [AppSettings]
    @State private var isChoosingLanguage = false
    @State private var plansPaywall: AccessController.PaywallRequest?
    /// The app-wide speech-model status, so a download outlives this sheet.
    private let speechModel = SpeechModelStatus.shared
    /// The leave warning is shown at most once per visit: warned, never trapped.
    @State private var warnedAboutModel = false
    @State private var leaveWarning: SettingsLeaveGuard.Decision?

    private var settings: AppSettings { settingsQuery.first ?? AppSettings.fetchOrCreate(in: modelContext) }
    private var appearance: AppearancePreference { settingsQuery.first?.appearance ?? .system }
    private var preference: InterviewLanguagePreference { .from(stored: settingsQuery.first?.interviewLanguageRaw) }
    /// What the next interview will use.
    private var selectedLanguage: InterviewLanguage { preference.resolved() }
    private var textScale: Double { min(1.6, max(0.8, settingsQuery.first?.fontScale ?? 1)) }

    private var leaveDecision: SettingsLeaveGuard.Decision {
        SettingsLeaveGuard.decision(for: speechModel.state, alreadyWarned: warnedAboutModel)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    // 1. Account: the most important setup state first.
                    if let entitlements {
                        Section {
                            SubscriptionSettingsView(entitlements: entitlements, access: access, previewApplies: previewApplies,
                                                     onViewPlans: { plansPaywall = .init(trigger: .settings) })
                                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                                .listRowBackground(Color.clear)
                        } header: {
                            Text("Account")
                        }
                    }

                    // 2. Interview language and its speech model.
                    Section {
                        Button { isChoosingLanguage = true } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Interview Language").foregroundStyle(Theme.Color.ink)
                                    Text(preference.label())
                                        .font(Typography.body(14))
                                        .foregroundStyle(Theme.Color.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                if speechModel.needsAction {
                                    Text("Action required")
                                        .font(Typography.body(12, weight: .semibold))
                                        .foregroundStyle(Theme.Color.warm)
                                        .accessibilityIdentifier("language-action-required")
                                }
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Color.secondary)
                            }
                        }
                        .accessibilityLabel("Interview Language, \(preference.label())\(speechModel.needsAction ? ", action required" : "")")
                        .accessibilityIdentifier("interview-language")
                        SpeechModelCard(language: selectedLanguage, status: speechModel)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                        if preference == .system, let note = InterviewLanguagePreference.resolveSystem().fallbackNote {
                            Text(note).font(Typography.body(12)).foregroundStyle(Theme.Color.warm)
                        }
                    } header: {
                        Text("Interview")
                    } footer: {
                        Text(interview.map { "This interview continues in \($0.current.displayName). A change here applies to your next interview." }
                             ?? InterviewLanguagePreference.explanation + " Saved interviews keep the language they used.")
                    }
                    .id(Self.interviewLanguageSection)

                    Section("Appearance") {
                        Picker("Appearance", selection: Binding(get: { appearance }, set: { value in
                            settings.appearanceRaw = value.rawValue
                            try? modelContext.save()
                        })) {
                            ForEach(AppearancePreference.allCases) { Text($0.shortLabel).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("appearance")
                        if appearance.isUltraContrast {
                            Text("Pure black background and white text everywhere, for bright rooms and low vision.")
                                .font(Typography.body(12))
                                .foregroundStyle(Theme.Color.secondary)
                        }
                    }

                    Section("Answers") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Answer text size")
                                Spacer()
                                Text("\(Int((textScale * 100).rounded()))%").foregroundStyle(Theme.Color.secondary)
                            }
                            Slider(value: Binding(get: { textScale }, set: { value in
                                settings.fontScale = (value * 10).rounded() / 10
                                try? modelContext.save()
                            }), in: 0.8...1.6, step: 0.1)
                            .accessibilityIdentifier("answer-text-size")
                            Text("I would lead with the migration I ran last year.")
                                .font(InterviewTheme.Font.answer(InterviewTheme.Metric.answerSize * textScale))
                                .foregroundStyle(Theme.Color.ink)
                        }
                        Text("Answers follow your voice as you read them aloud; words already spoken are muted.")
                            .font(Typography.body(12))
                            .foregroundStyle(Theme.Color.secondary)
                    }

                    Section("Help") {
                        if let support = LegalLinks.support { Link("Support", destination: support) }
                        if let terms = LegalLinks.terms { Link("Terms of Use", destination: terms) }
                        if let privacy = LegalLinks.privacy { Link("Privacy Policy", destination: privacy) }
                        if LegalLinks.support == nil, LegalLinks.terms == nil, LegalLinks.privacy == nil {
                            Text("Support, Terms and Privacy links appear here once their pages are published.")
                                .font(Typography.body(12))
                                .foregroundStyle(Theme.Color.secondary)
                        }
                    }
                }
                .onAppear {
                    guard focusesInterviewLanguage else { return }
                    Task { @MainActor in withAnimation { proxy.scrollTo(Self.interviewLanguageSection, anchor: .top) } }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Color.paper)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { attemptLeave() }.accessibilityIdentifier("settings-done") } }
            // Swiping down would skip the warning; until it has been shown once, leaving goes through Done.
            .interactiveDismissDisabled(leaveDecision != .leave)
            .alert(leaveWarningTitle, isPresented: Binding(get: { leaveWarning != nil }, set: { if !$0 { leaveWarning = nil } })) {
                switch leaveWarning {
                case .offerDownload:
                    Button("Download") {
                        leaveWarning = nil
                        speechModel.startDownload()
                    }
                    .accessibilityIdentifier("leave-download")
                    Button("Cancel", role: .cancel) { leaveWarning = nil }
                case .downloadInProgress:
                    Button("Keep downloading") {
                        leaveWarning = nil
                        dismiss()
                    }
                    Button("Cancel download", role: .destructive) {
                        leaveWarning = nil
                        speechModel.cancelDownload()
                    }
                default:
                    Button("OK", role: .cancel) { leaveWarning = nil }
                }
            } message: {
                Text(leaveWarningMessage)
            }
            .sheet(isPresented: $isChoosingLanguage) {
                InterviewLanguagePicker(selection: preference) { choice in
                    settings.interviewLanguageRaw = choice.rawValue
                    try? modelContext.save()
                }
            }
            .task(id: selectedLanguage.identifier) {
                // A new language deserves its own warning.
                warnedAboutModel = false
                await speechModel.refresh(for: selectedLanguage)
            }
            .sheet(item: $plansPaywall) { request in
                if let entitlements, let access {
                    // Buying from Settings never generates anything.
                    NeverblankPaywallView(trigger: request.trigger, entitlements: entitlements, access: access) { _ in
                        plansPaywall = nil
                    }
                }
            }
        }
    }

    static let interviewLanguageSection = "interview-language-section"

    /// Done: leave, unless the selected language's model is missing or downloading and the user has not
    /// been told yet this visit.
    private func attemptLeave() {
        let decision = leaveDecision
        guard decision != .leave else { return dismiss() }
        warnedAboutModel = true
        leaveWarning = decision
    }

    private var leaveWarningTitle: String {
        let name = selectedLanguage.speechModelName
        return leaveWarning == .downloadInProgress ? "\(name) speech model is still downloading." : "Download \(name) speech model?"
    }

    private var leaveWarningMessage: String {
        let name = selectedLanguage.speechModelName
        return leaveWarning == .downloadInProgress
            ? "Interviews in \(name) can start once it finishes. It keeps downloading if you leave Settings."
            : "\(name) interviews need this on-device speech model. Download it now before starting an interview."
    }
}

/// The selected interview language's speech model, as a card under the Interview Language row:
/// impossible to miss when a download is needed.
private struct SpeechModelCard: View {
    let language: InterviewLanguage
    let status: SpeechModelStatus

    private var name: String { language.speechModelName }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(border, lineWidth: 1))
    }

    private var needsAttention: Bool { status.needsAction || status.isDownloading }
    private var background: Color { needsAttention ? Theme.Color.card : Theme.Color.card.opacity(0.6) }
    private var border: Color {
        switch status.state {
        case .needsDownload, .downloading: Theme.Color.warm.opacity(0.7)
        case .failed, .unsupported: Theme.Color.error.opacity(0.7)
        case .ready: Theme.Color.action.opacity(0.35)
        case .checking: Theme.Color.hairline
        }
    }

    @ViewBuilder
    private var content: some View {
        switch status.state {
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking the \(name) speech model…").foregroundStyle(Theme.Color.secondary)
            }
            .font(Typography.body(14))
        case .ready:
            Label("\(name) speech model installed", systemImage: "checkmark.circle.fill")
                .font(Typography.body(14, weight: .medium))
                .foregroundStyle(Theme.Color.action)
                .accessibilityIdentifier("speech-model-ready")
        case .needsDownload:
            VStack(alignment: .leading, spacing: 10) {
                Label("Speech model required", systemImage: "exclamationmark.circle.fill")
                    .font(Typography.body(16, weight: .semibold))
                    .foregroundStyle(Theme.Color.warm)
                Text("\(name) needs an on-device speech model before interviews can start.")
                    .font(Typography.body(14))
                    .foregroundStyle(Theme.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                downloadButton("Download")
            }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 8) {
                Text("Downloading \(name) speech model…")
                    .font(Typography.body(15, weight: .semibold))
                    .foregroundStyle(Theme.Color.ink)
                ProgressView(value: fraction)
                    .tint(Theme.Color.action)
                    .accessibilityIdentifier("speech-model-progress")
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(Typography.body(12))
                    .foregroundStyle(Theme.Color.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Downloading \(name) speech model, \(Int((fraction * 100).rounded())) percent")
        case .unsupported:
            Label("\(language.displayName) is not supported for live interviews on this iPhone. Choose another language.",
                  systemImage: "xmark.octagon.fill")
                .font(Typography.body(14))
                .foregroundStyle(Theme.Color.error)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("speech-model-unsupported")
        case .failed:
            VStack(alignment: .leading, spacing: 10) {
                Label("Couldn't download the \(name) speech model.", systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.body(15, weight: .semibold))
                    .foregroundStyle(Theme.Color.error)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Check your connection and try again.")
                    .font(Typography.body(13))
                    .foregroundStyle(Theme.Color.secondary)
                downloadButton("Try again", identifier: "speech-model-retry")
            }
        }
    }

    private func downloadButton(_ title: String, identifier: String = "speech-model-download") -> some View {
        Button { status.startDownload() } label: {
            Label(title, systemImage: "arrow.down.circle.fill")
                .font(Typography.body(16, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.Color.action)
        .foregroundStyle(Theme.Color.onDark)
        .disabled(status.isDownloading)
        .accessibilityLabel("\(title == "Download" ? "Download" : "Try downloading") the \(name) speech model")
        .accessibilityIdentifier(identifier)
    }
}

extension InterviewLanguage {
    /// The language as a speech model is named in the interface: "Spanish", "French", "Traditional
    /// Chinese" — not the regional display name.
    var speechModelName: String {
        let locale = Locale(identifier: identifier)
        if languageCode == "zh" {
            let script = locale.language.script?.identifier
                ?? (["TW", "HK", "MO"].contains(locale.region?.identifier ?? "") ? "Hant" : "Hans")
            return script == "Hant" ? "Traditional Chinese" : "Simplified Chinese"
        }
        let name = Locale.current.localizedString(forLanguageCode: languageCode) ?? displayName
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
