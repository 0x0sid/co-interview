import SwiftUI

/// Renders script text with the live read styling, driven by a matcher's `PromptCursor`. Shared
/// by the real Prompt screen and the M1 debug replay screen so both agree on exactly how cursor
/// state maps to text appearance.
///
/// **Design — grey means "you actually said this", nothing else.**
///
/// Every earlier version drove the colour from the *cursor position*: grey everything behind the
/// cursor. That is wrong, and a real device trace showed exactly why. While the reader talked
/// off-script, the matcher jumped the cursor 14 → 20 → 26 → 43 → 100 → 119 → 156 and parked
/// there for over a minute. Because ~150 tokens were now "behind the cursor", the screen greyed
/// out most of a script the reader had never spoken a word of — while they were still, in their
/// own words, only up to "welcome to Prompter".
///
/// So the input here is `spokenTokenIndices`: the set of tokens the reader is *known to have
/// pronounced*. `PromptViewModel.newlySpokenTokens` builds it **per word, never per interval** —
/// only the words in a given feed are eligible, paired positionally back from the new cursor, and
/// each is added only if it actually resembles the script token it landed on. Recovery adds
/// nothing at all.
///
/// That distinction is not academic: an earlier version inserted the whole span
/// `previous..<new` on any `.advancing` move, and on the 2026-09-10 device session a single
/// `155 -> 184 advancing` step greyed **29 tokens the reader had not said**. Tokens skipped over by
/// a jump or a recovery are never added, so **anything not actually spoken stays full-contrast
/// `ink`, no matter where the cursor goes.**
///
/// Nothing else changes colour: no current-word marker (that flickered), no sentence-wide or
/// paragraph-wide sweep (that greyed unread text).
enum ScriptStyling {
    /// One sentence's styled text plus enough layout metadata for `PromptScreen` to lay sentences
    /// out as separate views (so `ScrollViewReader` has a per-sentence `id` to auto-scroll to) and
    /// space out paragraph breaks.
    struct SentenceBlock: Identifiable {
        let id: Int
        let isFirstInParagraph: Bool
        let text: Text
    }

    static func styledText(
        rawText: String,
        scriptIndex: ScriptIndex,
        cursor: PromptCursor,
        spokenTokenIndices: Set<Int> = [],
        palette: OutdoorMode.Palette = OutdoorMode.normal
    ) -> Text {
        Text(styledAttributedString(rawText: rawText, scriptIndex: scriptIndex, cursor: cursor, spokenTokenIndices: spokenTokenIndices, palette: palette))
    }

    /// The current sentence's text up to and including the word being read.
    ///
    /// Laid out invisibly at the block's own width, its rendered height is the vertical offset of
    /// the line the reader is on — real line geometry, where a token fraction was only an estimate
    /// (M5.3.2, docs/DECISIONS.md).
    static func prefixOfCurrentSentence(rawText: String, scriptIndex: ScriptIndex, cursor: PromptCursor) -> String {
        let index = currentSentenceIndex(scriptIndex: scriptIndex, cursor: cursor)
        guard index >= 0, index < scriptIndex.sentences.count else { return "" }
        let sentence = scriptIndex.sentences[index]
        let tokenIndex = min(max(cursor.tokenIndex, sentence.tokenStart), scriptIndex.tokens.count)
        let endOffset = tokenIndex > sentence.tokenStart && tokenIndex - 1 < scriptIndex.tokens.count
            ? scriptIndex.tokens[tokenIndex - 1].rangeEnd
            : sentence.rangeStart
        guard endOffset >= sentence.rangeStart, endOffset <= sentence.rangeEnd else { return "" }
        let start = String.Index(utf16Offset: sentence.rangeStart, in: rawText)
        let end = String.Index(utf16Offset: endOffset, in: rawText)
        guard start <= end, end <= rawText.endIndex else { return "" }
        return String(rawText[start..<end])
    }

