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
    @Environment(\.layoutMetrics) private var metrics

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
                                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                                .listRowBackground(Color.clear)
                        } header: {
                            sectionHeader("Account")
                        }
                    }

                    // 2. Interview language and its speech model.
                    Section {
                        Button { isChoosingLanguage = true } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Interview Language")
                                        .font(Typography.body(metrics.bodySize + 2))
                                        .foregroundStyle(Theme.Color.ink)
                                    Text(preference.label())
                                        .font(Typography.body(metrics.bodySize))
                                        .foregroundStyle(Theme.Color.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .layoutPriority(1)
                                Spacer(minLength: 6)
                                if speechModel.needsAction {
                                    Text("Action required")
                                        .font(Typography.body(metrics.footnoteSize, weight: .semibold))
                                        .foregroundStyle(Theme.Color.warm)
                                        .fixedSize()
                                        .accessibilityIdentifier("language-action-required")
                                }
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Color.secondary)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Interview Language, \(preference.label())\(speechModel.needsAction ? ", action required" : "")")
                        .accessibilityIdentifier("interview-language")
                        SpeechModelCard(language: selectedLanguage, status: speechModel)
                            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 2, trailing: 0))
                            .listRowBackground(Color.clear)
                        if preference == .system, let note = InterviewLanguagePreference.resolveSystem().fallbackNote {
                            Text(note).font(Typography.body(metrics.footnoteSize)).foregroundStyle(Theme.Color.warm)
                        }
                    } header: {
                        sectionHeader("Interview")
                    } footer: {
                        Text(interview.map { "This interview continues in \($0.current.displayName); a change applies to your next one." }
                             ?? "Speech recognition and answers use this language. The app's own language follows iPhone Settings.")
                            .font(Typography.body(metrics.footnoteSize))
                    }
                    .id(Self.interviewLanguageSection)

                    Section {
                        Picker("Appearance", selection: Binding(get: { appearance }, set: { value in
                            settings.appearanceRaw = value.rawValue
                            try? modelContext.save()
                        })) {
                            ForEach(AppearancePreference.allCases) { Text($0.shortLabel).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("appearance")
                    } header: {
                        sectionHeader("Appearance")
                    } footer: {
                        if appearance.isUltraContrast {
                            Text("Pure black and white, for bright rooms and low vision.")
                                .font(Typography.body(metrics.footnoteSize))
                        }
                    }

                    Section {
                        VStack(alignment: .leading, spacing: metrics.cardSpacing) {
                            HStack {
                                Text("Answer text size").font(Typography.body(metrics.bodySize + 2))
                                Spacer()
                                Text("\(Int((textScale * 100).rounded()))%")
                                    .font(Typography.body(metrics.bodySize + 1))
                                    .foregroundStyle(Theme.Color.secondary)
                            }
                            Slider(value: Binding(get: { textScale }, set: { value in
                                settings.fontScale = (value * 10).rounded() / 10
                                try? modelContext.save()
                            }), in: 0.8...1.6, step: 0.1)
                            .accessibilityIdentifier("answer-text-size")
                            // A short sample at the chosen size: enough to judge the scale, never a page.
                            Text("I'd lead with the migration.")
                                .font(InterviewTheme.Font.answer(InterviewTheme.Metric.answerSize * textScale))
                                .foregroundStyle(Theme.Color.ink)
                                .lineLimit(2)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity, maxHeight: metrics.previewMaxHeight, alignment: .leading)
                                .accessibilityLabel("Preview of answer text at \(Int((textScale * 100).rounded())) percent")
                        }
                        .padding(.vertical, metrics.isCompact ? 2 : 4)
                    } header: {
                        sectionHeader("Answers")
                    } footer: {
                        Text("Words you've already read aloud are dimmed.")
                            .font(Typography.body(metrics.footnoteSize))
                    }

                    Section {
                        if let support = LegalLinks.support { Link("Support", destination: support) }
                        if let terms = LegalLinks.terms { Link("Terms of Use", destination: terms) }
                        if let privacy = LegalLinks.privacy { Link("Privacy Policy", destination: privacy) }
                        if LegalLinks.support == nil, LegalLinks.terms == nil, LegalLinks.privacy == nil {
                            Text("Support and legal pages coming soon.")
                                .font(Typography.body(metrics.footnoteSize + 1))
                                .foregroundStyle(Theme.Color.secondary)
                        }
                    } header: {
                        sectionHeader("Help")
                    }
                }
                .listSectionSpacing(metrics.isCompact ? .compact : .default)
                .environment(\.defaultMinListRowHeight, metrics.isCompact ? 40 : 44)
                .onAppear {
                    guard focusesInterviewLanguage else { return }
                    Task { @MainActor in withAnimation { proxy.scrollTo(Self.interviewLanguageSection, anchor: .top) } }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Color.paper)
            // A compact header of our own: the system bar in a sheet spent a lot of height on a large
            // title area and an oversized Done pill.
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { header }
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

    /// Title centred, a compact Done on the right; 44–52 pt tall instead of the system sheet bar.
    private var header: some View {
        ZStack {
            Text("Settings")
                .font(Typography.body(metrics.bodySize + 3, weight: .semibold))
                .foregroundStyle(Theme.Color.ink)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Spacer()
                Button { attemptLeave() } label: {
                    Text("Done")
                        .font(Typography.body(metrics.bodySize + 1, weight: .semibold))
                        .foregroundStyle(Theme.Color.action)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Theme.Color.card, in: Capsule())
                        .overlay(Capsule().stroke(Theme.Color.hairline, lineWidth: 0.5))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-done")
            }
        }
        .padding(.horizontal, metrics.screenPadding)
        .frame(height: metrics.headerHeight)
        .background(Theme.Color.paper)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Typography.body(metrics.footnoteSize + 1, weight: .semibold))
            .foregroundStyle(Theme.Color.secondary)
            .textCase(nil)
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
/// prominent when something is needed, one quiet line when it is installed.
private struct SpeechModelCard: View {
    let language: InterviewLanguage
    let status: SpeechModelStatus
    @Environment(\.layoutMetrics) private var metrics

