import Foundation

/// Per-token similarity and windowed alignment scoring (§10.3). Pure functions, no state.
enum ConfidenceModel {
    /// Classic Levenshtein edit distance between two strings (character-level).
    static func levenshteinDistance(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }

        var previous = Array(0...bChars.count)
        var current = [Int](repeating: 0, count: bChars.count + 1)

        for i in 1...aChars.count {
            current[0] = i
            for j in 1...bChars.count {
                if aChars[i - 1] == bChars[j - 1] {
                    current[j] = previous[j - 1]
                } else {
                    current[j] = 1 + min(previous[j - 1], min(previous[j], current[j - 1]))
                }
            }
            swap(&previous, &current)
        }
        return previous[bChars.count]
    }

    /// Normalized Levenshtein similarity, 0...1, with no thresholding applied. `tokenSimilarity`
    /// below zeroes anything under `perTokenMatchThreshold` because *scoring* wants a token to
    /// contribute either real credit or none. Callers that need to ask the softer question
    /// "is this word even in the same neighbourhood as that one?" — telling an ASR wobble
    /// ("write" for "written", 0.71) apart from unrelated speech ("can" vs "page", 0.25) — need
    /// the raw figure, since both are simply 0 after thresholding.
    static func rawSimilarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 1.0 }
        let distance = levenshteinDistance(a, b)
        return 1.0 - Double(distance) / Double(maxLen)
    }

    /// Per-token similarity (§10.3): 1.0 for an exact match, else normalized Levenshtein
    /// similarity if it clears `perTokenMatchThreshold` ("absorbs ASR errors"), else 0 — a token
    /// that isn't at least a fuzzy match contributes no credit rather than partial noise.
    static func tokenSimilarity(_ a: String, _ b: String, config: MatcherConfig) -> Double {
        let normalized = rawSimilarity(a, b)
        if normalized == 1.0 { return 1.0 }
        return normalized >= config.perTokenMatchThreshold ? normalized : 0.0
    }

    /// Aligns `spokenWindow` (oldest-first) positionally against `scriptWindow` starting at a
    /// candidate anchor, with a linear recency ramp so the most recently spoken token weighs
    /// `recencyWeightMultiplier`x the oldest one in the window (§10.3 — "the speaker's mouth is
    /// at the end of the buffer"). `recencyWeightMultiplier`, when passed explicitly, overrides
    /// `config.recencyWeightMultiplier` — used by `RecoverySearch` to score with
    /// `config.recoveryRecencyMultiplier` instead, since recency bias is a local-tracking
    /// concept that doesn't apply to "does this window align here at all" (M4).
    static func score(
        spokenWindow: [String],
        scriptWindow: [String],
        config: MatcherConfig,
        recencyWeightMultiplier: Double? = nil
    ) -> Double {
        let n = min(spokenWindow.count, scriptWindow.count)
        guard n > 0 else { return 0.0 }
        let multiplier = recencyWeightMultiplier ?? config.recencyWeightMultiplier

        var weightedSum = 0.0
        var weightTotal = 0.0
        for i in 0..<n {
            let recencyFraction = n > 1 ? Double(i) / Double(n - 1) : 1.0
            let weight = 1.0 + recencyFraction * (multiplier - 1.0)
            weightedSum += tokenSimilarity(spokenWindow[i], scriptWindow[i], config: config) * weight
            weightTotal += weight
        }
        return weightTotal > 0 ? weightedSum / weightTotal : 0.0
    }

    /// Where a join happened: which spoken position covered which two script tokens.
    struct JoinSite {
        let spokenIndex: Int
        /// First of the two adjacent script tokens this spoken word covered.
        let scriptIndex: Int
    }

    /// Result of a join-aware alignment walk.
    struct JoinedAlignment {
        /// Recency-weighted score, normalized over the **spoken** positions exactly as `score` is,
        /// so a joined alignment is directly comparable to a 1:1 one and to every threshold.
        let score: Double
        /// How many *script* tokens the walk consumed. This is what the cursor destination is
        /// computed from — one more than the spoken count for each join, because the reader really
        /// did say both script tokens.
        let scriptConsumed: Int
        /// Script index the newest spoken token aligned to, for a join-aware freshest-token check.
        let freshestScriptIndex: Int
        /// Number of joins applied. 0 means this walk is identical to the 1:1 path.
        let joins: Int
        /// Exactly where each join occurred. Needed to report the join truthfully: the joined pair
        /// is generally **not** at the freshest position, so naming the newest word would describe
        /// a join that did not happen.
        let joinSites: [JoinSite]
    }

    /// Alignment walk that permits one spoken token to cover **two adjacent script tokens** when the
    /// recogniser emitted a compound as a single word (§12, M5.6).
    ///
    /// Eligibility is deliberately narrow, and each condition is load-bearing:
    ///
    /// 1. the ordinary 1:1 pairing at this position must already have **failed**
    ///    (`tokenSimilarity` below `perTokenMatchThreshold`), so nothing that currently matches can
    ///    change behaviour;
    /// 2. the concatenation must be a **near-exact** match (`joinedTokenMinSimilarity`, 0.95) — this
    ///    is what stops it becoming broad partial credit for unrelated substitutions;
    /// 3. it must beat the 1:1 alternative at that position;
    /// 4. at most `maximumJoinsPerWindow` joins per window.
    ///
    /// **Positions advance independently**: the spoken index always advances by 1, the script index
    /// by 1 normally and by 2 on a join. **Normalization is unchanged** — the denominator is the
    /// weight total over spoken positions, so a join cannot inflate a window's score above what the
    /// same words would score if the script had them as one token.
    static func alignWithJoin(
        spokenWindow: [String],
        scriptTokens: [String],
        anchor: Int,
        config: MatcherConfig,
        recencyWeightMultiplier: Double? = nil
    ) -> JoinedAlignment? {
        guard !spokenWindow.isEmpty, anchor >= 0, anchor < scriptTokens.count else { return nil }
        let multiplier = recencyWeightMultiplier ?? config.recencyWeightMultiplier

        // First pass: walk to discover how many spoken positions can be aligned and where the joins
        // fall. The recency weight depends on the *count* of aligned positions, so it cannot be
        // applied until that count is known.
        var similarities: [Double] = []
        var joinFlags: [Bool] = []
        var joinSites: [JoinSite] = []
        var scriptIndex = anchor
        var joins = 0
        var freshestScriptIndex = anchor
        for (spokenIndex, spoken) in spokenWindow.enumerated() {
            guard scriptIndex < scriptTokens.count else { break }
            let direct = tokenSimilarity(spoken, scriptTokens[scriptIndex], config: config)
            var similarity = direct
            var isJoin = false
            if config.allowSplitScriptTokenJoin,
               joins < config.maximumJoinsPerWindow,
               direct < config.perTokenMatchThreshold,
               scriptIndex + 1 < scriptTokens.count {
                let joined = rawSimilarity(spoken, scriptTokens[scriptIndex] + scriptTokens[scriptIndex + 1])
                if joined >= config.joinedTokenMinSimilarity, joined > direct {
                    similarity = joined
                    isJoin = true
                }
            }
            similarities.append(similarity)
            joinFlags.append(isJoin)
            freshestScriptIndex = scriptIndex
            if isJoin {
                joinSites.append(JoinSite(spokenIndex: spokenIndex, scriptIndex: scriptIndex))
                joins += 1
            }
            scriptIndex += isJoin ? 2 : 1
        }

        let n = similarities.count
        guard n > 0 else { return nil }

        var weightedSum = 0.0
        var weightTotal = 0.0
        for i in 0..<n {
            let recencyFraction = n > 1 ? Double(i) / Double(n - 1) : 1.0
            let weight = 1.0 + recencyFraction * (multiplier - 1.0)
            weightedSum += similarities[i] * weight
            weightTotal += weight
        }
        return JoinedAlignment(
            score: weightTotal > 0 ? weightedSum / weightTotal : 0.0,
            scriptConsumed: scriptIndex - anchor,
            freshestScriptIndex: freshestScriptIndex,
            joins: joins,
            joinSites: joinSites
        )
    }
}
