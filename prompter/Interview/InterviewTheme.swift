import SwiftUI

/// Design tokens for the v2.5 interview screen.
///
/// **Deliberately separate from `Theme`.** `Theme` carries Prompter's inherited palette — `paper`
/// `#F7F4EF`, `action` `#216A60` — and the script library, editor and teleprompter are painted with
/// it. v2.5 asks for `#F8F5EF` and `#2F6B5E`, so editing `Theme` would silently repaint every
/// inherited screen. These tokens live here and are used only by `Interview/`.
///
/// Every colour resolves per appearance through one dynamic provider, the same mechanism `Theme`
/// uses, so a single token serves light and dark without branching at the call site.
enum InterviewTheme {
    enum Color {
        /// Screen background. Warm off-white / greenish charcoal.
        static let background = dynamic(light: 0xF8F5EF, dark: 0x1D2120)
        /// Primary: deep teal / pale mint. Carries highlights, the Generate button and detected questions.
        static let primary = dynamic(light: 0x2F6B5E, dark: 0xBEEBDC)
        /// Text on top of `primary`.
        static let onPrimary = dynamic(light: 0xFFFFFF, dark: 0x16211D)
        /// Body text.
        static let ink = dynamic(light: 0x1C201F, dark: 0xECF1EE)
        /// Secondary labels, the counter, spoken-word fading.
        static let muted = dynamic(light: 0x7A807D, dark: 0x8E9995)
        /// Header pieces, context panel, cards.
        static let surface = dynamic(light: 0xFFFFFF, dark: 0x262C2A)
        /// The floating action pill.
        static let pillSurface = dynamic(light: 0xFFFFFF, dark: 0x2A302E)
        static let hairline = dynamic(light: 0xE5E0D6, dark: 0x333A38)
        /// Question pill fill.
        static let questionPill = dynamic(light: 0xE7EEEA, dark: 0x262C2A)
        /// Sparkle inside the question pill — dark on light, white on dark.
        static let questionSparkle = dynamic(light: 0x1C201F, dark: 0xFFFFFF)

        /// **The only red in the design.** Nothing else may use it.
        static let recording = dynamic(light: 0xD93C3C, dark: 0xFF6B6B)
        /// The recording mark when listening is paused: hollow and grey, never red.
        static let recordingPaused = dynamic(light: 0x9A9F9C, dark: 0x6E7A76)

        /// Demo badge. Violet, so it reads as "this is not real" at a glance.
        static let demoBadge = dynamic(light: 0x6C4BD1, dark: 0xB9A4F0)

        /// Code card: a solid near-black card on light, a bordered transparent one on dark.
        static let codeCardLight = SwiftUI.Color(uiColor: UIColor(rgb: 0x14171A))
        static let codeInk = dynamic(light: 0xE9EDEB, dark: 0xD9E2DE)
        static let codeType = dynamic(light: 0x8FD9C4, dark: 0xBEEBDC)
        static let codeKeyword = SwiftUI.Color(uiColor: UIColor(rgb: 0xC7A6F0))

        /// Follow-up likelihood dots. Green, amber, grey — **never red** (§1: red is the recording mark).
        static let likely = dynamic(light: 0x2F8B5E, dark: 0x86D6A8)
        static let possible = dynamic(light: 0xB8801F, dark: 0xE0B36A)
        static let lessLikely = dynamic(light: 0x8A908C, dark: 0x8E9995)

        static func dynamic(light: UInt32, dark: UInt32) -> SwiftUI.Color {
            SwiftUI.Color(uiColor: UIColor { traits in
                UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
            })
        }
    }

    /// Type, all three from the bundled faces, all scaling with Dynamic Type.
    enum Font {
        /// UI chrome — Hanken Grotesk.
        static func ui(_ size: CGFloat, weight: Typography.Weight = .regular, relativeTo style: UIFont.TextStyle = .body) -> SwiftUI.Font {
            Typography.scaledHankenGrotesk(size, weight: weight, relativeTo: style)
        }
        /// The answer — Source Serif 4 at 28pt, the size the board sets.
        static func answer(_ size: CGFloat = 28, weight: Typography.Weight = .regular) -> SwiftUI.Font {
            Typography.scaledSourceSerif4(size, weight: weight, relativeTo: .body)
        }
        /// Code — IBM Plex Mono.
        static func code(_ size: CGFloat = 12.5, weight: Typography.Weight = .regular) -> SwiftUI.Font {
            Typography.scaledMono(size, weight: weight, relativeTo: .footnote)
        }
    }

    enum Metric {
        /// Line height of the answer, as a multiple of its size (the board's 1.3).
        static let answerLineHeight: CGFloat = 1.3
        /// Extra leading needed to reach that line height.
        ///
        /// **Not `size × (lineHeight − 1)`.** SwiftUI's `lineSpacing` is added *on top of* the font's
        /// own line height, which for Source Serif 4 is already about 1.28× the point size. Treating
        /// it as the whole line height set the answer at roughly 1.6× and looked visibly loose, so
        /// this measures the face and adds only the difference.
        static let answerLineSpacing: CGFloat = {
            let size: CGFloat = 28
            let font = UIFont(name: "SourceSerif4Roman-Regular", size: size) ?? .systemFont(ofSize: size)
            return max(0, size * answerLineHeight - font.lineHeight)
        }()
        /// Space between answer paragraphs.
        static let answerParagraphSpacing: CGFloat = 18
        /// The Generate button.
        static let generateDiameter: CGFloat = 56
        /// Height of the fade the content scrolls under.
        static let bottomFade: CGFloat = 136
        /// Room the floating pill needs at the bottom of a scroll view. It is deliberately larger
        /// than the pill itself plus the fade above it: the last line of an answer and the
        /// Follow-ups link must be scrollable clear of the toolbar, never trapped under it.
        static let pillClearance: CGFloat = 168
    }

    /// Bridges these tokens into the inherited reader's palette type, so `ScriptStyling` renders the
    /// answer in v2.5 colours without being modified: `ink` is unread text, `spoken` is the muted
    /// tone confirmed-spoken words fade to.
    static var readingPalette: OutdoorMode.Palette {
        OutdoorMode.Palette(
            background: Color.background,
            ink: Color.ink,
            spoken: Color.muted,
            action: Color.primary
        )
    }
}
