import Testing
import Foundation
@testable import prompter

/// What the app adds to a classification for the backend's decision comparison (pipeline §15), and
/// what it must leave alone.
///
/// The backend compares the existing detector with Jev on the same snapshot. For that it needs to
/// know **which** speech a verdict was about, at which revision, and where in the session — so a
/// verdict about since-corrected speech can be recognised as stale. None of it may change what the
/// detector is asked, and an older backend must receive the same body it always did.
///
/// All content here is synthetic.
@MainActor
struct DecisionIdentityTests {
    private typealias Support = CopilotTestSupport

    @Test
    func aClassificationCarriesItsSpeechIdentityAndRevision() async throws {
        let provider = Support.StubProvider()
        provider.classifications = [DetectionResult(kind: .newQuestion, questionText: "Compare Java 8 and 9", confidence: 0.9)]
        let (coordinator, _, _) = Support.makeCoordinator(provider: provider)

        coordinator.ingest(Support.finalDelta("Could you compare Java 8 and Java 9?", at: 3))
        try await Support.waitUntil("a classification") { provider.lastClassificationRequest != nil }
        let request = try #require(provider.lastClassificationRequest)
        let utterance = try #require(coordinator.conversation.utterances.first)

        #expect(request.sessionID == coordinator.sessionID.uuidString)
        #expect(request.snapshotID.flatMap(UUID.init(uuidString:)) != nil, "each classification needs its own id")
        #expect(request.utterances == [.init(id: utterance.id.uuidString, revision: utterance.revision, isFinal: true)])
        #expect(request.generationEpoch == 0, "nothing has been generated yet")
        // The detector's own input is exactly what it was.
        #expect(request.newSpeech == "Could you compare Java 8 and Java 9?")
    }

    @Test
    func aKnownQuestionSaysWhetherItWasAnswered() async throws {
        let provider = Support.StubProvider()
        provider.classifications = [
            DetectionResult(kind: .newQuestion, questionText: "What is a HashMap?", confidence: 0.9),
            DetectionResult(kind: .none, questionText: "", confidence: 0.9),
        ]
        let (coordinator, _, _) = Support.makeCoordinator(provider: provider)

        coordinator.ingest(Support.finalDelta("What is a HashMap?", at: 3))
        try await Support.waitUntil("a card") { coordinator.cards.count == 1 }
        try await Support.waitUntil("its answer") { coordinator.cards[0].latestVersion != nil }
        coordinator.ingest(Support.finalDelta("Right, that makes sense to me now.", at: 12))
        try await Support.waitUntil("a second classification") { provider.classifyCallCount >= 2 }

        let request = try #require(provider.lastClassificationRequest)
        #expect(request.knownQuestions.first?.answered == true)
        #expect((request.generationEpoch ?? 0) >= 1, "the generation was not counted")
    }

    @Test
    func absentIdentityIsOmittedFromTheBody() throws {
        let request = ClassificationRequest(
            newSpeech: "Why?",
            recentConversation: ["Why?"],
            activeAnswerText: nil,
            knownQuestions: [.init(id: "a", text: "b")],
            language: "en"
        )
        let json = try #require(String(data: JSONEncoder().encode(request), encoding: .utf8))
        for key in ["sessionID", "snapshotID", "utterances", "generationEpoch", "diagnosticsSessionID", "captureContent", "answered"] {
            #expect(!json.contains("\"\(key)\""), "\(key) should be omitted when unknown, so an older backend sees the same body")
        }
    }

    // MARK: - Export

    private static let recordsJSON = """
    {"session":"s","decisions":{"mode":"shadow","model":"jev-1.13.0","config_version":"decisions-test"},
     "records":[{"snapshot_id":"11111111-aaaa","utterances":[{"id":"abcd-1","revision":2,"is_final":true}],
       "baseline":{"kind":"new_question"},
       "jev":{"status":"ok","role":"continuation","role_confidence":0.81,"parent_id":"none","answer_need":"general","latency_ms":412,"usage":{"input_tokens":733}},
       "comparison":{"role_agrees":false},"stale_reason":null,"controlled_by":"baseline"},
      {"snapshot_id":"22222222-bbbb","utterances":[],"baseline":{"kind":"none"},
       "jev":{"status":"stale","role":"filler"},"stale":true,"stale_reason":"utterance revised after the snapshot","controlled_by":"baseline"}]}
    """

    @Test
    func theExportShowsEachComparison() {
        let diagnostics = GenerateDiagnostics.shared
        let markdown = DiagnosticsExport.markdown(session: diagnostics, traces: [], title: "t", decisions: Self.recordsJSON)
        #expect(markdown.contains("## Decision comparisons (shadow)"))
        #expect(markdown.contains("continuation (0.81)"))
        #expect(markdown.contains("**no**"), "a disagreement must stand out")
        #expect(markdown.contains("stale: utterance revised after the snapshot"))
        #expect(markdown.contains("no conversation text"), "records without content must not flag the report as containing any")

        let json = DiagnosticsExport.json(session: diagnostics, traces: [], decisions: Self.recordsJSON)
        #expect(json.contains("\"decisionComparisons\""))
    }

    @Test
    func anUnavailableBackendIsSaidPlainly() {
        let markdown = DiagnosticsExport.markdown(session: GenerateDiagnostics.shared, traces: [], title: "t", decisions: nil)
        #expect(markdown.contains("Not available"))
        #expect(!DiagnosticsExport.json(session: GenerateDiagnostics.shared, traces: [], decisions: nil).contains("decisionComparisons"))
    }

    @Test
    func capturedDecisionTextFlagsTheReport() {
        let withContent = Self.recordsJSON.replacingOccurrences(
            of: "\"controlled_by\":\"baseline\"},",
            with: "\"controlled_by\":\"baseline\",\"content\":{\"new_speech\":\"synthetic\"}},"
        )
        let markdown = DiagnosticsExport.markdown(session: GenerateDiagnostics.shared, traces: [], title: "t", decisions: withContent)
        #expect(markdown.contains("contains captured conversation"))
    }
}
