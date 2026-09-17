import SwiftUI

/// The prototype interview surface: a pager of question cards, each with a suggested answer that can
/// be read aloud while the microphone keeps listening.
///
/// Development-only for now (reached from the debug menu). It exercises the pipeline end to end —
/// continuous listening, detection, grounded generation, streaming, reading — and is where the
/// measurements in `docs/CO_INTERVIEW_AI_PIPELINE.md` come from. The full reader geometry
/// (`readingOffset`, `ScrollOwnership`, pinch-to-scale, outdoor mode) is **not** wired in yet; that is
/// plan Increment 3.
struct CopilotScreen: View {
    @State private var coordinator: CopilotSessionCoordinator
    /// DEMO or LIVE, shown unmistakably in the status bar. Nil outside the development entry points.
    private let modeBadge: String?
    @State private var showTypedQuestion = false
    @State private var typedQuestion = ""
    @State private var showSources = false
    @Environment(\.dismiss) private var dismiss

    init(project: any ProjectContextProviding, provider: any CopilotProviding, audio: InterviewAudioInput, modeBadge: String? = nil) {
        _coordinator = State(initialValue: CopilotSessionCoordinator(project: project, provider: provider, audio: audio))
        self.modeBadge = modeBadge
    }

    init(coordinator: CopilotSessionCoordinator, modeBadge: String? = nil) {
        _coordinator = State(initialValue: coordinator)
        self.modeBadge = modeBadge
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider().overlay(Theme.Color.hairline)

            if coordinator.cards.isEmpty {
                emptyState
            } else {
                TabView(selection: Binding(
                    get: { coordinator.selectedCardIndex },
                    set: { coordinator.select(cardIndex: $0) }
                )) {
                    ForEach(Array(coordinator.cards.enumerated()), id: \.element.id) { index, card in
                        AnswerCardView(
                            card: card,
                            isSelected: index == coordinator.selectedCardIndex,
                            coordinator: coordinator
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
            }

            controls
        }
        .background(Theme.Color.paper.ignoresSafeArea())
        .navigationTitle(coordinator.project.projectName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("End") {
                    // Ends the session *before* dismissing: cancels detection and generation, stops
                    // capture and releases the audio session, so ordinary script reading — which
                    // starts its own capture — works immediately afterwards.
                    coordinator.endSession()
                    dismiss()
                }
                .accessibilityLabel("End interview session")
            }
        }
        .onAppear { coordinator.startListening() }
        .onDisappear { coordinator.endSession() }
        .sheet(isPresented: $showTypedQuestion) { typedQuestionSheet }
        .sheet(isPresented: $showSources) { sourcesSheet }
    }

    // MARK: Status

    private var statusBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if let modeBadge {
                    Text(modeBadge)
                        .font(Typography.mono(10, weight: .medium))
                        .foregroundStyle(Theme.Color.onDark)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(modeBadge == "LIVE" ? Theme.Color.warm : Theme.Color.action, in: Capsule())
                        .accessibilityLabel("\(modeBadge) mode")
                }
                Circle()
                    .fill(coordinator.audio.state.isActive ? Theme.Color.action : Theme.Color.secondary)
                    .frame(width: 8, height: 8)
                Text(coordinator.audio.state.label)
                    .font(Typography.body(13, weight: .medium))
                    .foregroundStyle(Theme.Color.ink)
                if coordinator.isClassifying {
                    Text("· checking for a question")
                        .font(Typography.body(12))
                        .foregroundStyle(Theme.Color.secondary)
                }
                Spacer()
                Text(coordinator.hasNewerCardThanSelected ? "Newer question ready" : "\(coordinator.cards.count) cards")
                    .font(Typography.body(12))
                    .foregroundStyle(coordinator.hasNewerCardThanSelected ? Theme.Color.warm : Theme.Color.secondary)
            }
            if coordinator.providerIsDevelopmentFake {
                banner(text: "DEVELOPMENT FAKE PROVIDER — answers are canned text, not a model", color: Theme.Color.warm)
            }
            if let error = coordinator.lastProviderError {
                banner(text: error, color: Theme.Color.error)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func banner(text: String, color: Color) -> some View {
        Text(text)
            .font(Typography.body(11, weight: .medium))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("Listening for a question")
                .font(Typography.display(22))
                .foregroundStyle(Theme.Color.ink)
            Text("Detected questions appear here as cards. You can also ask for an answer yourself.")
                .font(Typography.body(14))
                .foregroundStyle(Theme.Color.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                controlButton("Answer this", systemImage: "questionmark.bubble") {
                    coordinator.answerLastSpeech()
                }
                controlButton("Type", systemImage: "keyboard") { showTypedQuestion = true }
                controlButton(coordinator.audio.state == .pausedByUser ? "Resume listening" : "Pause listening",
                              systemImage: coordinator.audio.state == .pausedByUser ? "mic" : "mic.slash") {
                    if coordinator.audio.state == .pausedByUser {
                        coordinator.audio.resumeListening()
                    } else {
                        coordinator.audio.pauseListening()
                    }
                }
            }
            HStack(spacing: 12) {
                controlButton("Previous", systemImage: "chevron.left") {
                    coordinator.select(cardIndex: coordinator.selectedCardIndex - 1)
                }
                .disabled(coordinator.selectedCardIndex <= 0)

                controlButton("Next", systemImage: "chevron.right") {
                    coordinator.select(cardIndex: coordinator.selectedCardIndex + 1)
                }
                .disabled(!coordinator.hasNewerCardThanSelected)

                controlButton("Latest", systemImage: "arrow.down.to.line") {
                    coordinator.selectLatestCard()
                }
                .disabled(!coordinator.hasNewerCardThanSelected)

                controlButton("Sources", systemImage: "doc.text.magnifyingglass") { showSources = true }
                    .disabled(coordinator.selectedCard?.selectedVersion?.sources.isEmpty ?? true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.Color.card)
    }

    private func controlButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(Typography.body(12, weight: .medium))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: Theme.minimumTouchTarget)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(title)
    }

