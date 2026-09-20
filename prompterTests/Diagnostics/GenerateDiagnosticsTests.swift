import Testing
import Foundation
@testable import prompter

/// What the diagnostics record, what they refuse to record, and what they must never affect.
///
/// The point of these is the negative space as much as the positive: a diagnostic that changes a
/// request, leaks a token, or grows without limit is worse than no diagnostic at all.
///
/// All content here is synthetic.
@MainActor
struct GenerateDiagnosticsTests {
    private typealias H = ManualGenerationTests

    private static func freshDiagnostics() -> GenerateDiagnostics {
        let diagnostics = GenerateDiagnostics.shared
        diagnostics.startSession(appBuild: "1", commit: "test")
        return diagnostics
    }

    // MARK: - Correlation

    /// One tap is followed from the tap through to the answer under a single request id.
    @Test
    func aTapIsTraceableFromTapToAnswer() throws {
        let diagnostics = Self.freshDiagnostics()
        let (model, feed) = H.make()
        H.speak("What is a HashMap in Java?", in: model)
        H.tap(model, at: 0)

        let request = try #require(feed.discussionRequests.last)
        let trace = try #require(diagnostics.trace(requestID: request.requestID))
        #expect(trace.sessionID == diagnostics.sessionID, "the trace is not tied to this session")
        #expect(trace.outcome == .accepted)
        #expect(trace.tappedAt != nil)

        model.handle(.answerStarted(requestID: request.requestID, questionID: request.questionID))
        model.handle(.answerTopicResolved(requestID: request.requestID, topic: "What a HashMap is"))
        model.handle(.answerChunk(requestID: request.requestID, text: "A HashMap "))
        model.handle(.answerCompleted(
            requestID: request.requestID,
            blocks: [.prose("A HashMap stores key-value pairs.")],
            highlight: nil
        ))

        let finished = try #require(diagnostics.trace(requestID: request.requestID))
        #expect(finished.interpretedTitle == "What a HashMap is")
        #expect(finished.streamOutcome == .completed)
        #expect(finished.answerCharacters > 0)
        #expect(finished.toFirstTextMs != nil || finished.firstTextAt != nil)
    }

    /// The full transcript and the portion sent are both recorded, as separate numbers.
    ///
    /// One number cannot answer "was anything dropped?", which is the question a report exists for.
    @Test
    func fullAndSentTranscriptSizesAreBothRecorded() throws {
        _ = Self.freshDiagnostics()
        let (model, feed) = H.make()
        for index in 1...15 { H.speak("Line number \(index).", in: model) }
        H.tap(model, at: 0)

        let request = try #require(feed.discussionRequests.last)
        let trace = try #require(GenerateDiagnostics.shared.trace(requestID: request.requestID))
        #expect(trace.transcriptLineCount == 15)
        #expect(trace.sentLineCount == 15, "the whole session should be travelling now")
        #expect(trace.omitted == nil, "nothing was dropped, so nothing should be reported as dropped")
        #expect(trace.transcriptCharacters > 0)
        #expect(trace.sentCharacters > 0)
    }

    /// A tap that produced no request is still recorded, with why.
    @Test
    func rejectedAndDebouncedTapsAreRecordedWithTheirReason() throws {
        let diagnostics = Self.freshDiagnostics()
        let (model, _) = H.make()

        H.tap(model, at: 0)                               // nothing said yet
        #expect(diagnostics.traces.last?.outcome == .rejectedNothingToAnswer)
        #expect(diagnostics.traces.last?.outcomeReason?.isEmpty == false)

        H.speak("A question?", in: model)
        H.tap(model, at: 30)
        model.generate(now: Date(timeIntervalSince1970: 1_030.1))   // immediately again
        #expect(diagnostics.traces.last?.outcome == .debounced)
    }

    // MARK: - Content capture

