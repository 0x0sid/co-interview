import Foundation

/// Anchor search over a range of script tokens — used both for the normal local search and the
/// widened recovery search (§10.2), so the scanning loop isn't duplicated.
enum RecoverySearch {
    struct Candidate {
        let anchor: Int
        let score: Double
        /// Script tokens the alignment consumed. Equals the spoken window size on the ordinary 1:1
        /// path; larger when a split-script-token join fired (§12, M5.6). `applyAdvance` uses this
        /// for the cursor destination.
        let scriptConsumed: Int
        /// Script index the newest spoken token aligned to, so the freshest-token gate can ask about
        /// the right position when a join has shifted it.
        let freshestScriptIndex: Int
        /// Number of joins in this alignment. 0 means it is identical to the 1:1 path.
        let joins: Int
        /// Where each join occurred, so a join can be reported truthfully rather than by guessing
        /// it happened at the newest word.
        let joinSites: [ConfidenceModel.JoinSite]

        init(anchor: Int, score: Double, scriptConsumed: Int, freshestScriptIndex: Int,
             joins: Int = 0, joinSites: [ConfidenceModel.JoinSite] = []) {
            self.anchor = anchor
            self.score = score
            self.scriptConsumed = scriptConsumed
            self.freshestScriptIndex = freshestScriptIndex
            self.joins = joins
            self.joinSites = joinSites
        }
    }

    /// Scores every anchor in `range` (clamped to valid script bounds) and returns the best one.
    /// `requireDistinctiveSupport`, when true, skips any anchor whose matching positions are
    /// *entirely* common words (§10.4, M4) — used only by `recoverySearch` below, never by the
    /// local search inside `SlidingWindowMatcher.advance()` (which always passes the default
    /// `false`), so this has no effect on ordinary per-tick matching.
    static func bestAnchor(
        spokenWindow: [String],
        scriptTokens: [String],
        range: Range<Int>,
        config: MatcherConfig,
        requireDistinctiveSupport: Bool = false,
        recencyWeightMultiplier: Double? = nil,
        allowJoin: Bool = false
    ) -> Candidate? {
        guard !scriptTokens.isEmpty, !spokenWindow.isEmpty else { return nil }
        let lowerBound = max(0, range.lowerBound)
        let upperBound = min(scriptTokens.count, range.upperBound)
        guard lowerBound < upperBound else { return nil }

        var best: Candidate?
        for anchor in lowerBound..<upperBound {
            let end = min(scriptTokens.count, anchor + spokenWindow.count)
            guard end > anchor else { continue }
            let scriptWindow = Array(scriptTokens[anchor..<end])
            if requireDistinctiveSupport,
               !hasDistinctiveSupport(spokenWindow: spokenWindow, scriptWindow: scriptWindow, config: config) {
                continue
            }
            // `allowJoin` is passed only by the local search in `SlidingWindowMatcher.advance()`.
            // The recovery and suffix paths keep the strict 1:1 walk they have always used, so this
            // change cannot move a recovery jump or a re-acquisition.
            let candidate: Candidate
            if allowJoin, config.allowSplitScriptTokenJoin,
               let joined = ConfidenceModel.alignWithJoin(
                   spokenWindow: spokenWindow,
                   scriptTokens: scriptTokens,
                   anchor: anchor,
                   config: config,
                   recencyWeightMultiplier: recencyWeightMultiplier
               ) {
                candidate = Candidate(
                    anchor: anchor,
                    score: joined.score,
                    scriptConsumed: joined.scriptConsumed,
                    freshestScriptIndex: joined.freshestScriptIndex,
                    joins: joined.joins,
                    joinSites: joined.joinSites
                )
            } else {
                let score = ConfidenceModel.score(
                    spokenWindow: spokenWindow,
                    scriptWindow: scriptWindow,
                    config: config,
                    recencyWeightMultiplier: recencyWeightMultiplier
                )
                candidate = Candidate(
                    anchor: anchor,
                    score: score,
                    scriptConsumed: scriptWindow.count,
                    freshestScriptIndex: anchor + scriptWindow.count - 1
                )
            }
            if best == nil || candidate.score > best!.score {
                best = candidate
            }
        }
        return best
    }

    /// True if at least one aligned position is both a real match (similarity ≥
    /// `perTokenMatchThreshold`, i.e. counts as a match per §10.3) and a non-common word. A
    /// candidate built entirely from common-word coincidences — the root cause of
    /// `cookingIntro/adLibInsertion`'s false jumps (docs/MATCHING_ENGINE.md, M4) — has none.
    private static func hasDistinctiveSupport(spokenWindow: [String], scriptWindow: [String], config: MatcherConfig) -> Bool {
        for i in 0..<min(spokenWindow.count, scriptWindow.count) {
            guard !config.commonWords.contains(scriptWindow[i]) else { continue }
            if ConfidenceModel.tokenSimilarity(spokenWindow[i], scriptWindow[i], config: config) >= config.perTokenMatchThreshold {
                return true
            }
        }
        return false
    }

