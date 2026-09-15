import Testing
import Foundation
import SwiftUI
@testable import prompter

/// Presentation requirement 2: the line being read stays near the top, and the page follows
/// **continuously** — including all the way through a long sentence.
///
/// The previous mechanism asked `scrollTo(id:anchor:)` for a position. That API can only produce
/// `blockTop = a·(V − H)` with `a ∈ [0, 1]`, so a block's top can never rise above the viewport
/// top — and holding the reading line fixed inside a long sentence needs exactly that. The 2026-09-12
/// device log shows the consequence five times: `anchor=0.000` at progress 0.27, 0.27, 0.42, 0.24,
/// 0.30, each followed by silence until the next sentence began.
///
/// `PromptScreen.readingOffset` computes a content offset instead, which has no unreachable band.
@MainActor
struct ScrollAnchorTests {

    private static let readingLine: CGFloat = 0.12
    private static let viewport: CGFloat = 722      // the device log's measured viewport
    private static let spacing: CGFloat = 4

    private static func offset(block: Int, prefixHeight: CGFloat, heights: [Int: CGFloat], paragraphPadding: CGFloat = 0) -> CGFloat {
        PromptScreen.readingOffset(
            block: block, prefixHeight: prefixHeight, paragraphPadding: paragraphPadding,
            blockHeights: heights, blockSpacing: spacing,
            viewportHeight: viewport, readingLine: readingLine
        )
    }

    /// **The regression, using the device log's own geometry.** Sentence 1 measured 365 pt and the
    /// old anchor saturated at progress 0.27. The offset must keep increasing right through it.
    @Test
    func theTargetKeepsMovingThroughALongSentence() {
        let heights: [Int: CGFloat] = [0: 81, 1: 365, 2: 324, 3: 203]
        var previous = Self.offset(block: 1, prefixHeight: 0, heights: heights)
        var distinct: Set<Int> = []
        for step in 0...10 {
            let line = CGFloat(step) * 36.5
            let value = Self.offset(block: 1, prefixHeight: line, heights: heights)
            #expect(value >= previous - 0.001, "target moved backwards at prefixHeight \(line): \(previous) -> \(value)")
            distinct.insert(Int(value.rounded()))
            previous = value
        }
        #expect(distinct.count >= 8, "target saturated: only \(distinct.count) distinct offsets across a 365 pt sentence")
    }

    /// No saturation at any block height. Block 1 is used because block 0 sits above the reading
    /// line — the page is correctly pinned at the top there, and pinning is not saturation.
    @Test
    func noBlockHeightProducesASaturatedTarget() {
        let candidates: [CGFloat] = [81, 203, 324, 365, 700, 1200]
        for height in candidates {
            let heights: [Int: CGFloat] = [0: 400, 1: height, 2: 200]
            let atStart = Self.offset(block: 1, prefixHeight: 0, heights: heights)
            let atEnd = Self.offset(block: 1, prefixHeight: height, heights: heights)
            #expect(atEnd - atStart == height, "block height \(height): target moved \(atEnd - atStart) pt, expected \(height)")
        }
    }

    /// The reading line sits where it is asked to: a block whose top is already past the reading
    /// line scrolls by exactly the difference.
    @Test
    func theOffsetPlacesTheReadingLineWhereItIsAsked() {
        let heights: [Int: CGFloat] = [0: 100, 1: 100, 2: 100]
        // Block 2's top is at 100 + 4 + 100 + 4 = 208; reading 50 pt into it puts the line at 258.
        let expected: CGFloat = 258 - Self.readingLine * Self.viewport
        #expect(abs(Self.offset(block: 2, prefixHeight: 50, heights: heights) - expected) < 0.01)
    }

    /// Paragraph padding is part of the geometry, not ignored.
    @Test
    func paragraphPaddingShiftsTheTarget() {
        let heights: [Int: CGFloat] = [0: 100, 1: 100]
        let without = Self.offset(block: 1, prefixHeight: 0, heights: heights)
        let with = Self.offset(block: 1, prefixHeight: 0, heights: heights, paragraphPadding: 16)
        #expect(abs((with - without) - 16) < 0.01, "16 pt of paragraph padding must move the target by 16 pt")
    }

    /// The page never scrolls above the top of the content.
    @Test
    func theOffsetNeverGoesNegative() {
        let heights: [Int: CGFloat] = [0: 81, 1: 365]
        #expect(Self.offset(block: 0, prefixHeight: 0, heights: heights) == 0)
        #expect(Self.offset(block: 0, prefixHeight: 40, heights: heights) == 0, "early reading stays pinned at the top rather than scrolling backwards")
    }

    /// **Pacing, not duration-tuning.** Targets arrive one rendered line at a time, so the
    /// animation between them must still be running when the next lands. A linear ramp paced to the
    /// observed interval does that; an ease-out that settles before the next target is what reads as
    /// stepping.
    @Test
    func theFollowingAnimationIsPacedAndBounded() {
        // Clamped below: a burst of targets must not produce a jump.
        let fast = ScrollAnimator.following(interval: 0.01, reduceMotion: false)
        let atMinimum = ScrollAnimator.following(interval: ScrollAnimator.minimumFollowInterval, reduceMotion: false)
        #expect(fast == atMinimum, "a sub-minimum interval must clamp to the minimum, not animate instantly")

        // Clamped above: a long silence must not stretch the next move into a crawl.
        let slow = ScrollAnimator.following(interval: 30, reduceMotion: false)
        let atMaximum = ScrollAnimator.following(interval: ScrollAnimator.maximumFollowInterval, reduceMotion: false)
        #expect(slow == atMaximum, "a long gap must clamp to the maximum, not trail the reader")

        // Reduce Motion degrades rather than disappears.
        #expect(ScrollAnimator.following(interval: 0.5, reduceMotion: true) == .easeInOut(duration: 0.2))

        // Confirmed repositioning stays its own, separate transition.
        #expect(ScrollAnimator.recovery(reduceMotion: false) != ScrollAnimator.following(interval: 0.5, reduceMotion: false),
                "a distant skip must not use the following ramp")
    }
}
