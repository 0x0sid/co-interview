import Foundation

/// The bounded rolling record of what the microphone heard (§4).
///
/// Its whole job is to turn a stream of volatile/final `TranscriptDelta`s — which revise themselves,
/// repeat, and arrive out of step with speech — into a stable, deduplicated list of utterances with
/// **application-owned identifiers**, so everything downstream can be idempotent.
///
/// Pure Foundation and synchronous: no audio, no network, no UI. That is what makes the dedupe and
/// windowing rules testable without a microphone.
struct ConversationLog: Equatable, Sendable {
    /// Finalized utterances, oldest first, bounded by `maximumUtterances` / `windowSeconds`.
    private(set) var utterances: [Utterance] = []
    /// The utterance still being revised by volatile results, if any.
    private(set) var openUtterance: Utterance?

    /// Keeps the window small enough to send cheaply and to stay inside the detector's context.
    var maximumUtterances: Int = 40
    /// Older speech is dropped even if the count is small: an interview from ten minutes ago is not
    /// context for the question being asked now.
    var windowSeconds: TimeInterval = 180

    private var makeID: @Sendable () -> UUID

    init(maximumUtterances: Int = 40, windowSeconds: TimeInterval = 180, makeID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.maximumUtterances = maximumUtterances
        self.windowSeconds = windowSeconds
        self.makeID = makeID
    }

    static func == (lhs: ConversationLog, rhs: ConversationLog) -> Bool {
        lhs.utterances == rhs.utterances && lhs.openUtterance == rhs.openUtterance
    }

    /// Feeds one transcript delta.
    ///
    /// - Returns: the utterance that changed, and whether this delta closed it. `nil` means the delta
    ///   carried nothing new — an empty update, or a finalized repeat of speech already recorded.
    @discardableResult
    mutating func ingest(_ delta: TranscriptDelta, overlapsReading: Bool) -> (utterance: Utterance, didFinalize: Bool)? {
        let text = delta.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        switch delta.kind {
        case .volatile:
            if var open = openUtterance {
                // A revision of the same in-flight utterance keeps its identity. This is the single
                // most important dedupe rule: without it, every volatile update would look like new
                // speech and the detector would be called on each one.
                open.text = text
                open.endTime = delta.timestamp
                open.revision += 1
                open.overlapsReading = open.overlapsReading && overlapsReading
                openUtterance = open
                return (open, false)
            }
            let opened = Utterance(
                id: makeID(),
                text: text,
                isFinal: false,
                startTime: delta.timestamp,
                endTime: delta.timestamp,
                revision: 0,
                overlapsReading: overlapsReading
            )
            openUtterance = opened
            return (opened, false)

        case .final:
            // The transcriber can re-emit a finalized result covering speech already recorded (the
            // inherited pipeline's `.final` results repeat text as they settle). Recognise that by
            // normalized content plus overlapping time, and replace rather than append.
            let normalized: [String] = Tokenizer.normalize(text)
            let repeatIndex: Int? = utterances.lastIndex { existing in
                let existingWords: [String] = Tokenizer.normalize(existing.text)
                guard existingWords == normalized else { return false }
                let age: TimeInterval = delta.timestamp - existing.endTime
                return age >= 0 && age < repeatWindowSeconds
            }
            if let index = repeatIndex {
                var existing = utterances[index]
                existing.text = text
                existing.endTime = max(existing.endTime, delta.timestamp)
                existing.revision += 1
                utterances[index] = existing
                openUtterance = nil
                return (existing, true)
            }

            var closed = openUtterance ?? Utterance(
                id: makeID(),
                text: text,
                isFinal: false,
                startTime: delta.timestamp,
                endTime: delta.timestamp,
                revision: 0,
                overlapsReading: overlapsReading
            )
            closed.text = text
            closed.isFinal = true
            closed.endTime = delta.timestamp
            closed.overlapsReading = closed.overlapsReading && overlapsReading
            openUtterance = nil
            utterances.append(closed)
            prune(now: delta.timestamp)
            return (closed, true)
        }
    }

    /// A finalized repeat is only a repeat if it arrives close behind the original; the same sentence
    /// genuinely said again a minute later is new speech.
    private let repeatWindowSeconds: TimeInterval = 12

    private mutating func prune(now: TimeInterval) {
        if utterances.count > maximumUtterances {
            utterances.removeFirst(utterances.count - maximumUtterances)
        }
        utterances.removeAll { now - $0.endTime > windowSeconds }
    }

    /// Finalized utterances the given cut-off has not consumed yet.
    func utterances(after time: TimeInterval) -> [Utterance] {
        utterances.filter { $0.endTime > time }
    }

    /// Recent conversation for a model request: newest last, capped, and excluding speech that was the
    /// user reading a suggestion aloud — sending that back as "what was said" would let a suggestion
    /// masquerade as conversation (§5).
    func recentContext(maximumUtterances count: Int = 8) -> [Utterance] {
        Array(utterances.filter { !$0.overlapsReading }.suffix(count))
    }

    /// Unconsumed finalized utterances, grouped into **turns**: consecutive speech with no gap longer
    /// than `gapSeconds` between utterances.
    ///
    /// Why this exists: detection used to classify *everything* unconsumed as one block. When two
    /// questions were finalized before a classification ran — a fast exchange, or transcription
    /// catching up after a lag — they were classified together, produced one card, and the second
    /// question was silently swallowed by the cut-off. Grouping by turn keeps distinct questions
    /// distinct regardless of how transcript events happen to arrive.
    func pendingTurns(after time: TimeInterval, gapSeconds: TimeInterval) -> [[Utterance]] {
        var turns: [[Utterance]] = []
        for utterance in utterances(after: time) {
            if let last = turns.last?.last, utterance.startTime - last.endTime <= gapSeconds {
                turns[turns.count - 1].append(utterance)
            } else {
                turns.append([utterance])
            }
        }
        return turns
    }

    /// Text available for detection: finalized utterances after the cut-off plus the in-flight tail.
    func pendingText(after time: TimeInterval) -> String {
        var parts = utterances(after: time).map(\.text)
        if let openUtterance { parts.append(openUtterance.text) }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    var lastActivityTime: TimeInterval {
        max(openUtterance?.endTime ?? 0, utterances.last?.endTime ?? 0)
    }
}
