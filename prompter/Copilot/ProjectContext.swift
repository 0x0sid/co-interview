import Foundation

/// One passage of prepared project material.
///
/// This is the unit the generator cites. Its `id` is stable and application-owned so an answer can be
/// traced back to the exact passage and document version that supported it.
struct ProjectPassage: Identifiable, Equatable, Sendable {
    let id: String              // e.g. "cv#3"
    let documentID: String
    let documentTitle: String
    let documentVersion: String // e.g. "2026-09-02" or a content hash
    let locator: String         // "p. 2", "§ Experience"
    let text: String
}

/// A prepared project: instructions plus already-extracted passages.
///
/// **The interface the prototype is built against.** The synthetic fixture below satisfies it today;
/// the real document pipeline (import → extract → chunk → index, plan Increment 5) will satisfy the
/// same interface later without changing the generator, the coordinator or the UI.
protocol ProjectContextProviding: Sendable {
    var projectID: String { get }
    var projectName: String { get }
    /// User-written guidance. Trusted more than documents, less than the app's own rules.
    var instructions: String { get }
    var language: InterviewLanguage { get }
    /// Returns the passages most likely to support an answer to `question`.
    /// Must never return passages belonging to another project.
    func passages(forQuestion question: String, limit: Int) -> [ProjectPassage]
}

/// The language of an interview: the locale speech is recognised in and answers are written in.
///
/// Any locale the on-device `SpeechTranscriber` supports (`SpeechLocales`). **Stored values are
/// stable:** English and French keep their original raw values `"english"` and `"french"`, so every
/// saved interview and setting from before this type became locale-based decodes unchanged; any
/// other language is stored as its locale identifier ("de-DE", "es-MX").
struct InterviewLanguage: RawRepresentable, Hashable, Sendable, Identifiable {
    /// The transcriber locale, e.g. "en-US", "fr-FR", "zh-TW".
    let identifier: String

    static let english = InterviewLanguage(identifier: "en-US")
    static let french = InterviewLanguage(identifier: "fr-FR")

    init(identifier: String) { self.identifier = identifier }

    init?(rawValue: String) {
        switch rawValue {
        case "english": self = .english
        case "french": self = .french
        default:
            let locale = Locale(identifier: rawValue)
            guard !rawValue.isEmpty, locale.language.languageCode != nil else { return nil }
            self.init(identifier: rawValue)
        }
    }

    var rawValue: String {
        // Compared by identifier, never `self == …`: for a RawRepresentable type the default `==`
        // compares raw values, which would recurse back into this getter.
        switch identifier {
        case Self.english.identifier: "english"
        case Self.french.identifier: "french"
        default: identifier
        }
    }

    static func == (lhs: InterviewLanguage, rhs: InterviewLanguage) -> Bool { lhs.identifier == rhs.identifier }
    func hash(into hasher: inout Hasher) { hasher.combine(identifier) }

    var id: String { identifier }
    var locale: Locale { Locale(identifier: identifier) }
    var languageCode: String { locale.language.languageCode?.identifier ?? identifier }
    var isFrench: Bool { languageCode == "fr" }

    /// The locale handed to the transcriber.
    var transcriberLocale: Locale { locale }

    /// Sent as the request's `language`. English and French keep their original short codes.
    var bcp47: String {
        switch identifier {
        case Self.english.identifier: "en"
        case Self.french.identifier: "fr"
        default: identifier
        }
    }

    /// The reading engine's tokenization family (answer-following), by script.
    var readingLanguage: ReadingLanguage {
        switch languageCode {
        case "fr": .french
        case "zh": .traditionalChinese
        default: .english
        }
    }

    /// The language's own name, with its region: "Deutsch (Deutschland)", "English (United Kingdom)".
    var displayName: String { Self.nativeName(for: identifier) }

    /// The name in the app's interface language, for search and a second line: "German (Germany)".
    func localizedName(in interfaceLocale: Locale = .current) -> String {
        interfaceLocale.localizedString(forIdentifier: identifier) ?? identifier
    }

    static func nativeName(for identifier: String) -> String {
        let locale = Locale(identifier: identifier)
        let name = locale.localizedString(forIdentifier: identifier) ?? identifier
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }
}

/// Local lexical retrieval over already-prepared passages.
///
/// Deliberately simple and on-device: no embeddings, no network, no upload of whole documents (§5).
/// It scores passages by weighted overlap of normalized words, rarer words counting for more, so a
/// distinctive term ("Ariane", "cardiologie") outweighs a common one ("the", "de").
///
/// This is the prototype's retrieval. The architecture's §7.3 trigger for replacing it — projects that
/// exceed the context budget — is unchanged.
struct PassageRetriever: Sendable {
    let passages: [ProjectPassage]
    private let documentFrequency: [String: Int]

    init(passages: [ProjectPassage]) {
        self.passages = passages
        var frequency: [String: Int] = [:]
        for passage in passages {
            for word in Set(Tokenizer.normalize(passage.text)) {
                frequency[word, default: 0] += 1
            }
        }
        self.documentFrequency = frequency
    }

    func topPassages(for question: String, limit: Int) -> [ProjectPassage] {
        let queryWords = Set(Tokenizer.normalize(question)).subtracting(Self.stopWords)
        guard !queryWords.isEmpty, !passages.isEmpty else { return [] }
        let total = Double(passages.count)

        let scored: [(passage: ProjectPassage, score: Double)] = passages.map { passage in
            let words = Set(Tokenizer.normalize(passage.text))
            var score = 0.0
            for word in queryWords where words.contains(word) {
                let frequency = Double(documentFrequency[word] ?? 1)
                score += log(1 + total / frequency)
            }
            return (passage, score)
        }

        return scored
            .filter { $0.score > 0 }
            .sorted { ($0.score, $1.passage.id) > ($1.score, $0.passage.id) }
            .prefix(limit)
            .map(\.passage)
    }

    /// Common words in both evaluation languages. Small on purpose: this is a relevance heuristic, not
    /// a language model.
    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "you", "your", "me", "my",
        "is", "are", "was", "were", "do", "did", "does", "can", "could", "would", "about", "tell", "what",
        "how", "why", "who", "when", "that", "this", "it", "as", "at", "be", "by", "from",
        "le", "la", "les", "un", "une", "des", "du", "de", "et", "ou", "que", "qui", "quoi", "comment",
        "pourquoi", "vous", "votre", "vos", "moi", "mon", "ma", "mes", "est", "sont", "etait", "avez",
        "pouvez", "parlez", "dites", "dans", "sur", "pour", "avec", "au", "aux", "ce", "cette", "il", "elle",
    ]
}
