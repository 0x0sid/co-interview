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

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(EntitlementService.self) private var entitlements: EntitlementService?
    @Environment(AccessController.self) private var access: AccessController?
    @Query private var settingsQuery: [AppSettings]
    @State private var isChoosingLanguage = false
    @State private var plansPaywall: AccessController.PaywallRequest?
    /// The selected language's speech model: ready, download, unsupported or retry.
    @State private var speechModel = SpeechModelStatus()

    private var settings: AppSettings { settingsQuery.first ?? AppSettings.fetchOrCreate(in: modelContext) }
    private var appearance: AppearancePreference { settingsQuery.first?.appearance ?? .system }
    private var preference: InterviewLanguagePreference { .from(stored: settingsQuery.first?.interviewLanguageRaw) }
    /// What the next interview will use.
    private var selectedLanguage: InterviewLanguage { preference.resolved() }
    private var textScale: Double { min(1.6, max(0.8, settingsQuery.first?.fontScale ?? 1)) }

    var body: some View {
        NavigationStack {
            Form {
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

                Section {
                    Button { isChoosingLanguage = true } label: {
                        HStack {
                            Text("Interview Language").foregroundStyle(Theme.Color.ink)
                            Spacer()
                            Text(preference.label())
                                .foregroundStyle(Theme.Color.secondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Color.secondary)
                        }
                    }
                    .accessibilityIdentifier("interview-language")
                    SpeechModelRow(language: selectedLanguage, status: speechModel)
                    if preference == .system, let note = InterviewLanguagePreference.resolveSystem().fallbackNote {
                        Text(note).font(Typography.body(12)).foregroundStyle(Theme.Color.warm)
                    }
                } header: {
                    Text("Interview")
                } footer: {
                    Text(interview.map { "This interview continues in \($0.current.displayName). A change here applies to your next interview." }
                         ?? InterviewLanguagePreference.explanation + " Saved interviews keep the language they used.")
                }

                if let entitlements {
                    Section("Subscription") {
                        SubscriptionSettingsView(entitlements: entitlements, access: access, previewApplies: previewApplies,
                                                 onViewPlans: { plansPaywall = .init(trigger: .settings) })
                        Button("Restore Purchases") { plansPaywall = .init(trigger: .settings) }
                            .accessibilityIdentifier("settings-restore")
                    }
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
            .scrollContentBackground(.hidden)
            .background(Theme.Color.paper)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $isChoosingLanguage) {
                InterviewLanguagePicker(selection: preference) { choice in
                    settings.interviewLanguageRaw = choice.rawValue
                    try? modelContext.save()
                }
            }
            .task(id: selectedLanguage.identifier) { await speechModel.refresh(for: selectedLanguage) }
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
}

/// The selected interview language's speech model under the Interview Language row.
private struct SpeechModelRow: View {
    let language: InterviewLanguage
    let status: SpeechModelStatus

    var body: some View {
        switch status.state {
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking the speech model…").foregroundStyle(Theme.Color.secondary)
            }
            .font(Typography.body(13))
        case .ready:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .font(Typography.body(13))
                .foregroundStyle(Theme.Color.secondary)
                .accessibilityIdentifier("speech-model-ready")
        case .needsDownload:
            VStack(alignment: .leading, spacing: 6) {
                Text("\(language.displayName) speech model required")
                    .font(Typography.body(14, weight: .semibold))
                    .foregroundStyle(Theme.Color.ink)
                Text("Download once to use \(language.displayName) interviews on this iPhone.")
                    .font(Typography.body(12))
                    .foregroundStyle(Theme.Color.secondary)
                Button("Download") { Task { await status.download() } }
                    .font(Typography.body(14, weight: .semibold))
                    .accessibilityIdentifier("speech-model-download")
            }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction)
                    .accessibilityIdentifier("speech-model-progress")
                Text("Downloading the \(language.displayName) speech model… \(Int((fraction * 100).rounded()))%")
                    .font(Typography.body(12))
                    .foregroundStyle(Theme.Color.secondary)
            }
        case .unsupported:
            Text("\(language.displayName) is not supported for live interviews on this iPhone. Choose another language.")
                .font(Typography.body(13))
                .foregroundStyle(Theme.Color.error)
                .accessibilityIdentifier("speech-model-unsupported")
        case .failed:
            VStack(alignment: .leading, spacing: 6) {
                Text("The \(language.displayName) speech model did not finish downloading. Check your connection and try again.")
                    .font(Typography.body(13))
                    .foregroundStyle(Theme.Color.error)
                Button("Try again") { Task { await status.download() } }
                    .font(Typography.body(14, weight: .semibold))
                    .accessibilityIdentifier("speech-model-retry")
            }
        }
    }
}

