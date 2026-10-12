import SwiftUI

/// The live transcript at the top of the screen, in its two states.
///
/// **Collapsed** is the working state: the two newest lines. Two lines, no scrolling, nothing to
/// manage. **Plain transcript text only** (owner decision, 2026-09-28): no line is styled, underlined or
/// tappable as a "detected question" — a classifier's guess is not something to act on.
///
/// **Expanded** shows more of the conversation and reveals the Context panel. Collapsing it is a
/// view change only — the note and the attached images stay exactly where they were.
struct TranscriptStripView: View {
    let lines: [TranscriptLine]
    @Binding var isExpanded: Bool
    let context: ContextState
    let onNoteChanged: (String) -> Void
    /// "1 file", "2 files" — images and documents together — or nil when nothing is attached.
    var filesLabel: String? = nil
    /// Opens the session's file list and import actions.
    var onOpenFiles: () -> Void = {}
    /// Changes when "Add context" asks for the keyboard in the note field.
    var noteFocusRequest: Int = 0
    /// Whether the note field has the keyboard, so the screen can keep its floating control clear.
    var onEditingNoteChanged: (Bool) -> Void = { _ in }

    /// What is being typed. It becomes part of the interview's context only when "Add context" (or
    /// Return) is used — never keystroke by keystroke.
    @State private var draft: String = ""
    /// Where each addition goes in the transcript: the speech line that was newest when it was added.
    @State private var contextAnchors: [String: UUID] = [:]
    /// While the note has the keyboard, the transcript does not collapse under the user: a tap on its
    /// chevron first puts the keyboard away (the draft is kept), and only the next tap collapses. Losing a
    /// half-typed note to a mistimed tap is not a trade worth making for a few points of height.
    @FocusState private var isEditingNote: Bool
    /// The expanded transcript's natural height, so a short transcript takes only the room it needs.
    @State private var expandedContentHeight: CGFloat = 0
    /// Terminal-style following of the newest speech in the expanded transcript.
    @State private var follow = TranscriptFollow()
    /// Where the expanded transcript is: at (or within a few points of) its last line.
    @State private var isAtBottom = true

    /// The expanded feed's lines. Collapsed, the transcript is `CollapsedTranscriptPreview`: exactly
    /// three lines of height, so the answer below it never moves as the conversation continues.
    private var visibleLines: [TranscriptLine] {
        Array(lines.suffix(Self.expandedLineLimit))
    }

    /// How many lines the expanded transcript holds. More than this and it scrolls inside itself.
    /// How much history the expanded transcript keeps scrollable. Rows are lazy and keyed by stable
    /// line ids, so a revision re-renders one row, not the whole feed.
    static let expandedLineLimit = 300
    private static let bottomID = "transcript-bottom"

