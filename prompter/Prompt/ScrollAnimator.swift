import SwiftUI

/// §12.4's scroll feel: "smooth, interruptible, spring-based... Recovery jumps glide (~0.6s)."
/// Centralized here so `PromptScreen`'s normal per-sentence scroll and its recovery-grade jumps
/// use the same two presets, and Reduce Motion degrades both the same way.
enum ScrollAnimator {
    /// Ordinary voice-following motion.
    ///
    /// **Linear, and paced to the observed target interval — this is the fix for "stepped" motion.**
    /// The rendered prefix height advances in whole rendered lines, so targets arrive as ~40 pt
    /// steps (the 2026-09-11 device log: 14.7 → 55.4 → 136.4 → 177.0 → 217.4 → 298.4 → 339.0). An
    /// ease-out animates each step and *comes to rest* before the next arrives, which is exactly
    /// what reads as stepping. A linear ramp whose duration matches the interval between targets is
    /// still travelling when the next target lands, so consecutive steps blend into one continuous
    /// drift at roughly the reader's own pace.
    ///
    /// `interval` is measured from recent targets, not configured: there is no fixed-speed or WPM
    /// mode (§25 forbids one). It is clamped so a long pause or a burst cannot run the motion away.
    static func following(interval: TimeInterval, reduceMotion: Bool) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        let paced = min(max(interval, minimumFollowInterval), maximumFollowInterval)
        return .linear(duration: paced)
    }

    /// Bounds on the paced duration. Below the minimum the motion is a visible jump; above the
    /// maximum the display trails the reader.
    static let minimumFollowInterval: TimeInterval = 0.25
    static let maximumFollowInterval: TimeInterval = 1.2

    /// Legacy spring, retained for the debug replay screen's own scroll.
    ///
    /// Lower stiffness than the original `170` per explicit on-device feedback asking for an even
    /// slower scroll — a slower spring's final settle is gentler and less noticeable landing on
    /// top of a pause than a fast one's abrupt stop. `damping: 20` keeps this critically damped
    /// (ratio ≈1.0) at `stiffness: 100` — same non-oscillating behavior as before, just slower.
    static func normal(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .interpolatingSpring(stiffness: 100, damping: 20)
    }

    /// A confirmed reposition (paragraph skip, ad-lib return, suffix re-acquisition).
    ///
    /// **Short and bounded, deliberately — this replaced a slower spring.** The previous value was
    /// `.interpolatingSpring(stiffness: 60, damping: 16).speed(0.7)`, chosen so a big jump "reads as
    /// catching up". On device that meant *scrolling through every skipped paragraph*: a spring's
    /// settle time grows with distance, so a 30-token skip crawled. The requirement is the
    /// opposite — arrive promptly, then resume normal following (presentation contract §3,
    /// docs/DECISIONS.md 2026-09-11).
    ///
    /// A fixed-duration ease also bounds how long a scroll can stay in flight, so a newer matching
    /// decision cannot find a long spring still travelling toward a stale destination.
    static func recovery(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.45)
    }

    static func animation(for state: PromptCursor.State, reduceMotion: Bool) -> Animation {
        state == .recovering ? recovery(reduceMotion: reduceMotion) : normal(reduceMotion: reduceMotion)
    }
}
