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
        static let background = dynamic(light: 0xF8F5EF, dark: 0x1D2120, ultra: 0x000000)
        /// Primary: deep teal / pale mint. Carries highlights, the Generate button and detected questions.
        static let primary = dynamic(light: 0x2F6B5E, dark: 0xBEEBDC, ultra: 0xFFFFFF)
        /// Text on top of `primary`.
        static let onPrimary = dynamic(light: 0xFFFFFF, dark: 0x16211D, ultra: 0x000000)
        /// Body text.
        static let ink = dynamic(light: 0x1C201F, dark: 0xECF1EE, ultra: 0xFFFFFF)
        /// Secondary labels, the counter, spoken-word fading.
        static let muted = dynamic(light: 0x7A807D, dark: 0x8E9995, ultra: 0xFFFFFF)
        /// Header pieces, context panel, cards.
        static let surface = dynamic(light: 0xFFFFFF, dark: 0x262C2A, ultra: 0x000000)
        /// The floating action pill.
        static let pillSurface = dynamic(light: 0xFFFFFF, dark: 0x2A302E, ultra: 0x000000)
        static let hairline = dynamic(light: 0xE5E0D6, dark: 0x333A38, ultra: 0xFFFFFF)
        /// Question pill fill.
        static let questionPill = dynamic(light: 0xE7EEEA, dark: 0x262C2A, ultra: 0x000000)
        /// Sparkle inside the question pill — dark on light, white on dark.
        static let questionSparkle = dynamic(light: 0x1C201F, dark: 0xFFFFFF, ultra: 0xFFFFFF)

        /// **The only red in the design.** Nothing else may use it.
        static let recording = dynamic(light: 0xD93C3C, dark: 0xFF6B6B, ultra: 0xFFFFFF)
        /// The recording mark when listening is paused: hollow and grey, never red.
        static let recordingPaused = dynamic(light: 0x9A9F9C, dark: 0x6E7A76, ultra: 0xFFFFFF)

        /// Demo badge. Violet, so it reads as "this is not real" at a glance.
        static let demoBadge = dynamic(light: 0x6C4BD1, dark: 0xB9A4F0, ultra: 0xFFFFFF)

        /// Code card: a solid near-black card on light, a bordered transparent one on dark.
        static let codeCardLight = dynamic(light: 0x14171A, dark: 0x14171A, ultra: 0x000000)
        static let codeInk = dynamic(light: 0xE9EDEB, dark: 0xD9E2DE, ultra: 0xFFFFFF)
        static let codeType = dynamic(light: 0x8FD9C4, dark: 0xBEEBDC, ultra: 0xFFFFFF)
        static let codeKeyword = SwiftUI.Color(uiColor: UIColor(rgb: 0xC7A6F0))

        /// Follow-up likelihood dots. Green, amber, grey — **never red** (§1: red is the recording mark).
        static let likely = dynamic(light: 0x2F8B5E, dark: 0x86D6A8, ultra: 0xFFFFFF)
        static let possible = dynamic(light: 0xB8801F, dark: 0xE0B36A, ultra: 0xFFFFFF)
        static let lessLikely = dynamic(light: 0x8A908C, dark: 0x8E9995, ultra: 0xFFFFFF)

        /// `ultra` is Ultra Contrast: pure black and white. It is resolved from a trait, not a
        /// branch at the call site, so every view on this screen follows the choice unchanged.
        static func dynamic(light: UInt32, dark: UInt32, ultra: UInt32) -> SwiftUI.Color {
            SwiftUI.Color(uiColor: UIColor { traits in
                if traits[UltraContrastTrait.self] { return UIColor(rgb: ultra) }
                return UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
            })
        }
    }

    /// Type, all three from the bundled faces, all scaling with Dynamic Type.
    enum Font {
        /// UI chrome — Hanken Grotesk.
        static func ui(_ size: CGFloat, weight: Typography.Weight = .regular, relativeTo style: UIFont.TextStyle = .body) -> SwiftUI.Font {
            Typography.scaledHankenGrotesk(size, weight: weight, relativeTo: style)
        }
        /// The answer — Hanken Grotesk, the interface's own sans, at 21pt scaled with Dynamic Type.
        ///
        /// It was Source Serif 4 at 28pt. On a phone that set four or five words to a line and a
        /// short answer ran off the screen; read from a glance mid-interview, the serif was also
        /// harder to pick up again than the sans the rest of the screen already uses.
        static func answer(_ size: CGFloat = Metric.answerSize, weight: Typography.Weight = .regular) -> SwiftUI.Font {
            Typography.scaledHankenGrotesk(size, weight: weight, relativeTo: .title3)
        }
        /// Code — IBM Plex Mono.
        static func code(_ size: CGFloat = 12.5, weight: Typography.Weight = .regular) -> SwiftUI.Font {
            Typography.scaledMono(size, weight: weight, relativeTo: .footnote)
        }
    }

    enum Metric {
        /// The answer's base size, before Dynamic Type.
        static let answerSize: CGFloat = 21
        /// Line height of the answer, as a multiple of its size.
        static let answerLineHeight: CGFloat = 1.4
        /// Extra leading needed to reach that line height.
        ///
        /// **Not `size × (lineHeight − 1)`.** SwiftUI's `lineSpacing` is added *on top of* the font's
        /// own line height, so this measures the face and adds only the difference. (It is measured
        /// at the base size; Dynamic Type scales the font, and the relative leading stays close.)
        static let answerLineSpacing: CGFloat = {
            let size = answerSize
            let font = UIFont(name: "HankenGrotesk-Regular", size: size) ?? .systemFont(ofSize: size)
            return max(0, size * answerLineHeight - font.lineHeight)
        }()
        /// Space between answer paragraphs: clearly a new paragraph, not a new section.
        static let answerParagraphSpacing: CGFloat = 14
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

// MARK: - Ultra Contrast

/// Ultra Contrast (an `AppearancePreference`): pure black #000000 and pure white #FFFFFF, nothing
/// between. A UIKit trait bridged to the SwiftUI environment, so the dynamic colours above resolve
/// it the same way they resolve light and dark, and views that need more than a colour — outlines,
/// underlined speech-following, full-opacity icons — read `\.ultraContrast`.
struct UltraContrastTrait: UITraitDefinition {
    static let defaultValue = false
    static let affectsColorAppearance = true
    static let name = "UltraContrast"

    /// Sets or clears Ultra Contrast on every window the app has.
    @MainActor
    static func apply(_ isOn: Bool) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.traitOverrides[UltraContrastTrait.self] = isOn
            }
        }
    }
}

struct UltraContrastKey: UITraitBridgedEnvironmentKey {
    static let defaultValue = false
    static func read(from traitCollection: UITraitCollection) -> Bool { traitCollection[UltraContrastTrait.self] }
    static func write(to mutableTraits: inout UIMutableTraits, value: Bool) { mutableTraits[UltraContrastTrait.self] = value }
}

extension EnvironmentValues {
    var ultraContrast: Bool {
        get { self[UltraContrastKey.self] }
        set { self[UltraContrastKey.self] = newValue }
    }
}

extension View {
    /// A white outline in Ultra Contrast, where a black card on black would otherwise vanish.
    /// Nothing in light or dark.
    func ultraContrastOutline<S: InsettableShape>(_ shape: S, lineWidth: CGFloat = 1.5) -> some View {
        modifier(UltraContrastOutline(shape: shape, lineWidth: lineWidth))
    }
}

private struct UltraContrastOutline<S: InsettableShape>: ViewModifier {
    let shape: S
    let lineWidth: CGFloat
    @Environment(\.ultraContrast) private var ultraContrast

    func body(content: Content) -> some View {
        content.overlay {
            if ultraContrast { shape.strokeBorder(SwiftUI.Color.white, lineWidth: lineWidth) }
        }
    }
}