    /// The ceiling on the expanded transcript, so it can never take the whole screen.
    ///
    /// Expanding is a request to read a little more of what was said — not to give up the answer.
    /// Six long lines were already enough to push the answer off-screen on a phone, so the expanded
    /// strip stops here and scrolls within itself, and the answer keeps the rest.
    static let expandedMaxHeight: CGFloat = 168
    /// While context is being typed the transcript steps back to a couple of lines, so the field, its
    /// button and the floating session control all fit above the keyboard, even on a small iPhone.
    static let expandedWhileTypingMaxHeight: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: isExpanded ? 5 : 2) {
                header

                if isExpanded {
                    expandedFeed
                } else {
                    // Exactly three lines, reserved from the start: streaming never resizes it.
                    CollapsedTranscriptPreview(lines: lines)
                }
            }

            if isExpanded {
                contextPanel
            }
        }
        .onChange(of: isEditingNote) { _, editing in onEditingNoteChanged(editing) }
        .animation(.easeInOut(duration: 0.2), value: isEditingNote)
        // Opened from anywhere (the header or the ••• menu): at the newest line, following.
        .onChange(of: isExpanded) { _, expanded in if expanded { follow.jumpToLatest() } }
        .onChange(of: noteFocusRequest) { _, _ in
            // The panel appears in the same update that asks for focus; focus it once it exists.
            Task { @MainActor in isEditingNote = true }
        }
    }

    /// The whole row opens and closes the transcript: a clear chevron in a circle and, while closed, a
    /// quiet "Tap to expand".
    private var header: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Live transcript")
                        .font(InterviewTheme.Font.ui(15, weight: .semibold, relativeTo: .subheadline))
                        .foregroundStyle(InterviewTheme.Color.ink)
                    if !isExpanded {
                        Text("Tap to expand")
                            .font(InterviewTheme.Font.ui(11, relativeTo: .caption2))
                            .foregroundStyle(InterviewTheme.Color.muted)
                    }
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .foregroundStyle(InterviewTheme.Color.ink)
                    .frame(width: 30, height: 30)
                    .background(InterviewTheme.Color.ink.opacity(0.08), in: Circle())
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Live transcript")
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint(isExpanded ? "Collapses the transcript" : "Expands the transcript")
        .accessibilityAction(named: isExpanded ? "Collapse" : "Expand", toggle)
        // Kept as the identifier the UI tests (and older captures) navigate by.
        .accessibilityIdentifier(isExpanded ? "Collapse live transcript" : "Expand live transcript")
    }

    private func toggle() {
        guard !isEditingNote else { isEditingNote = false; return }
        withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        if isExpanded { follow.jumpToLatest() }
    }

    /// Like a terminal: opens at the newest line, stays pinned to it while speech arrives, and stops
    /// following — without being pulled back down — once the reader scrolls up. "↓ Latest" returns.
    private var expandedFeed: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(ContextState.rows(lines: visibleLines, entries: context.entries, anchors: contextAnchors)) { row in
                        switch row {
                        case .speech(let line): lineView(line)
                        case .context(let entry): contextRow(entry)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { expandedContentHeight = $0 }
            }
            .defaultScrollAnchor(.bottom)
            // Bounded and internally scrolled: a long tail of transcript scrolls here rather than
            // growing downwards into the answer. Content-sized up to the ceiling, so four short lines
            // do not sit on top of an empty band.
            .frame(height: min(max(expandedContentHeight, 1), isEditingNote ? Self.expandedWhileTypingMaxHeight : Self.expandedMaxHeight))
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 12
            } action: { _, atBottom in
                isAtBottom = atBottom
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .interacting: follow.readerBeganScrolling()
                case .idle: follow.scrollSettled(atBottom: isAtBottom)
                default: break
                }
            }
            // New speech — a new line or a revision of the newest — keeps the view pinned while
            // following. No animation per word: the view simply stays at the bottom.
            .onChange(of: lines.last.map { "\($0.id)|\($0.text.count)" }) { _, _ in
                guard follow.shouldScrollForNewContent() else { return }
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            // Just-added context shows where it lands, at the bottom.
            .onChange(of: context.entries.count) { old, new in
                guard new > old else { return }
                follow.jumpToLatest()
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if follow.showsLatestButton {
                    Button {
                        follow.jumpToLatest()
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                            .font(InterviewTheme.Font.ui(12, weight: .semibold, relativeTo: .caption1))
                            .foregroundStyle(InterviewTheme.Color.onPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(InterviewTheme.Color.primary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .accessibilityLabel("Jump to the latest transcript")
                    .accessibilityIdentifier("transcript-latest")
                    .transition(.opacity)
                }
            }
        }
    }

    /// Every line the same: text, no button, no highlight, no accessibility action.
    private func lineView(_ line: TranscriptLine) -> some View {
        Text(line.text)
            .font(InterviewTheme.Font.ui(14, relativeTo: .subheadline))
            .foregroundStyle(InterviewTheme.Color.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Added context, in the transcript where it was added: green, marked as added rather than said,
    /// with its own Clear.
    private func contextRow(_ entry: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 12, weight: .semibold))
                .accessibilityHidden(true)
            Text(entry)
                .font(InterviewTheme.Font.ui(14, weight: .medium, relativeTo: .subheadline))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Clear") {
                contextAnchors[entry] = nil
                onNoteChanged(context.removing(entry))
            }
            .font(InterviewTheme.Font.ui(12.5, weight: .semibold, relativeTo: .footnote))
            .buttonStyle(.plain)
            .accessibilityLabel("Clear this context")
        }
        .foregroundStyle(InterviewTheme.Color.primary)
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Added context: \(entry)")
        .accessibilityIdentifier("added-context")
    }

    // MARK: Context

    /// The note and the files the answers should take into account.
    ///
    /// Files are a count and a button here — "2 files" — and the list, their states and the import
    /// actions live in the Files sheet. The note stays inline because it is typed mid-interview.
    private var contextPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            // No heading: a roomy field says what it is for, and is always there with the transcript.
            TextField("Anything the answers should know", text: $draft, axis: .vertical)
                .lineLimit(3...6)
                .focused($isEditingNote)
                // Return is an ordinary new line, as in any multi-line field: Add context adds it, and
                // a tap anywhere outside puts the keyboard away.
                .font(InterviewTheme.Font.ui(14, relativeTo: .subheadline))
                .foregroundStyle(InterviewTheme.Color.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(InterviewTheme.Color.background, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(InterviewTheme.Color.hairline, lineWidth: 1))
                .accessibilityLabel("Context")
                .accessibilityIdentifier("context-note-field")

            HStack(spacing: 10) {
                Button(action: onOpenFiles) {
                    HStack(spacing: 5) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 13, weight: .semibold))
                        Text(filesLabel ?? "Files")
                            .font(InterviewTheme.Font.ui(12.5, weight: .semibold, relativeTo: .caption1))
                    }
                    .foregroundStyle(InterviewTheme.Color.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(InterviewTheme.Color.questionPill, in: Capsule())
                    .ultraContrastOutline(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(filesLabel.map { "\($0) attached. Show files" } ?? "Attach files")
                Spacer()
                addContextButton
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(InterviewTheme.Color.surface, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(InterviewTheme.Color.hairline, lineWidth: 1))
    }

    private var canAddDraft: Bool { ContextState.adding(draft, to: context.note) != nil }

    /// The primary action once there is something to add: accent-coloured, disabled while the field is
    /// blank (or only repeats what was already added), so one tap adds it once.
    private var addContextButton: some View {
        Button(action: addDraft) {
            Text("Add context")
                .font(InterviewTheme.Font.ui(13, weight: .semibold, relativeTo: .footnote))
                .foregroundStyle(InterviewTheme.Color.onPrimary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(InterviewTheme.Color.primary.opacity(canAddDraft ? 1 : 0.35), in: Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!canAddDraft)
        .accessibilityLabel("Add context")
        .accessibilityHint("Adds what you typed to this interview's context for the next answers")
        .accessibilityIdentifier("add-context")
    }

    /// Adds the draft to the interview's context once, then clears the field and puts the keyboard
    /// away. Nothing is generated: the context is used by the next Generate. With nothing to add
    /// (Done on an empty field) the keyboard still goes away: typing is never required to leave.
    private func addDraft() {
        guard let updated = ContextState.adding(draft, to: context.note) else {
            isEditingNote = false
            return
        }
        contextAnchors[draft.trimmingCharacters(in: .whitespacesAndNewlines)] = lines.last?.id
        onNoteChanged(updated)
        draft = ""
        isEditingNote = false
    }
}

/// The collapsed Live transcript: **exactly three lines of height, always**, showing the newest speech.
///
/// The height is reserved from the font's own metrics (three empty lines, `reservesSpace`), never
/// measured from the transcript, so a long partial cannot push it to four or five lines before the
/// next revision shrinks it again. The newest text sits at the bottom and older text is clipped at the
/// top; transcript updates carry no animation, so only expanding or collapsing changes the height.
struct CollapsedTranscriptPreview: View {
    let lines: [TranscriptLine]

    static let lineCount = 3
    /// One step below the expanded transcript's 14 pt, still comfortable on a small iPhone.
    static let font = InterviewTheme.Font.ui(13, relativeTo: .footnote)

    var body: some View {
        // The fixed box: three lines of the preview font, whatever the text is.
        Text(verbatim: "\n\n")
            .font(Self.font)
            .lineLimit(Self.lineCount, reservesSpace: true)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottomLeading) {
                Text(Self.previewText(from: lines))
                    .font(Self.font)
                    .foregroundStyle(InterviewTheme.Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .bottomLeading)
                    // Clipping hides the older text above the box but does not stop it taking touches or
                    // accessibility focus: without these it covered the header and swallowed the tap
                    // that expands the transcript.
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .clipped()
            .contentShape(Rectangle())
            // Older text fades as it leaves the top edge, so the cut reads as scrolled, not broken.
            .mask(
                LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0),
                                       .init(color: .black, location: 0.28)],
                               startPoint: .top, endPoint: .bottom)
            )
            .transaction { $0.animation = nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(lines.last?.text ?? "No speech yet")
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("transcript-preview")
    }

    /// The newest speech, as one flowing text: the last lines, newest last, bounded so a long
    /// interview never lays out more than a few lines' worth of text here.
    static func previewText(from lines: [TranscriptLine], maxCharacters: Int = 320) -> String {
        var parts: [String] = []
        var count = 0
        for line in lines.reversed() {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            parts.insert(text, at: 0)
            count += text.count + 1
            if count >= maxCharacters { break }
        }
        let joined = parts.joined(separator: " ")
        return joined.count > maxCharacters ? String(joined.suffix(maxCharacters)) : joined
    }
}