    private var typedQuestionSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ask a question")
                    .font(Typography.display(20))
                TextField("What should I answer?", text: $typedQuestion, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
                Spacer()
            }
            .padding(20)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ask") {
                        coordinator.askTyped(typedQuestion)
                        typedQuestion = ""
                        showTypedQuestion = false
                    }
                    .disabled(typedQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showTypedQuestion = false }
                }
            }
        }
    }

    private var sourcesSheet: some View {
        NavigationStack {
            List(coordinator.selectedCard?.selectedVersion?.sources ?? []) { source in
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.documentTitle)
                        .font(Typography.body(14, weight: .semibold))
                    Text("\(source.locator) · version \(source.documentVersion)")
                        .font(Typography.body(11))
                        .foregroundStyle(Theme.Color.secondary)
                    Text(source.excerpt)
                        .font(Typography.body(12))
                        .foregroundStyle(Theme.Color.spoken)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// One question card: the question, then either the streaming preview or the frozen readable text.
struct AnswerCardView: View {
    let card: QuestionCard
    let isSelected: Bool
    let coordinator: CopilotSessionCoordinator

    private var version: AnswerVersion? { card.selectedVersion }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    questionHeader
                    answerBody
                    versionPicker
                }
                .padding(20)
                .onChange(of: alignment?.cursor.tokenIndex ?? 0) { _, _ in
                    guard let alignment else { return }
                    let sentence = ScriptStyling.currentSentenceIndex(scriptIndex: alignment.scriptIndex, cursor: alignment.cursor)
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(sentence, anchor: .center) }
                }
            }
        }
    }

    private var alignment: ReadingAlignment? {
        isSelected ? coordinator.activeAlignment() : nil
    }

    private var questionHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Question \(card.sequence)\(card.origin == .detected ? "" : " · \(card.origin.rawValue)")")
                .font(Typography.body(11, weight: .medium))
                .foregroundStyle(Theme.Color.secondary)
            Text(card.questionText)
                .font(Typography.body(16, weight: .semibold))
                .foregroundStyle(Theme.Color.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Question \(card.sequence) of \(coordinator.cards.count). \(card.questionText)")
    }

    @ViewBuilder
    private var answerBody: some View {
        if let version {
            switch version.status {
            case .queued:
                statusLine("Queued — waiting for an earlier answer to finish", color: Theme.Color.secondary)
            case .streaming, .complete, .cancelled, .superseded, .failed:
                if version.hasReadableText, let alignment, isSelected {
                    readableText(alignment: alignment, version: version)
                } else if version.hasReadableText {
                    Text(version.readableSegments[min(card.activeSegmentIndex, version.readableSegments.count - 1)])
                        .font(Typography.reading(24, face: .hankenGrotesk))
                        .foregroundStyle(Theme.Color.ink)
                } else {
                    previewText(version)
                }
                statusFooter(version)
                routeLine(version)
            }
        } else {
            statusLine("No answer yet", color: Theme.Color.secondary)
        }
    }

    /// The streaming preview. Muted, explicitly not followable, and never handed to the matcher —
    /// its tail can still be revised by the next delta.
    private func previewText(_ version: AnswerVersion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(version.fullText.isEmpty ? "Generating…" : version.fullText)
                .font(Typography.reading(22, face: .hankenGrotesk))
                .foregroundStyle(Theme.Color.spoken)
            if !version.committedText.isEmpty {
                Button("Read this opening now") { coordinator.beginReadingSelectedCard() }
                    .buttonStyle(.borderedProminent)
                    .font(Typography.body(13, weight: .medium))
            }
        }
    }

    /// Frozen, immutable reading text with the existing spoken-word fading.
    private func readableText(alignment: ReadingAlignment, version: AnswerVersion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(ScriptStyling.sentenceBlocks(
                rawText: alignment.text,
                scriptIndex: alignment.scriptIndex,
                cursor: alignment.cursor,
                spokenTokenIndices: alignment.spokenTokenIndices
            )) { block in
                block.text
                    .font(Typography.reading(26, face: .hankenGrotesk))
                    .id(block.id)
                    .animation(.easeInOut(duration: 0.45), value: alignment.spokenTokenIndices.count)
            }

            HStack(spacing: 12) {
                Button(card.isFollowingPaused ? "Resume following" : "Pause following") {
                    coordinator.setReadingPaused(!card.isFollowingPaused)
                }
                .buttonStyle(.bordered)
                if coordinator.selectedCardHasNextSegment {
                    Button("Continue") { coordinator.continueToNextSegment() }
                        .buttonStyle(.borderedProminent)
                }
                Button("Regenerate") { coordinator.regenerate(cardID: card.id) }
                    .buttonStyle(.bordered)
            }
            .font(Typography.body(12, weight: .medium))

            if !version.pendingText.isEmpty || version.status == .streaming {
                Text("More is still being written — it becomes readable when you tap Continue.")
                    .font(Typography.body(11))
                    .foregroundStyle(Theme.Color.secondary)
            }
        }
    }

    @ViewBuilder
    private func statusFooter(_ version: AnswerVersion) -> some View {
        switch version.status {
        case .streaming:
            statusLine("Generating with \(version.modelLabel)…", color: Theme.Color.secondary)
        case .complete where version.incompleteReason != nil:
            statusLine("Stopped early: \(version.incompleteReason ?? ""). The text above stays readable — Regenerate adds a new version.",
                       color: Theme.Color.warm)
        case .complete:
            statusLine(version.sources.isEmpty
                ? "No project source used — general answer"
                : "\(version.sources.count) source\(version.sources.count == 1 ? "" : "s")",
                color: version.sources.isEmpty ? Theme.Color.warm : Theme.Color.secondary)
        case .failed(let message):
            statusLine("Generation failed: \(message). Previous text is still readable.", color: Theme.Color.error)
        case .cancelled:
            statusLine("Cancelled", color: Theme.Color.secondary)
        case .superseded:
            statusLine("Replaced by a newer version", color: Theme.Color.secondary)
        case .queued:
            EmptyView()
        }
    }

    @ViewBuilder
    private func routeLine(_ version: AnswerVersion) -> some View {
        if let route = version.route {
            // What actually served the answer, as reported — never inferred from the preference list.
            statusLine(route.summary, color: Theme.Color.secondary)
        }
    }

    private func statusLine(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Typography.body(12))
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var versionPicker: some View {
        if card.versions.count > 1 {
            HStack(spacing: 8) {
                ForEach(card.versions) { candidate in
                    Button("v\(candidate.number)") {
                        coordinator.selectVersion(candidate.id, cardID: card.id)
                    }
                    .buttonStyle(.bordered)
                    .font(Typography.body(11, weight: .medium))
                    .tint(candidate.id == card.selectedVersionID ? Theme.Color.action : Theme.Color.secondary)
                }
            }
        }
    }
}
