import Testing
@testable import prompter

struct RecoveryTests {
    let config = MatcherConfig.default

    @Test
    func bestAnchorFindsExactMatchOverNoise() {
        let script = ["the", "quick", "brown", "fox", "jumps", "over", "the", "lazy", "dog"]
        let spoken = ["brown", "fox", "jumps"]
        let best = RecoverySearch.bestAnchor(spokenWindow: spoken, scriptTokens: script, range: 0..<script.count, config: config)
        #expect(best?.anchor == 2)
        #expect(best?.score == 1.0)
    }

    @Test
    func bestAnchorScoresLowWhenRealMatchIsOutsideRange() {
        // Plain 2-digit numeric strings: a single-digit substitution between two of them already
        // fails the 0.8 per-token threshold (1 - 1/2 = 0.5), so there's no coincidental near-match
        // the way there would be with a longer shared prefix like "tok10" vs "tok20".
        let script = Array(10..<60).map { String($0) }
        let spoken = ["10", "11"]
        let best = RecoverySearch.bestAnchor(spokenWindow: spoken, scriptTokens: script, range: 20..<30, config: config)
        // The real match (script index 0, value "10") is outside [20, 30), so nothing in range
        // should score above the per-token match threshold.
        #expect((best?.score ?? 0) < config.perTokenMatchThreshold)
    }

    @Test
    func recoverySearchFindsFarAnchorWithinNearWindowFirst() {
        var script = Array(0..<450).map { "tok\($0)" }
        script[300] = "zzzzzzzzzz"
        let spoken = ["zzzzzzzzzz"]
        let result = RecoverySearch.recoverySearch(spokenWindow: spoken, scriptTokens: script, cursor: 0, config: config)
        #expect(result?.anchor == 300)
        #expect(result?.score == 1.0)
    }

    @Test
    func recoverySearchFallsBackToWholeScriptBeyondNearWindow() {
        var script = Array(0..<900).map { "tok\($0)" }
        script[800] = "zzzzzzzzzz"
        let spoken = ["zzzzzzzzzz"]
        // cursor + recoveryWindowForward (400) = 400, so index 800 is only reachable via the
        // whole-script fallback.
        let result = RecoverySearch.recoverySearch(spokenWindow: spoken, scriptTokens: script, cursor: 0, config: config)
        #expect(result?.anchor == 800)
    }

    @Test
    func recoverySearchReturnsNilWhenNothingClearsJumpThreshold() {
        let script = Array(0..<50).map { "tok\($0)" }
        let result = RecoverySearch.recoverySearch(spokenWindow: ["completelydifferent"], scriptTokens: script, cursor: 0, config: config)
        #expect(result == nil)
    }
}
