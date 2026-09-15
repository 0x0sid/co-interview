import SwiftUI
import NaturalLanguage

/// M5.1-D: per-script reading direction. `auto` (the default) detects the script's dominant
/// language via `NLLanguageRecognizer` and maps it to a layout direction via `Locale
/// .characterDirection(forLanguage:)` — Arabic/Hebrew resolve right-to-left, CJK/Latin/everything
/// else resolves left-to-right (CJK's horizontal writing direction genuinely is left-to-right;
/// vertical CJK is a separate axis `characterDirection` doesn't report, and isn't in scope here).
/// `leftToRight`/`rightToLeft` are the manual override, stored per-`Script`.
enum ScriptTextDirection: String, CaseIterable, Codable {
    case auto
    case leftToRight
    case rightToLeft

    var displayName: String {
        switch self {
        case .auto: "Auto"
        case .leftToRight: "Left"
        case .rightToLeft: "Right"
        }
    }
}

enum TextDirectionDetector {
    /// Resolves an override (or auto-detects) to a concrete `LayoutDirection` for a given text.
    static func resolvedDirection(for text: String, override: ScriptTextDirection) -> LayoutDirection {
        switch override {
        case .leftToRight: return .leftToRight
        case .rightToLeft: return .rightToLeft
        case .auto: return detectedDirection(for: text)
        }
    }

    /// Verified against the installed iOS 26 SDK: `NLLanguageRecognizer.dominantLanguage(for:)`
    /// (`NLLanguageRecognizer.h`) and `Locale.Language(identifier:).characterDirection`
    /// (`Foundation.swiftinterface` — the non-deprecated replacement for `Locale
    /// .characterDirection(forLanguage:)`, deprecated iOS 16).
    static func detectedDirection(for text: String) -> LayoutDirection {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let language = NLLanguageRecognizer.dominantLanguage(for: text) else {
            return .leftToRight
        }
        let direction = Locale.Language(identifier: language.rawValue).characterDirection
        return direction == .rightToLeft ? .rightToLeft : .leftToRight
    }
}
