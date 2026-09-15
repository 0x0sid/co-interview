import SwiftUI

/// §13's "single override layer" for high-contrast / outdoor reading, toggled from Settings
/// (§12.6) and applied only on the prompt screen — it overrides individual tokens, it does not
/// replace the whole `Theme` palette (bg/ink/spoken/action all get direct substitutes; everything
/// else on the prompt screen keeps using `Theme.Color` as normal).
enum OutdoorMode {
    struct Palette {
        let background: Color
        let ink: Color
        let spoken: Color
        let action: Color
    }

    static let normal = Palette(
        background: Theme.Color.paper,
        ink: Theme.Color.ink,
        spoken: Theme.Color.spoken,
        action: Theme.Color.action
    )

    static let outdoor = Palette(
        background: Color(hex: 0xFFFBF2),
        ink: Color(hex: 0x0E0B14),
        spoken: Color(hex: 0x6B6B6B),
        action: Color(hex: 0x033D30)
    )

    static func palette(outdoor isOutdoor: Bool) -> Palette {
        isOutdoor ? outdoor : normal
    }
}
