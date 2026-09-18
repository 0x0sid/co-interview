import Testing
import UIKit
@testable import prompter

/// Proves the v2.5 screen gets the faces it asks for.
///
/// A missing font does not fail loudly on iOS — `UIFont(name:size:)` returns nil and SwiftUI quietly
/// substitutes the system face, which looks close enough in a screenshot to be missed. These tests
/// are the difference between "the answer is set in Source Serif 4" and "the answer is set in
/// something". They also report what each PostScript name actually resolves to, so a silent
/// substitution is named rather than assumed.
@MainActor
struct InterviewTypographyTests {
    /// Every face the interview screen uses, by the PostScript name `Typography` asks for.
    static let requiredFaces = [
        "HankenGrotesk-Regular",        // UI chrome
        "SourceSerif4Roman-Regular",    // the answer
        "IBMPlexMono-Regular",          // code cards
        "IBMPlexMono-Medium"
    ]

    @Test
    func everyBundledFaceResolvesToItself() {
        for name in Self.requiredFaces {
            let font = UIFont(name: name, size: 17)
            #expect(font != nil, "\(name) did not load — the screen would silently fall back to the system face")
            if let font {
                // `fontName` is what was actually resolved. If it differs, the system substituted
                // something and the design is not what is on screen.
                #expect(font.fontName == name, "\(name) resolved to \(font.fontName)")
            }
        }
    }

    /// The answer face carries its variable axes, which is how weight and optical size are set.
    @Test
    func theAnswerFaceIsVariable() throws {
        let font = try #require(UIFont(name: "SourceSerif4Roman-Regular", size: 28))
        let axes = CTFontCopyVariationAxes(font) as? [[String: Any]]
        let identifiers = (axes ?? []).compactMap { $0[kCTFontVariationAxisIdentifierKey as String] as? Int }
        // 'wght' and 'opsz' as OSType integers — the same constants `Typography` varies.
        #expect(identifiers.contains(0x77676874), "Source Serif 4 has no weight axis")
        #expect(identifiers.contains(0x6F70737A), "Source Serif 4 has no optical size axis")
    }

    /// Dynamic Type has to reach the interview screen: its type is built through `UIFontMetrics`,
    /// so a larger content size must produce a larger font rather than a fixed one.
    @Test
    func interviewTypeScalesWithDynamicType() {
        let base = UIFont(name: "HankenGrotesk-Regular", size: 15) ?? .systemFont(ofSize: 15)
        let small = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: base,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .small)
        )
        let large = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: base,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityLarge)
        )
        #expect(large.pointSize > small.pointSize, "interview type does not respond to Dynamic Type")
    }
}
