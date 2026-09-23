import Foundation
import SwiftUI

/// The few words in an answer worth finding at a glance.
///
/// **What this is for.** The answer is read aloud under pressure. Between sentences the speaker
/// looks back at the screen and has to re-find their place and the thing they were about to say —
/// the class name, the version, the figure. Emphasising those makes the page scannable without
/// turning it into a summary.
///
/// **Why weight and not colour.** Colour already means something here: `ScriptStyling` greys the
/// words the reader has actually spoken, which is the live reading feedback. A keyword coloured
/// differently would either be mistaken for reading state or would fight it. Emphasis is therefore
/// carried by **font weight**, which composes with the fade instead of competing with it — a spoken
/// keyword goes grey and stays bold.
///
/// **Deliberately local and deterministic.** No model call, no second request, nothing to wait for:
/// the answer is already streaming and an emphasis that arrived late would move text under the
/// reader's eye. These are shape rules — identifiers, acronyms, versions, figures — not an attempt
/// to understand the sentence.
enum AnswerKeywords {
    /// A span of the answer to emphasise, in UTF-16 offsets into the text it was found in.
    struct Span: Equatable, Sendable {
        let start: Int
        let end: Int
    }

    /// At most this many spans per answer.
    ///
    /// Emphasis only works while it is scarce. An answer with forty bold words is an answer with no
    /// bold words, so the longest, most specific candidates win and the rest are left plain.
    static let maximumSpans = 12

    /// The shortest run of characters worth emphasising. Two-letter tokens are noise.
    static let minimumLength = 2

