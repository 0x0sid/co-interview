import Foundation

/// **Synthetic** inter-word timing for the fixture suite.
///
/// ⚠️ This replaces a fixture that was derived from real device captures and was removed from the
/// public snapshot. **It does not reproduce any captured behaviour or any previously observed
/// failure.** It is a plausible speaking cadence — nothing more — so that the fixture suite has a
/// non-constant timing source and the matcher is not only ever exercised at a fixed interval.
///
/// The original capture-derived timing is preserved in the private historical repository. If a
/// timing-sensitive regression needs reproducing, use that, not this.
enum SyntheticTiming {
    /// Seconds between consecutive spoken words. Chosen to span a natural speaking range with
    /// occasional longer gaps; not measured from anyone.
    static let pattern: [TimeInterval] = [
        0.32, 0.28, 0.41, 0.35, 0.30, 0.52, 0.27, 0.38,
        0.33, 0.45, 0.29, 0.36, 0.61, 0.31, 0.40, 0.34,
    ]
}
