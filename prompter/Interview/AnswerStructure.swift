import Foundation

/// The answer's small, **closed** structure — the only format the answer prompt asks for
/// (`backend/server.mjs`, "HOW TO WRITE IT"): a lead paragraph, points on lines starting "- ", and
/// short anchor phrases wrapped in `==…==`. Not Markdown: nothing else is interpreted, so a stray
/// asterisk or `#` is just text.
///
/// **The source keeps the syntax; nothing else ever sees it.** Stored prose blocks hold the raw
/// lines (bullet prefix and markers included), so a reopened answer is rebuilt exactly. Everything
/// shown, aligned, tokenised or read aloud goes through `Prose.text`, which has neither.
///
/// **Streaming-safe by construction.** The whole streamed text is re-parsed on every chunk, so the
/// rules only have to be right for a prefix of the final text:
/// - a marker that has not closed yet is hidden, and its phrase renders as plain text until the
///   closing `==` arrives — then only the background changes, never the glyphs or their positions;
/// - a trailing `=` or `==` at the end of the stream is held back (it may be half a marker);
/// - a line that so far is only a bullet character (`-`) shows nothing until its words arrive, and a
///   line starting `- ` is a point from its first word.
enum AnswerStructure {
    static let bulletPrefixes = ["- ", "• ", "* "]
    static let marker = "=="
    /// The lead's highlight plus one key term in a few points; later marks render as plain text.
    static let maximumEmphasis = 4
    /// A highlight carries the answer (the lead's is up to about ten words) but is never a sentence:
    /// longer phrases render as plain text.
    static let maximumEmphasisWords = 12
    static let maximumEmphasisLength = 90
    /// Without spaces (Chinese, Japanese) a "word" count says nothing, so length decides alone.
    static let maximumUnspacedEmphasisLength = 24

    struct Prose: Equatable {
        enum Role: Equatable { case lead, body, bullet }
        /// Which element of the answer's `blocks` this came from.
        let blockIndex: Int
        let role: Role
        /// What is shown and read aloud: no bullet prefix, no markers.
        let text: String
        /// Semantic emphasis, as UTF-16 ranges into `text`.
        let emphasis: [NSRange]
    }

    static func isBullet(_ raw: String) -> Bool {
        let trimmed = raw.drop { $0 == " " }
        return bulletPrefixes.contains { trimmed.hasPrefix($0) } || isBareBulletMark(raw)
    }

    /// "-" alone: a point whose words have not arrived yet.
    static func isBareBulletMark(_ raw: String) -> Bool {
        ["-", "•", "*"].contains(raw.trimmingCharacters(in: .whitespaces))
    }

