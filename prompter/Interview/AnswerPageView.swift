import SwiftUI

/// One question page: the question bar with its inline `n/N`, the answer, and the Follow-ups link.
///
/// **The answer is rendered by the inherited reader, not by a new one.** `ScriptStyling.sentenceBlocks`
/// greys exactly the words the reader is known to have pronounced, driven by this page's
/// `ReadingAlignment` — the same path the teleprompter uses.
///
/// **Blocks keep their original order.** A code card that the answer put between two paragraphs is
/// rendered between those paragraphs, not collected at the end. The aligned text is the prose only,
/// so the code is visible but never greyed out as if it had been spoken: `proseText` joins the prose
/// blocks in order, and paragraph *i* of that text is prose block *i* here.
struct AnswerPageView: View {
    let question: InterviewQuestion
    let counterText: String
    let alignment: ReadingAlignment?
    let isAutoScrolling: Bool
    let isGenerating: Bool
    let failureMessage: String?
    let onGenerate: () -> Void
    let onFollowUps: () -> Void
    let onBeginManualScroll: () -> Void
    let onEndManualScroll: (Range<Int>?) -> Void
    let onResumeFollowing: () -> Void

    private var answer: InterviewAnswer? { question.selectedAnswer }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                questionBar

                if let answer, !answer.blocks.isEmpty {
                    answerBlocks(answer)
                    if answer.version > 1, answer.isComplete {
                        Text("v\(answer.version) · Generated just now")
                            .font(InterviewTheme.Font.ui(12, relativeTo: .caption1))
                            .foregroundStyle(InterviewTheme.Color.muted)
                    }
                } else if isGenerating {
                    generatingState
                } else {
                    emptyState
                }

                if let failureMessage {
                    Text(failureMessage)
                        .font(InterviewTheme.Font.ui(13, relativeTo: .footnote))
                        .foregroundStyle(InterviewTheme.Color.muted)
                }

                if !question.followUps.isEmpty, answer?.isComplete == true {
                    followUpsLink
                }

