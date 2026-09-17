import Foundation
import Observation
import SwiftUI

/// Aligns live speech against **one immutable piece of text** and records which of its words the
/// reader has actually pronounced.
///
/// Extracted from `PromptViewModel` (M5 behaviour, unchanged) so the same alignment can serve both the
/// script reader and the interview copilot, where each answer version needs its own independent
/// alignment while a single audio session runs underneath. `PromptViewModel` now owns the audio
/// session and delegates every alignment decision here; the rules, thresholds and comments below are
/// the originals.
///
/// **Deviation from §11.4 (logged in docs/DECISIONS.md, 2026-08-13)**: originally only `.final`
/// deltas were fed to the matcher, per `TranscriptStream`'s "volatile is display-only" contract.
/// Two rounds of on-device `[PromptDebug]` logging showed `.final` results arriving 2-15s apart
/// even during continuous reading — since the cursor only ever moved on `.final`, this alone
/// explained the reported "a lot of delay", and it also meant the matcher's own silence-freeze
/// timer (which only resets on `.final`) fired ~1.5s after nearly every sentence regardless of
/// whether the reader had actually gone quiet, producing the reported "unstable"
/// advancing-then-frozen cycling. Fixed by incrementally feeding the *newly appended* words from
/// each `.volatile` delta to the matcher too, not just `.final` — kept safe against volatile's
/// well-known revision behavior by only ever feeding a strict prefix-extension of what was already
/// fed, and by having the eventual `.final` catch up on anything volatile never got a chance to (a
/// mid-utterance revision, or the tail end of a sentence).
@MainActor
@Observable
final class ReadingAlignment {
    /// The text being read. Immutable for the lifetime of this object: the matcher captures its tokens
    /// at initialisation, so text that could change would invalidate every token index, spoken marker
    /// and cursor position. Growing answers are handled by creating a new alignment for a new frozen
    /// segment (see `AnswerVersion.readableSegments`), never by mutating this.
    let text: String
    let scriptIndex: ScriptIndex

    private(set) var cursor = PromptCursor(tokenIndex: 0, confidence: 0, state: .holding)

    /// Tokens the reader is *known to have pronounced* — the only thing `ScriptStyling` is allowed
    /// to grey out.
    ///
    /// Deliberately not "everything before the cursor". A real device trace (2026-08-22) had the
    /// matcher jump the cursor 14 → 20 → 26 → 43 → 100 → 119 → 156 while the reader talked
    /// off-script, and a position-based rule greyed ~150 tokens they had never spoken — most of
    /// the script, while they were still at "welcome to Prompter". Only ordinary, small,
    /// `.advancing` steps count as reading; jumps and recoveries move the cursor without marking
    /// anything, so skipped text stays black because it genuinely was not read.
    private(set) var spokenTokenIndices: Set<Int> = []
    private(set) var listeningText = ""

    private var matcher: SlidingWindowMatcher
    /// Recently fed words, used to pair a reacquisition against the clause that supported it.
    private var fedHistory: [String] = []
    /// Token positions a landing crossed, which contextual bridging may never span.
    private var continuityBreaks: Set<Int> = []
    /// Normalized words already fed from `.volatile` deltas for the *current* in-flight utterance.
    private var volatileWordsFedToMatcher: [String] = []
    private var lastFinalAudioTimestamp: TimeInterval?

    /// What one delta did, so a caller can tell whether the speech it carried actually belonged to
    /// this text. The copilot uses it as *text* evidence, never as speaker identification.
    struct IngestOutcome: Equatable, Sendable {
        var fedWordCount: Int = 0
        var newlySpokenCount: Int = 0
        var didAdvance: Bool = false
        var cursorMoved: Bool = false
    }

    init(text: String) {
        self.text = text
        let index = ScriptIndex.build(from: text)
        self.scriptIndex = index
        self.matcher = SlidingWindowMatcher(scriptIndex: index)
    }

