import SwiftUI

/// §13 v3 design system — light/dark semantic palette (M5.10, docs/DECISIONS.md).
///
/// Supersedes the v2 single-appearance "liseuse" palette. Every colour is a **dynamic** provider
/// resolved against the active `UITraitCollection`, so one token serves both appearances and
/// nothing has to branch on colour scheme at the call site.
///
/// The three anchor colours are fixed by the approved design; everything else is derived and its
/// contrast is **measured**, not eyeballed — see `ThemeContrastTests`.
///
/// `Accessibility/OutdoorMode.swift` still layers a high-contrast override on top for the prompt
/// screen; it overrides tokens, it does not replace this palette.
enum Theme {
    enum Color {
        // MARK: Anchors (fixed by the approved design)

        /// App background. Light `#F7F4EF`, dark `#151719`.
        static let paper = dynamic(light: 0xF7F4EF, dark: 0x151719)
        /// Primary text. Light `#242331`, dark `#F2F0EB`.
        static let ink = dynamic(light: 0x242331, dark: 0xF2F0EB)
        /// Buttons, links, accents. Light `#216A60`, dark `#9ED8C4`.
        static let action = dynamic(light: 0x216A60, dark: 0x9ED8C4)

        // MARK: Derived surfaces

        /// Card surface — a half-step off `paper` so it separates without a border.
        static let card = dynamic(light: 0xFFFFFF, dark: 0x1E2124)
        /// Hairline/border, only where separation is needed without a card.
        static let hairline = dynamic(light: 0xE4DFD6, dark: 0x2C3034)

        // MARK: Reading states
        //
        // **Unread text is full contrast.** Only individually confirmed spoken words are muted —
        // the invariant is that nothing except confirmed speech may look completed, so there is no
        // separate lighter "future" tone any more.

        /// Not-yet-spoken text — deliberately identical to `ink`.
        static let future = ink
        /// Already-spoken text — muted but still comfortably readable, never invisible.
        static let spoken = dynamic(light: 0x6E6B7A, dark: 0x8B9095)
        /// Secondary labels (word counts, captions). Same muted tone as spoken text.
        static let secondary = spoken
        /// Current-sentence highlight underlay — a faint accent tint; `ink` on top stays high.
        static let currentSentence = dynamic(light: 0xE4EDE9, dark: 0x1E2A27)

        // MARK: Status

        /// Recording dot, success moments — use sparingly.
        static let warm = dynamic(light: 0xB8641F, dark: 0xE0A06A)
        /// Errors — muted, no alarm-red.
        static let error = dynamic(light: 0x8C3A2E, dark: 0xE08C7E)
        /// Text on `ink`- or `action`-filled surfaces.
        static let onDark = dynamic(light: 0xFFFFFF, dark: 0x151719)

        /// Builds a colour that resolves per appearance.
        static func dynamic(light: UInt32, dark: UInt32) -> SwiftUI.Color {
            SwiftUI.Color(uiColor: UIColor { traits in
                UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
            })
        }
    }

    enum Shape {
        static let cornerRadius: CGFloat = 14
        static let cornerRadiusRange: ClosedRange<CGFloat> = 12...16
        static let borderWidth: CGFloat = 2
    }

    /// Minimum touch target required by the accessibility contract.
    static let minimumTouchTarget: CGFloat = 44
}

extension SwiftUI.Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Reader appearance preference. Stored as a raw `String` so the SwiftData model stays trivially
/// migratable.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// `nil` means "follow the system", which is the default.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