    /// With capture off, no conversation and no answer text is kept anywhere.
    @Test
    func captureOffKeepsNoConversationOrAnswerText() throws {
        let diagnostics = Self.freshDiagnostics()
        diagnostics.isContentCaptureEnabled = false
        let (model, feed) = H.make()
        H.speak("My salary expectation is ninety thousand.", in: model)
        H.tap(model, at: 0)
        let request = try #require(feed.discussionRequests.last)
        model.handle(.answerStarted(requestID: request.requestID, questionID: request.questionID))
        model.handle(.answerCompleted(requestID: request.requestID, blocks: [.prose("A private answer.")], highlight: nil))

        let trace = try #require(diagnostics.trace(requestID: request.requestID))
        #expect(trace.captured == nil, "conversation was kept with capture off")
        #expect(trace.utterances.allSatisfy { $0.text.isEmpty }, "utterance text was kept with capture off")

        let markdown = DiagnosticsExport.markdown(session: diagnostics, traces: [trace], title: "t")
        #expect(!markdown.contains("ninety thousand"), "the export leaked the conversation")
        #expect(!markdown.contains("A private answer"), "the export leaked the answer")
        #expect(markdown.contains("no conversation text"), "the export does not say it is content-free")
        // The counts still travel: that is the whole point of the off state.
        #expect(markdown.contains("Whole session transcript"))
    }