    /// Finds the spans worth emphasising in `text`.
    ///
    /// Overlaps are resolved in favour of the longer span, so "LinkedHashSet" is emphasised once
    /// rather than colliding with a nested match.
    static func spans(in text: String) -> [Span] {
        guard !text.isEmpty else { return [] }
        var candidates: [Span] = []

        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern.regex) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in expression.matches(in: text, range: range) {
                // Group 1 when the pattern defines one (so "Java 8" emphasises without its
                // surrounding punctuation), otherwise the whole match.
                let captured = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound
                    ? match.range(at: 1)
                    : match.range
                guard captured.location != NSNotFound, captured.length >= minimumLength else { continue }
                candidates.append(Span(start: captured.location, end: captured.location + captured.length))
            }
        }

        return prune(candidates)
    }

    /// Drops overlaps and anything past the budget.
    ///
    /// Longest first: a longer span is the more specific one, and specificity is the whole point.
    /// Ties break on position so the result is stable for the same input.
    private static func prune(_ candidates: [Span]) -> [Span] {
        let ordered = candidates.sorted { left, right in
            let leftLength = left.end - left.start
            let rightLength = right.end - right.start
            if leftLength != rightLength { return leftLength > rightLength }
            return left.start < right.start
        }

        var kept: [Span] = []
        for candidate in ordered {
            guard kept.count < maximumSpans else { break }
            let overlaps = kept.contains { existing in
                candidate.start < existing.end && existing.start < candidate.end
            }
            if !overlaps { kept.append(candidate) }
        }
        return kept.sorted { $0.start < $1.start }
    }

    /// Emphasises the keyword spans of `source` inside an attributed string built from it.
    ///
    /// Sets **only** the font, to the caller's own face at a heavier weight.
    ///
    /// `inlinePresentationIntent = .stronglyEmphasized` looked right in a unit test and wrong on
    /// screen: SwiftUI resolved it against a different family, so emphasised runs rendered visibly
    /// smaller than the serif around them and broke the line's rhythm. Handing in the exact bold
    /// font keeps the typeface and optical size identical and changes only the weight.
    ///
    /// No colour is set either way, so `ScriptStyling`'s reading fade remains the only thing colour
    /// means — a spoken keyword greys out and stays bold.
    static func emphasise(_ attributed: inout AttributedString, source: String, font: Font) {
        for span in spans(in: source) {
            guard let range = attributedRange(span, source: source, attributed: attributed) else { continue }
            attributed[range].font = font
        }
    }

    /// An attributed copy of `text` with its keywords emphasised and its inline-code markers hidden.
    static func emphasised(_ text: String, font: Font) -> AttributedString {
        var attributed = AttributedString(text)
        emphasise(&attributed, source: text, font: font)
        hideInlineCodeMarkers(&attributed)
        return attributed
    }

    /// Removes the backticks around inline code from what is **displayed**.
    ///
    /// The model marks inline code the Markdown way, and `var` with its backticks is not something
    /// to read aloud. They are removed here, at the very end, from the attributed string only: the
    /// reading text, its tokens and the speech-following alignment are built from the original and
    /// never see the change — the tokenizer ignores punctuation, so the spoken words are identical
    /// either way. The code itself keeps its emphasis, which was applied before this runs.
    static func hideInlineCodeMarkers(_ attributed: inout AttributedString) {
        let plain = String(attributed.characters)
        guard plain.contains("`"),
              let regex = try? NSRegularExpression(pattern: "`([^`\n]{1,40})`") else { return }
        let matches = regex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
        // Back to front, so earlier offsets stay valid while later characters are removed.
        for match in matches.reversed() {
            for offset in [match.range.location + match.range.length - 1, match.range.location] {
                let index = String.Index(utf16Offset: offset, in: plain)
                guard let range = Range(index..<plain.index(after: index), in: attributed) else { continue }
                attributed.removeSubrange(range)
            }
        }
    }

    private static func attributedRange(
        _ span: Span,
        source: String,
        attributed: AttributedString
    ) -> Range<AttributedString.Index>? {
        guard span.start >= 0, span.end <= source.utf16.count, span.start < span.end else { return nil }
        let start = String.Index(utf16Offset: span.start, in: source)
        let end = String.Index(utf16Offset: span.end, in: source)
        return Range(start..<end, in: attributed)
    }

    private struct Pattern {
        let regex: String
    }

    /// Shape rules, in no particular order — `prune` decides what survives.
    ///
    /// Each is a thing a speaker loses their place on: a name they must get exactly right, a version
    /// that changes the answer, or a number they are quoting.
    private static let patterns: [Pattern] = [
        // `inline code`, when the model marks it. The backticks are excluded from the span.
        Pattern(regex: "`([^`\n]{2,40})`"),
        // CamelCase and PascalCase identifiers: HashMap, LinkedHashSet, ConcurrentHashMap.
        Pattern(regex: "\\b[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]*)+\\b"),
        // Acronyms: API, SQL, JPMS, UDP, JVM. Bounded so a shouted sentence is not all keyword.
        Pattern(regex: "\\b[A-Z]{2,6}\\b"),
        // A named thing with a version: Java 8, Swift 6, HTTP/2, Node 22.
        Pattern(regex: "\\b([A-Z][A-Za-z.+#]{1,14}\\s?/?\\s?\\d+(?:\\.\\d+)?)\\b"),
        // Figures the speaker is quoting: 18 per cent, 89%, 1.4 million.
        Pattern(regex: "\\b(\\d+(?:\\.\\d+)?\\s?(?:%|per cent|percent|million|billion|thousand|ms|s\\b))"),
        // Method-ish and dotted identifiers: queue.enqueue, Stream.of, System.out.
        Pattern(regex: "\\b[a-zA-Z][A-Za-z0-9]*\\.[a-zA-Z][A-Za-z0-9]*(?:\\(\\))?"),

        // --- Ordinary language, not code -------------------------------------------------------
        //
        // A speaker loses their place on more than identifiers. These are the phrases an answer
        // turns on: the quantity being quoted, the named thing, the term being defined, and the
        // clause that carries the actual claim.

        // A bare quantity with its unit: "512 items", "two years", "40 requests".
        //
        // The unit is a closed list on purpose. An open "number followed by a word" rule matched
        // "8 added" in "Java 8 added the Stream API" — and because it was the longer span it won,
        // emphasising a fragment that means nothing and hiding the version that does.
        Pattern(regex: "\\b(\\d+(?:\\.\\d+)?\\s+(?:items?|records?|rows?|requests?|users?|messages?|bytes?|"
                     + "seconds?|minutes?|hours?|days?|weeks?|months?|years?|times?|entries|threads?|nodes?|calls?))\\b"),
        Pattern(regex: "\\b((?:twice|three|four|five|ten)\\s+(?:times|fold))\\b"),
        // Multi-word proper nouns: "Mill Street", "Stream API", "Project Jigsaw".
        Pattern(regex: "\\b([A-Z][a-z]{2,}\\s[A-Z][A-Za-z]{1,})\\b"),
        // A term being introduced or defined — the word the sentence exists to name.
        Pattern(regex: "(?:called|known as|named|that is|which is)\\s+([a-z]{4,}(?:\\s[a-z]{3,}){0,2})"),
        // Something in quotes is being pointed at deliberately.
        Pattern(regex: "[\u{201C}\"]([^\u{201D}\"\n]{3,40})[\u{201D}\"]"),
    ]
}
