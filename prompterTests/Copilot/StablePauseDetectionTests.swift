import Testing
import Foundation
@testable import prompter

/// The path a spoken question actually takes on a device, and the bug that lost it.
///
/// On-device transcription publishes volatile text long before it finalizes. When the speaker pauses,
/// the detection policy fires its `stablePause` trigger and classifies that in-flight text — which is
/// the whole point of the trigger, because waiting for finalization can take seconds.
///
/// That path had no finalized utterances behind it, so `apply` received an empty consumed-utterance
/// group and its `guard !consumed.isEmpty` discarded a perfectly good `new_question` verdict. Worse,
/// `lastClassifiedText` was recorded anyway, so when the identical words finalized a moment later the
/// policy refused to classify them again ("nothing new since the last call"). The question was not
/// delayed — it was lost for good, which is exactly what "questions are not reliably detected" looked
/// like on the phone while the backend logged successful classifications.
@MainActor
struct StablePauseDetectionTests {
    static func coordinator(
        provider: CopilotTestSupport.StubProvider
    ) -> CopilotSessionCoordinator {
        CopilotSessionCoordinator(
            project: SyntheticProjectFixture.transportProgramme,
            provider: provider,
            audio: InterviewAudioInput(makeService: { FakeTranscriptionService(results: []) }),
            generationMode: .manual
        )
    }

    static func detectingProvider(_ question: String) -> CopilotTestSupport.StubProvider {
        let provider = CopilotTestSupport.StubProvider()
        provider.classifications = [DetectionResult(kind: .newQuestion, questionText: question, confidence: 0.9)]
        return provider
    }

    /// Speech that has not finalized yet must still be able to become a question.
    @Test
    func aQuestionDetectedFromStillVolatileSpeechBecomesAQuestion() async throws {
        let provider = Self.detectingProvider("How do you handle backpressure?")
        let coordinator = Self.coordinator(provider: provider)

        // Volatile text, as the transcriber publishes it while the interviewer is still speaking.
        coordinator.ingest(CopilotTestSupport.volatileDelta("How do you handle backpressure", at: 1.0))
        // Then the speaker pauses: the stable-pause trigger fires on the in-flight tail.
        coordinator.tick(now: 2.0)
        try await Task.sleep(for: .milliseconds(150))

        #expect(provider.classifyCallCount >= 1, "the pause should have triggered a classification")
        #expect(coordinator.cards.count == 1, "a detected question was discarded because it had not finalized yet")
        #expect(coordinator.cards.first?.questionText.contains("backpressure") == true)
    }

    /// And once it has become a question, finalizing the same words must not create a second one.
    @Test
    func finalizingTheSameSpeechDoesNotDuplicateTheQuestion() async throws {
        let provider = Self.detectingProvider("How do you handle backpressure?")
        let coordinator = Self.coordinator(provider: provider)

        coordinator.ingest(CopilotTestSupport.volatileDelta("How do you handle backpressure", at: 1.0))
        coordinator.tick(now: 2.0)
        try await Task.sleep(for: .milliseconds(150))
        let afterPause = coordinator.cards.count

        coordinator.ingest(CopilotTestSupport.finalDelta("How do you handle backpressure?", at: 2.1))
        coordinator.tick(now: 3.5)
        try await Task.sleep(for: .milliseconds(150))

        #expect(afterPause == 1)
        #expect(coordinator.cards.count == 1, "finalizing the same speech created a duplicate question")
    }

    /// A second, genuinely different question still gets its own entry.
    @Test
    func aDifferentQuestionAfterwardsStillBecomesItsOwnQuestion() async throws {
        let provider = CopilotTestSupport.StubProvider()
        provider.classifications = [
            DetectionResult(kind: .newQuestion, questionText: "How do you handle backpressure?", confidence: 0.9),
            DetectionResult(kind: .newQuestion, questionText: "And retries?", confidence: 0.9),
        ]
        let coordinator = Self.coordinator(provider: provider)

        coordinator.ingest(CopilotTestSupport.volatileDelta("How do you handle backpressure", at: 1.0))
        coordinator.tick(now: 2.0)
        try await Task.sleep(for: .milliseconds(150))

        // Close the first utterance before the next one begins. A final delta arriving straight
        // after volatile text finalizes *that* utterance rather than starting a new one, which is
        // how the transcriber actually behaves.
        coordinator.ingest(CopilotTestSupport.finalDelta("How do you handle backpressure", at: 2.2))
        coordinator.tick(now: 3.2)
        try await Task.sleep(for: .milliseconds(150))

        coordinator.ingest(CopilotTestSupport.finalDelta("And what about retries?", at: 4.0))
        coordinator.tick(now: 5.5)
        try await Task.sleep(for: .milliseconds(250))

        #expect(coordinator.cards.count == 2, "the second question was swallowed")
    }
}