    private var name: String { language.speechModelName }

    var body: some View {
        content
            .padding(.horizontal, metrics.cardPadding)
            .padding(.vertical, status.state == .ready || status.state == .checking ? metrics.cardSpacing + 2 : metrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: metrics.cardCornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: metrics.cardCornerRadius, style: .continuous).stroke(border, lineWidth: 1))
    }

    private var border: Color {
        switch status.state {
        case .needsDownload, .downloading: Theme.Color.warm.opacity(0.7)
        case .failed, .unsupported: Theme.Color.error.opacity(0.7)
        case .ready: Theme.Color.action.opacity(0.3)
        case .checking: Theme.Color.hairline
        }
    }

    /// Icon, a title and at most one short line — the same shape in every state.
    private func message(_ title: String, _ detail: String?, icon: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: metrics.bodySize + 1, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.body(metrics.bodySize + 1, weight: .semibold))
                    .foregroundStyle(detail == nil ? tint : Theme.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(Typography.body(metrics.bodySize))
                        .foregroundStyle(Theme.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        switch status.state {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking the \(name) speech model…")
                    .font(Typography.body(metrics.bodySize))
                    .foregroundStyle(Theme.Color.secondary)
            }
        case .ready:
            message("\(name) speech model installed", nil, icon: "checkmark.circle.fill", tint: Theme.Color.action)
                .accessibilityIdentifier("speech-model-ready")
        case .needsDownload:
            VStack(alignment: .leading, spacing: metrics.cardSpacing + 2) {
                message("Speech model required", "\(name) needs an on-device speech model before interviews can start.",
                        icon: "exclamationmark.circle.fill", tint: Theme.Color.warm)
                downloadButton("Download")
            }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: metrics.cardSpacing) {
                HStack {
                    Text("Downloading \(name) speech model…")
                        .font(Typography.body(metrics.bodySize + 1, weight: .semibold))
                        .foregroundStyle(Theme.Color.ink)
                    Spacer(minLength: 6)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(Typography.body(metrics.bodySize).monospacedDigit())
                        .foregroundStyle(Theme.Color.secondary)
                }
                ProgressView(value: fraction)
                    .tint(Theme.Color.action)
                    .accessibilityIdentifier("speech-model-progress")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Downloading \(name) speech model, \(Int((fraction * 100).rounded())) percent")
        case .unsupported:
            message("Not supported on this iPhone", "Choose another interview language.", icon: "xmark.octagon.fill", tint: Theme.Color.error)
                .accessibilityIdentifier("speech-model-unsupported")
        case .failed:
            VStack(alignment: .leading, spacing: metrics.cardSpacing + 2) {
                message("Couldn't download the \(name) speech model.", "Check your connection and try again.",
                        icon: "exclamationmark.triangle.fill", tint: Theme.Color.error)
                downloadButton("Try again", identifier: "speech-model-retry")
            }
        }
    }

    private func downloadButton(_ title: String, identifier: String = "speech-model-download") -> some View {
        Button { status.startDownload() } label: { Label(title, systemImage: "arrow.down.circle.fill") }
        .buttonStyle(CardPrimaryButtonStyle())
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
