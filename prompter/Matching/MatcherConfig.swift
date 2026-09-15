import Foundation

/// All matcher thresholds live here (§10.5) so the fixture replay harness can tune
/// them in one place. Values below are the shipping defaults; see
/// docs/MATCHING_ENGINE.md for the reasoning and the fixture-suite results that
/// validated them.
struct MatcherConfig: Equatable {
    /// Ring buffer of most-recently-spoken normalized tokens (§10.2).
    var ringBufferSize = 20

    /// Local search window around the cursor, in script tokens: [cursor - back, cursor + forward].
    var localSearchBackward = 10
    var localSearchForward = 40

    /// Number of trailing spoken tokens aligned against a candidate anchor (§10.3, K = 6-12).
    var alignmentWindow = 9

    /// Per-token normalized-Levenshtein similarity at/above this counts as a match (§10.3).
    var perTokenMatchThreshold = 0.8

    /// How similar the *newest* spoken word must be to the script token it would land on for an
    /// ordinary local advance to be allowed at all (`RecoverySearch.hasFreshestTokenSupport`).
    ///
    /// Deliberately far looser than `perTokenMatchThreshold`, and measured on the *raw*
    /// similarity. This gate exists to stop an unrelated off-script word riding forward on the
    /// strength of older matches still in the window — not to demand clean ASR. Streaming
    /// recognition emits imperfect words constantly ("write" for "written" = 0.71, "prompt" for
    /// "prompter" = 0.75), and requiring a full match here froze the cursor on real device reads
    /// (M5.1). 0.5 separates the two populations: ASR wobble on the right word stays well above
    /// it, genuinely unrelated speech ("can" vs "page" = 0.25) stays well below.
    var freshestTokenMinSimilarity = 0.5

    /// Recency weighting multiplier applied to the most recent token in the alignment window
    /// relative to the oldest (linear ramp), per §10.3 ("latest spoken tokens x2").
    var recencyWeightMultiplier = 2.0

    /// Local-search score at/above this advances the cursor (§10.2).
    var advanceThreshold = 0.72

    /// How many consecutive updates the best local anchor must advance consistently before a
    /// *tracked* read may advance at `trackedAdvanceThreshold` instead of `advanceThreshold`.
    ///
    /// **Evidence, not a loosened threshold.** In the captured 2026-09-12 stall the cursor sat at
    /// token 216 for 9.6 s while the reader read paragraph 4 continuously. Replaying it shows the
    /// local anchor tracking them perfectly the whole time — 207, 208, 209, 210, 211, 212, 213, 214,
    /// 215, 216, 217, 219, 220, 221, 222, 223, one token per fed word — with the score hovering at
    /// 0.62-0.70, just under `advanceThreshold`, until it finally touched 0.722 and advanced.
    ///
    /// A monotonically advancing anchor is independent evidence that the alignment is following the
    /// reader, and it is exactly what off-script speech does *not* produce: in the M5.1 capture the
    /// off-script anchors jump around (53, 202, 40, 41, 43, 6). So a *run* of consistent anchors can
    /// justify an advance that a single mediocre score cannot, without changing `advanceThreshold`
    /// for anything else.
    ///
    // MARK: - Split-script-token join (M5.6)

    /// Allows one spoken token to align against **two adjacent script tokens** when the recogniser
    /// emits a compound as a single word — the captured `backup` against the script's `back` `up`.
    ///
    /// This is a narrow correction to *alignment*, not to scoring generosity. It applies only where
    /// the ordinary 1:1 pairing has already failed, and only when the concatenation is a near-exact
    /// match (`joinedTokenMinSimilarity`), so it cannot hand partial credit to an unrelated
    /// substitution. See docs/MATCHING_ENGINE.md §12.
    var allowSplitScriptTokenJoin = true

    /// How close `spoken` must be to `script[i] + script[i+1]` for the join to be eligible.
    /// Deliberately far above `perTokenMatchThreshold` (0.8): the captured case scores **1.000**,
    /// and anything materially below that is a guess rather than a tokenisation difference.
    var joinedTokenMinSimilarity = 0.95

    /// At most this many joins per alignment window. Bounded to the demonstrated mismatch — there is
    /// no evidence for multi-join windows, and an unbounded walk could consume the script far faster
    /// than the reader is speaking.
    var maximumJoinsPerWindow = 1

