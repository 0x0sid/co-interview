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
    /// The whitespace that followed the last committed sentence, exactly as the model wrote it. It is
    /// committed in front of the next sentence, so line breaks and blank lines survive.
    private var gap: String = ""

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
        let tail = String(pendingText.reversed().drop { $0.isWhitespace }.reversed())
        pendingText = ""
        guard !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        appendToCommitted(tail)
        return true
    }

    /// **Committed text is the stream itself, cut at a sentence boundary — never re-joined.** It used
    /// to trim each sentence and join them with a single space, which turned `logic.\n\n```java` into
    /// `logic. ```java`: the opening fence was no longer at the start of a line, the parser missed it,
    /// the code rendered as prose and the prose after the closing fence as code. Blank lines between
    /// paragraphs were lost the same way. Keeping the original whitespace keeps both, and the text is
    /// still append-only, so nothing the reader is following ever changes.
    private mutating func commitCompleteSentences() -> Bool {
        var didCommit = false
        while let boundary = Self.firstSentenceBoundary(in: pendingText) {
            let sentence = String(pendingText[pendingText.startIndex..<boundary])
            let rest = pendingText[boundary...]
            let whitespace = rest.prefix { $0.isWhitespace }
            pendingText = String(rest.dropFirst(whitespace.count))
            guard !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                gap += sentence + whitespace
                continue
            }
            appendToCommitted(sentence)
            gap = String(whitespace)
            didCommit = true
        }
        return didCommit
    }

    private mutating func appendToCommitted(_ sentence: String) {
        if committedText.isEmpty {
            // Only the very start is trimmed: a preview that opens with blank space reads as a bug.
            committedText = String(sentence.drop { $0.isWhitespace })
        } else {
            committedText += gap + sentence
        }
        gap = ""
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
