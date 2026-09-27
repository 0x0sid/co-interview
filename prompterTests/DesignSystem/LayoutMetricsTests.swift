import CoreGraphics
import Testing
@testable import prompter

/// Compact metrics on small iPhones, regular on the rest — from the window's real size.
struct LayoutMetricsTests {
    @Test(arguments: [
        (CGSize(width: 375, height: 667), true),    // iPhone SE (2nd/3rd gen)
        (CGSize(width: 320, height: 568), true),    // iPhone SE (1st gen)
        (CGSize(width: 375, height: 812), true),    // iPhone 12/13 mini: narrow
        (CGSize(width: 393, height: 852), false),   // iPhone 15/16
        (CGSize(width: 430, height: 932), false),   // Pro Max
    ])
    func smallPhonesAreCompact(_ size: CGSize, _ compact: Bool) {
        #expect(LayoutMetrics.forSize(size).isCompact == compact, "\(size)")
    }

    @Test
    func compactTightensSpaceButKeepsTapTargets() {
        let regular = LayoutMetrics.regular, compact = LayoutMetrics.compact
        #expect(compact.sectionSpacing < regular.sectionSpacing)
        #expect(compact.cardPadding < regular.cardPadding)
        #expect(compact.headerHeight < regular.headerHeight)
        #expect(compact.previewMaxHeight < regular.previewMaxHeight)
        #expect(compact.primaryControlHeight >= 44, "the primary action stays a safe tap target")
        #expect(compact.headerHeight >= 44)
        #expect(compact.bodySize >= 13, "text shrinks least")
    }

    @Test
    func anUnmeasuredWindowIsRegular() {
        #expect(!LayoutMetrics.forSize(.zero).isCompact)
    }
}
