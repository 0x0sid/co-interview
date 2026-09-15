import Foundation
import SwiftData

@Model
final class Script {
    @Attribute(.unique) var id: UUID
    var title: String
    var rawText: String
    var locale: String
    var wordCount: Int
    var tokenCacheData: Data?
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    /// M5.1-D: per-script reading-direction override, stored as `ScriptTextDirection`'s raw
    /// value (plain `String`, matching this project's existing convention of not storing enums
    /// directly on `@Model` types) — "auto" (default) detects the dominant language via
    /// `TextDirectionDetector`; "leftToRight"/"rightToLeft" are the manual override.
    var textDirectionOverrideRaw: String = ScriptTextDirection.auto.rawValue
    /// **Reading language (M5.12)** — the language the script is written in, used to choose the
    /// speech-recognition locale. Stored as `ReadingLanguage`'s raw value, matching this project's
    /// convention of not storing enums directly on `@Model` types. Defaults to English.
    ///
    /// Distinct from `locale`, which was the device locale captured at creation and was never read
    /// by anything; this is an explicit user choice.
    var readingLanguageRaw: String = ReadingLanguage.english.rawValue
    @Relationship(deleteRule: .cascade) var sessions: [PromptSession]

    init(
        id: UUID = UUID(),
        title: String,
        rawText: String,
        locale: String = Locale.current.identifier,
        wordCount: Int = 0,
        tokenCacheData: Data? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastUsedAt: Date? = nil,
        textDirectionOverride: ScriptTextDirection = .auto,
        sessions: [PromptSession] = []
    ) {
        self.id = id
        self.title = title
        self.rawText = rawText
        self.locale = locale
        self.wordCount = wordCount
        self.tokenCacheData = tokenCacheData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.textDirectionOverrideRaw = textDirectionOverride.rawValue
        self.sessions = sessions
    }

    var textDirectionOverride: ScriptTextDirection {
        get { ScriptTextDirection(rawValue: textDirectionOverrideRaw) ?? .auto }
        set { textDirectionOverrideRaw = newValue.rawValue }
    }

    /// §12.1's "~duration estimate" / §12.3's live speaking-time estimate — 150 wpm per
    /// docs/BUILD_SPEC.md §12.3.
    static let wordsPerMinute = 150.0

    var estimatedDurationSeconds: Int {
        Int((Double(wordCount) / Self.wordsPerMinute * 60).rounded())
    }
}

extension Script {
    /// Typed accessor for `readingLanguageRaw`, falling back to English for unknown values.
    ///
    /// For rows created before M5.12 the stored value is empty, so `ReadingLanguage.from` also
    /// consults the legacy `locale` field rather than discarding what it knew.
    var readingLanguage: ReadingLanguage {
        get {
            readingLanguageRaw.isEmpty
                ? ReadingLanguage.from(storedIdentifier: locale)
                : ReadingLanguage.from(storedIdentifier: readingLanguageRaw)
        }
        set { readingLanguageRaw = newValue.rawValue }
    }
}