    /// The text of one prose block with its bullet prefix and markers removed, and where the
    /// accepted marked phrases are.
    ///
    /// A marker opens only before a non-space and closes only after one, so `x == y` stays literal.
    /// Inside a backtick span nothing is a marker. An opener that never closes is hidden.
    static func strip(_ raw: String, isStreamTail: Bool = false) -> (text: String, emphasis: [NSRange]) {
        if isBareBulletMark(raw) { return ("", []) }
        var body = Substring(raw.trimmingCharacters(in: .whitespaces))
        if let prefix = bulletPrefixes.first(where: { body.hasPrefix($0) }) {
            body = body.dropFirst(prefix.count).drop { $0 == " " }
        }
        let chars = Array(body)
        var text = ""
        var ranges: [NSRange] = []
        var openAt: Int?                      // UTF-16 offset in `text` where an open phrase starts
        var i = 0
        func utf16Count() -> Int { (text as NSString).length }
        while i < chars.count {
            let c = chars[i]
            // A backtick span is copied as is: code never carries a marker.
            if c == "`", let close = chars[(i + 1)...].firstIndex(of: "`") {
                text += String(chars[i...close])
                i = close + 1
                continue
            }
            if c == "=", i + 1 < chars.count, chars[i + 1] == "=" {
                let before: Character? = i > 0 ? chars[i - 1] : nil
                let after: Character? = i + 2 < chars.count ? chars[i + 2] : nil
                if let start = openAt, let before, !before.isWhitespace {
                    let length = utf16Count() - start
                    if length > 0 { ranges.append(NSRange(location: start, length: length)) }
                    openAt = nil
                    i += 2
                    continue
                }
                if openAt == nil, let after, !after.isWhitespace, after != "=" {
                    openAt = utf16Count()
                    i += 2
                    continue
                }
                if after == nil, isStreamTail || openAt == nil {
                    // `==` at the very end: half of a marker still arriving, or an opener with
                    // nothing after it. Either way it is not text anyone should see.
                    i += 2
                    continue
                }
            }
            if c == "=", i == chars.count - 1, isStreamTail,
               i == 0 || chars[i - 1] != "=" {
                // A single `=` at the very end of the stream may be the first half of `==`.
                i += 1
                continue
            }
            text.append(c)
            i += 1
        }
        // Whatever was held back at the end (half a marker) may leave the space before it behind.
        while text.last?.isWhitespace == true { text.removeLast() }
        let length = (text as NSString).length
        let clamped = ranges.compactMap { range -> NSRange? in
            let end = min(range.location + range.length, length)
            return end > range.location ? NSRange(location: range.location, length: end - range.location) : nil
        }
        let accepted = clamped.filter { isAcceptableEmphasis(($0.location, $0.length), in: text) }
        return (text, accepted)
    }

    /// Restraint the app enforces whatever the model sends: a few words, never the whole point,
    /// never a sentence, never code.
    static func isAcceptableEmphasis(_ range: (location: Int, length: Int), in text: String) -> Bool {
        let phrase = (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !trimmed.isEmpty, !phrase.contains("`") else { return false }
        let whole = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard trimmed != whole else { return false }
        if phrase.contains(where: { "。！？!?".contains($0) }) || phrase.contains(". ") { return false }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        if words.count <= 1, trimmed.unicodeScalars.contains(where: isUnspacedScript) {
            return trimmed.count <= maximumUnspacedEmphasisLength
        }
        return words.count <= maximumEmphasisWords && (phrase as NSString).length <= maximumEmphasisLength
    }

    private static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: true
        default: false
        }
    }

    static func displayText(_ raw: String) -> String { strip(raw).text }

    /// Every prose block of an answer that has something to show, with its role and emphasis.
    ///
    /// The last block is the stream's tail and holds back a half-arrived marker. Emphasis is capped
    /// across the whole answer, first come first kept, so a later chunk never moves an earlier one.
    static func prose(of blocks: [AnswerBlock]) -> [Prose] {
        let lastProse = blocks.lastIndex { if case .prose = $0 { true } else { false } }
        var result: [Prose] = []
        var emphasised = 0
        for (index, block) in blocks.enumerated() {
            guard case .prose(let raw) = block else { continue }
            let (text, ranges) = strip(raw, isStreamTail: index == lastProse)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let kept = Array(ranges.prefix(max(0, maximumEmphasis - emphasised)))
            emphasised += kept.count
            let role: Prose.Role = isBullet(raw) ? .bullet : (result.isEmpty ? .lead : .body)
            result.append(Prose(blockIndex: index, role: role, text: text, emphasis: kept))
        }
        return result
    }

    /// What speech-following, tokenisation and reading alignment see: the shown text only,
    /// paragraphs separated by a blank line, in the same order and count as `prose(of:)`.
    static func spokenText(of blocks: [AnswerBlock]) -> String {
        prose(of: blocks).map(\.text).joined(separator: "\n\n")
    }

    /// Whether an answer carries the structure at all — old answers and older backends do not, and
    /// then render exactly as before (heuristic keyword weight, no lead styling).
    static func isStructured(_ blocks: [AnswerBlock]) -> Bool {
        blocks.contains { block in
            guard case .prose(let raw) = block else { return false }
            return isBullet(raw) || raw.contains(marker)
        }
    }
}
