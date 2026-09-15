import Testing
import Foundation
@testable import prompter

/// Replay of a real, *working* device read (M5.1, 2026-08-22) — the regression guard for the
/// freshest-token gate.
///
/// The first version of `RecoverySearch.hasFreshestTokenSupport` required the newest spoken word
/// to be a full per-token match (`perTokenMatchThreshold`, 0.8) against the script token it would
/// land on. That froze the cursor on device: streaming ASR emits the correct word imperfectly all
/// the time, and every such word vetoed the advance outright.
///
/// The words below are taken verbatim from a device trace that advanced *correctly* before the
/// gate existed, including its real ASR errors. The decisive one is "write" for the script's
/// "written" (raw similarity 0.71): the device log recorded
///
///     VOLATILE-FED 1 word(s) "write"  cursor -> token 10  confidence=0.85  state=advancing
///
/// so a matcher that refuses to advance there is refusing to track a normal read.
struct RealDeviceReadReplayTests {
    @Test
    func imperfectAsrOnTheNewestWordStillAdvances() {
        let tokens = ScriptIndex.build(from: PromptDemoFixture.defaultScriptText).tokenTexts
        let matcher = SlidingWindowMatcher(scriptTokens: tokens, config: .default)

        // Verbatim fed-word sequence and audio timings from the device trace.
        let fed: [(t: TimeInterval, word: String)] = [
            (4.12, "welcome"), (4.14, "to"), (6.00, "prompter"),
            (7.95, "this"), (7.97, "is"), (8.94, "a"), (8.95, "longer"), (8.97, "test"),
            (9.88, "script"),
            // ASR heard "write"; the script says "written". This is the case that froze.
            (13.75, "write"),
        ]

        var cursor = matcher.current
        for step in fed {
            cursor = matcher.advance(spoken: [Token(step.word, at: step.t)], now: step.t)
        }

        // Script tokens 0-8 are "welcome to prompter this is a longer test script"; token 9 is
        // "written". A healthy matcher is at 10 here, exactly as the device logged.
        #expect(cursor.tokenIndex >= 10, "cursor stalled at \(cursor.tokenIndex) — a normal read with ordinary ASR noise must keep advancing")
    }

    /// The gate must still do its job: a genuinely unrelated word does not advance, even with a
    /// window full of real matches behind it. Without this, loosening the threshold above could
    /// silently reopen the meta-commentary false jump.
    @Test
    func anUnrelatedNewestWordStillDoesNotAdvance() {
        let tokens = ScriptIndex.build(from: PromptDemoFixture.defaultScriptText).tokenTexts
        let matcher = SlidingWindowMatcher(scriptTokens: tokens, config: .default)

        var now: TimeInterval = 0
        for word in tokens[0..<9] {
            now += 0.4
            _ = matcher.advance(spoken: [Token(word, at: now)], now: now)
        }
        let before = matcher.current.tokenIndex
        #expect(before == 9, "precondition: clean read should reach 9, got \(before)")

        // "zzzzqqq" has no relation to the script's next token.
        now += 0.4
        let after = matcher.advance(spoken: [Token("zzzzqqq", at: now)], now: now)
        #expect(after.tokenIndex == before, "an unrelated newest word must not advance the cursor")
    }
}
