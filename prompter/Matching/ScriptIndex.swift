import Foundation

/// Preprocessed, cacheable representation of a script (§9 `Script.tokenCacheData`, §10.1).
///
/// Built once at script save/edit time. Sentence and paragraph segmentation use Foundation's
/// `String.enumerateSubstrings(in:options:)` with `.bySentences` / `.byParagraphs` /
/// `.byWords` (ICU-backed, ships in Foundation — no NaturalLanguage import needed), which keeps
/// `Matching/` Foundation-only per the hard constraint on this module.
struct ScriptIndex: Codable, Equatable {
    struct TokenSpan: Codable, Equatable {
        /// Normalized token text (§10.1.2: lowercase, NFKD-folded, punctuation-stripped).
        let text: String
        /// UTF-16 offset range of the original (non-normalized) word in `rawText`.
        let rangeStart: Int
        let rangeEnd: Int
        let sentenceIndex: Int
    }

    struct SentenceSpan: Codable, Equatable {
        let rangeStart: Int
        let rangeEnd: Int
        /// Half-open range into `tokens`.
        let tokenStart: Int
        let tokenEnd: Int
        let paragraphIndex: Int
    }

    let tokens: [TokenSpan]
    let sentences: [SentenceSpan]
    let paragraphCount: Int

    var tokenTexts: [String] { tokens.map(\.text) }

    /// Per-paragraph token ranges, derived from the sentences each paragraph contains. Shared by
    /// the debug replay screen and the test fixture suite so both agree on where a paragraph
    /// begins and ends.
    var paragraphTokenRanges: [Range<Int>] {
        var starts: [Int: Int] = [:]
        var ends: [Int: Int] = [:]
        for sentence in sentences {
            starts[sentence.paragraphIndex] = min(starts[sentence.paragraphIndex] ?? .max, sentence.tokenStart)
            ends[sentence.paragraphIndex] = max(ends[sentence.paragraphIndex] ?? .min, sentence.tokenEnd)
        }
        return (0..<paragraphCount).compactMap { paragraph in
            guard let start = starts[paragraph], let end = ends[paragraph] else { return nil }
            return start..<end
        }
    }

    static func build(from rawText: String) -> ScriptIndex {
        guard !rawText.isEmpty else {
            return ScriptIndex(tokens: [], sentences: [], paragraphCount: 0)
        }

        var tokens: [TokenSpan] = []
        var sentences: [SentenceSpan] = []
        var paragraphIndex = 0

        let fullRange = rawText.startIndex..<rawText.endIndex
        rawText.enumerateSubstrings(in: fullRange, options: [.byParagraphs, .localized]) { _, paragraphRange, _, _ in
            rawText.enumerateSubstrings(in: paragraphRange, options: [.bySentences, .localized]) { _, sentenceRange, _, _ in
                let sentenceIndex = sentences.count
                let tokenStart = tokens.count

                rawText.enumerateSubstrings(in: sentenceRange, options: [.byWords, .localized]) { word, wordRange, _, _ in
                    guard let word else { return }
                    let normalized = Tokenizer.normalizeWord(word)
                    guard !normalized.isEmpty else { return }
                    tokens.append(
                        TokenSpan(
                            text: normalized,
                            rangeStart: wordRange.lowerBound.utf16Offset(in: rawText),
                            rangeEnd: wordRange.upperBound.utf16Offset(in: rawText),
                            sentenceIndex: sentenceIndex
                        )
                    )
                }

                sentences.append(
                    SentenceSpan(
                        rangeStart: sentenceRange.lowerBound.utf16Offset(in: rawText),
                        rangeEnd: sentenceRange.upperBound.utf16Offset(in: rawText),
                        tokenStart: tokenStart,
                        tokenEnd: tokens.count,
                        paragraphIndex: paragraphIndex
                    )
                )
            }

            paragraphIndex += 1
        }

        return ScriptIndex(tokens: tokens, sentences: sentences, paragraphCount: paragraphIndex)
    }
}
