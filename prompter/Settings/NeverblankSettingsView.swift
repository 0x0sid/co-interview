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
    /// The text-size slider's own state: the drag updates this and the preview only; the stored
    /// preference is written once, on release (`AnswerTextSizeEditor`).
    @State private var textSize = AnswerTextSizeEditor(persisted: 1)
    @Environment(\.layoutMetrics) private var metrics

    private var settings: AppSettings { settingsQuery.first ?? AppSettings.fetchOrCreate(in: modelContext) }
    private var appearance: AppearancePreference { settingsQuery.first?.appearance ?? .system }
    private var preference: InterviewLanguagePreference { .from(stored: settingsQuery.first?.interviewLanguageRaw) }
    /// What the next interview will use.
    private var selectedLanguage: InterviewLanguage { preference.resolved() }

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

                    // 2. Interview language and its speech model: one group, the status as its second row.
                    Section {
                        Button { isChoosingLanguage = true } label: {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) {
                                    Text("Interview Language")
                                        .font(Typography.body(metrics.bodySize + 1))
                                        .foregroundStyle(Theme.Color.ink)
                                        .fixedSize()
                                    Spacer(minLength: 8)
                                    Text(preference.label())
                                        .font(Typography.body(metrics.bodySize + 1))
                                        .foregroundStyle(Theme.Color.secondary)
                                        .lineLimit(1)
                                    chevron
                                }
                                // A long language name on a small phone: under the title instead.
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("Interview Language")
                                            .font(Typography.body(metrics.bodySize + 1))
                                            .foregroundStyle(Theme.Color.ink)
                                        Text(preference.label())
                                            .font(Typography.body(metrics.bodySize))
                                            .foregroundStyle(Theme.Color.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 6)
                                    chevron
                                }
                            }
                            .frame(minHeight: 40)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Interview Language, \(preference.label())\(speechModel.needsAction ? ", action required" : "")")
                        .accessibilityIdentifier("interview-language")
                        SpeechModelStatusRow(language: selectedLanguage, status: speechModel)
                        if preference == .system, let note = InterviewLanguagePreference.resolveSystem().fallbackNote {
                            Text(note).font(Typography.body(metrics.footnoteSize)).foregroundStyle(Theme.Color.warm)
                        }
                    } header: {
                        sectionHeader("Interview")
                    } footer: {
                        // Only when it matters: a running interview keeps its language.
                        if interview != nil {
                            Text("Changes apply to your next interview.")
                                .font(Typography.body(metrics.footnoteSize - 1))
                        }
                    }
                    .id(Self.interviewLanguageSection)

                    Section {
                        Picker("Appearance", selection: Binding(get: { appearance }, set: { value in
                            // Applied before the save, so the open sheet changes on this tap.
                            AppearanceController.apply(value)
                            settings.appearanceRaw = value.rawValue
                            try? modelContext.save()
                        })) {
                            ForEach(AppearancePreference.allCases) { Text($0.shortLabel).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityIdentifier("appearance")
                        // The segmented control is its own container: no row card around it.
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    } header: {
                        sectionHeader("Appearance")
                    } footer: {
                        if appearance.isUltraContrast {
                            Text("Pure black and white, for bright rooms and low vision.")
                                .font(Typography.body(metrics.footnoteSize))
                        }
                    }

                    Section {
                        answerTextSize
                    } header: {
                        sectionHeader("Answers")
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
                    textSize.syncPersisted(settingsQuery.first?.fontScale ?? 1)
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

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.Color.secondary.opacity(0.7))
    }

    /// Answer text size: the percentage, a slider, a one-line preview. The drag moves only this
    /// view's draft (`textSize`) and its preview — nothing else in the app re-renders until release.
    private var answerTextSize: some View {
        VStack(alignment: .leading, spacing: metrics.isCompact ? 4 : 6) {
            HStack {
                Text("Answer text size").font(Typography.body(metrics.bodySize + 1))
                Spacer()
                Text("\(textSize.percent)%")
                    .font(Typography.body(metrics.bodySize).monospacedDigit())
                    .foregroundStyle(Theme.Color.secondary)
            }
            Slider(value: Binding(get: { textSize.displayed }, set: { value in
                if let commit = textSize.update(value) { persistTextSize(commit) }
            }), in: AnswerTextSizeEditor.range, step: AnswerTextSizeEditor.step) { editing in
                if let commit = textSize.setEditing(editing) { persistTextSize(commit) }
            }
            .tint(Theme.Color.action)
            .accessibilityLabel("Answer text size")
            .accessibilityValue("\(textSize.percent) percent")
            .accessibilityIdentifier("answer-text-size")
            AnswerTextSizePreview(scale: textSize.displayed)
        }
        .padding(.vertical, 2)
    }

    /// Once per change, never per drag tick.
    private func persistTextSize(_ value: Double) {
        guard settings.fontScale != value else { return }
        settings.fontScale = value
        try? modelContext.save()
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

/// A plain sample of answer text at the chosen size — no reader, no alignment, no parsing: only the
/// answer face, its size and line spacing. Cheap enough to redraw on every drag tick.
private struct AnswerTextSizePreview: View {
    let scale: Double

    var body: some View {
        Text("I'd lead with the migration.")
            .font(InterviewTheme.Font.answer(InterviewTheme.Metric.answerSize * scale))
            .lineSpacing(InterviewTheme.Metric.answerLineSpacing * scale)
            .foregroundStyle(Theme.Color.ink)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
            .accessibilityLabel("Preview of answer text at \(Int((scale * 100).rounded())) percent")
            .accessibilityIdentifier("answer-text-preview")
    }
}

/// The selected interview language's speech model, as the language group's second row: one quiet
/// line when installed, a short line and an inline action otherwise. No card of its own.
private struct SpeechModelStatusRow: View {
    let language: InterviewLanguage
    let status: SpeechModelStatus
    @Environment(\.layoutMetrics) private var metrics

    private var name: String { language.speechModelName }

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    }

    private func line(_ title: String, icon: String, tint: Color, weight: Typography.Weight = .regular) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: metrics.bodySize - 1, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(Typography.body(metrics.bodySize, weight: weight))
                .foregroundStyle(weight == .regular ? Theme.Color.secondary : Theme.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        switch status.state {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking speech model…")
                    .font(Typography.body(metrics.bodySize))
                    .foregroundStyle(Theme.Color.secondary)
            }
        case .ready:
            line("Speech model installed", icon: "checkmark.circle.fill", tint: Theme.Color.action)
                .accessibilityLabel("\(name) speech model installed")
                .accessibilityIdentifier("speech-model-ready")
        case .needsDownload:
            HStack(spacing: 8) {
                line("Speech model required", icon: "exclamationmark.circle.fill", tint: Theme.Color.warm, weight: .medium)
                Spacer(minLength: 6)
                actionButton("Download")
            }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Downloading speech model…")
                        .font(Typography.body(metrics.bodySize))
                        .foregroundStyle(Theme.Color.secondary)
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
            line("Not supported on this iPhone. Choose another language.", icon: "xmark.octagon.fill", tint: Theme.Color.error, weight: .medium)
                .accessibilityIdentifier("speech-model-unsupported")
        case .failed:
            HStack(spacing: 8) {
                line("Download failed", icon: "exclamationmark.triangle.fill", tint: Theme.Color.error, weight: .medium)
                Spacer(minLength: 6)
                actionButton("Retry", identifier: "speech-model-retry")
            }
        }
    }

    private func actionButton(_ title: String, identifier: String = "speech-model-download") -> some View {
        Button(title) { status.startDownload() }
            .font(Typography.body(metrics.bodySize, weight: .semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(Theme.Color.action)
            .fixedSize()
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
