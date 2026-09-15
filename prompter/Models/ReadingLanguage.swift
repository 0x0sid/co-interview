import Foundation

/// **Per-script reading language (M5.12)** — the language the script is *written in*, which is what
/// speech recognition must be told.
///
/// Deliberately separate from the interface language. Changing the app's language must never
/// translate or rewrite a script, and the keyboard or interface locale must never decide how a take
/// is transcribed.
enum ReadingLanguage: String, CaseIterable, Identifiable, Sendable {
    case english
    case french
    case traditionalChinese

    var id: String { rawValue }

    /// The locale handed to `SpeechAssetManager.supportedLocale(for:)`. It resolves this to a locale
    /// the installed `SpeechTranscriber` actually supports, or throws — nothing is silently
    /// substituted, so French is never transcribed with an English model.
    var requestedLocale: Locale {
        switch self {
        case .english: Locale(identifier: "en-US")
        case .french: Locale(identifier: "fr-FR")
        case .traditionalChinese: Locale(identifier: "zh-Hant-TW")
        }
    }

    /// Shown in the picker, in the language itself — a reader choosing their script's language
    /// recognises its endonym faster than a translated name.
    var displayName: String {
        switch self {
        case .english: "English"
        case .french: "Français"
        case .traditionalChinese: "繁體中文"
        }
    }

    /// **English is the default**, including for unknown stored values, so an older script or a
    /// future addition can never strand an existing store.
    static func from(storedIdentifier: String?) -> ReadingLanguage {
        guard let storedIdentifier else { return .english }
        if let exact = ReadingLanguage(rawValue: storedIdentifier) { return exact }
        // Older rows stored a raw locale identifier in `Script.locale` (it defaulted to
        // `Locale.current.identifier`), so map by language code rather than discarding it.
        let code = Locale(identifier: storedIdentifier).language.languageCode?.identifier
        switch code {
        case "fr": return .french
        case "zh": return .traditionalChinese
        default: return .english
        }
    }

    /// Whether this language's text is segmented by whitespace. Traditional Chinese is not, which is
    /// why `Tokenizer` cannot treat it the same way (see docs/DECISIONS.md, M5.12).
    var isWhitespaceSegmented: Bool { self != .traditionalChinese }
}
