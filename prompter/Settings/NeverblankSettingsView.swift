import SwiftUI
import SwiftData

/// Neverblank's settings, one sheet from the home screen's gear or an interview's gear. Presenting it
/// never interrupts a running interview; every preference is stored and applies app-wide.
struct NeverblankSettingsView: View {
    /// In an interview the language row changes **that interview's** language (history, answers and
    /// files are kept); on the home screen it sets the preference for new interviews.
    struct InterviewLanguageControl {
        let current: InterviewLanguage
        let onChange: (InterviewLanguage) -> Void
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

    private var settings: AppSettings { settingsQuery.first ?? AppSettings.fetchOrCreate(in: modelContext) }
    private var appearance: AppearancePreference { settingsQuery.first?.appearance ?? .system }
    private var preference: InterviewLanguagePreference { .from(stored: settingsQuery.first?.interviewLanguageRaw) }
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
                            Text("Interview language").foregroundStyle(Theme.Color.ink)
                            Spacer()
                            Text(interview?.current.displayName ?? preference.label())
                                .foregroundStyle(Theme.Color.secondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Color.secondary)
                        }
                    }
                    .accessibilityIdentifier("interview-language")
                } header: {
                    Text("Interview")
                } footer: {
                    Text(interview == nil
                         ? InterviewLanguagePreference.explanation + " Saved interviews keep the language they used."
                         : "Changing it restarts recognition for this interview; the transcript, answers and files so far are kept and are not translated.")
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
                if let interview {
                    InterviewLanguagePicker(selection: .language(interview.current), allowsSystem: false) { choice in
                        if case .language(let chosen) = choice, chosen != interview.current { interview.onChange(chosen) }
                    }
                } else {
                    InterviewLanguagePicker(selection: preference) { choice in
                        settings.interviewLanguageRaw = choice.rawValue
                        try? modelContext.save()
                    }
                }
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
}