    /// True once the cursor has run past the end of the text on a real advance.
    var isComplete: Bool {
        !scriptIndex.tokens.isEmpty && cursor.tokenIndex >= scriptIndex.tokens.count
    }

    /// §11.7 / M4 Step 3: distinctive vocabulary fed to the transcriber as a recognition bias.
    /// Reuses `MatcherConfig.commonWords` as the "not distinctive" filter, deduplicated, capped at 100.
    var distinctiveVocabulary: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for token in scriptIndex.tokenTexts {
            guard !MatcherConfig.default.commonWords.contains(token) else { continue }
            guard seen.insert(token).inserted else { continue }
            result.append(token)
            if result.count >= 100 { break }
        }
        return result
    }

    /// Begins again from the top with a fresh matcher: nothing has been spoken yet in this take.
    func restart() {
        matcher = SlidingWindowMatcher(scriptIndex: scriptIndex)
        cursor = matcher.current
        spokenTokenIndices = []
        fedHistory = []
        continuityBreaks = []
        volatileWordsFedToMatcher = []
        lastFinalAudioTimestamp = nil
        listeningText = ""
    }

    /// Continues with the *existing* matcher — cursor, ring buffer and confidence untouched. Used when
    /// a take resumes after an interruption, and when the copilot returns to a card being read.
    func resumeKeepingProgress() {
        cursor = matcher.current
        listeningText = ""
    }

    /// Feeds one transcript delta. Returns what it changed.
    @discardableResult
    func ingest(_ delta: TranscriptDelta, animated: Bool = true) -> IngestOutcome {
        switch delta.kind {
        case .volatile:
            listeningText = delta.text
            let words = Tokenizer.normalize(delta.text)
            // Withhold the trailing word — the one word still in a position to be revised by whatever
            // comes next in this same utterance (docs/ARCHITECTURE.md, "Volatile reconciliation") — it
            // only becomes safe to feed once a later word appears after it (proving it settled) or the
            // eventual `.final` confirms it via the catch-up diff below.
            let stableWordCount = max(0, words.count - 1)
            let alreadyFed = volatileWordsFedToMatcher.count
            // Only feed the new tail if this volatile update is a strict extension of what we already
            // fed — if the ASR revised earlier words instead of just appending, skip it silently
            // rather than feed something possibly wrong; the next `.final` will catch up.
            guard stableWordCount > alreadyFed, Array(words.prefix(alreadyFed)) == volatileWordsFedToMatcher else {
                return IngestOutcome()
            }
            let newWords = Array(words[alreadyFed..<stableWordCount])
            let newTokens = newWords.map { Token($0, at: delta.timestamp) }
            let outcome = apply(
                matcher.advance(spoken: newTokens, now: delta.timestamp),
                fedWords: newWords,
                animation: animated ? .easeInOut(duration: 0.2) : nil
            )
            volatileWordsFedToMatcher = Array(words[0..<stableWordCount])
            return outcome

        case .final:
            lastFinalAudioTimestamp = delta.timestamp
            listeningText = ""
            // A same-length correction (e.g. volatile fed "rid", final corrects it to "rides") isn't
            // caught by comparing counts alone — walk word-by-word and re-feed from the first point of
            // disagreement, so a same-position correction isn't silently lost.
            var matchingPrefixCount = 0
            while matchingPrefixCount < volatileWordsFedToMatcher.count,
                  matchingPrefixCount < delta.tokens.count,
                  volatileWordsFedToMatcher[matchingPrefixCount] == delta.tokens[matchingPrefixCount].text {
                matchingPrefixCount += 1
            }
            let catchUpTokens = Array(delta.tokens.suffix(from: matchingPrefixCount))
            volatileWordsFedToMatcher = []
            return apply(
                matcher.advance(spoken: catchUpTokens, now: delta.timestamp),
                fedWords: catchUpTokens.map(\.text),
                animation: animated ? .easeInOut(duration: 0.25) : nil
            )
        }
    }

    /// Real silence produces no deltas at all, so the matcher never gets a chance to notice a gap and
    /// trigger `.frozen` (§10.4, "the eye contact feature"). The caller ticks this in the transcript's
    /// own clock domain.
    func tick(now: TimeInterval) {
        cursor = matcher.advance(spoken: [], now: now)
    }

    private func apply(_ newCursor: PromptCursor, fedWords: [String], animation: Animation?) -> IngestOutcome {
        guard let animation else {
            return applyCursor(newCursor, fedWords: fedWords)
        }
        var outcome = IngestOutcome()
        withAnimation(animation) {
            outcome = applyCursor(newCursor, fedWords: fedWords)
        }
        return outcome
    }

    /// Moves the cursor, and records which tokens that particular move *proves* were spoken.
    ///
    /// The test is the matcher's own state, not the size of the step. `.advancing` means the local
    /// search tracked continuous reading; `.recovering` means it gave up and jumped to a new position,
    /// which proves nothing about the text in between.
    @discardableResult
    private func applyCursor(_ newCursor: PromptCursor, fedWords: [String] = []) -> IngestOutcome {
        let previousIndex = cursor.tokenIndex

        // Recent history, not just this feed: the words that supported a reacquisition are usually
        // already in the buffer by the time the landing happens (M5.4).
        fedHistory.append(contentsOf: fedWords)
        if fedHistory.count > Self.fedHistoryLimit {
            fedHistory.removeFirst(fedHistory.count - Self.fedHistoryLimit)
        }

        // A landing the reader may not have read through: never bridge across it.
        if newCursor.state == .recovering || newCursor.tokenIndex - previousIndex > MatcherConfig.default.forwardCapWithoutRecovery {
            continuityBreaks.insert(newCursor.tokenIndex)
            continuityBreaks.insert(previousIndex)
        }

        let direct = Self.newlySpokenTokens(
            fedWords: fedHistory,
            from: previousIndex,
            to: newCursor.tokenIndex,
            state: newCursor.state,
            scriptTokens: scriptIndex.tokenTexts
        )
        spokenTokenIndices.formUnion(direct)

        let bridged = Self.bridgedTokens(
            directlySpoken: spokenTokenIndices,
            continuityBreaks: continuityBreaks,
            maximumGap: Self.maximumBridgedTokens
        ).subtracting(spokenTokenIndices)
        spokenTokenIndices.formUnion(bridged)

        #if DEBUG
        // Direct and inferred coverage are reported separately, so inferred is never mistaken for
        // recognition in evidence (M5.4, docs/DECISIONS.md).
        if !direct.isEmpty || !bridged.isEmpty {
            let tokens = scriptIndex.tokenTexts
            func describe(_ set: Set<Int>) -> String {
                set.sorted().map { "\($0):\($0 < tokens.count ? tokens[$0] : "?")" }.joined(separator: " ")
            }
            print("[Styling] applyCursor \(previousIndex)->\(newCursor.tokenIndex) \(newCursor.state) fed=\(fedWords) direct=[\(describe(direct))] bridged=[\(describe(bridged))]")
        } else if newCursor.tokenIndex > previousIndex {
            print("[Styling] applyCursor \(previousIndex)->\(newCursor.tokenIndex) \(newCursor.state) fed=\(fedWords) direct=NONE bridged=NONE (skipped text stays dark)")
        }
        #endif

        cursor = newCursor
        return IngestOutcome(
            fedWordCount: fedWords.count,
            newlySpokenCount: direct.count + bridged.count,
            didAdvance: newCursor.state == .advancing,
            cursorMoved: newCursor.tokenIndex != previousIndex
        )
    }

    // MARK: - The pure rules (unchanged from `PromptViewModel`, which now forwards to them)

    /// Returns the script tokens these words confirm as **directly** spoken.
    ///
    /// **Evidence decides, not the cursor state.** Recovery must not grey the interval it skipped, but
    /// the words it was given — and the words still in recent history that supported the reacquisition
    /// — are real speech that aligned to real script tokens. Both properties come from one cap:
    /// eligibility never reaches further back than the supplied words, so a jump cannot colour the
    /// interval it crossed, whatever its state.
    ///
    /// A single failed pair is treated as an ASR **substitution** and skipped; **two consecutive**
    /// failures stop the walk, which is the signature of an insertion shifting every earlier pair.
    nonisolated static func newlySpokenTokens(
        fedWords: [String],
        from previousIndex: Int,
        to newIndex: Int,
        state: PromptCursor.State,
        scriptTokens: [String]
    ) -> Set<Int> {
        guard newIndex > previousIndex, !fedWords.isEmpty else { return [] }
        var result: Set<Int> = []
        let earliestEligible = max(0, newIndex - fedWords.count)
        var tokenIndex = newIndex - 1
        var wordIndex = fedWords.count - 1
        var consecutiveFailures = 0
        var sawFailure = false
        while tokenIndex >= earliestEligible, wordIndex >= 0 {
            // **The bar rises after the first failure.** Pairs before any failure are anchored to the
            // newest word — the best-supported pairing available, since it is the one the matcher
            // advanced on. Once a pair fails the alignment may also have shifted, so every later pair
            // compounds a second source of error and must be strong rather than merely plausible.
            let bar = sawFailure ? shiftedPairMinSimilarity : spokenWordMinSimilarity
            let matched = tokenIndex >= 0 && tokenIndex < scriptTokens.count
                && ConfidenceModel.rawSimilarity(fedWords[wordIndex], scriptTokens[tokenIndex]) >= bar
            if matched {
                result.insert(tokenIndex)
                consecutiveFailures = 0
            } else {
                sawFailure = true
                consecutiveFailures += 1
                if consecutiveFailures >= 2 { break }
            }
            tokenIndex -= 1
            wordIndex -= 1
        }
        return result
    }

    /// Fills short gaps **between two directly confirmed tokens**, so one misrecognised word does not
    /// leave a clause dark while the reader demonstrably read through it (M5.4).
    ///
    /// Strictly bounded: at most `maximumBridgedTokens` contiguous dark tokens, only with a direct
    /// anchor on **both** sides, and never across a `continuityBreak`. Ambiguity leaves tokens unmarked.
    nonisolated static func bridgedTokens(
        directlySpoken: Set<Int>,
        continuityBreaks: Set<Int>,
        maximumGap: Int
    ) -> Set<Int> {
        guard directlySpoken.count >= 2 else { return [] }
        let sorted = directlySpoken.sorted()
        var bridged: Set<Int> = []
        for (before, after) in zip(sorted, sorted.dropFirst()) {
            let gap = after - before - 1
            guard gap > 0, gap <= maximumGap else { continue }
            let span = (before + 1)...(after - 1)
            guard !span.contains(where: { continuityBreaks.contains($0) }),
                  !continuityBreaks.contains(after) else { continue }
            bridged.formUnion(span)
        }
        return bridged
    }

    /// Longest run of unconfirmed tokens that may be inferred as read. About one clause.
    nonisolated static let maximumBridgedTokens = 6

    /// Similarity a pair must reach **after** an earlier pair in the same walk has failed, when the
    /// alignment may have shifted. Deliberately `MatcherConfig.perTokenMatchThreshold` (0.8).
    nonisolated static let shiftedPairMinSimilarity = 0.8

    /// How many recently fed words are retained for pairing.
    nonisolated static let fedHistoryLimit = 16

    /// How closely a fed word must resemble the script token it landed on before that token is shown
    /// as spoken. Deliberately the same 0.5 "is this even the same word?" bar as
    /// `MatcherConfig.freshestTokenMinSimilarity`: streaming ASR emits the right word imperfectly all
    /// the time ("write" for "written" = 0.71), and demanding a full match would leave genuinely-read
    /// words stubbornly black.
    nonisolated static let spokenWordMinSimilarity = 0.5
}
