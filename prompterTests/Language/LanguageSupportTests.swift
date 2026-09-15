import Testing
import Foundation
@testable import prompter

/// **M5.12 — what each language actually does today.**
///
/// These tests are written to *record behaviour*, including where it is broken. A language is not
/// "supported" because a picker lists it.
struct LanguageSupportTests {

    // MARK: Model and routing

    @Test
    func englishIsTheDefaultEverywhere() {
        #expect(Script(title: "t", rawText: "hello").readingLanguage == .english)
        #expect(ReadingLanguage.from(storedIdentifier: nil) == .english)
        #expect(ReadingLanguage.from(storedIdentifier: "nonsense") == .english)
    }

    /// Legacy rows stored a device locale in `Script.locale`; it is mapped, not discarded.
    @Test
    func legacyLocaleIdentifiersMapToALanguage() {
        #expect(ReadingLanguage.from(storedIdentifier: "fr_FR") == .french)
        #expect(ReadingLanguage.from(storedIdentifier: "zh-Hant-TW") == .traditionalChinese)
        #expect(ReadingLanguage.from(storedIdentifier: "en_GB") == .english)
    }

    /// Each language requests a distinct locale — nothing collapses to English.
    @Test
    func eachLanguageRequestsItsOwnLocale() {
        let codes = ReadingLanguage.allCases.map { $0.requestedLocale.language.languageCode?.identifier }
        #expect(codes == ["en", "fr", "zh"])
        #expect(Set(codes).count == ReadingLanguage.allCases.count, "two languages share a locale")
    }

    /// Changing the interface language must never touch script text.
    @Test
    func interfaceLanguageDoesNotAlterScriptText() {
        let original = "Bonjour, c'est l'accord."
        let script = Script(title: "t", rawText: original)
        let settings = AppSettings()
        settings.interfaceLanguageRaw = "fr"
        #expect(script.rawText == original, "the script text changed with the interface language")
        script.readingLanguage = .french
        #expect(script.rawText == original, "the script text changed with the reading language")
    }

    // MARK: Tokenization — the part that decides whether tracking can work at all

    /// English is the control and must be unchanged.
    @Test
    func englishTokenizationIsUnchanged() {
        #expect(Tokenizer.normalize("Welcome to Prompter. This is a longer test script.")
                == ["welcome", "to", "prompter", "this", "is", "a", "longer", "test", "script"])
    }

    /// **French: records what actually happens to apostrophes and accents.**
    @Test
    func frenchTokenizationBehaviour() {
        var report = "FRENCH TOKENIZATION (current behaviour)\n\n"
        let cases = [
            "Bonjour tout le monde",
            "c'est l'accord",
            "qu'est-ce que c'est",
            "déjà vu, très élégant",
            "l'été prochain",
        ]
        for text in cases {
            report += "  \(text.padding(toLength: 26, withPad: " ", startingAt: 0)) -> \(Tokenizer.normalize(text))\n"
        }
        try? report.write(toFile: "/tmp/lang_fr.txt", atomically: true, encoding: .utf8)

        // Accents fold correctly — this part genuinely works.
        #expect(Tokenizer.normalize("déjà vu") == ["deja", "vu"])
        #expect(Tokenizer.normalize("très élégant") == ["tres", "elegant"])
        // Elision joins into one token: "c'est" -> "cest". Both sides agree, which is what matters
        // for alignment — the risk is that the *recogniser* emits "c" + "est", which only a device
        // capture can establish.
        #expect(Tokenizer.normalize("c'est l'accord") == ["cest", "laccord"])
        // Hyphenated interrogatives split on the hyphen, exactly as the script side splits them.
        #expect(Tokenizer.normalize("qu'est-ce") == ["quest", "ce"])
        // **The safety property**: spoken and script tokenization agree for French too.
        for text in ["c'est l'accord, qu'est-ce que c'est", "déjà vu, très élégant l'été prochain"] {
            #expect(Tokenizer.normalize(text) == ScriptIndex.build(from: text).tokenTexts,
                    "French spoken/script tokenization disagree: \(text)")
        }
    }

    /// **Traditional Chinese now segments**, because the spoken side uses the same ICU segmenter the
    /// script side always used. Before M5.12 this produced exactly one token per line.
    @Test
    func traditionalChineseIsSegmented() {
        let sentence = "歡迎使用提詞機這是一個較長的測試腳本"
        let spoken = Tokenizer.normalize(sentence)
        let script = ScriptIndex.build(from: sentence).tokenTexts
        let report = """
        TRADITIONAL CHINESE SEGMENTATION (after M5.12)

          input            : \(sentence)   (\(sentence.count) characters)
          spoken side      : \(spoken.count) tokens — \(spoken)
          script side      : \(script.count) tokens — \(script)
          sides agree      : \(spoken == script)

        Before M5.12 the spoken side split on whitespace and produced ONE token for the whole line,
        while the script side used ICU and produced \(script.count). Nothing could align across that.
        """
        try? report.write(toFile: "/tmp/lang_zh.txt", atomically: true, encoding: .utf8)

        #expect(spoken.count > 10, "Chinese is not being segmented: \(spoken.count) token(s)")
        #expect(spoken == script, "the spoken and script sides disagree — alignment cannot work")
    }

    /// The matcher can now advance through a Chinese script, with the English control beside it.
    @Test
    func theMatcherTracksSegmentedChineseAndEnglishIsUnchanged() {
        // English control.
        let english = ScriptIndex.build(from: "Welcome to Prompter. This is a longer test script.")
        let englishMatcher = SlidingWindowMatcher(scriptTokens: english.tokenTexts, config: .default)
        var now: TimeInterval = 0
        var englishCursor = 0
        for word in english.tokenTexts.prefix(6) {
            now += 0.4
            englishCursor = englishMatcher.advance(spoken: [Token(word, at: now)], now: now).tokenIndex
        }

        // Chinese: feed the script's own tokens, exactly as the English control does.
        let chinese = ScriptIndex.build(from: "歡迎使用提詞機這是一個較長的測試腳本")
        let chineseMatcher = SlidingWindowMatcher(scriptTokens: chinese.tokenTexts, config: .default)
        now = 0
        var chineseCursor = 0
        for word in chinese.tokenTexts.prefix(6) {
            now += 0.4
            chineseCursor = chineseMatcher.advance(spoken: [Token(word, at: now)], now: now).tokenIndex
        }

        #expect(englishCursor >= 5, "the English control regressed: cursor \(englishCursor)")
        #expect(chinese.tokenTexts.count > 10, "Chinese script produced \(chinese.tokenTexts.count) tokens")
        #expect(chineseCursor >= 5, "the matcher did not track segmented Chinese: cursor \(chineseCursor)")
    }

    /// **English parity is the safety property for the segmentation change.**
    @Test
    func segmentationChangeIsANoOpForEnglish() {
        let cases = [
            "Welcome to Prompter. This is a longer test script, written specifically.",
            "not just one or two lines",
            "don't stop — it's the reader's choice",
            "As you speak, the current sentence should highlight.",
        ]
        for text in cases {
            let viaNormalize = Tokenizer.normalize(text)
            let viaScriptIndex = ScriptIndex.build(from: text).tokenTexts
            #expect(viaNormalize == viaScriptIndex,
                    "spoken and script tokenization disagree for English: \(text)\n  \(viaNormalize)\n  \(viaScriptIndex)")
        }
    }
}