    /// With capture on, the snapshot recorded is the one taken at the tap — later revisions to the
    /// transcript must not rewrite it.
    @Test
    func captureOnPreservesTheTapSnapshotDespiteLaterRevisions() throws {
        let diagnostics = Self.freshDiagnostics()
        diagnostics.isContentCaptureEnabled = true
        defer { diagnostics.isContentCaptureEnabled = false }

        let lineID = UUID()
        let (model, feed) = H.make()
        model.handle(.transcriptLine(TranscriptLine(id: lineID, text: "Tell me about ash maps", isFinal: true)))
        H.tap(model, at: 0)
        let request = try #require(feed.discussionRequests.last)

        // The recogniser revises the same utterance afterwards, and more speech arrives.
        model.handle(.transcriptLine(TranscriptLine(id: lineID, text: "Tell me about hash maps", isFinal: true, revision: 1)))
        H.speak("And also about trees.", in: model)

        let captured = try #require(diagnostics.trace(requestID: request.requestID)?.captured)
        #expect(captured.transcriptAtTap == ["Tell me about ash maps"],
                "the trace was rewritten by speech that arrived after the tap")
        #expect(!captured.snapshotNewInput.contains("And also about trees."),
                "speech from after the tap leaked into the snapshot")
    }

    /// Capture returns to off for every new session, so it cannot be left on by accident.
    @Test
    func captureIsOffAgainForEachNewSession() {
        let diagnostics = GenerateDiagnostics.shared
        diagnostics.isContentCaptureEnabled = true
        diagnostics.startSession(appBuild: "1", commit: "test")
        #expect(diagnostics.isContentCaptureEnabled == false)
    }

    // MARK: - Redaction

    /// Credentials never survive into an export, whichever field they arrive in.
    @Test
    func exportsRedactCredentialsAndExcludeImageBytes() {
        let cases = [
            "Authorization: Bearer abcdef0123456789",
            "my key is sk-abcdef0123456789xyz",
            "{\"token\": \"super-secret-value\"}",
            "{\"api_key\":\"another-secret\"}",
            "data:image/jpeg;base64,\(String(repeating: "A", count: 200))",
        ]
        for text in cases {
            let redacted = Redaction.redact(text)
            #expect(!redacted.contains("abcdef0123456789"), "a credential survived: \(redacted)")
            #expect(!redacted.contains("super-secret-value"), "a token survived: \(redacted)")
            #expect(!redacted.contains("another-secret"), "an api key survived: \(redacted)")
            #expect(!redacted.contains(String(repeating: "A", count: 200)), "image bytes survived")
        }
    }

    /// Attachments are recorded as counts, never as bytes.
    @Test
    func attachmentsAreRecordedWithoutTheirBytes() throws {
        let diagnostics = Self.freshDiagnostics()
        diagnostics.isContentCaptureEnabled = true
        defer { diagnostics.isContentCaptureEnabled = false }
        let (model, feed) = H.make()
        H.speak("What do you make of this diagram?", in: model)
        H.tap(model, at: 0)
        let request = try #require(feed.discussionRequests.last)
        let trace = try #require(diagnostics.trace(requestID: request.requestID))

        let json = DiagnosticsExport.json(session: diagnostics, traces: [trace])
        #expect(json.contains("\"attachments\""))
        #expect(!json.contains("base64"), "an export mentioned image bytes")
    }

    // MARK: - Bounds, clearing and failure

    /// The store never grows past its bound.
    @Test
    func theStoreIsBounded() {
        let diagnostics = Self.freshDiagnostics()
        for index in 0..<(GenerateDiagnostics.maximumTraces + 15) {
            diagnostics.recordTap(requestID: UUID(), outcome: .accepted, reason: "\(index)")
        }
        #expect(diagnostics.traces.count == GenerateDiagnostics.maximumTraces)
    }

    @Test
    func clearingEmptiesTheStore() {
        let diagnostics = Self.freshDiagnostics()
        diagnostics.recordTap(requestID: UUID(), outcome: .accepted, reason: nil)
        #expect(!diagnostics.traces.isEmpty)
        diagnostics.clear()
        #expect(diagnostics.traces.isEmpty)
    }

    /// A late event for a request the bound already evicted is ignored, not fatal.
    @Test
    func anEventForAnUnknownRequestIsHarmless() {
        let diagnostics = Self.freshDiagnostics()
        diagnostics.recordTitle(requestID: UUID(), title: "a title for nothing")
        diagnostics.recordAnswer(requestID: UUID(), answerVersion: 1, text: "orphan")
        #expect(diagnostics.traces.isEmpty, "an orphan event invented a trace")
    }

    /// A failed request keeps its trace and is still exportable — that is exactly the case someone
    /// needs to send on.
    @Test
    func failedAndQueuedRequestsRemainExportable() throws {
        let diagnostics = Self.freshDiagnostics()
        let (model, feed) = H.make()
        H.speak("A question that will fail?", in: model)
        H.tap(model, at: 0)
        let request = try #require(feed.discussionRequests.last)
        model.handle(.answerFailed(requestID: request.requestID, message: "the backend did not answer"))

        let trace = try #require(diagnostics.trace(requestID: request.requestID))
        #expect(trace.streamOutcome == .failed)
        #expect(trace.failureDetail?.isEmpty == false)

        let markdown = DiagnosticsExport.markdown(session: diagnostics, traces: diagnostics.traces, title: "t")
        #expect(markdown.contains("failed"))
        let json = DiagnosticsExport.json(session: diagnostics, traces: diagnostics.traces)
        #expect(json.contains("\"stream\" : \"failed\"") || json.contains("\"stream\": \"failed\""))
    }

    /// Marking a problem attaches to the request on screen without touching anything else.
    @Test
    func markingAProblemAttachesToTheRequest() throws {
        let diagnostics = Self.freshDiagnostics()
        let (model, feed) = H.make()
        H.speak("Something looked wrong here?", in: model)
        H.tap(model, at: 0)
        let request = try #require(feed.discussionRequests.last)

        diagnostics.markProblem(requestID: request.requestID, note: "answered the wrong version")
        let trace = try #require(diagnostics.trace(requestID: request.requestID))
        #expect(trace.problemNote == "answered the wrong version")
        #expect(trace.markedAt != nil)
        #expect(DiagnosticsExport.markdown(session: diagnostics, traces: [trace], title: "t")
            .contains("Marked as a problem"))
    }

    // MARK: - Independence

    /// Diagnostics never change what is sent.
    ///
    /// The same speech is generated twice, once with capture off and once with it on, and the two
    /// snapshots handed to the feed must be identical.
    @Test
    func capturingDoesNotChangeTheRequest() throws {
        let diagnostics = GenerateDiagnostics.shared

        diagnostics.startSession(appBuild: "1", commit: "test")
        diagnostics.isContentCaptureEnabled = false
        let (plainModel, plainFeed) = H.make()
        H.speak("Compare Java versions.", in: plainModel)
        H.speak("And Java 7.", in: plainModel)
        H.tap(plainModel, at: 0)

        diagnostics.startSession(appBuild: "1", commit: "test")
        diagnostics.isContentCaptureEnabled = true
        defer { diagnostics.isContentCaptureEnabled = false }
        let (capturedModel, capturedFeed) = H.make()
        H.speak("Compare Java versions.", in: capturedModel)
        H.speak("And Java 7.", in: capturedModel)
        H.tap(capturedModel, at: 0)

        let plain = try #require(plainFeed.discussionRequests.last).discussion
        let captured = try #require(capturedFeed.discussionRequests.last).discussion
        #expect(plain.allLines == captured.allLines, "capturing changed the conversation sent")
        #expect(plain.newLines == captured.newLines, "capturing changed what was asked")
        #expect(plain.background == captured.background)
    }
}
