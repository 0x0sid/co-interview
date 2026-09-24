import Testing
import Foundation
import AVFAudio
import Speech
@testable import prompter

/// The live path, end to end through the real pipeline with a stub provider.
///
/// These drive an actual `CopilotSessionCoordinator` — the same detection, retrieval and streaming
/// the live build uses — with `FakeTranscriptionService` supplying speech and a scripted provider
/// supplying verdicts and text. Nothing here talks to a network, and nothing re-implements the
/// pipeline: if these pass, the wiring between the approved screen and the existing pipeline holds.
@MainActor
struct LiveInterviewFeedTests {
    // MARK: Support

    static func makeFeed(
        provider: CopilotTestSupport.StubProvider = questionDetectingProvider(),
        project: SyntheticProject = SyntheticProjectFixture.transportProgramme
    ) -> (LiveInterviewFeed, CopilotSessionCoordinator, CopilotTestSupport.StubProvider) {
        let coordinator = CopilotSessionCoordinator(
            project: project,
            provider: provider,
            audio: InterviewAudioInput(makeService: { FakeTranscriptionService(results: []) }),
            generationMode: .manual
        )
        return (LiveInterviewFeed(coordinator: coordinator), coordinator, provider)
    }

    /// A detector that calls the first thing it sees a question.
    static func questionDetectingProvider() -> CopilotTestSupport.StubProvider {
        let provider = CopilotTestSupport.StubProvider()
        provider.classifications = [DetectionResult(kind: .newQuestion, questionText: "How do you handle backpressure?", confidence: 0.9)]
        return provider
    }

    /// Collects events without waiting on timers.
    static func drain(_ feed: LiveInterviewFeed, limit: Int = 64) async -> [InterviewFeedEvent] {
        var collected: [InterviewFeedEvent] = []
        for await event in feed.events {
            collected.append(event)
            if collected.count >= limit { break }
        }
        return collected
    }

    // MARK: Detection never generates

    /// The single most important live rule: speech produces questions, not answers.
    @Test
    func detectingAQuestionInLiveNeverStartsAnAnswer() async throws {
        let (feed, coordinator, _) = Self.makeFeed()
        coordinator.ingest(CopilotTestSupport.finalDelta("How do you handle backpressure?", at: 1.0))
        coordinator.tick(now: 3.0)
        try await Task.sleep(for: .milliseconds(60))

        #expect(coordinator.cards.count == 1, "detection did not produce a question")
        #expect(coordinator.cards[0].versions.isEmpty, "an answer was generated without anyone asking")
        _ = feed
    }

    @Test
    func generationHappensOnlyWhenTheScreenAsks() async throws {
        let (feed, coordinator, _) = Self.makeFeed()
        coordinator.ingest(CopilotTestSupport.finalDelta("How do you handle backpressure?", at: 1.0))
        coordinator.tick(now: 3.0)
        try await Task.sleep(for: .milliseconds(60))
        let card = try #require(coordinator.cards.first)

        let questionID = UUID()
        // The feed maps interface ids to pipeline cards when it announces them; re-announce here so
        // the mapping exists without depending on stream delivery order.
        feed.registerForTesting(questionID: questionID, cardID: card.id)
        feed.requestAnswer(requestID: UUID(), question: InterviewQuestion(id: questionID, text: card.questionText), isRegeneration: false)
        try await Task.sleep(for: .milliseconds(120))

        #expect(coordinator.cards[0].versions.count == 1, "Generate did not start exactly one version")
    }

    // MARK: Transcript revisions

    /// Revisions update a line; they never add a second copy of the same speech.
    @Test
    func transcriptRevisionsUpdateOneLineInsteadOfDuplicating() async throws {
        let model = InterviewScreenModel(mode: .live, feed: Self.makeFeed().0)
        let id = UUID()
        model.handle(.transcriptLine(TranscriptLine(id: id, text: "How do you", isFinal: false)))
        model.handle(.transcriptLine(TranscriptLine(id: id, text: "How do you handle", isFinal: false)))
        model.handle(.transcriptLine(TranscriptLine(id: id, text: "How do you handle backpressure?", isFinal: true)))

        #expect(model.transcript.count == 1, "a revised line was appended instead of updated")
        #expect(model.transcript[0].text == "How do you handle backpressure?")
        #expect(model.transcript[0].isFinal)
    }

