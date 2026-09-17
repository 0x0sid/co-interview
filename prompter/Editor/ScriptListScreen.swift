import SwiftUI
import SwiftData

/// §12.1 Home — the app's real root screen as of M5, replacing `RootView`'s debug list. Script
/// list from SwiftData (title, word count, ~duration, last used), big "New Script" action, mascot
/// idle top corner, Demo hero card on first launch, empty state otherwise.
struct ScriptListScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Script.updatedAt, order: .reverse) private var scripts: [Script]
    @Query private var settingsQuery: [AppSettings]
    @Environment(EntitlementService.self) private var entitlements

    @State private var navigateToNewScript = false
    @State private var showDemo = false
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var scriptToOpen: Script?
    /// Pending deletion, driving the confirmation dialog. Non-nil means "asked, not yet confirmed".
    @State private var scriptPendingDeletion: Script?
    /// Surfaced when the store refuses a delete — an unsuccessful deletion must never look complete.
    @State private var deletionError: String?

    /// True while the Premium announcement has never been opened.
    private var hasUnreadPremiumAnnouncement: Bool {
        !(settingsQuery.first?.hasSeenPremiumAnnouncement ?? false)
    }

    private var settings: AppSettings {
        AppSettings.fetchOrCreate(in: modelContext)
    }

    /// Newest-first, filtered by the search field. Title *and* body are searched, because a script
    /// is often remembered by a phrase in it rather than its auto-derived title.
    private var filteredScripts: [Script] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return scripts }
        return scripts.filter {
            $0.title.lowercased().contains(query) || $0.rawText.lowercased().contains(query)
        }
    }

    /// The most recently used script, if any — the target of the prominent open action.
    private var mostRecent: Script? {
        scripts.filter { $0.lastUsedAt != nil }.max { ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                searchField

                #if DEBUG
                // The copilot's home entry. **Development builds only** — it opens the interview
                // prototype, which answers from a sample project and is not a shipping feature yet.
                // Before this existed the copilot was reachable only through a launch argument or the
                // debug menu, so a normal launch showed just the teleprompter.
                copilotEntryCard
                #endif

                if let mostRecent {
                    openScriptCard(mostRecent)
                }

                if !(settingsQuery.first?.hasCompletedDemo ?? false) {
                    demoHeroCard
                }

                if scripts.isEmpty {
                    emptyState
                } else {
                    scriptList
                }
            }
            .padding(20)
            .padding(.bottom, 96)   // room for the floating New script action
        }
        .background(Theme.Color.paper)
        .scrollDismissesKeyboard(.interactively)
        .overlay(alignment: .bottom) { newScriptButton }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToNewScript) {
            ScriptEditorScreen(script: nil)
        }
        .navigationDestination(item: $scriptToOpen) { script in
            ScriptEditorScreen(script: script)
        }
        .fullScreenCover(isPresented: $showDemo) {
            DemoScreen(onCreateScript: { navigateToNewScript = true })
        }
        .sheet(isPresented: $showSettings) { SettingsScreen(entitlements: entitlements) }
        // Cancel is the safe action and is the default; the destructive role is explicit.
        .confirmationDialog(
            scriptPendingDeletion.map { "Delete \u{201C}\($0.title.isEmpty ? "Untitled" : $0.title)\u{201D}?" } ?? "",
            isPresented: Binding(get: { scriptPendingDeletion != nil }, set: { if !$0 { scriptPendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let script = scriptPendingDeletion { delete(script) }
                scriptPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { scriptPendingDeletion = nil }
        } message: {
            Text("This cannot be undone.")
        }
        .alert("Couldn\u{2019}t delete script", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
            Button("OK", role: .cancel) { deletionError = nil }
        } message: {
            Text(deletionError ?? "")
        }
        // `@Query` alone won't create the singleton `AppSettings` row on a fresh install — this
        // ensures it exists (falling back to `false`/defaults above is what keeps the first
        // render, before this runs, safe rather than force-unwrapped).
        .task { _ = settings }
    }

    #if DEBUG
    private var copilotEntryCard: some View {
        NavigationLink {
            CopilotStartScreen()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.Color.onDark)
                    .frame(width: 44, height: 44)
                    .background(Theme.Color.action, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Interview Copilot")
                        .font(Typography.body(17, weight: .semibold))
                        .foregroundStyle(Theme.Color.ink)
                    Text("Listens, suggests answers, and follows your voice as you read them")
                        .font(Typography.body(12))
                        .foregroundStyle(Theme.Color.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Color.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.Color.hairline, lineWidth: 0.5))
        }
        .accessibilityLabel("Interview Copilot. Listens, suggests answers, and follows your voice as you read them.")
    }
    #endif

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.Color.secondary)
            TextField("Search scripts", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(Theme.Color.ink)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Color.secondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.minimumTouchTarget)
        .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Color.hairline, lineWidth: 0.5))
    }

    /// **Labelled "Open script", not "Continue reading".** The mockup shows the latter, but nothing
    /// in the data model stores a reading position — `Script` has no cursor field and
    /// `PromptSession` records only duration and completion. Opening starts from the beginning, so
    /// calling it "Continue reading" would promise a capability that does not exist (M5.10).
    private func openScriptCard(_ script: Script) -> some View {
        Button {
            scriptToOpen = script
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open script")
                        .font(Typography.body(13))
                        .foregroundStyle(Theme.Color.secondary)
                    Text(script.title.isEmpty ? "Untitled" : script.title)
                        .font(Typography.body(17, weight: .semibold))
                        .foregroundStyle(Theme.Color.ink)
                        .lineLimit(2)
                    Text("\(script.wordCount) words")
                        .font(Typography.body(13))
                        .foregroundStyle(Theme.Color.secondary)
                }
                Spacer(minLength: 8)
                Label("Open", systemImage: "play.fill")
                    .font(Typography.body(15, weight: .semibold))
                    .foregroundStyle(Theme.Color.onDark)
                    .padding(.horizontal, 16)
                    .frame(height: Theme.minimumTouchTarget)
                    .background(Capsule().fill(Theme.Color.action))
            }
            .padding(16)
            .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: Theme.Shape.cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open script, \(script.title.isEmpty ? "Untitled" : script.title), \(script.wordCount) words")
    }

    private var newScriptButton: some View {
        Button {
            navigateToNewScript = true
        } label: {
            Label("New script", systemImage: "plus")
                .font(Typography.body(17, weight: .semibold))
                .foregroundStyle(Theme.Color.onDark)
                .padding(.horizontal, 24)
                .frame(height: 52)
                .background(Capsule().fill(Theme.Color.action))
        }
        .padding(.bottom, 20)
        .accessibilityLabel("New script")
    }

    private var header: some View {
        HStack {
            Text("Scripts")
                .font(Typography.display(34))
                .foregroundStyle(Theme.Color.ink)
            Spacer()
            Button {
                showSettings = true
            } label: {
                // **The unread badge lives on the gear (M5.13)**, so the announcement is visible
                // without opening Settings. Opening Settings does NOT clear it — only opening the
                // Premium screen does, and then permanently.
                Image(systemName: "gearshape")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.Color.ink)
                    .frame(width: Theme.minimumTouchTarget, height: Theme.minimumTouchTarget)
                    .overlay(alignment: .topTrailing) {
                        if hasUnreadPremiumAnnouncement {
                            Text("1")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Circle().fill(Color.red))
                                .offset(x: -2, y: 4)
                        }
                    }
            }
            .accessibilityLabel(hasUnreadPremiumAnnouncement
                                ? "Settings, 1 new item: Prompter Premium"
                                : "Settings")
        }
    }

    private var demoHeroCard: some View {
        Button {
            showDemo = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text("See the magic — 30 seconds")
                    .font(Typography.body(19, weight: .semibold))
                    .foregroundStyle(Theme.Color.ink)
                Text("Try Prompter with a bundled script. No signup, never metered.")
                    .font(Typography.body(15))
                    .foregroundStyle(Theme.Color.spoken)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: Theme.Shape.cornerRadius)
                    .fill(Theme.Color.currentSentence)
            )
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            MascotView(expression: .idle, size: 72)
            Text("Paste your first script.")
                .font(Typography.body(17, weight: .medium))
                .foregroundStyle(Theme.Color.spoken)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var scriptList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent")
                .font(Typography.body(14, weight: .semibold))
                .foregroundStyle(Theme.Color.secondary)

            if filteredScripts.isEmpty {
                Text("No scripts match \u{201C}\(searchText)\u{201D}.")
                    .font(Typography.body(15))
                    .foregroundStyle(Theme.Color.secondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(filteredScripts) { script in
                    NavigationLink {
                        ScriptEditorScreen(script: script)
                    } label: {
                        ScriptRow(script: script)
                    }
                    .buttonStyle(.plain)
                    // Discoverable delete. **Swipe-to-delete is not offered here**: `.swipeActions`
                    // requires a `List`, and the approved layout is a card stack in a `ScrollView`.
                    // Converting it to a `List` to gain the swipe would change the accepted design,
                    // so the long-press menu is the affordance rather than a fake swipe.
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            scriptPendingDeletion = script
                        }
                    }
                    .accessibilityAction(named: "Delete") { scriptPendingDeletion = script }
                }
            }
        }
    }
}

