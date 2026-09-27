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
    @Binding var isContextOpen: Bool
    let context: ContextState
    let onNoteChanged: (String) -> Void
    /// "1 file", "2 files" — images and documents together — or nil when nothing is attached.
    var filesLabel: String? = nil
    /// Opens the session's file list and import actions.
    var onOpenFiles: () -> Void = {}
    /// Changes when "Add context" asks for the keyboard in the note field.
    var noteFocusRequest: Int = 0

    @State private var note: String = ""
    /// While the note has the keyboard, neither panel collapses under the user. Losing a half-typed
    /// note to a mistimed tap on a chevron is not a trade worth making for a few points of height.
    @FocusState private var isEditingNote: Bool
    /// The expanded transcript's natural height, so a short transcript takes only the room it needs.
    @State private var expandedContentHeight: CGFloat = 0
    /// Terminal-style following of the newest speech in the expanded transcript.
    @State private var follow = TranscriptFollow()
    /// Where the expanded transcript is: at (or within a few points of) its last line.
    @State private var isAtBottom = true

    /// **Collapsed is exactly two lines**: the two newest things said. It never grows, so the answer
    /// below it never moves as the conversation continues. Expanding shows a longer tail.
    private var visibleLines: [TranscriptLine] {
        Array(lines.suffix(isExpanded ? Self.expandedLineLimit : 2))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                header

                if isExpanded {
                    expandedFeed
                } else {
                    ForEach(visibleLines) { line in
                        lineView(line)
                    }
                }
            }

            if isExpanded {
                contextPanel
            }
        }
        .onAppear { note = context.note }
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
        guard !isEditingNote else { return }
        withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        if isExpanded { follow.jumpToLatest() }
    }

    /// Like a terminal: opens at the newest line, stays pinned to it while speech arrives, and stops
    /// following — without being pulled back down — once the reader scrolls up. "↓ Latest" returns.
    private var expandedFeed: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(visibleLines) { line in
                        lineView(line)
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
            .frame(height: min(max(expandedContentHeight, 1), Self.expandedMaxHeight))
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

    // MARK: Context

    /// The note and the files the answers should take into account.
    ///
    /// Files are a count and a button here — "2 files" — and the list, their states and the import
    /// actions live in the Files sheet. The note stays inline because it is typed mid-interview.
    private var contextPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    guard !isEditingNote else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { isContextOpen.toggle() }
                } label: {
                    HStack {
                        Text("Context")
                            .font(InterviewTheme.Font.ui(15, weight: .medium, relativeTo: .subheadline))
                        Image(systemName: isContextOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(InterviewTheme.Color.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onOpenFiles) {
                    HStack(spacing: 5) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 13, weight: .semibold))
                        if let filesLabel {
                            Text(filesLabel)
                                .font(InterviewTheme.Font.ui(12.5, weight: .semibold, relativeTo: .caption1))
                        }
                    }
                    .foregroundStyle(InterviewTheme.Color.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(InterviewTheme.Color.questionPill, in: Capsule())
                    .ultraContrastOutline(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(filesLabel.map { "\($0) attached. Show files" } ?? "Attach files")
            }

            if isContextOpen {
                TextField("Anything the answers should know", text: $note)
                    .focused($isEditingNote)
                    .font(InterviewTheme.Font.ui(14, relativeTo: .subheadline))
                    .foregroundStyle(InterviewTheme.Color.ink)
                    .onChange(of: note) { _, newValue in onNoteChanged(newValue) }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(InterviewTheme.Color.background, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(InterviewTheme.Color.hairline, lineWidth: 1))
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(InterviewTheme.Color.surface, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(InterviewTheme.Color.hairline, lineWidth: 1))
    }
}