    /// Finalized history is never rewritten by a late partial.
    @Test
    func aLatePartialCannotRewriteFinalizedHistory() {
        let model = InterviewScreenModel(mode: .live, feed: Self.makeFeed().0)
        let id = UUID()
        model.handle(.transcriptLine(TranscriptLine(id: id, text: "Settled text.", isFinal: true)))
        model.handle(.transcriptLine(TranscriptLine(id: id, text: "Sett", isFinal: false)))

        #expect(model.transcript[0].text == "Settled text.")
    }

    @Test
    func distinctSpeechKeepsDistinctLines() {
        let model = InterviewScreenModel(mode: .live, feed: Self.makeFeed().0)
        model.handle(.transcriptLine(TranscriptLine(text: "First thing said.", isFinal: true)))
        model.handle(.transcriptLine(TranscriptLine(text: "Second thing said.", isFinal: true)))

        #expect(model.transcript.count == 2)
    }

    // MARK: Live never simulates

    @Test
    func liveNeverFadesTextOnATimer() async throws {
        let (feed, coordinator, _) = Self.makeFeed()
        let model = InterviewScreenModel(mode: .live, feed: feed)
        #expect(model.isSimulatedReadingEnabled == false)
        #expect(model.stepSimulatedReading() == false)
        _ = coordinator
    }

    /// Real speech, and only real speech, advances reading.
    ///
    /// The answer is produced through the model's own request path — asking for one and then feeding
    /// the events back — because the model deliberately ignores stream events for a request it never
    /// issued. That guard is what stops a late or foreign event writing into a page.
    @Test
    func realTranscriptDeltasAdvanceTheReader() throws {
        let feed = InterviewScreenModelTests.RecordingFeed()
        let model = InterviewScreenModel(mode: .live, feed: feed)
        let question = InterviewQuestion(text: "How?")
        model.handle(.questionDetected(question))
        model.generate(for: question)
        let request = try #require(feed.requests.last)
        model.handle(.answerStarted(requestID: request.requestID, questionID: question.id))
        model.handle(.answerCompleted(
            requestID: request.requestID,
            blocks: [.prose("We bound the queue rather than the producer.")],
            highlight: nil
        ))

        let page = try #require(model.currentQuestion)
        let alignment = try #require(model.alignment(for: page))
        #expect(alignment.spokenTokenIndices.isEmpty)

        for (index, word) in ["we", "bound", "the", "queue"].enumerated() {
            model.ingestLiveDelta(TranscriptDelta(
                text: word,
                tokens: [Token(word, at: Double(index))],
                kind: .final,
                timestamp: Double(index)
            ))
        }

        #expect(alignment.spokenTokenIndices.count >= 3, "real speech did not advance the reader")
    }

    // MARK: Answer text

