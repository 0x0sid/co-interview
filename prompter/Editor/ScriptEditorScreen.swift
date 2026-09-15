import SwiftUI
import SwiftData

/// §12.3 Script Editor — promotes the debug paste screen's guts (`PromptTextInputScreen`, still
/// kept separately behind the debug gear for arbitrary quick-test text) onto a real, persisted
/// `Script`. Create (pass `script: nil`) and edit funnel through the same view: creating just
/// means a fresh `Script` gets inserted into the context immediately, so autosave has something
/// to write to from the first keystroke.
struct ScriptEditorScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var settingsQuery: [AppSettings]

    @State private var script: Script
    @State private var saveTask: Task<Void, Never>?
    @State private var rewritePreview: String?
    @State private var rewriteError: String?
    @State private var isRewriting = false
    @State private var navigateToPrompt = false
    /// Tracks what `handleTextChange` last wrote into `script.title` itself, so it can tell "the
    /// title still matches what auto-derivation set it to, keep syncing" apart from "the user
    /// typed their own title, stop overwriting it" — both cases leave `script.title` non-empty,
    /// so emptiness alone can't distinguish them (§12.3: "auto from first line (editable)").
    @State private var lastAutoTitle = ""
    /// Editor-only reading size, separate from the prompt screen's persisted `AppSettings
    /// .fontScale` (pinch-to-scale while actually prompting) — this is a quick, session-local
    /// legibility convenience for writing/editing, not a stored preference.
    /// Native cursor/selection tracking (`TextEditor(text:selection:)`, iOS 18+) — lets the
    /// bracket-insert button place `[pause]` at the actual cursor position (replacing a
    /// selection, if any) instead of always appending to the end of the text.
    @State private var textSelection: TextSelection?
    /// Whether the body editor holds first responder. Drives the keyboard-aware layout (M5.12).
    @FocusState private var isEditingBody: Bool
    @Environment(EntitlementService.self) private var entitlements
    @State private var usage: UsageTracker?
    @State private var showPaywall = false

    private let isNewScript: Bool

    init(script existingScript: Script?) {
        if let existingScript {
            _script = State(initialValue: existingScript)
            isNewScript = false
        } else {
            // Pre-filled with the same example script the debug paste screen has always used —
            // gives a new script something real to look at/edit immediately instead of a blank
            // page, and keeps "Start" usable right away.
            _script = State(initialValue: Script(title: "", rawText: PromptDemoFixture.defaultScriptText))
            isNewScript = true
        }
    }

    private var settings: AppSettings? { settingsQuery.first }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Title", text: $script.title)
                .font(Typography.body(20, weight: .semibold))
                .foregroundStyle(Theme.Color.ink)
                .padding(.horizontal, 20)
                .padding(.top, 16)

            statsRow
            remainingTimeRow
            readingLanguageRow

            // **Keyboard-aware editing (M5.12).** `TextEditor` owns its own scrolling and keeps the
            // insertion point visible; SwiftUI's built-in keyboard avoidance shrinks this view when
            // the keyboard appears. What previously made the bottom of a long script unreachable was
            // not the avoidance — it was the `Start` button sitting *between* the editor and the
            // keyboard, permanently consuming the space the last paragraphs needed.
            //
            // No fixed keyboard-height estimate and no extra scroll gesture is introduced: the fix
            // is to give the editor that space back while editing.
            TextEditor(text: $script.rawText, selection: $textSelection)
                .font(Typography.body(16))
                .foregroundStyle(Theme.Color.ink)
                .multilineTextAlignment(resolvedTextDirection == .rightToLeft ? .trailing : .leading)
                .environment(\.layoutDirection, resolvedTextDirection)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)
                .focused($isEditingBody)
                .onChange(of: script.rawText) { _, newValue in
                    handleTextChange(newValue)
                }

            if settings?.aiRewriteEnabled == true, AIRewriteService.isAvailable {
                aiRewriteButton
            }

            if let rewriteError {
                Text(rewriteError)
                    .font(Typography.body(13))
                    .foregroundStyle(Theme.Color.error)
                    .padding(.horizontal, 20)
            }

            // Hidden while the keyboard is up: it is not needed mid-edit, and leaving it there is
            // what covered the end of the document. It returns the moment editing stops.
            if !isEditingBody {
                Button("Start reading") {
                    isEditingBody = false
                    script.lastUsedAt = .now
                    try? modelContext.save()
                    // **The allowance is checked here, before the take — never during one.**
                    // Premium reads unlimited; a free reader with time left starts and is allowed to
                    // overrun; a free reader with nothing left sees the paywall instead.
                    if entitlements.status.allowsUnlimitedReading || (usage?.canStartMeteredTake ?? true) {
                        navigateToPrompt = true
                    } else {
                        showPaywall = true
                    }
                }
                .buttonStyle(.prompterPrimary)
                .disabled(script.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isEditingBody)
        .toolbar {
            // The accessible way out of the keyboard. A drag-to-dismiss gesture was deliberately not
            // added: it would compete with the editor's own scrolling.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isEditingBody = false }
                    .accessibilityLabel("Dismiss keyboard")
            }
        }
        .onChange(of: isEditingBody) { _, editing in
            // Persist when editing ends, so text survives dismissal, backgrounding and appearance
            // changes without waiting for `onDisappear`.
            if !editing { try? modelContext.save() }
        }
        .background(Theme.Color.paper)
        .navigationTitle(isNewScript ? "New Script" : "Edit Script")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToPrompt) {
            PromptScreen(
                scriptText: script.rawText,
                makeService: { TranscriptionService(audioCapture: AudioCaptureService()) },
                textDirectionOverride: script.textDirectionOverride,
                readingLanguage: script.readingLanguage,
                usage: entitlements.status.allowsUnlimitedReading ? nil : usage
            )
        }
        .sheet(isPresented: $showPaywall) {
            NavigationStack { PaywallScreen(entitlements: entitlements) }
        }
        .onAppear {
            if usage == nil { usage = UsageTracker(context: modelContext) }
            if isNewScript {
                modelContext.insert(script)
                handleTextChange(script.rawText) // populate title/word count for the pre-filled example
            }
        }
        .onDisappear {
            saveTask?.cancel()
            try? modelContext.save()
        }
        .sheet(item: rewritePreviewItem) { preview in
            rewriteReviewSheet(preview: preview)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            Text("\(wordCount) words")
            Text("~\(estimatedMinutes) min")
        }
        .font(Typography.body(13))
        .foregroundStyle(Theme.Color.spoken)
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    /// **Per-script reading language.** Labelled for what it does — it decides how the take is
    /// transcribed, not how the interface is displayed. Changing it never alters the script text.
    ///
    /// Hidden while the keyboard is up so it does not compete for editing space.
    @ViewBuilder
    private var readingLanguageRow: some View {
        if !isEditingBody {
            HStack(spacing: 8) {
                Text("Reading language")
                    .font(Typography.body(13))
                    .foregroundStyle(Theme.Color.secondary)
                Spacer()
                Picker("Reading language", selection: Binding(
                    get: { script.readingLanguage },
                    set: { script.readingLanguage = $0; try? modelContext.save() }
                )) {
                    ForEach(ReadingLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.Color.action)
                .accessibilityLabel("Reading language, the language this script is written in")
            }
            .padding(.horizontal, 20)
            .padding(.top, 2)
        }
    }

    /// Remaining free reading time — shown only to free readers, and only when not editing.
    @ViewBuilder
    private var remainingTimeRow: some View {
        if !isEditingBody, !entitlements.status.allowsUnlimitedReading, let usage {
            let remaining = usage.remainingSeconds
            Text(remaining > 0
                 ? "\(remaining / 60) min \(remaining % 60) s of free reading left today"
                 : "Free reading time used up for today")
                .font(Typography.body(12))
                .foregroundStyle(Theme.Color.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 2)
                .accessibilityLabel(remaining > 0
                                    ? "\(remaining / 60) minutes \(remaining % 60) seconds of free reading left today"
                                    : "Free reading time used up for today")
        }
    }

    private var wordCount: Int { Tokenizer.normalize(script.rawText).count }
    private var estimatedMinutes: Int { max(1, Int((Double(wordCount) / Script.wordsPerMinute).rounded())) }

    /// M5.1-D: resolved live from the current text + the script's stored override, so typing
    /// Arabic (or switching the picker) re-aligns the editor immediately, not just the prompt
    /// screen.
    private var resolvedTextDirection: LayoutDirection {
        TextDirectionDetector.resolvedDirection(for: script.rawText, override: script.textDirectionOverride)
    }

    // **The A / A / [ ] toolbar was removed (M5.10.)** It held two font-size buttons and a
    // bracket-insert button that typed "[pause]" into the script. All three are gone, along with
    // their divider and container; the space they occupied now belongs to the script body.
    //
    // Reader text size lives in Settings as a single labelled control — there is no second pair of
    // "A" buttons anywhere. The pause-marker insertion action was **not relocated** into another
    // menu; it no longer exists.
    //
    // **Existing script text is untouched.** Scripts that already contain "[pause]" keep it
    // verbatim: removing the way to insert a marker must not rewrite documents that have one. No
    // migration, no stripping, no title repair.

    private func handleTextChange(_ newText: String) {
        if script.title.isEmpty || script.title == lastAutoTitle {
            let derived = String((newText.split(separator: "\n").first ?? "").prefix(60))
            script.title = derived
            lastAutoTitle = derived
        }
        script.wordCount = wordCount
        script.updatedAt = .now

        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? modelContext.save()
        }
    }

    private var aiRewriteButton: some View {
        Button {
            runRewrite()
        } label: {
            HStack {
                if isRewriting {
                    ProgressView().tint(Theme.Color.action)
                }
                Text("Optimize for speaking")
            }
        }
        .buttonStyle(.prompterSecondary)
        .disabled(isRewriting || script.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func runRewrite() {
        isRewriting = true
        rewriteError = nil
        Task {
            defer { isRewriting = false }
            do {
                rewritePreview = try await AIRewriteService.rewrite(script.rawText)
            } catch {
                rewriteError = "Couldn't rewrite right now — try again."
            }
        }
    }

    // `Identifiable` wrapper so `.sheet(item:)` can drive the diff review without a second Bool.
    private struct RewritePreview: Identifiable {
        let id = UUID()
        let text: String
    }

    private var rewritePreviewItem: Binding<RewritePreview?> {
        Binding(
            get: { rewritePreview.map(RewritePreview.init) },
            set: { rewritePreview = $0?.text }
        )
    }

    private func rewriteReviewSheet(preview: RewritePreview) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ScriptDiff.diff(original: script.rawText, revised: preview.text)) { line in
                        diffLineView(line)
                    }
                }
                .padding(20)
            }
            .background(Theme.Color.paper)
            .navigationTitle("Review rewrite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reject") { rewritePreview = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Accept") {
                        script.rawText = preview.text
                        rewritePreview = nil
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func diffLineView(_ line: ScriptDiff.Line) -> some View {
        switch line {
        case .unchanged(let text):
            Text(text)
                .font(Typography.body(15))
                .foregroundStyle(Theme.Color.ink)
        case .removed(let text):
            Text(text)
                .font(Typography.body(15))
                .foregroundStyle(Theme.Color.error)
                .strikethrough()
        case .added(let text):
            Text(text)
                .font(Typography.body(15))
                .foregroundStyle(Theme.Color.ink)
                .padding(.horizontal, 4)
                .background(Theme.Color.currentSentence)
        }
    }
}

#Preview {
    NavigationStack {
        ScriptEditorScreen(script: nil)
    }
    .modelContainer(for: [Script.self, PromptSession.self, UsageLedger.self, AppSettings.self], inMemory: true)
}