    /// Same styling as `styledText`, split into one block per sentence (per `ScriptIndex.sentences`)
    /// so `PromptScreen` can render each as its own `Text` with a stable `.id()` for auto-scroll.
    static func sentenceBlocks(
        rawText: String,
        scriptIndex: ScriptIndex,
        cursor: PromptCursor,
        spokenTokenIndices: Set<Int> = [],
        palette: OutdoorMode.Palette = OutdoorMode.normal
    ) -> [SentenceBlock] {
        let attributed = styledAttributedString(rawText: rawText, scriptIndex: scriptIndex, cursor: cursor, spokenTokenIndices: spokenTokenIndices, palette: palette)
        var previousParagraph = -1
        return scriptIndex.sentences.enumerated().compactMap { index, sentence in
            let start = String.Index(utf16Offset: sentence.rangeStart, in: rawText)
            let end = String.Index(utf16Offset: sentence.rangeEnd, in: rawText)
            guard let attrRange = Range(start..<end, in: attributed) else { return nil }
            let isFirstInParagraph = sentence.paragraphIndex != previousParagraph
            previousParagraph = sentence.paragraphIndex
            return SentenceBlock(id: index, isFirstInParagraph: isFirstInParagraph, text: Text(AttributedString(attributed[attrRange])))
        }
    }

    /// The sentence the cursor is currently inside (or the script's last sentence once the cursor
    /// has run past the end) — the thing `PromptScreen` auto-scrolls to keep visible, and the
    /// sentence the scroll anchor targets.
    static func currentSentenceIndex(scriptIndex: ScriptIndex, cursor: PromptCursor) -> Int {
        if cursor.tokenIndex < scriptIndex.tokens.count {
            return scriptIndex.tokens[cursor.tokenIndex].sentenceIndex
        }
        return scriptIndex.tokens.last?.sentenceIndex ?? 0
    }

    /// Continuous-scroll support: how far the cursor is through the *current* sentence, as a
    /// 0...1 fraction of that sentence's token count — `PromptScreen` uses this to nudge the
    /// scroll position progressively within a sentence instead of only jumping on sentence
    /// boundaries.
    static func progressWithinCurrentSentence(scriptIndex: ScriptIndex, cursor: PromptCursor) -> Double {
        let index = currentSentenceIndex(scriptIndex: scriptIndex, cursor: cursor)
        guard index < scriptIndex.sentences.count else { return 0 }
        let sentence = scriptIndex.sentences[index]
        let span = sentence.tokenEnd - sentence.tokenStart
        guard span > 0 else { return 0 }
        let progressed = min(max(cursor.tokenIndex - sentence.tokenStart, 0), span)
        return Double(progressed) / Double(span)
    }

    /// Not `private`: `ScriptStylingTests` inspects the raw `AttributedString` runs directly —
    /// `Text` doesn't expose its underlying attributes back out.
    static func styledAttributedString(
        rawText: String,
        scriptIndex: ScriptIndex,
        cursor: PromptCursor,
        spokenTokenIndices: Set<Int> = [],
        palette: OutdoorMode.Palette = OutdoorMode.normal,
        underlineSpoken: Bool = false
    ) -> AttributedString {
        var attributed = AttributedString(rawText)
        // Default: full-contrast ink. Anything not proven spoken stays this colour — including
        // text the cursor has moved past without the reader ever saying it.
        attributed.foregroundColor = palette.ink

        // Grey exactly the tokens the reader actually pronounced. Nothing is inferred from the
        // cursor's position: a jump forward leaves everything it skipped black.
        for index in spokenTokenIndices where index >= 0 && index < scriptIndex.tokens.count {
            let token = scriptIndex.tokens[index]
            guard let attrRange = attributedRange(rangeStart: token.rangeStart, rangeEnd: token.rangeEnd, rawText: rawText, attributed: attributed) else { continue }
            // Ultra Contrast never dims the answer: a spoken word keeps full ink and is underlined.
            if underlineSpoken {
                attributed[attrRange].underlineStyle = .single
            } else {
                attributed[attrRange].foregroundColor = palette.spoken
            }
        }

        return attributed
    }

    private static func attributedRange(
        rangeStart: Int,
        rangeEnd: Int,
        rawText: String,
        attributed: AttributedString
    ) -> Range<AttributedString.Index>? {
        let start = String.Index(utf16Offset: rangeStart, in: rawText)
        let end = String.Index(utf16Offset: rangeEnd, in: rawText)
        return Range(start..<end, in: attributed)
    }
}
