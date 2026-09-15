import Testing
import SwiftUI
import UIKit
@testable import prompter

/// **M5.10 — the palette's contrast is measured, not eyeballed.**
@MainActor
struct ThemeContrastTests {

    private func resolve(_ color: Color, dark: Bool) -> UIColor {
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
    }

    private func luminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    private func contrast(_ a: Color, _ b: Color, dark: Bool) -> Double {
        let la = luminance(resolve(a, dark: dark)), lb = luminance(resolve(b, dark: dark))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func hex(_ color: Color, dark: Bool) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolve(color, dark: dark).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(r * 255 + 0.5), Int(g * 255 + 0.5), Int(b * 255 + 0.5))
    }

    @Test
    func anchorsMatchTheApprovedDesign() {
        #expect(hex(Theme.Color.paper, dark: false) == "F7F4EF")
        #expect(hex(Theme.Color.ink, dark: false) == "242331")
        #expect(hex(Theme.Color.action, dark: false) == "216A60")
        #expect(hex(Theme.Color.paper, dark: true) == "151719")
        #expect(hex(Theme.Color.ink, dark: true) == "F2F0EB")
        #expect(hex(Theme.Color.action, dark: true) == "9ED8C4")
    }

    @Test
    func primaryTextClearsAA() {
        var out = "CONTRAST (WCAG)\n"
        for dark in [false, true] {
            let ratio = contrast(Theme.Color.ink, Theme.Color.paper, dark: dark)
            out += String(format: "  ink on paper %@: %.2f:1\n", dark ? "dark" : "light", ratio)
            #expect(ratio >= 4.5, "ink on paper is \(String(format: "%.2f", ratio)):1 in \(dark ? "dark" : "light")")
        }
        for dark in [false, true] {
            out += String(format: "  spoken on paper %@: %.2f:1\n", dark ? "dark" : "light", contrast(Theme.Color.spoken, Theme.Color.paper, dark: dark))
            out += String(format: "  onDark on action %@: %.2f:1\n", dark ? "dark" : "light", contrast(Theme.Color.onDark, Theme.Color.action, dark: dark))
            out += String(format: "  ink on currentSentence %@: %.2f:1\n", dark ? "dark" : "light", contrast(Theme.Color.ink, Theme.Color.currentSentence, dark: dark))
        }
        try? out.write(toFile: "/tmp/contrast.txt", atomically: true, encoding: .utf8)
    }

    @Test
    func spokenTextIsMutedButStillLegible() {
        for dark in [false, true] {
            let ratio = contrast(Theme.Color.spoken, Theme.Color.paper, dark: dark)
            #expect(ratio >= 3.0, "spoken on paper is \(String(format: "%.2f", ratio)):1 in \(dark ? "dark" : "light")")
            #expect(ratio < contrast(Theme.Color.ink, Theme.Color.paper, dark: dark),
                    "spoken must be visibly quieter than unread text")
        }
    }

    /// **Unread text is full contrast.** Nothing but confirmed speech may look completed.
    @Test
    func unreadTextIsIdenticalToPrimaryText() {
        for dark in [false, true] {
            #expect(resolve(Theme.Color.future, dark: dark) == resolve(Theme.Color.ink, dark: dark),
                    "unread text is dimmer than primary text in \(dark ? "dark" : "light")")
        }
    }

    @Test
    func accentSurfacesCarryReadableLabels() {
        for dark in [false, true] {
            let ratio = contrast(Theme.Color.onDark, Theme.Color.action, dark: dark)
            #expect(ratio >= 4.5, "onDark on action is \(String(format: "%.2f", ratio)):1 in \(dark ? "dark" : "light")")
        }
    }

    @Test
    func currentSentenceUnderlayKeepsTextReadable() {
        for dark in [false, true] {
            let ratio = contrast(Theme.Color.ink, Theme.Color.currentSentence, dark: dark)
            #expect(ratio >= 4.5, "ink on currentSentence is \(String(format: "%.2f", ratio)):1 in \(dark ? "dark" : "light")")
        }
    }

    @Test
    func appearancePreferenceMapsToColorSchemes() {
        #expect(AppearancePreference.system.colorScheme == nil)
        #expect(AppearancePreference.light.colorScheme == .light)
        #expect(AppearancePreference.dark.colorScheme == .dark)
        #expect(AppearancePreference(rawValue: "nonsense") == nil)
        #expect(AppSettings().appearance == .system, "System must be the default")
    }
}