/// Deletes a script through the existing persistence layer.
///
/// **Scope is deliberately narrow.** `Script` cascades only to its own `PromptSession` rows
/// (`Script.sessions`, `.cascade`). `UsageLedger` is keyed by calendar day and holds **no**
/// relationship to `Script`, so deleting a script cannot reset the daily allowance; entitlement
/// state lives outside SwiftData entirely and is untouched. Nothing else references a script by id.
///
/// **Failures are surfaced, never swallowed.** SwiftData's `delete` is not itself throwing, but the
/// `save` is: if it fails the object is rolled back into the context and the reader is told, rather
/// than seeing the row vanish from a list that would repopulate on next launch.
extension ScriptListScreen {
    func delete(_ script: Script) {
        // Clear navigation that points at the row being removed, so nothing holds a dangling
        // reference after the object leaves the context.
        if scriptToOpen?.id == script.id { scriptToOpen = nil }

        modelContext.delete(script)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            deletionError = "The script could not be removed. It is still in your library. (\(error.localizedDescription))"
        }
    }
}

private struct ScriptRow: View {
    let script: Script

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(script.title.isEmpty ? "Untitled" : script.title)
                    .font(Typography.body(17, weight: .medium))
                    .foregroundStyle(Theme.Color.ink)
                    .lineLimit(2)                      // long titles wrap rather than truncate hard
                Text(subtitle)
                    .font(Typography.body(13))
                    .foregroundStyle(Theme.Color.secondary)
                if !preview.isEmpty {
                    Text(preview)
                        .font(Typography.body(13))
                        .foregroundStyle(Theme.Color.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Theme.Shape.cornerRadius)
                .fill(Theme.Color.card)
        )
    }

    /// First line of the body, trimmed — the mockup's preview text. Uses the stored script
    /// verbatim; nothing is rewritten or stripped.
    private var preview: String {
        let body = script.rawText
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return body.count > 90 ? String(body.prefix(90)) + "\u{2026}" : body
    }

    private var subtitle: String {
        let minutes = max(1, script.estimatedDurationSeconds / 60)
        let words = "\(script.wordCount) words · ~\(minutes) min"
        guard let lastUsedAt = script.lastUsedAt else { return words }
        let relative = lastUsedAt.formatted(.relative(presentation: .named))
        return "\(words) · used \(relative)"
    }
}

#Preview {
    NavigationStack {
        ScriptListScreen()
    }
    .modelContainer(for: [Script.self, PromptSession.self, UsageLedger.self, AppSettings.self], inMemory: true)
}