                if !isAutoScrolling {
                    resumeFollowingButton
                }
            }
            // The floating toolbar sits over the bottom of the page, so the content gets its full
            // height back as padding: the last line of an answer and the Follow-ups link can always
            // be scrolled clear of the pill rather than hiding under it.
            .padding(.bottom, InterviewTheme.Metric.pillClearance)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 6).onChanged { _ in onBeginManualScroll() }
        )
        .onScrollPhaseChange { _, phase in
            // The reader keeps the scroll until the view settles; only then is the region they chose
            // meaningful (see `ScrollOwnership.endManualInteraction`).
            guard phase == .idle else { return }
            onEndManualScroll(visibleTokenRange)
        }
    }

    /// Without per-block geometry the visible range cannot be measured honestly, and
    /// `ScrollOwnership` deliberately treats "unmeasured" as "stay detached". Passing the whole text
    /// would make its in-region check vacuous, so this answers only when there is nothing to be
    /// wrong about — a short answer that fits on one screen.
    private var visibleTokenRange: Range<Int>? {
        guard let alignment, alignment.scriptIndex.tokens.count <= 60 else { return nil }
        return 0..<alignment.scriptIndex.tokens.count
    }

    // MARK: Question bar

    /// The question and its position, in one bar. There is no separate "Question 2/3" row anywhere
    /// on the screen — the counter lives here.
    private var questionBar: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(question.text)
                .font(InterviewTheme.Font.ui(15, weight: .semibold, relativeTo: .subheadline))
                .foregroundStyle(InterviewTheme.Color.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(counterText)
                .font(InterviewTheme.Font.ui(12, weight: .medium, relativeTo: .caption1))
                .monospacedDigit()
                .foregroundStyle(InterviewTheme.Color.muted)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(InterviewTheme.Color.questionPill, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(InterviewTheme.Color.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Question \(counterText). \(question.text)")
    }

    // MARK: Answer

    /// One block, paired with which paragraph of the aligned text it is (prose only). Computed once,
    /// outside the view builder, so the pairing cannot depend on how often SwiftUI re-evaluates a body.
    private struct PositionedBlock: Identifiable {
        let id: Int
        let block: AnswerBlock
        let proseIndex: Int?
    }

    private func positionedBlocks(_ answer: InterviewAnswer) -> [PositionedBlock] {
        var proseIndex = 0
        return answer.blocks.enumerated().map { offset, block in
            switch block {
            case .prose:
                defer { proseIndex += 1 }
                return PositionedBlock(id: offset, block: block, proseIndex: proseIndex)
            case .code:
                return PositionedBlock(id: offset, block: block, proseIndex: nil)
            }
        }
    }

    @ViewBuilder
    private func answerBlocks(_ answer: InterviewAnswer) -> some View {
        let paragraphs = alignment.map { styledParagraphs(for: $0) }

        VStack(alignment: .leading, spacing: InterviewTheme.Metric.answerParagraphSpacing) {
            ForEach(positionedBlocks(answer)) { positioned in
                switch positioned.block {
                case .prose(let text):
                    if let paragraphs, let index = positioned.proseIndex, index < paragraphs.count {
                        // Read mode: the whole paragraph as one Text, so it flows as a paragraph
                        // while individual spoken words still fade.
                        paragraphs[index]
                            .font(InterviewTheme.Font.answer())
                            .lineSpacing(InterviewTheme.Metric.answerLineSpacing)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(text)
                            .font(InterviewTheme.Font.answer())
                            .lineSpacing(InterviewTheme.Metric.answerLineSpacing)
                            .foregroundStyle(InterviewTheme.Color.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .code(let code):
                    CodeCardView(code: code)
                }
            }
        }
    }

    /// One styled `Text` per paragraph of the aligned answer.
    ///
    /// **A paragraph is one `Text`, not one view per sentence.** Laying each sentence out separately
    /// would break the paragraph: every sentence would start on a new line instead of flowing on from
    /// the previous one. So the paragraph is sliced out of the styled attributed string by its own
    /// character range, which keeps the original spacing exactly as written and still greys
    /// individual spoken words.
    ///
    /// Paragraph *i* corresponds to prose block *i*, because `proseText` joins the prose blocks with
    /// a blank line and nothing else.
    private func styledParagraphs(for alignment: ReadingAlignment) -> [Text] {
        let attributed = ScriptStyling.styledAttributedString(
            rawText: alignment.text,
            scriptIndex: alignment.scriptIndex,
            cursor: alignment.cursor,
            spokenTokenIndices: alignment.spokenTokenIndices,
            palette: InterviewTheme.readingPalette
        )

        // The character span of each paragraph, from the sentences that make it up.
        var spans: [(start: Int, end: Int)] = []
        for sentence in alignment.scriptIndex.sentences {
            if sentence.paragraphIndex == spans.count - 1, var last = spans.last {
                last.end = max(last.end, sentence.rangeEnd)
                spans[spans.count - 1] = last
            } else if sentence.paragraphIndex >= spans.count {
                spans.append((sentence.rangeStart, sentence.rangeEnd))
            }
        }

        return spans.compactMap { span in
            let start = String.Index(utf16Offset: span.start, in: alignment.text)
            let end = String.Index(utf16Offset: span.end, in: alignment.text)
            guard start <= end, end <= alignment.text.endIndex,
                  let range = Range(start..<end, in: attributed) else { return nil }
            return Text(AttributedString(attributed[range]))
        }
    }

    // MARK: States

    /// A detected question with no answer yet. It says what to do rather than pretending to think.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No answer yet.")
                .font(InterviewTheme.Font.answer(24))
                .foregroundStyle(InterviewTheme.Color.muted)
            Button(action: onGenerate) {
                HStack(spacing: 7) {
                    SparkleShape()
                        .fill(InterviewTheme.Color.onPrimary)
                        .frame(width: 15, height: 15)
                    Text("Generate an answer")
                        .font(InterviewTheme.Font.ui(14, weight: .semibold, relativeTo: .subheadline))
                        .foregroundStyle(InterviewTheme.Color.onPrimary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(InterviewTheme.Color.primary, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Generate an answer for this question")
        }
    }

    private var generatingState: some View {
        HStack(spacing: 9) {
            if !InterviewTestingFlags.quietMotion {
                ProgressView().controlSize(.small)
            }
            Text("Writing an answer…")
                .font(InterviewTheme.Font.ui(14, relativeTo: .subheadline))
                .foregroundStyle(InterviewTheme.Color.muted)
        }
    }

    private var followUpsLink: some View {
        Button(action: onFollowUps) {
            HStack(spacing: 5) {
                Text("Follow-ups")
                    .font(InterviewTheme.Font.ui(13, weight: .semibold, relativeTo: .footnote))
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(InterviewTheme.Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var resumeFollowingButton: some View {
        Button(action: onResumeFollowing) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 11, weight: .bold))
                Text("Resume following")
                    .font(InterviewTheme.Font.ui(13, weight: .semibold, relativeTo: .footnote))
            }
            .foregroundStyle(InterviewTheme.Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(InterviewTheme.Color.questionPill, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The code card. Solid near-black on light, a bordered transparent panel on dark — the board's own
/// treatment, so code reads as code in both appearances.
///
/// It is **never** part of the text the reader follows: `InterviewAnswer.proseText` excludes it by
/// construction, so there is no way for a code sample to be greyed out as if it had been spoken.
struct CodeCardView: View {
    let code: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var didCopy = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(InterviewTheme.Font.code())
                    .foregroundStyle(InterviewTheme.Color.codeInk)
                    .lineSpacing(12.5 * 0.5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                UIPasteboard.general.string = code
                didCopy = true
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(InterviewTheme.Color.codeInk.opacity(0.7))
                    .padding(10)
            }
            .accessibilityLabel("Copy code")
        }
        .background {
            if colorScheme == .dark {
                RoundedRectangle(cornerRadius: 13).stroke(InterviewTheme.Color.hairline, lineWidth: 1)
            } else {
                RoundedRectangle(cornerRadius: 13).fill(InterviewTheme.Color.codeCardLight)
            }
        }
    }
}
