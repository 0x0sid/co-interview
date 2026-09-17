import Foundation
import Testing
@testable import prompter

/// Deterministic test doubles for the copilot pipeline. Nothing here touches the network, the
/// microphone, or the development fake provider — every classification and every streamed token is
/// supplied by the test itself.
///
/// All synthetic content, per the repository rule that no captured speech enters the tree.
enum CopilotTestSupport {
    /// Polls `condition` until it holds or the budget runs out.
    ///
    /// The coordinator drives generation from detached `Task`s, so a test has to wait for *observable
    /// state*, not for a fixed sleep. This mirrors the lesson recorded in `VolatileReconciliationTests`:
    /// wait on a signal the production path actually produces.
    @MainActor
    static func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(3),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for: \(description)")
        throw CancellationError()
    }

    static func finalDelta(_ text: String, at timestamp: TimeInterval) -> TranscriptDelta {
        TranscriptDelta(
            text: text,
            tokens: Tokenizer.normalize(text).map { Token($0, at: timestamp) },
            kind: .final,
            timestamp: timestamp
        )
    }

    static func volatileDelta(_ text: String, at timestamp: TimeInterval) -> TranscriptDelta {
        TranscriptDelta(text: text, tokens: [], kind: .volatile, timestamp: timestamp)
    }

    /// A transcript service that never ends on its own, so "is capture still running?" is observable.
    final class OpenEndedTranscriptionService: Transcribing, @unchecked Sendable {
        private var continuation: AsyncStream<TranscriptDelta>.Continuation?
        private(set) var stopCount = 0
        private(set) var startCount = 0

        func start(locale: Locale, contextualStrings: [String]) async throws -> AsyncStream<TranscriptDelta> {
            startCount += 1
            let (stream, continuation) = AsyncStream<TranscriptDelta>.makeStream()
            self.continuation = continuation
            return stream
        }

        func stop() async {
            stopCount += 1
            continuation?.finish()
            continuation = nil
        }

        func emit(_ delta: TranscriptDelta) {
            continuation?.yield(delta)
        }
    }

    /// A provider whose every answer the test controls.
    final class StubProvider: CopilotProviding, @unchecked Sendable {
        let detectionModelLabel = "stub-detector"
        let answerModelLabel = "stub-answer"
        let isDevelopmentFake = false

        /// Returned in order; the last one repeats once the queue empties.
        var classifications: [DetectionResult] = []
        var classificationError: Error?
        var generationError: Error?
        /// Text handed out as one delta per element, unless `manualStreams` is true.
        var answerChunks: [String] = ["First sentence here. ", "Second sentence follows. "]
        /// When true, `generate` parks and the test pushes deltas through `push(_:)` / `finishStream()`.
        var manualStreams = false

        private(set) var classifyCallCount = 0
        private(set) var generateCallCount = 0
        private(set) var lastAnswerRequest: AnswerRequest?
        private(set) var lastClassificationRequest: ClassificationRequest?
        private var continuations: [AsyncThrowingStream<AnswerStreamEvent, Error>.Continuation] = []
        private var cancellations = 0
        var cancelCount: Int { cancellations }

        func classify(_ request: ClassificationRequest) async throws -> DetectionResult {
            classifyCallCount += 1
            lastClassificationRequest = request
            if let classificationError { throw classificationError }
            if classifications.count > 1 { return classifications.removeFirst() }
            return classifications.first ?? DetectionResult(kind: .none, questionText: "", confidence: 0)
        }

        func generate(_ request: AnswerRequest) -> AsyncThrowingStream<AnswerStreamEvent, Error> {
            generateCallCount += 1
            lastAnswerRequest = request
            let chunks = answerChunks
            let error = generationError
            let manual = manualStreams
            return AsyncThrowingStream { continuation in
                self.continuations.append(continuation)
                continuation.onTermination = { reason in
                    if case .cancelled = reason { self.cancellations += 1 }
                }
                guard !manual else { return }
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                for chunk in chunks { continuation.yield(.delta(chunk)) }
                continuation.yield(.sources(request.passages.map(\.id)))
                continuation.yield(.completed(usageOutputTokens: nil))
                continuation.finish()
            }
        }

        /// Pushes into the *n*-th open stream (0 = first requested), for out-of-order tests.
        func push(_ event: AnswerStreamEvent, stream index: Int = 0) {
            guard continuations.indices.contains(index) else { return }
            continuations[index].yield(event)
        }

        func finishStream(_ index: Int = 0, throwing error: Error? = nil) {
            guard continuations.indices.contains(index) else { return }
            continuations[index].finish(throwing: error)
        }

        var openStreamCount: Int { continuations.count }
    }

    /// A detector whose verdict for each scripted line is known in advance.
    ///
    /// Replay tests use this rather than `FakeCopilotProvider` so they assert a **pipeline** guarantee
    /// — every turn the detector calls a question becomes exactly one card, in order, none lost, none
    /// duplicated — instead of asserting the fake's crude keyword rules, which are a stand-in for a
    /// model and not the thing under test.
    final class ScriptedDetectorProvider: CopilotProviding, @unchecked Sendable {
        let detectionModelLabel = "scripted-detector"
        let answerModelLabel = "scripted-answer"
        let isDevelopmentFake = false

        private let lines: [SyntheticInterview.Line]
        private(set) var unmatchedSpeech: [String] = []

        init(interview: SyntheticInterview) {
            self.lines = interview.lines
        }

        func classify(_ request: ClassificationRequest) async throws -> DetectionResult {
            let speech = Tokenizer.normalize(request.newSpeech)
            // Match the scripted line this speech belongs to by word overlap, so volatile revisions and
            // turn grouping do not have to reproduce the line verbatim.
            let match = lines.max { first, second in
                overlap(speech, Tokenizer.normalize(first.text)) < overlap(speech, Tokenizer.normalize(second.text))
            }
            guard let match, overlap(speech, Tokenizer.normalize(match.text)) >= 0.6 else {
                unmatchedSpeech.append(request.newSpeech)
                return DetectionResult(kind: .none, questionText: "", confidence: 0.3)
            }
            switch match.expectation {
            case .question:
                return DetectionResult(kind: .newQuestion, questionText: match.text, confidence: 0.9)
            case .continuation:
                let related = request.knownQuestions.last.flatMap { UUID(uuidString: $0.id) }
                return DetectionResult(kind: related == nil ? .none : .continuation,
                                       questionText: match.text, relatedCardID: related, confidence: 0.8)
            case .noQuestion:
                return DetectionResult(kind: .none, questionText: "", confidence: 0.8)
            }
        }

        private func overlap(_ spoken: [String], _ line: [String]) -> Double {
            guard !line.isEmpty else { return 0 }
            let spokenSet = Set(spoken)
            return Double(line.filter(spokenSet.contains).count) / Double(line.count)
        }

        func generate(_ request: AnswerRequest) -> AsyncThrowingStream<AnswerStreamEvent, Error> {
            AsyncThrowingStream { continuation in
                let first = request.passages.first
                continuation.yield(.delta("Answering \(request.question.prefix(24)). "))
                continuation.yield(.delta("Grounded in \(first?.documentTitle ?? "no source"). "))
                continuation.yield(.sources(first.map { [$0.id] } ?? []))
                continuation.yield(.completed(usageOutputTokens: nil))
                continuation.finish()
            }
        }
    }

    /// A tiny fixture project, independent of the shipped synthetic fixtures.
    static func project(
        id: String = "test-project",
        language: InterviewLanguage = .english,
        passages: [ProjectPassage]? = nil
    ) -> SyntheticProject {
        SyntheticProject(
            projectID: id,
            projectName: "Test project",
            instructions: "Answer in the first person and prefer figures from my documents.",
            language: language,
            passages: passages ?? [
                ProjectPassage(id: "\(id)#1", documentID: "doc", documentTitle: "Fixture document",
                               documentVersion: "2026-01-01", locator: "p. 1",
                               text: "The corridor carries forty thousand journeys each day and cost twenty two million."),
                ProjectPassage(id: "\(id)#2", documentID: "doc", documentTitle: "Fixture document",
                               documentVersion: "2026-01-01", locator: "p. 2",
                               text: "Punctuality rose from seventy one to eighty nine per cent over two years."),
            ]
        )
    }

    /// A coordinator wired to stubs, with an audio input whose service the test controls.
    @MainActor
    static func makeCoordinator(
        provider: StubProvider,
        project: SyntheticProject? = nil,
        service: OpenEndedTranscriptionService = OpenEndedTranscriptionService()
    ) -> (coordinator: CopilotSessionCoordinator, audio: InterviewAudioInput, service: OpenEndedTranscriptionService) {
        let audio = InterviewAudioInput(makeService: { service })
        let coordinator = CopilotSessionCoordinator(
            project: project ?? Self.project(),
            provider: provider,
            audio: audio
        )
        return (coordinator, audio, service)
    }
}
