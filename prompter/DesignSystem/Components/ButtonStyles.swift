import SwiftUI

/// §13's primary action style — filled `action` (teal), `onDark` label. Used for the big "New
/// Script" button, "Start", demo CTAs, and anywhere else a screen has one clear primary action.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.body(17, weight: .semibold))
            .foregroundStyle(Theme.Color.onDark)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: Theme.Shape.cornerRadius)
                    .fill(Theme.Color.action)
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
    }
}

/// §13's secondary action style — `action`-colored label/border on `paper`, no fill. `ink` and
/// `action` never sit directly on each other (§13's hard rule) — this style only ever renders on
/// `paper`/`card`, never on an `ink`-filled surface.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.body(17, weight: .medium))
            .foregroundStyle(Theme.Color.action)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: Theme.Shape.cornerRadius)
                    .stroke(Theme.Color.action, lineWidth: Theme.Shape.borderWidth)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var prompterPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var prompterSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}
