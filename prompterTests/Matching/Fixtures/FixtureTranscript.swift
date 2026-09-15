import Foundation
@testable import prompter

/// One simulated spoken session against a script, with ground truth to score the matcher
/// against (§10.5, §16 M1 gate). `checkpoints` are fed to `SlidingWindowMatcher.advance`
/// in order; `expectedCursor` is what a perfect tracker should report immediately after that
/// checkpoint.
struct FixtureTranscript {
    struct Checkpoint {
        let tokens: [Token]
        let now: TimeInterval
        let expectedCursor: Int
    }

    let scriptName: String
    let scenario: String
    let scriptTokens: [String]
    let checkpoints: [Checkpoint]

    var spokenWordCount: Int {
        checkpoints.reduce(0) { $0 + $1.tokens.count }
    }

    /// Re-stamps every checkpoint at a flat `perWord` cadence, leaving the token sequence,
    /// checkpoint grouping and `expectedCursor` ground truth **byte-identical**.
    ///
    /// This is what makes the M1 gate's timing change auditable rather than a silent denominator
    /// swap: the same 28 fixtures, the same 1307 checkpoints and the same 6395 spoken words can be
    /// scored under the historical constant cadence and under the measured one, and any difference
    /// in the result is attributable to timing alone (M5.2, docs/MATCHING_ENGINE.md).
    ///
    /// `pause(seconds:)` checkpoints carry no tokens; their gap is preserved verbatim so the
    /// silence-freeze fixtures keep testing silence.
    func retimedAtConstantCadence(perWord: TimeInterval = 0.4) -> FixtureTranscript {
        var time: TimeInterval = 0
        var previousNow: TimeInterval = 0
        var rebuilt: [Checkpoint] = []
        for checkpoint in checkpoints {
            if checkpoint.tokens.isEmpty {
                time += checkpoint.now - previousNow   // preserve the silence gap exactly
            } else {
                time += perWord * Double(checkpoint.tokens.count)
            }
            previousNow = checkpoint.now
            rebuilt.append(Checkpoint(
                tokens: checkpoint.tokens.map { Token($0.text, at: time) },
                now: time,
                expectedCursor: checkpoint.expectedCursor
            ))
        }
        return FixtureTranscript(scriptName: scriptName, scenario: scenario, scriptTokens: scriptTokens, checkpoints: rebuilt)
    }
}

/// Deterministic ASR-noise simulation shared by the misrecognition fixtures.
enum ASRNoise {
    static let homophones: [String: String] = [
        "there": "their", "their": "there", "to": "too", "too": "to",
        "for": "four", "four": "for", "here": "hear", "hear": "here",
        "know": "no", "no": "know", "right": "write", "write": "right",
        "would": "wood", "wood": "would", "new": "knew", "knew": "new",
        "week": "weak", "weak": "week", "made": "maid", "sea": "see",
        "see": "sea", "one": "won", "won": "one", "buy": "by", "by": "buy",
        "meet": "meat", "meat": "meet", "which": "witch", "witch": "which",
        "where": "wear", "wear": "where", "some": "sum", "sum": "some",
    ]

    /// Uses a known homophone when one exists, otherwise perturbs one character — either way
    /// simulating a plausible ASR misrecognition rather than a random string.
    static func corrupt(_ word: String) -> String {
        if let homophone = homophones[word] { return homophone }
        guard word.count >= 3 else { return word }
        var chars = Array(word)
        let mid = chars.count / 2
        chars.swapAt(mid, mid - 1)
        return String(chars)
    }
}

/// Builds up a `FixtureTranscript.checkpoints` list while tracking simulated audio time at a
/// ~150 wpm speaking rate (§12.3).
final class TranscriptBuilder {
    struct SpokenUnit {
        /// Script token index (exclusive upper bound) a correct tracker should have reached
        /// after this unit is spoken. Off-script content (ad-libs) repeats the prior value.
        let coveredThrough: Int
        /// Word actually appearing in the transcript, or nil if the ASR dropped it.
        let emitted: String?
    }

    private(set) var checkpoints: [FixtureTranscript.Checkpoint] = []
    private var time: TimeInterval = 0
    /// Index into `SyntheticTiming.pattern`, advanced once per spoken word so the whole fixture suite
    /// inherits the measured bursty cadence instead of a flat constant.
    private var timingStep = 0

    /// Advances the clock by one word using the **measured** device inter-word gap distribution
    /// rather than a flat 0.4 s (M5.2, docs/MATCHING_ENGINE.md — "timing fidelity"). Real ASR
    /// settles two or three words at once and then pauses; a constant hid a whole class of bug in
    /// which a time-based matcher rule passes every fixture and does nothing on device.
    private func advanceClock() {
        time += SyntheticTiming.pattern[timingStep % SyntheticTiming.pattern.count]
        timingStep += 1
    }

    func speak(_ units: [SpokenUnit], batchSize: Int = 5) {
        var i = 0
        while i < units.count {
            let batchEnd = min(i + batchSize, units.count)
            var tokens: [Token] = []
            for j in i..<batchEnd {
                advanceClock()
                if let word = units[j].emitted {
                    tokens.append(Token(word, at: time))
                }
            }
            checkpoints.append(.init(tokens: tokens, now: time, expectedCursor: units[batchEnd - 1].coveredThrough))
            i = batchEnd
        }
    }

    func pause(seconds: TimeInterval, expectedCursor: Int) {
        time += seconds
        checkpoints.append(.init(tokens: [], now: time, expectedCursor: expectedCursor))
    }

    static func clean(scriptTokens: [String], range: Range<Int>) -> [SpokenUnit] {
        range.map { SpokenUnit(coveredThrough: $0 + 1, emitted: scriptTokens[$0]) }
    }
}