    /// True if the *most recently spoken* token — the final aligned position, which the
    /// recency-weighted score in `ConfidenceModel.score` already treats as most significant — is
    /// at least *plausibly related* to the script token the candidate aligns it to.
    ///
    /// Guards against a stale, already-confirmed window (8 real matches from *previous* ticks)
    /// carrying an unrelated final word (an ad-lib) across `advanceThreshold` on the strength of
    /// old evidence alone. Real incident: ad-libbing "can" mid-tangent scored 0.85 overall
    /// because the other 8 positions in the window were genuine matches from moments earlier —
    /// but the window's own final position was "page", and "can" has no relation to it.
    /// `hasDistinctiveSupport` above does not catch this: it only asks whether *any*
    /// non-common-word position anywhere in the window matches, and those stale real matches
    /// already satisfy that trivially.
    ///
    /// **Uses `freshestTokenMinSimilarity` (0.5) on the raw similarity, NOT a full match.** The
    /// first version of this gate demanded `perTokenMatchThreshold` (0.8) and froze the cursor on
    /// real device reads: streaming ASR routinely emits the right word imperfectly ("write" for
    /// "written" = 0.71, "prompt" for "prompter" = 0.75), and rejecting those rejects normal
    /// reading. The point is to reject *unrelated* words, not imperfect ones.
    static func hasFreshestTokenSupport(spokenWindow: [String], scriptTokens: [String], anchor: Int, config: MatcherConfig) -> Bool {
        let end = min(scriptTokens.count, anchor + spokenWindow.count)
        guard end > anchor else { return false }
        let scriptWindow = Array(scriptTokens[anchor..<end])
        let n = min(spokenWindow.count, scriptWindow.count)
        guard n > 0 else { return false }
        return ConfidenceModel.rawSimilarity(spokenWindow[n - 1], scriptWindow[n - 1]) >= config.freshestTokenMinSimilarity
    }

    /// Freshest-token support for an alignment that may contain a join, which shifts the script
    /// index the newest spoken word lands on. Without this the gate would test the newest word
    /// against the wrong token and reject exactly the alignments the join exists to accept.
    ///
    /// The newest word is also allowed to satisfy the gate against the **joined pair** it covers, so
    /// a trailing `backup` supports its own alignment against `back` `up`.
    static func hasFreshestTokenSupport(
        spokenWindow: [String],
        scriptTokens: [String],
        candidate: Candidate,
        config: MatcherConfig
    ) -> Bool {
        guard let newest = spokenWindow.last else { return false }
        let index = candidate.freshestScriptIndex
        guard index >= 0, index < scriptTokens.count else { return false }
        if ConfidenceModel.rawSimilarity(newest, scriptTokens[index]) >= config.freshestTokenMinSimilarity {
            return true
        }
        // The newest token may itself be the join.
        if candidate.joins > 0, index + 1 < scriptTokens.count {
            let joined = scriptTokens[index] + scriptTokens[index + 1]
            if ConfidenceModel.rawSimilarity(newest, joined) >= config.freshestTokenMinSimilarity {
                return true
            }
        }
        return false
    }

    /// Widened recovery search (§10.2): try `[cursor, cursor + recoveryWindowForward]` first,
    /// then the whole script; a candidate only counts if it clears `recoveryJumpThreshold` *and*
    /// has distinctive support (M4) — a high score from common-word coincidence alone doesn't
    /// count as evidence of a real match.
    static func recoverySearch(
        spokenWindow: [String],
        scriptTokens: [String],
        cursor: Int,
        config: MatcherConfig
    ) -> Candidate? {
        let nearRange = cursor..<(cursor + config.recoveryWindowForward)
        if let near = bestAnchor(
            spokenWindow: spokenWindow,
            scriptTokens: scriptTokens,
            range: nearRange,
            config: config,
            requireDistinctiveSupport: true,
            recencyWeightMultiplier: config.recoveryRecencyMultiplier
        ), near.score >= config.recoveryJumpThreshold {
            return near
        }

        let wholeScript = 0..<scriptTokens.count
        if let whole = bestAnchor(
            spokenWindow: spokenWindow,
            scriptTokens: scriptTokens,
            range: wholeScript,
            config: config,
            requireDistinctiveSupport: true,
            recencyWeightMultiplier: config.recoveryRecencyMultiplier
        ), whole.score >= config.recoveryJumpThreshold {
            return whole
        }

        return nil
    }

    /// Best candidate across both the near-range and whole-script searches, *without* the
    /// `recoveryJumpThreshold` gate `recoverySearch` applies — evidence-gathering only, used by
    /// `SlidingWindowMatcher` to snapshot the best opportunity seen on every stalled tick, not
    /// just the tick the sustain timer happens to arm on. The timer/eviction race this fixes: the
    /// ring buffer's useful content can be evicted by newer speech before the timer allows a
    /// jump, so by the time recovery is *permitted* to act, `recoverySearch`'s fresh, current-tick
    /// candidate may already be worse than one seen earlier in the same stall (M4,
    /// docs/MATCHING_ENGINE.md — token-155 freeze on build 56ba154). The threshold check still
    /// happens exactly once, at the moment the matcher acts on the retained snapshot.
    static func bestStallCandidate(
        spokenWindow: [String],
        scriptTokens: [String],
        cursor: Int,
        config: MatcherConfig
    ) -> Candidate? {
        let nearRange = cursor..<(cursor + config.recoveryWindowForward)
        let near = bestAnchor(
            spokenWindow: spokenWindow,
            scriptTokens: scriptTokens,
            range: nearRange,
            config: config,
            requireDistinctiveSupport: true,
            recencyWeightMultiplier: config.recoveryRecencyMultiplier
        )

        let wholeScript = 0..<scriptTokens.count
        let whole = bestAnchor(
            spokenWindow: spokenWindow,
            scriptTokens: scriptTokens,
            range: wholeScript,
            config: config,
            requireDistinctiveSupport: true,
            recencyWeightMultiplier: config.recoveryRecencyMultiplier
        )

        switch (near, whole) {
        case let (near?, whole?): return near.score >= whole.score ? near : whole
        case let (near?, nil): return near
        case let (nil, whole?): return whole
        case (nil, nil): return nil
        }
    }
}
