import Testing
import SwiftUI
import UIKit
@testable import prompter

/// Ultra Contrast is genuinely black and white, light and dark are unchanged, and the screen stays
/// awake for exactly the life of a foreground interview session.
@MainActor
struct UltraContrastTests {
    private func hex(_ color: Color, _ traits: UITraitCollection) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (UInt32((r * 255).rounded()) << 16) | (UInt32((g * 255).rounded()) << 8) | UInt32((b * 255).rounded())
    }

    private let ultra = UITraitCollection { traits in
        traits.userInterfaceStyle = .dark
        traits[UltraContrastTrait.self] = true
    }
    private let dark = UITraitCollection(userInterfaceStyle: .dark)
    private let light = UITraitCollection(userInterfaceStyle: .light)

    @Test
    func theScreenIsPureBlackAndItsTextAndControlsPureWhite() {
        typealias C = InterviewTheme.Color
        for background in [C.background, C.surface, C.pillSurface, C.questionPill, C.codeCardLight, C.onPrimary] {
            #expect(hex(background, ultra) == 0x000000)
        }
        for foreground in [C.ink, C.muted, C.primary, C.hairline, C.codeInk, C.questionSparkle, C.recording, C.recordingPaused] {
            #expect(hex(foreground, ultra) == 0xFFFFFF)
        }
    }

    @Test
    func lightAndDarkAreUnchanged() {
        typealias C = InterviewTheme.Color
        #expect(hex(C.background, light) == 0xF8F5EF)
        #expect(hex(C.background, dark) == 0x1D2120)
        #expect(hex(C.ink, light) == 0x1C201F)
        #expect(hex(C.ink, dark) == 0xECF1EE)
        #expect(hex(C.primary, light) == 0x2F6B5E)
        #expect(hex(C.primary, dark) == 0xBEEBDC)
        #expect(hex(C.recording, dark) == 0xFF6B6B)
        #expect(hex(C.codeCardLight, light) == 0x14171A)
    }

    @Test
    func ultraContrastIsANewChoiceThatRendersDark() {
        #expect(AppearancePreference.allCases == [.system, .light, .dark, .ultraContrast])
        #expect(AppearancePreference.ultraContrast.label == "Ultra Contrast")
        #expect(AppearancePreference.ultraContrast.colorScheme == .dark)
        #expect(AppearancePreference.dark.isUltraContrast == false)
    }

    /// Speech-following never dims the answer in Ultra Contrast: spoken words keep full ink and are
    /// underlined. The default (the reader and ordinary modes) still greys them.
    @Test
    func spokenWordsAreUnderlinedNotDimmed() {
        let text = "Alpha beta gamma delta."
        let index = ScriptIndex.build(from: text)
        let cursor = PromptCursor(tokenIndex: 2, confidence: 1, state: .advancing)
        let palette = InterviewTheme.readingPalette
        let ultraText = ScriptStyling.styledAttributedString(rawText: text, scriptIndex: index, cursor: cursor,
                                                             spokenTokenIndices: [0, 1], palette: palette, underlineSpoken: true)
        for run in ultraText.runs {
            #expect(run.foregroundColor == palette.ink, "a word was dimmed in Ultra Contrast")
        }
        let underlined = ultraText.runs.filter { $0.underlineStyle != nil }.map { String(ultraText[$0.range].characters) }.joined()
        #expect(underlined.contains("Alpha") && underlined.contains("beta") && !underlined.contains("gamma"))

        let ordinary = ScriptStyling.styledAttributedString(rawText: text, scriptIndex: index, cursor: cursor,
                                                            spokenTokenIndices: [0, 1], palette: palette)
        #expect(ordinary.runs.contains { $0.foregroundColor == palette.spoken })
        #expect(!ordinary.runs.contains { $0.underlineStyle != nil })
    }
}

@MainActor
struct ScreenAwakeTests {
    @Test
    func awakeOnlyWhileASessionIsActiveInTheForeground() {
        var calls: [Bool] = []
        var awake = ScreenAwake()
        awake.setIdleTimerDisabled = { calls.append($0) }

        awake.apply(sessionActive: true, sceneActive: true)    // listening, generating, reading, paused
        awake.apply(sessionActive: true, sceneActive: false)   // backgrounded
        awake.apply(sessionActive: true, sceneActive: true)    // back to the running interview
        awake.apply(sessionActive: false, sceneActive: true)   // ended or dismissed
        #expect(calls == [true, false, true, false])
        #expect(!ScreenAwake.shouldKeepAwake(sessionActive: false, sceneActive: false))
    }
}
