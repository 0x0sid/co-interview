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
enum InterviewLanguagePreference: Hashable, Identifiable, Sendable {
    case system
    case language(InterviewLanguage)

    static let english = InterviewLanguagePreference.language(.english)
    static let french = InterviewLanguagePreference.language(.french)

    var id: String { rawValue }

    /// Stored in settings and on each session: "system", or the language's own raw value.
    var rawValue: String {
        switch self {
        case .system: "system"
        case .language(let language): language.rawValue
        }
    }

    init?(rawValue: String) {
        if rawValue == "system" { self = .system; return }
        guard let language = InterviewLanguage(rawValue: rawValue) else { return nil }
        self = .language(language)
    }

    struct Resolution: Equatable, Sendable {
        let language: InterviewLanguage
        /// The device's first preferred language, in its own name — shown beside "System language".
        let systemLanguageName: String
        /// Set when the device's first language is not supported and another was used instead. Always
        /// shown: nothing is substituted silently.
        let fallbackNote: String?
    }

    /// Resolves "System language" from the device's preferred languages against what the transcriber
    /// supports.
    static func resolveSystem(preferredLanguages: [String] = Locale.preferredLanguages,
                              supported: [String] = SpeechLocales.supported) -> Resolution {
        let first = preferredLanguages.first ?? "en-US"
        let firstName = InterviewLanguage.nativeName(for: first)
        if let direct = SpeechLocales.bestMatch(for: first, in: supported) {
            return Resolution(language: InterviewLanguage(rawValue: direct) ?? InterviewLanguage(identifier: direct),
                              systemLanguageName: firstName, fallbackNote: nil)
        }
        let fallbackID = preferredLanguages.dropFirst().lazy.compactMap { SpeechLocales.bestMatch(for: $0, in: supported) }.first
        let fallback = fallbackID.map(Self.language(for:)) ?? .english
        return Resolution(
            language: fallback,
            systemLanguageName: firstName,
            fallbackNote: "\(firstName) isn't available for interview recognition on this iPhone. Using \(fallback.displayName) — choose another language if you prefer."
        )
    }

    /// The language a session started now would use.
    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> InterviewLanguage {
        switch self {
        case .system: Self.resolveSystem(preferredLanguages: preferredLanguages).language
        case .language(let language): language
        }
    }

    /// "System language (English (United States))" — the resolved language is always visible.
    func label(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .system: "System language (\(Self.resolveSystem(preferredLanguages: preferredLanguages).language.displayName))"
        case .language(let language): language.displayName
        }
    }

    static func from(stored: String?) -> InterviewLanguagePreference {
        stored.flatMap(InterviewLanguagePreference.init(rawValue:)) ?? .system
    }

    /// English and French keep their named values, so an identifier maps back to them.
    static func language(for identifier: String) -> InterviewLanguage {
        switch identifier {
        case InterviewLanguage.english.identifier: .english
        case InterviewLanguage.french.identifier: .french
        default: InterviewLanguage(identifier: identifier)
        }
    }

    /// One sentence under the picker, so nobody has to guess what the setting changes.
    static let explanation = "Speech is recognised and answers are written in this language. The app's own interface language is set in iPhone Settings."
}