    /// Each step still requires `hasFreshestTokenSupport`, so a run cannot be built from stale
    /// window content. Setting this to `Int.max` disables the path; the control test does that.
    var trackedRunLength = 3

    /// Score bar for an advance backed by a consistent anchor run. Only reachable with
    /// `trackedRunLength` consecutive consistent, freshest-supported anchors.
    /// **0.70 is swept, not chosen.** All four constraints measured together, only this satisfies
    /// them; `0.60` breaks the M5.2 cursor-lost P0 at every run length by creeping the cursor through
    /// an ad-lib, and `run >= 4` preserves the P0 but no longer breaks the stall:
    ///
    /// ```
    ///   run  bar  | P0 (want 30...70)  meta (<=100)  stall cursor @127.9s  M1 false jumps
    ///   off  --   |   42                  60              216                  0
    ///    3   0.60 |   24  LOST            60              224                  0
    ///    3   0.65 |   42                  60              220                  0
    ///    3   0.70 |   42                  60              220                  0   <- shipped
    ///    4   0.65 |   42                  60              216  (no gain)       0
    ///    5   0.70 |   42                  60              216  (no gain)       0
    /// ```
    ///
    /// 0.65 and 0.70 are indistinguishable on every measurement, so the stricter is taken: the
    /// concession is 0.02 below `advanceThreshold`, granted only on three consecutive consistent
    /// freshest-supported anchors.
    var trackedAdvanceThreshold = 0.70

    /// How far the local anchor may move between updates and still count as consistent. One token
    /// per word is the norm; two tolerates a single dropped or merged word.
    var trackedAnchorStep = 1

    /// Local-search score below this, sustained, triggers recovery search (§10.2).
    var recoveryTriggerThreshold = 0.45

    /// How long low confidence must persist (in seconds of spoken audio time, not wall clock)
    /// before recovery search runs (§10.2).
    var recoverySustainedSeconds: TimeInterval = 2.5

    /// How long *mediocre* confidence (the ambiguous band between `recoveryTriggerThreshold`
    /// and `advanceThreshold` — not confident enough to advance, not low enough to have already
    /// counted toward `recoverySustainedSeconds`) must persist before it also arms recovery
    /// search. Longer than `recoverySustainedSeconds` on purpose: a mid-band score is closer to
    /// correct than a clearly-low one, so it shouldn't trip recovery as eagerly (M4, on-device
    /// "cursor gets stuck / slow to transition" report — docs/MATCHING_ENGINE.md).
    var mediocreConfidenceSustainedSeconds: TimeInterval = 4.0

    /// Recovery search first widens to [cursor, cursor + this], then the whole script (§10.2).
    var recoveryWindowForward = 400

    /// Alignment window size used only by `RecoverySearch` (not local per-tick scoring, which
    /// keeps using `alignmentWindow`). A single ordinary ASR near-miss landing in the last
    /// position or two of a 9-token window can single-handedly veto an otherwise 7-of-9-exact
    /// candidate; a wider window dilutes one near-miss across more genuinely-matching tokens
    /// (M4, docs/MATCHING_ENGINE.md — token-155 freeze on build 56ba154). Tuned empirically
    /// against the real failing window, not assumed — see MATCHING_ENGINE.md for the numbers.
    var recoveryAlignmentWindow = 12

    /// Recency weighting multiplier used only by `RecoverySearch`, independent of
    /// `recencyWeightMultiplier` (which stays local-tracking-only, unchanged). Recovery is
    /// asking "does this window align here at all", not "where is the mouth right now" — the
    /// question recency bias exists to answer doesn't apply, and doubling the weight of the
    /// single most recent token is exactly what let one ASR near-miss veto an otherwise
    /// strongly-matching candidate (M4). Flat by default (1.0 = no recency bias).
    var recoveryRecencyMultiplier: Double = 1.0

    /// Recovery / big-forward-jump candidates must score at/above this to actually move the
    /// cursor (§10.2, §10.4).
    var recoveryJumpThreshold = 0.80

    /// How long a stall must persist before a recovery candidate is held to the stricter
    /// `extendedStallJumpThreshold` below instead of the ordinary `recoveryJumpThreshold`.
    /// A short stall is most likely misrecognized *on-script* speech (an ASR stumble, a skipped
    /// line) — recovery should stay eager. A stall this long is much more likely to be genuine
    /// *off-script* speech, where any high-scoring candidate is more plausibly a coincidence than
    /// a real reading position (M5.1, docs/MATCHING_ENGINE.md — the meta-commentary false jump).
    var extendedStallSeconds: TimeInterval = 8.0

