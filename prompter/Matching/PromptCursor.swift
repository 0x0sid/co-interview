import Foundation

/// Emitted by `SlidingWindowMatcher` at up to 10 Hz (§10.2).
struct PromptCursor: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// Confidently tracking; cursor just moved.
        case advancing
        /// Confidence isn't high enough to move (ad-lib, mid-collapse, or the ambiguous zone
        /// between the recovery and advance thresholds). Cursor holds (§10.4).
        case holding
        /// A wide/whole-script recovery search just found and jumped to a new anchor (§10.2).
        case recovering
        /// No speech for > `silenceFreezeSeconds`; cursor is deliberately not evaluated (§10.4 —
        /// "this is the eye-contact feature").
        case frozen
    }

    var tokenIndex: Int
    var confidence: Double
    var state: State
}
