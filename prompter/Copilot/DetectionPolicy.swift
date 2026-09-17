import Foundation

/// Decides **when** to ask the detector, so the model is not called on every partial token, every
/// sentence, or every silence (§4).
///
/// Pure value type with an explicit clock, so every rule is testable without audio or network.
struct DetectionPolicy: Sendable {
    /// Minimum new normalized words before any call. Below this there is usually nothing to classify
    /// — but see `looksInterrogative`: "Why?" is four characters and a real question.
    var minimumNewWords = 4
    /// Volatile text must stop changing for this long before it counts as stable.
    var stablePauseSeconds: TimeInterval = 0.6
    /// Floor between two classification calls, so a burst of finals cannot fan out into a burst of requests.
    var cooldownSeconds: TimeInterval = 0.4
    /// New words that make a question plausible enough to start retrieval early, in parallel with
    /// detection. Retrieval is local and produces nothing visible, so a wrong guess costs nothing.
    var earlyRetrievalWords = 6
    /// Silence between finalized utterances that separates one conversational turn from the next.
    /// Detection classifies a turn at a time, so two questions asked in quick succession stay two
    /// questions (see `ConversationLog.pendingTurns`).
    var turnGapSeconds: TimeInterval = 0.8

    enum Trigger: Equatable, Sendable {
        /// An utterance finalized — the strongest stable signal.
        case finalized
        /// Volatile text stopped changing for `stablePauseSeconds`.
        case stablePause
        /// The user asked explicitly; bypasses every gate except "there is text".
        case manual
    }

    struct Decision: Equatable, Sendable {
        var shouldClassify: Bool
        var trigger: Trigger?
        var shouldStartRetrieval: Bool
        var text: String
    }

    struct Input {
        /// Text not yet sent to the detector (finalized utterances after the cut-off, plus the tail).
        var pendingText: String
        /// True if a finalized utterance arrived with this update.
        var didFinalize: Bool
        /// Transcript-clock now.
        var now: TimeInterval
        /// When the pending text last changed.
        var lastChangeTime: TimeInterval
        /// When the last classification was started.
        var lastClassificationTime: TimeInterval?
        /// The exact text of the last classification, so identical text is not re-sent.
        var lastClassifiedText: String?
        /// A classification is already in flight.
        var isClassificationInFlight: Bool
        /// Every utterance contributing to `pendingText` matched the answer being read aloud.
        var allPendingOverlapsReading: Bool
        /// The user tapped "Answer this".
        var isManualRequest: Bool = false
        /// Finalized speech is still waiting to be classified after this one. Draining that backlog is
        /// not a burst of new requests, so the cooldown — which exists to stop a flurry of transcript
        /// events fanning out into a flurry of calls — does not apply to it.
        var hasUnclassifiedBacklog: Bool = false
    }

    /// A cheap, local "is this worth asking the detector about?" test for **short** speech only.
    ///
    /// Deliberately not a detector: it decides whether to spend one classification, never whether a
    /// card is created. Without it, `minimumNewWords` silently swallowed real questions — "Why?",
    /// "Et ensuite ?" — because they are shorter than the noise floor, while "Right. Understood."
    /// is the same length and must stay swallowed.
    static func looksInterrogative(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // A question mark is the strongest short-form signal, in both evaluation languages (French
        // spaces it: "Et ensuite ?").
        if trimmed.hasSuffix("?") || trimmed.hasSuffix("？") { return true }
        let words = Tokenizer.normalize(trimmed)
        guard let first = words.first else { return false }
        return shortInterrogativeOpeners.contains(first)
    }

    /// Opening words that make a short turn a likely question. Small and explicit; anything longer
    /// than the noise floor reaches the detector on its own merits anyway.
    static let shortInterrogativeOpeners: Set<String> = [
        "why", "how", "when", "where", "who", "what", "which", "really",
        "pourquoi", "comment", "quand", "ou", "qui", "quoi", "quel", "quelle", "vraiment", "ensuite",
    ]

    func decide(_ input: Input) -> Decision {
        let words = Tokenizer.normalize(input.pendingText)
        let text = input.pendingText.trimmingCharacters(in: .whitespacesAndNewlines)

        if input.isManualRequest {
            // Manual always wins: it exists precisely for the speech automatic detection missed.
            return Decision(shouldClassify: !words.isEmpty, trigger: .manual, shouldStartRetrieval: !words.isEmpty, text: text)
        }

        let idle = Decision(shouldClassify: false, trigger: nil, shouldStartRetrieval: false, text: text)

        guard !input.isClassificationInFlight else { return idle }
        // Length is a noise filter, not a definition of a question. A short turn that is shaped like
        // one still deserves a classification; a short backchannel does not.
        guard words.count >= minimumNewWords || Self.looksInterrogative(text) else { return idle }
        // Nothing new since the last call: re-asking would return the same answer and cost the same.
        guard text != input.lastClassifiedText else { return idle }
        // Speech that is only the user reading the current suggestion is not a question signal. The
        // detector still sees genuine follow-ups, because an utterance only counts as overlapping when
        // the reader confirmed those words against the answer text being read.
        guard !input.allPendingOverlapsReading else { return idle }

        if !input.hasUnclassifiedBacklog,
           let last = input.lastClassificationTime,
           input.now - last < cooldownSeconds { return idle }

        let trigger: Trigger?
        if input.didFinalize {
            trigger = .finalized
        } else if input.now - input.lastChangeTime >= stablePauseSeconds {
            trigger = .stablePause
        } else {
            trigger = nil
        }

        guard let trigger else {
            // Not stable yet — but a plausible question is forming, so retrieval may start now.
            return Decision(
                shouldClassify: false,
                trigger: nil,
                shouldStartRetrieval: words.count >= earlyRetrievalWords,
                text: text
            )
        }

        return Decision(shouldClassify: true, trigger: trigger, shouldStartRetrieval: true, text: text)
    }
}
