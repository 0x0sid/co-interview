import Foundation

/// One piece of transcript output. `.volatile` deltas are for live UI display only (§12.4's
/// muted "listening" feel comes later in M3/M4) — only `.final` deltas carry normalized tokens,
/// because volatile text gets revised and re-emitted as more audio arrives, and feeding that to
/// the matcher would mean duplicate/inconsistent tokens (§11.4).
struct TranscriptDelta: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case volatile
        case final
    }

    let text: String
    let tokens: [Token]
    let kind: Kind
    /// Audio-session-relative time (seconds since the transcriber started), used to measure
    /// time-to-first-volatile-result (§16 M2 gate) and to timestamp tokens for the matcher.
    let timestamp: TimeInterval
}

/// Merges volatile/finalized transcription results into normalized token deltas, per Apple's
/// WWDC25 guidance (§11.4): on a final result, clear the carried-over volatile text and emit the
/// finalized tokens exactly once. Plain Foundation state machine — no Speech-framework types
/// here, so it's usable from both the real `TranscriptionService` and tests without a
/// microphone.
///
/// `@unchecked Sendable`: mutable state (`volatileText`), but only ever driven sequentially by
/// one consumer loop (`TranscriptionService`'s `reporting` task) — never accessed concurrently.
final class TranscriptStream: @unchecked Sendable {
    private(set) var volatileText: String = ""

    /// Feed one raw transcription result. Returns the delta to publish, or nil if there's
    /// nothing new worth reporting (e.g. an empty/whitespace-only update).
    func ingest(text: String, isFinal: Bool, at timestamp: TimeInterval) -> TranscriptDelta? {
        if isFinal {
            volatileText = ""
            let words = Tokenizer.normalize(text)
            guard !words.isEmpty else { return nil }
            let tokens = words.map { Token($0, at: timestamp) }
            return TranscriptDelta(text: text, tokens: tokens, kind: .final, timestamp: timestamp)
        }

        guard !text.isEmpty else { return nil }
        volatileText = text
        return TranscriptDelta(text: text, tokens: [], kind: .volatile, timestamp: timestamp)
    }
}
