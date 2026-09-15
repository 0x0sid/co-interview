import Foundation

/// Decides when automatic following may resume after the reader has repositioned the text by hand
/// (M5.7, docs/DECISIONS.md).
///
/// Pure value type with no SwiftUI or matcher dependencies, so the rule can be tested directly
/// rather than inferred from a rendered view. **It never touches matcher state** — it only observes
/// cursor updates that have already happened.
struct ScrollOwnership: Equatable {
    /// Why a resumption happened, for the ownership diagnostics.
    struct Resumption: Equatable {
        let firstToken: Int
        let lastToken: Int
        let evidenceCount: Int
        let chosenRegion: Range<Int>
    }

    /// Number of fresh, in-region, forward-moving cursor updates required to resume.
    static let resumeEvidenceCount = 3

    /// True while the reader owns the scroll.
    private(set) var isManuallyDetached = false
    /// Token range visible when the manual interaction ended. Captured once, so later automatic
    /// movement cannot widen the region the reader actually chose.
    ///
    /// `nil` means the rule is **not armed**: either no manual interaction has settled, or it
    /// settled without measurable block geometry. In the second case automatic resumption stays off
    /// permanently until the reader taps Resume following or Restart — see `endManualInteraction`.
    private(set) var chosenRegion: Range<Int>?
    /// Fresh evidence gathered since the interaction ended.
    private(set) var evidence: [Int] = []
    /// Last cursor index seen, so an unchanged cursor is never counted as evidence.
    private var lastSeenToken: Int?
    /// True between the first drag change and `ScrollPhase` returning to `.idle`.
    private(set) var isInteracting = false

    /// The reader touched the scroll view. Ownership transfers immediately and any evidence
    /// gathered before this interaction is discarded.
    mutating func beginManualInteraction() {
        isManuallyDetached = true
        isInteracting = true
        chosenRegion = nil
        evidence = []
        lastSeenToken = nil
    }

    /// The scroll phase settled. Only now is the chosen region meaningful — capturing it mid-flick
    /// would record wherever the content happened to be passing.
    ///
    /// **`visibleTokens == nil` means the layout could not be measured, and the rule is deliberately
    /// left unarmed.** An earlier version substituted the whole script in that case, which made the
    /// in-region check (R4) vacuously true and would have allowed an automatic resumption on a
    /// layout nobody had measured — exactly the snap-back the rule exists to prevent. Staying
    /// detached is the safe failure: the reader keeps Resume following and Restart, so they are
    /// never stranded, and nothing moves the page without evidence.
    mutating func endManualInteraction(visibleTokens: Range<Int>?) {
        guard isManuallyDetached else { return }
        isInteracting = false
        chosenRegion = visibleTokens.flatMap { $0.isEmpty ? nil : $0 }
        evidence = []
        lastSeenToken = nil
    }

    /// True when a settled interaction produced a measured region, so evidence can accumulate.
    /// False means automatic resumption cannot happen at all — only the explicit controls can.
    var isArmed: Bool { isManuallyDetached && !isInteracting && chosenRegion != nil }

    /// A cursor update arrived. Returns a `Resumption` on the update that satisfies the rule,
    /// otherwise `nil`.
    ///
    /// `isAdvancing` must be true only for `PromptCursor.State.advancing`: a held, recovering or
    /// frozen cursor is not evidence that the reader is reading *here*.
    mutating func observeCursor(token: Int, isAdvancing: Bool, scrollIsIdle: Bool) -> Resumption? {
        guard isManuallyDetached else { return nil }
        // R2: never while the reader is dragging or the view is still decelerating.
        guard !isInteracting, scrollIsIdle else { return nil }
        guard let region = chosenRegion else { return nil }

        defer { lastSeenToken = token }

        // Fresh: the cursor actually moved. A stale cursor republished by a re-layout is not
        // evidence, however high its confidence.
        guard let previous = lastSeenToken else { return nil }
        guard token != previous, isAdvancing else { return nil }

        // R4: the match must be inside the region the reader chose, not the passage recognition
        // may still be tracking elsewhere.
        guard region.contains(token) else {
            evidence = []
            return nil
        }

        // R5: strictly forward through that passage.
        if let last = evidence.last, token <= last {
            evidence = [token]
            return nil
        }
        evidence.append(token)

        guard evidence.count >= Self.resumeEvidenceCount else { return nil }

        let resumption = Resumption(
            firstToken: evidence.first ?? token,
            lastToken: token,
            evidenceCount: evidence.count,
            chosenRegion: region
        )
        resumeAutomatically()
        return resumption
    }

    /// Automatic following takes over again — by rule, or by the reader tapping Resume following.
    mutating func resumeAutomatically() {
        isManuallyDetached = false
        isInteracting = false
        chosenRegion = nil
        evidence = []
        lastSeenToken = nil
    }
}
