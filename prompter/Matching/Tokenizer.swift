import Foundation

/// A single normalized spoken word with the audio-time it was spoken at.
///
/// `timestamp` is audio/session time (seconds since the prompting session started), not wall
/// clock — this is what makes the matcher fully deterministic and replay-testable (§10.5,
/// §24.4): a fixture can specify an arbitrary long gap between two tokens to simulate silence
/// without any real waiting.
struct Token: Equatable, Sendable {
    let text: String
    let timestamp: TimeInterval

    init(_ text: String, at timestamp: TimeInterval) {
        self.text = text
        self.timestamp = timestamp
    }
}

/// Pure text normalization shared by script preprocessing (§10.1) and the live spoken buffer
/// (§10.2). Foundation-only: lowercase → strip punctuation → NFKD diacritic fold → collapse
/// whitespace.
enum Tokenizer {
    /// Normalizes a single word: lowercase, NFKD diacritic fold, then strip punctuation
    /// (anything that isn't alphanumeric).
    static func normalizeWord(_ word: String) -> String {
        let folded = word.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        var result = ""
        result.reserveCapacity(folded.count)
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    /// Splits raw text into words and normalizes each, dropping any that become empty (pure
    /// punctuation, e.g. an em dash standing alone).
    ///
    /// **Uses ICU word segmentation (`.byWords`), the same call `ScriptIndex.build` already makes on
    /// the script side (M5.12).** It previously split on whitespace here while the script side used
    /// ICU, so the two disagreed for any language whose words are not whitespace-separated:
    ///
    /// ```
    ///   "歡迎使用提詞機這是一個較長的測試腳本"
    ///     whitespace (spoken side, before) : 1 token  — the entire line
    ///     ICU        (script side, always) : 14 tokens
    /// ```
    ///
    /// Nothing could align across that mismatch, which is why Traditional Chinese could not be
    /// tracked. Making both sides use the same segmenter fixes it by construction rather than by
    /// special-casing a language.
    ///
    /// **Measured as a no-op for English** — identical output on ordinary prose, contractions,
    /// possessives and em dashes (`SegmentationParityTests`). For French it changes `"qu'est-ce"`
    /// from one token to `"quest"`/`"ce"` — which is what the script side already produced, so this
    /// makes the two agree rather than introducing a new split.
    ///
    /// No threshold, scoring rule or recovery behaviour is touched.
    static func normalize(_ text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .localized]) { word, _, _, _ in
            guard let word else { return }
            let normalized = normalizeWord(word)
            if !normalized.isEmpty { result.append(normalized) }
        }
        return result
    }
}