    /// Recovery jump bar applied once a stall has lasted `extendedStallSeconds`. Deliberately set
    /// between the two achievable scores either side of the real failure: with
    /// `recoveryAlignmentWindow` = 12 and flat recovery recency, 10-of-12 matches scores 0.8333
    /// (the observed false jump) and 11-of-12 scores 0.9167. 0.88 sits in that gap, so a long
    /// off-script stretch must align *near-perfectly* (11+ of 12) to move the cursor, while one
    /// ordinary ASR error in an otherwise-clean return to the script still recovers.
    var extendedStallJumpThreshold = 0.88

    /// Shortest suffix of the alignment window that may be scored on its own when the full window
    /// fails to clear `advanceThreshold` (§ "M5.2 — the suffix-window re-acquisition rule",
    /// docs/MATCHING_ENGINE.md).
    ///
    /// When a reader resumes reading after off-script speech, the window straddles the boundary:
    /// its older half is the ad-lib, its newer half is real reading, and no anchor scores well
    /// against the whole thing. Re-scoring against just the newest K words finds the reader. This
    /// is deliberately expressed in **words, not seconds** — an earlier time-based version of this
    /// fix passed its fixture and was a no-op on device, because at the measured per-word spacing a
    /// 9-word window spans anywhere from 2.7 s to 7.2 s and elapsed time is not a stable proxy for
    /// window content.
    ///
    /// **5 is a measured lower bound — but not for the reason first claimed.** An earlier draft
    /// justified it by noting a 4-word suffix let off-script speech reach 0.778, above
    /// `advanceThreshold` (0.72). That argument was wrong: suffix advances are gated by
    /// `suffixJumpThreshold` (0.92), not `advanceThreshold`, and 0.778 is well below 0.92. The
    /// claim was withdrawn.
    ///
    /// The supported bound runs the other way — it is an *upper* limit on the width, established by
    /// running the actual rule: at `minimumSuffixWindow = 6` the P0 trace is no longer recovered
    /// (cursor 18, lost) because the re-acquisition happens on a 5-word suffix. 5 is therefore the
    /// widest floor at which the rule still works, measured with every other value held fixed:
    ///
    /// ```
    ///   minW  bar   distinctive | P0 cursor  meta-commentary | M1 mean   M1 false jumps
    ///     5   0.92      yes     |    42            60        | 0.7659         0
    ///     6   0.92      yes     |    18  LOST      60        | 0.7995         0
    /// ```
    ///
    /// Whether 4 would also be safe has **not** been tested, and is deliberately left untested: 5
    /// works, and narrowing further buys nothing.
    ///
    /// Setting this to `alignmentWindow` disables suffix scoring entirely; the control test in
    /// `SuffixReacquisitionTests` does exactly that.
    var minimumSuffixWindow = 5

    /// Score a shorter-than-full suffix must reach to advance the cursor on its own.
    ///
    /// **Flat rather than a ramp, and that part is measured.** The rule was first drafted assuming
    /// narrower suffixes are more coincidental and so ramped the bar up as the window narrowed.
    /// Against this script the opposite holds — off-script speech scores *higher* at wider
    /// suffixes. Max local score by suffix width, reconstructed timing:
    ///
    /// ```
    ///   trace                                W9     W8     W7     W6     W5     W4
    ///   reading ¶2 — must fire            0.926  1.000  1.000  1.000  1.000  1.000
    ///   off-script commentary — must not  0.852  0.833  0.810  0.778  0.733  0.778
    /// ```
    ///
    /// A ramp anchored at `advanceThreshold` would have let a W8 suffix fire on pure off-script
    /// speech at 0.833. One flat bar above every off-script figure does not.
    ///
    /// **The exact value is NOT discriminated by the available evidence, and is not presented as
    /// tuned.** 0.92, 0.95 and 1.00 produce byte-identical results on every measurement available —
    /// P0 cursor, meta-commentary hold, M1 mean error and M1 false jumps — because the work of
    /// rejecting coincidences is done by `suffixRequiresDistinctiveSupport`, not by this number.
    /// 0.92 is chosen within that undiscriminated band on robustness grounds: it still admits a
    /// re-acquisition carrying one ordinary ASR wobble in a 6-8 word suffix, where 1.00 would
    /// demand a perfect transcript and would likely never fire on a real device.
    var suffixJumpThreshold = 0.92

