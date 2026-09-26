import SwiftUI

/// Choosing the interview language: a searchable sheet of every language the on-device transcriber
/// supports (`SpeechLocales`), each in its own name and in the interface language, regional variants
/// listed separately, the current choice checked.
///
/// A language the transcriber does not support is never listed and never substituted. One whose
/// on-device model is not installed yet says so — it downloads when an interview first uses it.
/// This is the **interview** language only; the app's interface follows the iPhone's language.
struct InterviewLanguagePicker: View {
    let selection: InterviewLanguagePreference
    /// Offered on the home screen; a running interview needs a concrete language.
    var allowsSystem = true
    let onSelect: (InterviewLanguagePreference) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var identifiers: [String] = SpeechLocales.supported

    private var system: InterviewLanguagePreference.Resolution { InterviewLanguagePreference.resolveSystem() }

    private var rows: [InterviewLanguage] {
        let languages = identifiers.map(InterviewLanguagePreference.language(for:))
        let sorted = languages.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return sorted }
        return sorted.filter {
            $0.displayName.localizedCaseInsensitiveContains(needle)
                || $0.localizedName().localizedCaseInsensitiveContains(needle)
                || $0.identifier.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if allowsSystem, query.isEmpty {
                    Section {
                        row(title: "System language",
                            subtitle: system.language.displayName,
                            note: system.fallbackNote,
                            selected: selection == .system) { choose(.system) }
                            .accessibilityIdentifier("language-system")
                    } footer: {
                        Text(InterviewLanguagePreference.explanation)
                    }
                }
                Section {
                    ForEach(rows) { language in
                        row(title: language.displayName,
                            subtitle: language.localizedName() == language.displayName ? nil : language.localizedName(),
                            note: SpeechLocales.isInstalled(language.identifier) ? nil : "Downloads the first time an interview uses it",
                            selected: selection == .language(language)) { choose(.language(language)) }
                            .accessibilityIdentifier("language-\(language.identifier)")
                    }
                } footer: {
                    Text("Only languages this iPhone can recognise on-device are listed. Nothing is substituted: if a language can't be used, the interview says so.")
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search languages")
            .navigationTitle("Interview language")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                await SpeechLocales.load()
                identifiers = SpeechLocales.supported
            }
        }
    }

    private func choose(_ preference: InterviewLanguagePreference) {
        onSelect(preference)
        dismiss()
    }

    private func row(title: String, subtitle: String?, note: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Typography.body(16, weight: selected ? .semibold : .regular))
                        .foregroundStyle(Theme.Color.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(Typography.body(13))
                            .foregroundStyle(Theme.Color.secondary)
                    }
                    if let note {
                        Text(note)
                            .font(Typography.body(12))
                            .foregroundStyle(Theme.Color.warm)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.Color.action)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
