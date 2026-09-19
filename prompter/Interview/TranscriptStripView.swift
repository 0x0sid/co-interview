import PhotosUI
import SwiftUI

/// The live transcript at the top of the screen, in its two states.
///
/// **Collapsed** is the working state: the last detected question, underlined in the primary colour,
/// and the line currently being spoken beneath it in muted grey. Two lines, no scrolling, nothing to
/// manage.
///
/// **Expanded** shows more of the conversation and reveals the Context panel. Collapsing it is a
/// view change only — the note and the attached images stay exactly where they were.
struct TranscriptStripView: View {
    let lines: [TranscriptLine]
    @Binding var isExpanded: Bool
    @Binding var isContextOpen: Bool
    let context: ContextState
    let onSelectQuestion: (UUID) -> Void
    let onAddImage: (ContextImage) -> Void
    let onRemoveImage: (UUID) -> Void
    let onNoteChanged: (String) -> Void
    /// Said **before** anything is generated when part of the attached context cannot actually be
    /// used — so nobody attaches five screenshots and assumes the model read them.
    var limitationMessage: String? = nil
    /// Per-attachment state text, so each thumbnail says what happened to it rather than leaving the
    /// user to guess whether it was used.
    var attachmentStates: [UUID: String] = [:]

    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var note: String = ""

    /// **Collapsed is exactly two lines**: the last detected question and the newest thing said. It
    /// never grows, so the answer below it never moves as the conversation continues. Expanding
    /// shows a longer tail of the same transcript.
    private var visibleLines: [TranscriptLine] {
        guard !isExpanded else { return Array(lines.suffix(6)) }
        let newest = lines.last
        let lastQuestion = lines.last(where: { $0.isDetectedQuestion && $0.id != newest?.id })
        return [lastQuestion, newest].compactMap { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { isExpanded.toggle() }
                } label: {
                    HStack {
                        Text("Live transcript")
                            .font(InterviewTheme.Font.ui(15, weight: .medium, relativeTo: .subheadline))
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(InterviewTheme.Color.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse live transcript" : "Expand live transcript")

                ForEach(visibleLines) { line in
                    lineView(line)
                }
            }

            if isExpanded {
                contextPanel
            }
        }
        .onAppear { note = context.note }
    }

    @ViewBuilder
    private func lineView(_ line: TranscriptLine) -> some View {
        if line.isDetectedQuestion {
            Button {
                if let id = line.questionID { onSelectQuestion(id) }
            } label: {
                Text(line.text)
                    .font(InterviewTheme.Font.ui(14, relativeTo: .subheadline))
                    .foregroundStyle(InterviewTheme.Color.primary)
                    .underline(true, color: InterviewTheme.Color.primary.opacity(0.55))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(line.questionID == nil)
            .accessibilityHint(line.questionID == nil ? "" : "Opens this question")
        } else {
            Text(line.text)
                .font(InterviewTheme.Font.ui(14, relativeTo: .subheadline))
                .foregroundStyle(InterviewTheme.Color.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Context

    /// Notes and images the user wants the answers to take into account.
    ///
    /// **In memory only.** Nothing here is written to disk or sent anywhere in this build; it is the
    /// shape the real context will take, filled with whatever the user attaches this session.
    private var contextPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isContextOpen.toggle() }
            } label: {
                HStack {
                    Text("Context")
                        .font(InterviewTheme.Font.ui(15, weight: .medium, relativeTo: .subheadline))
                    Spacer()
                    Text(context.counterText)
                        .font(InterviewTheme.Font.ui(11.5, weight: .medium, relativeTo: .caption2))
                        .monospacedDigit()
                    Image(systemName: isContextOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(InterviewTheme.Color.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isContextOpen {
                HStack(spacing: 10) {
                    TextField("Anything the answers should know", text: $note)
                        .font(InterviewTheme.Font.ui(14, relativeTo: .subheadline))
                        .foregroundStyle(InterviewTheme.Color.ink)
                        .onChange(of: note) { _, newValue in onNoteChanged(newValue) }
                    PhotosPicker(selection: $pickerSelection, maxSelectionCount: ContextState.imageLimit, matching: .images) {
                        Image(systemName: "photo")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(InterviewTheme.Color.muted)
                    }
                    .disabled(context.isFull)
                    .accessibilityLabel(context.isFull ? "Image limit reached" : "Add an image")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(InterviewTheme.Color.background, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(InterviewTheme.Color.hairline, lineWidth: 1))

                if let limitationMessage {
                    Text(limitationMessage)
                        .font(InterviewTheme.Font.ui(11.5, relativeTo: .caption2))
                        .foregroundStyle(InterviewTheme.Color.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !context.images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(context.images) { image in
                                VStack(spacing: 3) {
                                    thumbnail(image)
                                    if let state = attachmentStates[image.id] {
                                        Text(state)
                                            .font(InterviewTheme.Font.ui(9.5, relativeTo: .caption2))
                                            .foregroundStyle(InterviewTheme.Color.muted)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                            .frame(width: 66)
                                    }
                                }
                            }
                        }
                        .padding(.top, 5)
                        .padding(.trailing, 5)
                    }
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(InterviewTheme.Color.surface, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(InterviewTheme.Color.hairline, lineWidth: 1))
        .onChange(of: pickerSelection) { _, items in
            Task { await load(items) }
        }
    }

    private func thumbnail(_ image: ContextImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let uiImage = UIImage(data: image.data) {
                    Image(uiImage: uiImage).resizable().scaledToFill()
                } else {
                    InterviewTheme.Color.hairline
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 9))

            Button {
                onRemoveImage(image.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(InterviewTheme.Color.background)
                    .frame(width: 17, height: 17)
                    .background(InterviewTheme.Color.ink, in: Circle())
            }
            .offset(x: 5, y: -5)
            .accessibilityLabel("Remove image")
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            onAddImage(ContextImage(data: data))
        }
        pickerSelection = []
    }
}
