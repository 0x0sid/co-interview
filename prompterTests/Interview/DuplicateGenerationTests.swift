import Testing
import Foundation
@testable import prompter

/// The reported bug: after one question is answered, silence or another tap produces the same
/// question again.
///
/// Reproduced here before it was fixed. Two independent causes, both of which create an entry the
/// user never asked for:
///
/// 1. **Every card was announced as a detected question — including the one Generate had just
///    created.** `beginDiscussionAnswer` appends a card, which fires `onCardAppended`, which the
///    live feed translated into `.questionDetected`. The screen already had its own entry for that
///    tap, so one tap produced two tabs.
/// 2. **A manual card claimed no transcript.** It was appended with no utterance ids, so detection
///    never marked the speech it covered as consumed. The next silence tick classified the very same
///    words and produced another card — the "same question repeatedly during silence" symptom.
@MainActor
struct DuplicateGenerationTests {
    static func liveSession(
        detecting question: String? = nil
    ) -> (LiveInterviewFeed, CopilotSessionCoordinator, CopilotTestSupport.StubProvider) {
        let provider = CopilotTestSupport.StubProvider()
        if let question {
            provider.classifications = [DetectionResult(kind: .newQuestion, questionText: question, confidence: 0.9)]
        }
        let coordinator = CopilotSessionCoordinator(
            project: SyntheticProjectFixture.transportProgramme,
            provider: provider,
            audio: InterviewAudioInput(makeService: { FakeTranscriptionService(results: []) }),
            generationMode: .manual
        )
        return (LiveInterviewFeed(coordinator: coordinator), coordinator, provider)
    }

    /// Cause 1: one tap, one tab.
    @Test
    func oneGenerateTapProducesExactlyOneEntry() async throws {
        let (feed, coordinator, _) = Self.liveSession()
        let model = InterviewScreenModel(mode: .live, feed: feed)
        model.handle(.transcriptLine(TranscriptLine(text: "How do I remove duplicates in Java")))

        model.generate(now: Date(timeIntervalSince1970: 1_000))
        try await Task.sleep(for: .milliseconds(120))

        // Drain whatever the feed announced into the model, exactly as the screen's loop does.
        for await event in feed.events {
            model.handle(event)
            if case .answerStarted = event { break }
        }

        #expect(model.questions.count == 1, "one tap created more than one tab")
        #expect(coordinator.cards.count == 1)
    }

    /// Cause 2: silence after an answered question must not re-detect it.
    @Test
    func silenceAfterAnsweringDoesNotRedetectTheSameQuestion() async throws {
        let (feed, coordinator, provider) = Self.liveSession(detecting: "How do I remove duplicates in Java?")
        // The speech that will be covered by the Generate tap.
        coordinator.ingest(CopilotTestSupport.finalDelta("How do I remove duplicates in Java", at: 1.0))

        feed.requestAnswerForDiscussion(
            requestID: UUID(),
            discussion: DiscussionSnapshot(["How do I remove duplicates in Java"]),
            questionID: UUID()
        )
        try await Task.sleep(for: .milliseconds(120))
        let afterGenerate = coordinator.cards.count

        // Now nothing but silence: repeated ticks, no new speech.
        for tick in 1...6 {
            coordinator.tick(now: 2.0 + Double(tick))
            try await Task.sleep(for: .milliseconds(40))
        }

        #expect(coordinator.cards.count == afterGenerate,
                "silence produced \(coordinator.cards.count - afterGenerate) extra question(s) for speech already answered")
        // A classification already in flight when Generate was tapped may still return — that is
        // unavoidable and harmless. What matters is that its verdict creates nothing: the speech it
        // was about is now marked consumed, so `apply` rejects it. Silence must add no further
        // classifications beyond that one.
        let afterFirstTick = provider.classifyCallCount
        for tick in 7...12 {
            coordinator.tick(now: 2.0 + Double(tick))
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(provider.classifyCallCount == afterFirstTick,
                "continued silence kept re-classifying speech that was already answered")
        #expect(coordinator.cards.count == afterGenerate, "a late verdict created a duplicate question")
    }

    /// Repeated identical transcriber events are the same speech, not new questions.
    @Test
    func repeatedIdenticalTranscriptEventsDoNotCreateNewWork() {
        let (model, feed) = Self.screenOnly()
        let id = UUID()
        model.handle(.transcriptLine(TranscriptLine(id: id, text: "How do I remove duplicates", isFinal: false)))
        model.generate(now: Date(timeIntervalSince1970: 1_000))
        #expect(feed.discussionRequests.count == 1)

        // The same utterance finalizes — same identity, same words plus punctuation.
        model.handle(.transcriptLine(TranscriptLine(id: id, text: "How do I remove duplicates?", isFinal: true)))
        model.generate(now: Date(timeIntervalSince1970: 1_010))

        #expect(feed.discussionRequests.count == 1, "a partial-to-final event was treated as new input")
        #expect(model.questions.count == 1, "a partial-to-final event created a second tab")
    }

    static func screenOnly() -> (InterviewScreenModel, ManualGenerationTests.RecordingFeed) {
        let feed = ManualGenerationTests.RecordingFeed()
        return (InterviewScreenModel(mode: .live, feed: feed), feed)
    }
}
