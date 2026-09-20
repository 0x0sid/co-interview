import Testing
import Foundation
@testable import prompter

/// One synthetic Generate tap driven through the **real** path — `InterviewScreenModel` →
/// `LiveInterviewFeed` → `CopilotSessionCoordinator` → `BackendCopilotProvider` → the local backend →
/// the configured provider — and then exported, to prove the diagnostics fields are actually wired
/// to each other rather than merely present in a struct.
///
/// **This is deliberately not a fixture.** A hand-populated export proves only that the formatter
/// works; it cannot show that the snapshot the screen took is the snapshot that was serialized, that
/// the messages the backend assembled are the ones fetched back, or that the title on the tab came
/// from the model. Every field asserted here travelled the whole way.
///
/// It needs a live local backend and makes one real, billed provider call, so it is **opt-in**:
///
///     COINTERVIEW_LIVE_DIAGNOSTICS=1 \
///     xcodebuild test … -only-testing:prompterTests/DiagnosticsIntegrationTests
///
/// The backend must be running with `COPILOT_DIAGNOSTICS=1`. Content is synthetic throughout.
@MainActor
struct DiagnosticsIntegrationTests {
    nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["COINTERVIEW_LIVE_DIAGNOSTICS"] == "1"
    }

    private static var backendURL: URL {
        URL(string: ProcessInfo.processInfo.environment["COINTERVIEW_LIVE_BASE"] ?? "http://127.0.0.1:8787")!
    }

    private static var token: String {
        ProcessInfo.processInfo.environment["COINTERVIEW_LIVE_TOKEN"] ?? ""
    }

    /// Skipped — not failed — when the opt-in is absent, so an ordinary run stays green without
    /// pretending this ran.
    @Test(.enabled(if: DiagnosticsIntegrationTests.isEnabled))
    func aRealGenerateProducesAFullyPopulatedExport() async throws {
        try #require(!Self.token.isEmpty, "set COINTERVIEW_LIVE_TOKEN to the backend's client token")

        let diagnostics = GenerateDiagnostics.shared
        diagnostics.startSession(appBuild: "integration", commit: "integration")

        let provider = BackendCopilotProvider(
            baseURL: Self.backendURL,
            token: Self.token,
            detectionModelLabel: "detection",
            answerModelLabel: "answer"
        )
        let coordinator = CopilotSessionCoordinator(
            project: LiveSessionContext(language: .english),
            provider: provider,
            audio: InterviewAudioInput(makeService: { FakeTranscriptionService(results: []) }),
            generationMode: .manual
        )
        let feed = LiveInterviewFeed(coordinator: coordinator)
        let model = InterviewScreenModel(mode: .live, feed: feed)
        model.start()

        // Switched on **after** the session started, which is the flow a person has to use: capture
        // is per-session and resets when one begins.
        diagnostics.isContentCaptureEnabled = true
        defer { diagnostics.isContentCaptureEnabled = false }

        // A first tap, answered, so the second has genuine historical context behind it.
        model.handle(.transcriptLine(TranscriptLine(text: "Could you explain the difference between Java and Java 8?")))
        // Real clock, so the exported timings are the real ones.
        model.generate()
        try await Self.waitForAnswer(model: model, diagnostics: diagnostics, index: 0)

        // The follow-up fragments — the reported case.
        model.handle(.transcriptLine(TranscriptLine(text: "And Java 9.")))
        model.handle(.transcriptLine(TranscriptLine(text: "And Java 7.")))
        model.generate()
        try await Self.waitForAnswer(model: model, diagnostics: diagnostics, index: 1)

        let trace = try #require(diagnostics.traces.last)
        diagnostics.markProblem(requestID: trace.requestID, note: "integration check")

        // --- Correlation, route and timings --------------------------------------------------
        #expect(trace.sessionID == diagnostics.sessionID)
        #expect(trace.outcome == .accepted)
        #expect(trace.streamOutcome == .completed, "the stream did not complete: \(trace.failureDetail ?? "—")")
        let attempt = try #require(trace.attempts.first, "no route was reported")
        #expect(!attempt.gateway.isEmpty)
        #expect(!attempt.requestedModel.isEmpty)
        #expect(attempt.actualModel != "", "the actual model was not recorded")
        #expect(trace.backendVersion != nil, "the backend version never arrived")
        #expect(trace.toFirstTextMs != nil, "no time-to-first-text was measured")
        #expect(trace.toCompleteMs != nil, "no completion time was measured")
        #expect(trace.totalMs != nil, "no total was measured")
        #expect((trace.queuedMs ?? 0) >= 0 && (trace.preparingMs ?? 0) >= 0,
                "a timing came out negative — the ends were stamped from different clocks")

        // --- The interpreted title, from the model -------------------------------------------
        let title = try #require(trace.interpretedTitle, "no interpreted title arrived")
        #expect(!title.isEmpty)
        #expect(title != "And Java 7.", "the title is still the last transcript fragment")

        // --- Snapshot: whole transcript, split into new input and history ---------------------
        let captured = try #require(trace.captured, "content capture was on but nothing was captured")
        #expect(captured.transcriptAtTap.count == 3, "the full transcript at the tap was not captured")
        #expect(captured.snapshotNewInput == ["And Java 9.", "And Java 7."])
        #expect(captured.snapshotBackground.contains { $0.contains("Java 8") },
                "the historical context is missing from the capture")
        #expect(!captured.priorSuggestions.isEmpty, "the earlier answer was not carried as context")

        // --- The serialized request, with nothing secret in it --------------------------------
        let requestJSON = try #require(captured.requestJSON, "the serialized request was not captured")
        #expect(requestJSON.contains("And Java 7."), "the request capture is not the request that was sent")
        #expect(requestJSON.contains("recentConversation"))
        #expect(!requestJSON.contains(Self.token), "the client token appeared in the captured request")
        #expect(!requestJSON.lowercased().contains("authorization"))
        #expect(!requestJSON.contains("base64"), "image bytes appeared in the captured request")

        // --- The actual provider messages, fetched back from the backend ----------------------
        let messages = try #require(captured.providerMessages,
                                    "the provider messages were not fetched — is COPILOT_DIAGNOSTICS=1 set?")
        #expect(messages.contains("TO ANSWER NOW"), "the labelled request block is missing")
        #expect(messages.contains("CONVERSATION so far"), "the conversation block is missing")
        #expect(messages.contains("Java 8"), "the history never reached the provider")
        #expect(!messages.contains(Self.token), "the client token appeared in the provider messages")

        // --- The answer ------------------------------------------------------------------------
        let answer = try #require(captured.answerText, "the answer was not captured")
        #expect(answer.count > 20)
        #expect(trace.answerCharacters > 0)

        // --- And all of it survives the export --------------------------------------------------
        let markdown = DiagnosticsExport.markdown(
            session: diagnostics, traces: diagnostics.traces, title: "Co-Interview — live integration"
        )
        let json = DiagnosticsExport.json(session: diagnostics, traces: diagnostics.traces)
        #expect(markdown.contains("contains captured conversation"))
        #expect(markdown.contains("TO ANSWER NOW"))
        #expect(markdown.contains(title))
        #expect(!markdown.contains(Self.token), "the export leaked the client token")
        #expect(!json.contains(Self.token), "the JSON export leaked the client token")

        let directory = URL(fileURLWithPath: "/tmp/diag-live", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try markdown.write(to: directory.appendingPathComponent("live-report.md"), atomically: true, encoding: .utf8)
        try json.write(to: directory.appendingPathComponent("live-report.json"), atomically: true, encoding: .utf8)
    }

    /// Waits for the trace at `index` to finish, including the provider-messages fetch that happens
    /// after the answer is on screen.
    private static func waitForAnswer(
        model: InterviewScreenModel,
        diagnostics: GenerateDiagnostics,
        index: Int
    ) async throws {
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(100))
            guard diagnostics.traces.indices.contains(index) else { continue }
            let trace = diagnostics.traces[index]
            if trace.streamOutcome == .failed || trace.streamOutcome == .timedOut {
                Issue.record("request \(index) failed: \(trace.failureDetail ?? "no detail")")
                return
            }
            // The messages are fetched after completion, so completion alone is not yet the end.
            if trace.streamOutcome == .completed,
               !diagnostics.isContentCaptureEnabled || trace.captured?.providerMessages != nil {
                return
            }
        }
        Issue.record("request \(index) never completed")
    }
}
