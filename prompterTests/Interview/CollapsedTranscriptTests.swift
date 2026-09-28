import SwiftUI
import Testing
import UIKit
@testable import prompter

/// The collapsed Live transcript is exactly three lines tall from the start — whatever the transcript
/// holds — and always shows the newest speech. Heights are measured from the real views.
@MainActor
struct CollapsedTranscriptTests {
    static let width: CGFloat = 339                        // an iPhone SE's content width

    static func line(_ text: String, final: Bool = true) -> TranscriptLine { TranscriptLine(text: text, isFinal: final) }

    static func height<V: View>(_ view: V, width: CGFloat = width) -> CGFloat {
        UIHostingController(rootView: view.frame(width: width)).sizeThatFits(in: CGSize(width: width, height: .infinity)).height
    }

    static func previewHeight(_ lines: [TranscriptLine]) -> CGFloat { height(CollapsedTranscriptPreview(lines: lines)) }

    static let long = "Could you walk me through how you would design a rate limiter for a public API that has to serve millions of requests, and what you would do about bursts, fairness between tenants and the storage behind the counters?"

    @Test
    func theCollapsedPreviewIsThreeLinesTallWhateverItHolds() {
        let oneLine = Self.previewHeight([Self.line("Tell me about yourself.")])
        let empty = Self.previewHeight([])
        let many = Self.previewHeight((0..<30).map { Self.line("Line \($0): \(Self.long)") })
        #expect(oneLine == empty && oneLine == many, "heights: empty \(empty), one line \(oneLine), long \(many)")

        // Exactly three lines of the preview font, not more.
        let lineHeight = UIFont.preferredFont(forTextStyle: .footnote).lineHeight
        #expect(oneLine < lineHeight * 4, "at most three lines tall (\(oneLine) vs line \(lineHeight))")
        #expect(oneLine > lineHeight * 2, "reserves three lines even for one line of speech")
    }

    @Test
    func streamingPartialsNeverChangeTheCollapsedHeight() {
        var heights: Set<CGFloat> = []
        var partial = ""
        for word in Self.long.split(separator: " ") {                   // a partial growing word by word
            partial += partial.isEmpty ? String(word) : " \(word)"
            heights.insert(Self.previewHeight([Self.line("Earlier answer.", final: true), Self.line(partial, final: false)]))
        }
        #expect(heights.count == 1, "the collapsed height moved while speech streamed: \(heights.sorted())")
    }

    @Test
    func theNewestSpeechIsWhatThePreviewShows() {
        let lines = (0..<40).map { Self.line("Older line \($0) about something else entirely.") } + [Self.line("The newest question?")]
        let text = CollapsedTranscriptPreview.previewText(from: lines)
        #expect(text.hasSuffix("The newest question?"), "the latest speech is last and kept")
        #expect(!text.contains("Older line 0 "), "the beginning of a long transcript is not what is shown")
        #expect(text.count <= 320, "bounded: a long interview never lays out a page of text here")
    }

    @Test
    func expandingAndCollapsingChangeTheStripHeight() {
        let lines = (0..<12).map { Self.line("Line \($0): \(Self.long)") }
        func strip(_ expanded: Bool) -> some View {
            TranscriptStripView(lines: lines, isExpanded: .constant(expanded), isContextOpen: .constant(false),
                                context: ContextState(), onNoteChanged: { _ in })
        }
        let collapsed = Self.height(strip(false))
        let expanded = Self.height(strip(true))
        #expect(expanded > collapsed, "expanded \(expanded) vs collapsed \(collapsed)")
        #expect(collapsed == Self.height(TranscriptStripView(lines: [Self.line("Hi.")], isExpanded: .constant(false),
                                                             isContextOpen: .constant(false), context: ContextState(),
                                                             onNoteChanged: { _ in })),
                "the collapsed strip is the same height for one short line and a long transcript")
    }

    @Test
    func theExpandedFeedStillCarriesTheFullHistory() {
        #expect(TranscriptStripView.expandedLineLimit >= 300)
    }
}
