import SwiftUI
import CoreText

enum Typography {
    enum Weight {
        case light
        case regular
        case medium
        case semibold
        case bold
    }

    /// §13 v2's user-selectable prompt reading face — Hanken Grotesk (default, matches the UI
    /// face) or Source Serif 4 (the liseuse serif option), a real product feature not
    /// decoration.
    enum ReadingFace {
        case hankenGrotesk
        case sourceSerif4
    }

    /// Four-char-code identifiers for OpenType variation axes. Verified against CoreText/
    /// CTFont.h: kCTFontVariationAxisIdentifierKey values are the OSType-style axis tag as an
    /// integer (e.g. 'wght' = 0x77676874, computed the same way as 'opsz' = 0x6F70737A below).
    private static let weightAxisIdentifier = 0x77676874
    private static let opticalSizeAxisIdentifier = 0x6F70737A

    static func display(_ size: CGFloat, weight: Weight = .bold) -> Font {
        variableFont(postScriptName: "SpaceGrotesk-Light", size: size, variations: [weightAxisIdentifier: spaceGroteskWeight(weight)])
    }

    /// §13 v2's UI face — Hanken Grotesk replaces Inter here as of M5 (the migration note in
    /// docs/BUILD_SPEC.md §13 and docs/DECISIONS.md 2026-08-14).
    static func body(_ size: CGFloat, weight: Weight = .regular) -> Font {
        hankenGrotesk(size, weight: weight)
    }

    static func mono(_ size: CGFloat, weight: Weight = .regular) -> Font {
        switch weight {
        case .light, .regular:
            return .custom("IBMPlexMono-Regular", size: size)
        case .medium, .semibold, .bold:
            return .custom("IBMPlexMono-Medium", size: size)
        }
    }

    /// §13 v2's UI face — Hanken Grotesk. PostScript name (`HankenGrotesk-Regular`) and its
    /// `wght` axis range (100-900, default 400) verified directly against the downloaded font
    /// file via fontTools, not memory.
    static func hankenGrotesk(_ size: CGFloat, weight: Weight = .regular) -> Font {
        variableFont(postScriptName: "HankenGrotesk-Regular", size: size, variations: [weightAxisIdentifier: hankenGroteskWeight(weight)])
    }

    /// §13 v2's serif reading-face option — Source Serif 4. PostScript name
    /// (`SourceSerif4Roman-Regular`) and its `wght` (200-900) / `opsz` (8-60) axes verified
    /// directly against the downloaded font file via fontTools. `opsz` is tied to the point
    /// size rather than fixed — that axis exists specifically so small (text) sizes and large
    /// (display) sizes each get strokes optimized for their own size, which is the font's own
    /// intended use, not an arbitrary choice.
    static func sourceSerif4(_ size: CGFloat, weight: Weight = .regular) -> Font {
        variableFont(
            postScriptName: "SourceSerif4Roman-Regular",
            size: size,
            variations: [
                weightAxisIdentifier: sourceSerif4Weight(weight),
                opticalSizeAxisIdentifier: min(max(size, 8), 60),
            ]
        )
    }

    /// Dispatches to whichever face the reader has selected for the prompt screen (§13 v2,
    /// §12.6) — not called from any screen yet, see `ReadingFace`'s doc comment.
    static func reading(_ size: CGFloat, weight: Weight = .regular, face: ReadingFace) -> Font {
        switch face {
        case .hankenGrotesk: hankenGrotesk(size, weight: weight)
        case .sourceSerif4: sourceSerif4(size, weight: weight)
        }
    }

    private static func spaceGroteskWeight(_ weight: Weight) -> CGFloat {
        switch weight {
        case .light: 300
        case .regular: 400
        case .medium: 500
        case .semibold: 500
        case .bold: 700
        }
    }

    private static func hankenGroteskWeight(_ weight: Weight) -> CGFloat {
        switch weight {
        case .light: 300
        case .regular: 400
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        }
    }

    private static func sourceSerif4Weight(_ weight: Weight) -> CGFloat {
        switch weight {
        case .light: 300
        case .regular: 400
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        }
    }

    // MARK: - Dynamic Type (v2.5 interview screen)
    //
    // The functions above return a fixed-size `Font`, which is right for the teleprompter: its size
    // is the reader's own pinch-to-scale setting, and letting the system scale it too would fight
    // that. The interview screen has no such control, so its type follows Dynamic Type — these
    // overloads scale the same bundled faces through `UIFontMetrics`, which is how a custom
    // `UIFont` participates in Dynamic Type (the `relativeTo:` of `Font.custom`). Additive by
    // design: nothing above changes, so script reading is untouched.

    static func scaledHankenGrotesk(_ size: CGFloat, weight: Weight = .regular, relativeTo textStyle: UIFont.TextStyle = .body) -> Font {
        scaledVariableFont(
            postScriptName: "HankenGrotesk-Regular", size: size,
            variations: [weightAxisIdentifier: hankenGroteskWeight(weight)], relativeTo: textStyle
        )
    }

    static func scaledSourceSerif4(_ size: CGFloat, weight: Weight = .regular, relativeTo textStyle: UIFont.TextStyle = .body) -> Font {
        scaledVariableFont(
            postScriptName: "SourceSerif4Roman-Regular", size: size,
            variations: [
                weightAxisIdentifier: sourceSerif4Weight(weight),
                opticalSizeAxisIdentifier: min(max(size, 8), 60),
            ],
            relativeTo: textStyle
        )
    }

    /// `Font.custom(_:size:relativeTo:)` already scales, so the mono face needs no metrics dance.
    static func scaledMono(_ size: CGFloat, weight: Weight = .regular, relativeTo textStyle: Font.TextStyle = .footnote) -> Font {
        switch weight {
        case .light, .regular:
            return .custom("IBMPlexMono-Regular", size: size, relativeTo: textStyle)
        case .medium, .semibold, .bold:
            return .custom("IBMPlexMono-Medium", size: size, relativeTo: textStyle)
        }
    }

    private static func scaledVariableFont(
        postScriptName: String,
        size: CGFloat,
        variations: [Int: CGFloat],
        relativeTo textStyle: UIFont.TextStyle
    ) -> Font {
        let base = variableUIFont(postScriptName: postScriptName, size: size, variations: variations)
        return Font(UIFontMetrics(forTextStyle: textStyle).scaledFont(for: base))
    }

    private static func variableFont(postScriptName: String, size: CGFloat, variations: [Int: CGFloat]) -> Font {
        Font(variableUIFont(postScriptName: postScriptName, size: size, variations: variations))
    }

    private static func variableUIFont(postScriptName: String, size: CGFloat, variations: [Int: CGFloat]) -> UIFont {
        let variationAttributeName = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        let attributes: [UIFontDescriptor.AttributeName: Any] = [
            .name: postScriptName,
            variationAttributeName: variations,
        ]
        let descriptor = UIFontDescriptor(fontAttributes: attributes)
        return UIFont(descriptor: descriptor, size: size)
    }
}