    /// Prose and code keep the order the model wrote them in, and code never joins the aligned text.
    @Test
    func fencedCodeBecomesACardInPlace() {
        let blocks = AnswerBlock.parsed(from: """
        We bound the queue.

        ```
        let q = BoundedQueue(capacity: 512)
        ```

        That is the whole trick.
        """)

        #expect(blocks.count == 3)
        if case .prose(let first) = blocks[0] { #expect(first == "We bound the queue.") } else { Issue.record("first block is not prose") }
        if case .code(let code) = blocks[1] { #expect(code.contains("BoundedQueue")) } else { Issue.record("the code block left its position") }
        if case .prose(let last) = blocks[2] { #expect(last == "That is the whole trick.") } else { Issue.record("last block is not prose") }

        let answer = InterviewAnswer(version: 1, blocks: blocks, isComplete: true)
        #expect(answer.proseText.contains("BoundedQueue") == false, "code leaked into the aligned text")
    }

    /// An unterminated fence keeps the text visible rather than dropping it.
    @Test
    func anUnterminatedCodeFenceStillShowsItsText() {
        let blocks = AnswerBlock.parsed(from: "Here it is:\n\n```\nlet x = 1")
        #expect(blocks.contains { if case .code(let c) = $0 { return c.contains("let x = 1") } else { return false } })
    }

    // MARK: Session end

    @Test
    func endingTheSessionStopsCaptureAndRejectsLateWork() async throws {
        let (feed, coordinator, _) = Self.makeFeed()
        coordinator.startListening()
        feed.end()

        #expect(coordinator.state == .ended)
        #expect(coordinator.audio.state == .idle, "the microphone was not released")

        // Anything arriving now is rejected by the coordinator's own guard.
        coordinator.ingest(CopilotTestSupport.finalDelta("A late question?", at: 99))
        #expect(coordinator.cards.isEmpty)
    }

    // MARK: Context

    /// The typed note reaches the provider, and it is the note **as it was when Generate was
    /// pressed** — editing it afterwards cannot change an answer already in flight.
    @Test
    func theSessionNoteIsSnapshottedIntoTheRequest() async throws {
        let (feed, coordinator, provider) = Self.makeFeed()
        coordinator.ingest(CopilotTestSupport.finalDelta("How do you handle backpressure?", at: 1.0))
        coordinator.tick(now: 3.0)
        try await Task.sleep(for: .milliseconds(60))
        let card = try #require(coordinator.cards.first)

        coordinator.sessionNote = "Focus on Java 17"
        let questionID = UUID()
        feed.registerForTesting(questionID: questionID, cardID: card.id)
        feed.requestAnswer(requestID: UUID(), question: InterviewQuestion(id: questionID, text: card.questionText), isRegeneration: false)
        try await Task.sleep(for: .milliseconds(150))

        coordinator.sessionNote = "changed after the request"

        let request = try #require(provider.lastAnswerRequest)
        #expect(request.extraContext == "Focus on Java 17")
    }

    /// **No image uploads.** Attached files, photos included, reach a request only as excerpts of
    /// text read on the device; the request's image list is always empty.
    @Test
    func noImageIsEverAttachedToARequest() async throws {
        let (feed, coordinator, _) = Self.makeFeed()
        let model = InterviewScreenModel(mode: .live, feed: feed)
        coordinator.sessionImages = [AnswerRequest.ImageAttachment(mime: "image/jpeg", data: "AAAA")]
        model.context.note = "a note"
        model.syncSessionNote()
        #expect(coordinator.sessionImages.isEmpty, "an image would have been uploaded")
        #expect(coordinator.sessionNote == "a note")
    }

    /// The smallest valid JPEG, so preparation has something real to decode.
    static func onePixelJPEG() -> Data {
        let base64 = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q=="
        return Data(base64Encoded: base64) ?? Data()
    }

    // MARK: Readiness

    /// Listening and generation are independent: a missing provider must not stop transcription.
    @Test
    func aMissingProviderLeavesListeningAvailable() {
        var readiness = LiveReadiness()
        readiness.blockers = [.providerNotConfigured]
        #expect(readiness.canListen)
        #expect(readiness.canGenerate == false)
        #expect(readiness.isListenOnly)
    }

    /// A denied microphone stops the session; that is a different state with a different fix.
    @Test
    func aDeniedMicrophoneStopsListening() {
        var readiness = LiveReadiness()
        readiness.blockers = [.microphoneDenied]
        #expect(readiness.canListen == false)
        #expect(readiness.summary.contains("Microphone"))
    }

    /// The app's own token failing is never reported as a provider-credential problem.
    @Test
    func clientAuthenticationFailureIsItsOwnState() {
        var readiness = LiveReadiness()
        readiness.blockers = [.clientAuthenticationFailed]
        #expect(readiness.canListen)
        #expect(readiness.summary.contains("access token"))
        #expect(readiness.summary.contains("provider") == false)
    }

    // MARK: Readiness probe mapping

    /// Builds a readiness result from a canned probe outcome, with permissions already granted, so
    /// these tests isolate the backend half.
    static func readiness(from probe: LiveReadiness.BackendProbe) async -> LiveReadiness {
        await LiveReadiness.check(
            configuration: ProviderConfiguration(availability: .backend(url: URL(string: "https://example.test")!), token: "t"),
            language: .english,
            microphonePermission: .granted,
            speechAuthorization: .authorized,
            probe: { _ in probe }
        )
    }

    /// A slow backend must be retryable, not a dead end. This is the failure that made a healthy
    /// backend look unreachable for a whole session.
    @Test
    func aTimedOutProbeIsReportedAsATimeoutAndIsRetryable() async {
        let readiness = await Self.readiness(from: .timedOut)
        #expect(readiness.blockers.contains(.backendTimedOut))
        #expect(readiness.isRetryable, "a timeout must offer Retry")
        #expect(readiness.canListen, "a slow backend must never stop transcription")
    }

    /// A rejected token is an authentication problem, not an unreachable backend — different cause,
    /// different fix, different message.
    @Test
    func arejectedTokenIsReportedAsAuthenticationNotUnreachable() async {
        let readiness = await Self.readiness(from: .unauthorized)
        #expect(readiness.blockers.contains(.clientAuthenticationFailed))
        #expect(readiness.blockers.contains { if case .backendUnreachable = $0 { true } else { false } } == false)
        #expect(readiness.summary.contains("access token"))
        #expect(readiness.isRetryable == false, "retrying will not fix a wrong token")
    }

    @Test
    func aMissingProviderCredentialIsItsOwnState() async {
        let readiness = await Self.readiness(from: .providerUnconfigured)
        #expect(readiness.blockers.contains(.providerNotConfigured))
        #expect(readiness.canListen, "listening continues without a provider")
        #expect(readiness.canGenerate == false)
    }

    @Test
    func transportAndDnsFailuresAreDistinguished() async {
        let tls = await Self.readiness(from: .transportSecurityFailed)
        #expect(tls.blockers.contains(.transportSecurityFailed))
        #expect(tls.isRetryable == false)

        let dns = await Self.readiness(from: .hostNotFound)
        #expect(dns.blockers.contains(.backendHostNotFound))
        #expect(dns.summary.contains("could not be found"))
        #expect(dns.isRetryable, "a changed tunnel URL is worth one retry")

        let offline = await Self.readiness(from: .offline)
        #expect(offline.blockers.contains(.deviceOffline))
    }

    /// A healthy backend reports no blockers and carries its capability through.
    @Test
    func aHealthyProbeLeavesNoBlockers() async {
        let readiness = await Self.readiness(from: .ok(summary: "openrouter · balanced", providerConfigured: true, acceptsImages: true))
        #expect(readiness.blockers.isEmpty)
        #expect(readiness.canGenerate)
        #expect(readiness.answerAcceptsImages)
    }

    @Test
    func pausingReleasesTheMicrophoneWithoutEndingTheSession() {
        let (feed, coordinator, _) = Self.makeFeed()
        coordinator.startListening()
        feed.pause()

        #expect(feed.isPaused)
        #expect(coordinator.audio.state == .pausedByUser)
        #expect(coordinator.state == .active, "pausing listening ended the session")
    }
}

/// A line recognised in partial results and then finalized must reach the screen **as final, with the
/// final wording** — and so reach the next request. It used not to: closing an utterance keeps its
/// revision, the feed only re-emitted on a revision change, and the line stayed on screen as its last
/// partial, marked not final. A request then dropped it entirely unless it happened to be the very
/// last line, because a snapshot carries final lines plus only the newest one as provisional.
@MainActor
struct FinalizedPartialTests {
    private typealias Support = CopilotTestSupport

    @Test
    func aFinalizedPartialReachesTheScreenAndTheRequest() async throws {
        let provider = Support.StubProvider()
        provider.classifications = [DetectionResult(kind: .none, questionText: "", confidence: 0.9)]
        let coordinator = CopilotSessionCoordinator(
            project: LiveSessionContext(language: .english),
            provider: provider,
            audio: InterviewAudioInput(makeService: { FakeTranscriptionService(results: []) }),
            generationMode: .manual
        )
        let model = InterviewScreenModel(mode: .live, feed: LiveInterviewFeed(coordinator: coordinator))
        model.start()

        coordinator.ingest(Support.volatileDelta("Could you compare Java", at: 1))
        coordinator.ingest(Support.volatileDelta("Could you compare Java 9 and Java 8", at: 1.5))
        coordinator.ingest(Support.finalDelta("Could you compare Java 9 and Java 8 and Java 7?", at: 2))
        coordinator.ingest(Support.volatileDelta("Java", at: 4))
        coordinator.ingest(Support.finalDelta("Java 10.", at: 4.5))
        try await Support.waitUntil("both finalized lines on screen") {
            model.transcript.count == 2 && model.transcript.allSatisfy(\.isFinal)
        }
        #expect(model.transcript.map(\.text) == ["Could you compare Java 9 and Java 8 and Java 7?", "Java 10."])

        model.generate(now: Date(timeIntervalSince1970: 1_000))
        try await Support.waitUntil("the request") { provider.lastAnswerRequest != nil }
        #expect(provider.lastAnswerRequest?.newInput == ["Could you compare Java 9 and Java 8 and Java 7?", "Java 10."],
                "a finalized line was missing from the request")
        model.stop()
    }
}
