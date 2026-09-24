import Foundation

/// The interview language the user chose: the system language, or an explicit one.
///
/// **What it controls.** One setting drives both halves of the interview: speech is *recognised* in
/// this language (the on-device transcriber's locale), and answers are *written* in it (the request's
/// `language`). There is no separate answer-language setting, so there is no "same as interview"
/// choice to offer — the label says "Interview language" and the explanation says both.
///
/// Only languages the app recognises are offered. "System language" resolves to the first of the
/// device's preferred languages the app supports, and says so when the device's own first language
/// is not one of them.
enum InterviewLanguagePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case french

    var id: String { rawValue }

    struct Resolution: Equatable, Sendable {
        let language: InterviewLanguage
        /// The device's first preferred language, in its own name — shown beside "System language".
        let systemLanguageName: String
        /// Set when the device's first language is not supported and another was used instead.
        let fallbackNote: String?
    }

    /// Resolves "System language" from the device's preferred languages.
    static func resolveSystem(preferredLanguages: [String] = Locale.preferredLanguages) -> Resolution {
        let first = preferredLanguages.first ?? "en"
        let firstName = Self.name(of: first)
        if let direct = supported(first) {
            return Resolution(language: direct, systemLanguageName: firstName, fallbackNote: nil)
        }
        let fallback = preferredLanguages.dropFirst().lazy.compactMap(Self.supported).first ?? .english
        return Resolution(
            language: fallback,
            systemLanguageName: firstName,
            fallbackNote: "\(firstName) isn't available for interview recognition. Using \(fallback.displayName)."
        )
    }

    /// The language a session started now would use.
    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> InterviewLanguage {
        switch self {
        case .system: Self.resolveSystem(preferredLanguages: preferredLanguages).language
        case .english: .english
        case .french: .french
        }
    }

    /// "System language (English)" — the resolved language is always visible, never implied.
    func label(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .system: "System language (\(Self.resolveSystem(preferredLanguages: preferredLanguages).language.displayName))"
        case .english: InterviewLanguage.english.displayName
        case .french: InterviewLanguage.french.displayName
        }
    }

    static func from(stored: String?) -> InterviewLanguagePreference {
        stored.flatMap(InterviewLanguagePreference.init(rawValue:)) ?? .system
    }

    private static func supported(_ identifier: String) -> InterviewLanguage? {
        switch Locale(identifier: identifier).language.languageCode?.identifier {
        case "en": .english
        case "fr": .french
        default: nil
        }
    }

    private static func name(of identifier: String) -> String {
        let locale = Locale(identifier: identifier)
        let code = locale.language.languageCode?.identifier ?? identifier
        return (locale.localizedString(forLanguageCode: code) ?? identifier).capitalized(with: locale)
    }

    /// One sentence under the picker, so nobody has to guess what the setting changes.
    static let explanation = "Speech is recognised and answers are written in this language."
}
