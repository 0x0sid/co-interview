import Foundation

/// Turns a stream of model text deltas into an **append-only** committed prefix of whole sentences,
/// plus a pending tail that is preview-only (§7).
///
/// Why this exists: the reader aligns speech against a token sequence built once by
/// `ScriptIndex.build(from:)`, and `SlidingWindowMatcher` captures those tokens at initialisation.
/// Text that can still change underneath the cursor would invalidate token indices, spoken markers and
/// the cursor itself. So text becomes readable only in whole sentences, and only after it can no
/// longer be revised.
///
/// Pure value type — no networking, no UI, fully testable.
struct StreamingAnswerAssembler: Equatable, Sendable {
    /// Whole sentences, in order. **Only ever appended to.**
    private(set) var committedText: String = ""
    /// The tail still being written. Shown as a muted preview; never given to the reader.
    private(set) var pendingText: String = ""

    /// Appends a model delta.
    /// - Returns: `true` when `committedText` grew, i.e. there is new readable material.
    @discardableResult
    mutating func append(_ delta: String) -> Bool {
        guard !delta.isEmpty else { return false }
        pendingText += delta
        return commitCompleteSentences()
    }

    /// The stream ended: everything left becomes committed, whether or not it ends a sentence.
    @discardableResult
    mutating func finish() -> Bool {
        let tail = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingText = ""
        guard !tail.isEmpty else { return false }
        appendToCommitted(tail)
        return true
    }

    private mutating func commitCompleteSentences() -> Bool {
        var didCommit = false
        while let boundary = Self.firstSentenceBoundary(in: pendingText) {
            let sentence = String(pendingText[pendingText.startIndex..<boundary])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Drop the whitespace that closed the sentence: committed sentences are re-joined with a
            // single space, and a preview that starts with a stray space reads as a rendering bug.
            pendingText = String(pendingText[boundary...].drop { $0.isWhitespace })
            guard !sentence.isEmpty else { continue }
            appendToCommitted(sentence)
            didCommit = true
        }
        return didCommit
    }

    private mutating func appendToCommitted(_ sentence: String) {
        if committedText.isEmpty {
            committedText = sentence
        } else {
            committedText += " " + sentence
        }
    }

    /// Index just past the end of the first complete sentence in `text`, or `nil`.
    ///
    /// Deliberately conservative: a terminator only closes a sentence when whitespace follows it, so a
    /// decimal number, an abbreviation mid-word, or a terminator still being streamed does not split
    /// text early. French spacing (`« … ? »`, narrow no-break space before `?` and `!`) works because
    /// the check is "terminator, then whitespace", not "terminator, then a capital letter".
    static func firstSentenceBoundary(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if sentenceTerminators.contains(character) {
                var after = text.index(after: index)
                // Run through closing punctuation that belongs to the same sentence.
                while after < text.endIndex, closingPunctuation.contains(text[after]) {
                    after = text.index(after: after)
                }
                guard after < text.endIndex else { return nil }   // may still be extended
                if text[after].isWhitespace {
                    return after
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    private static let closingPunctuation: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»", "”"]
}
