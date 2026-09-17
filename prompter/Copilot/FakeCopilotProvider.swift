#if DEBUG
import Foundation

/// A deterministic stand-in for the backend, for development and for tests that must not touch the
/// network (§9).
///
/// **Development-only, and never silent.** It is compiled out of release builds entirely, it is
/// reached only when a developer switches it on, and everything it returns carries
/// `isDevelopmentFake = true`, which the UI renders as a visible badge. It exists to exercise timing,
/// cancellation and reader behaviour — not to simulate answer quality, and its latencies are
/// synthetic, so **no performance conclusion may be drawn from it** (§10).
final class FakeCopilotProvider: CopilotProviding, @unchecked Sendable {
    let detectionModelLabel = "development fake (no model)"
    let answerModelLabel = "development fake (no model)"
    let isDevelopmentFake = true

    /// Synthetic delays, so streaming and cancellation are observable. Zero in tests.
    private let firstDeltaDelay: Duration
    private let interDeltaDelay: Duration
    private let classificationDelay: Duration

    init(firstDeltaDelay: Duration = .milliseconds(180),
         interDeltaDelay: Duration = .milliseconds(35),
         classificationDelay: Duration = .milliseconds(120)) {
        self.firstDeltaDelay = firstDeltaDelay
        self.interDeltaDelay = interDeltaDelay
        self.classificationDelay = classificationDelay
    }

    func classify(_ request: ClassificationRequest) async throws -> DetectionResult {
        if classificationDelay > .zero { try? await Task.sleep(for: classificationDelay) }
        try Task.checkCancellation()

        let text = request.newSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = Tokenizer.normalize(text)
        guard words.count >= 3 else {
            return DetectionResult(kind: .none, questionText: "", confidence: 0.2, isDevelopmentFake: true)
        }

        // Deliberately crude keyword rules — a stand-in for a model, not a detector. Real detection
        // quality is a property of `gpt-5.4-nano`, measured separately.
        let lowered = text.lowercased()
        let requestOpeners = ["tell me", "explain", "walk me", "describe", "how do", "how did", "what",
                              "why", "could you", "can you", "parlez", "expliquez", "pourquoi",
                              "comment", "décrivez", "pouvez-vous", "qu'est"]
        let isRequest = requestOpeners.contains { lowered.contains($0) } || lowered.hasSuffix("?")
        guard isRequest else {
            return DetectionResult(kind: .none, questionText: "", confidence: 0.6, isDevelopmentFake: true)
        }

        let endsCleanly = lowered.hasSuffix("?") || words.count >= 6
        guard endsCleanly else {
            return DetectionResult(kind: .incomplete, questionText: text, confidence: 0.5, isDevelopmentFake: true)
        }

        // "And what about X" / "actually" style follow-ups attach to the newest known question.
        let continuationMarkers = ["and what about", "actually", "sorry, i meant", "et pour", "en fait"]
        if let newest = request.knownQuestions.last,
           continuationMarkers.contains(where: { lowered.hasPrefix($0) }),
           let id = UUID(uuidString: newest.id) {
            return DetectionResult(kind: .continuation, questionText: text, relatedCardID: id,
                                   confidence: 0.7, isDevelopmentFake: true)
        }

        return DetectionResult(kind: .newQuestion, questionText: text, confidence: 0.8, isDevelopmentFake: true)
    }

    func generate(_ request: AnswerRequest) -> AsyncThrowingStream<AnswerStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let sentences = Self.fakeSentences(for: request)
                var isFirst = true
                for sentence in sentences {
                    for chunk in Self.chunks(of: sentence) {
                        try Task.checkCancellation()
                        let delay = isFirst ? firstDeltaDelay : interDeltaDelay
                        isFirst = false
                        if delay > .zero { try? await Task.sleep(for: delay) }
                        try Task.checkCancellation()
                        continuation.yield(.delta(chunk))
                    }
                }
                continuation.yield(.sources(request.passages.map(\.id)))
                continuation.yield(.completed(usageOutputTokens: nil))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Text that is obviously synthetic when read, so a fake answer can never be mistaken for a real
    /// suggestion in a screenshot or a recording.
    private static func fakeSentences(for request: AnswerRequest) -> [String] {
        let isFrench = request.language.hasPrefix("fr")
        guard let first = request.passages.first else {
            return isFrench
                ? ["[FAUX] Mes documents ne couvrent pas ce point, je le dis franchement. ",
                   "Je peux décrire ma méthode générale, puis revenir vers vous avec le chiffre exact. "]
                : ["[FAKE] My documents do not cover that, and I would rather say so than guess. ",
                   "I can describe how I would approach it, and follow up with the exact figure afterwards. "]
        }
        let excerpt = first.text.split(separator: " ").prefix(14).joined(separator: " ")
        return isFrench
            ? ["[FAUX] D'après \(first.documentTitle), \(excerpt). ",
               "C'est le point que je mettrais en avant en premier. ",
               "Ensuite, j'expliquerais comment nous avons suivi ce résultat mois par mois. "]
            : ["[FAKE] From \(first.documentTitle), \(excerpt). ",
               "That is the point I would lead with. ",
               "Then I would explain how we tracked that result month by month. "]
    }

    private static func chunks(of sentence: String) -> [String] {
        // Word-sized chunks, like a real token stream.
        sentence.split(separator: " ", omittingEmptySubsequences: false).map { $0 + " " }
    }
}
#endif