    /// Whether a suffix candidate must have at least one non-common-word match
    /// (`RecoverySearch.bestAnchor`'s `requireDistinctiveSupport`). The recovery search has always
    /// required this; the ordinary local search never has, because a full 9-token window carries
    /// enough evidence on its own. A *suffix* sits between the two: it is a short window making a
    /// potentially large move, which is precisely the shape that matched coincidentally in M4's
    /// `cookingIntro/adLibInsertion`.
    ///
    /// **This is the gate that actually does the discriminating**, measured across the full M1
    /// fixture suite with everything else held fixed:
    ///
    /// ```
    ///   distinctive support | M1 meanCursorError | M1 false jumps
    ///          off          |      0.8424        |       2   (productLaunch/misrecognition,
    ///                       |                    |            productLaunch/mediocreStall)
    ///          on           |      0.7659        |       0
    /// ```
    ///
    /// Without it the rule introduced two false jumps the suite had never had. With it there are
    /// none, and mean cursor error is *better* than the pre-M5.2 published figure of 0.9074.
    var suffixRequiresDistinctiveSupport = true

    /// How long a retained `bestStallCandidate` stays valid before it is discarded in favour of
    /// whatever the current ring buffer supports (M5.2).
    ///
    /// The snapshot exists to survive the timer/eviction race (M4, token-155): useful window
    /// content can be evicted by newer speech before the sustain timer permits a jump. But it was
    /// retained *forever* and replaced only by a strictly higher score, so on the measured trace a
    /// candidate captured at t=5.995s pointing at anchor 7 (score 0.667) stayed frozen for the
    /// remaining 42 ticks of the session — and the stall that would clear it is only cleared by an
    /// advance that cannot happen. Loosening the jump bar then made the matcher act on that stale
    /// snapshot and land on the wrong token rather than recover.
    ///
    /// Set above both `recoverySustainedSeconds` (2.5) and `mediocreConfidenceSustainedSeconds`
    /// (4.0) so the snapshot still comfortably outlives the timer it was built to outlive.
    /// `.infinity` restores the old keep-forever behaviour — used by the control test.
    var stallCandidateFreshnessSeconds: TimeInterval = 5.0

    /// Hysteresis: cursor never moves backward more than this many tokens per update (§10.4).
    var backwardCap = 3

    /// Hysteresis: cursor never jumps forward more than this many tokens per update unless the
    /// candidate meets `recoveryJumpThreshold` (§10.4).
    var forwardCapWithoutRecovery = 6

    /// Gap since the last spoken token, in seconds of audio time, above which the cursor freezes
    /// entirely (§10.4 — "this is the eye-contact feature").
    var silenceFreezeSeconds: TimeInterval = 1.5

    /// Standalone filler tokens stripped from the spoken buffer before scoring (§10.4).
    var fillerStoplist: Set<String> = ["um", "uh", "erm", "hmm", "like"]

    /// Adjacent token bigrams (as literal pairs) stripped as filler phrases (§10.4: "you know").
    var fillerBigrams: Set<[String]> = [["you", "know"]]

    /// Common short English function words. Used only as a recovery-candidate *eligibility*
    /// filter (`RecoverySearch.bestAnchor`'s `requireDistinctiveSupport`), not a scoring weight —
    /// an earlier attempt to discount these words' weight in `ConfidenceModel.score` was
    /// falsified (it perturbed unrelated fixtures while leaving the actual bug's numbers
    /// byte-identical, since discounting weight doesn't move a weighted average when every
    /// position in the window is already a match). A recovery candidate whose entire matching
    /// window is built from these words alone gets skipped outright, regardless of its raw score
    /// (M4, docs/MATCHING_ENGINE.md — root-caused against `cookingIntro/adLibInsertion`, where a
    /// synthetic ad-lib phrase's common-word overlap alone scored a coincidental 1.00 against
    /// unrelated content).
    var commonWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "he", "i", "if", "in",
        "into", "is", "it", "its", "just", "no", "not", "of", "on", "or", "she", "so", "such",
        "than", "that", "the", "their", "then", "there", "these", "they", "this", "to", "too",
        "up", "very", "was", "we", "will", "with", "you", "your"
    ]

    static let `default` = MatcherConfig()
}
