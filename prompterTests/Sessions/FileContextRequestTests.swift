import Foundation
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import prompter

/// File context is fixed when Generate is accepted, survives failure and Retry unchanged, says when
/// files are still being read, and reaches broad personal questions.
@MainActor
struct FileContextRequestTests {
    private typealias S = SessionTestSupport
    private typealias H = ManualGenerationTests

    static let cv = """
        Alex Morgan — Senior backend engineer.
        Zephyr Logistics, 2019–present: led the migration of 40 services to Kafka and cut delivery-tracking latency by 60%.
        Before that, four years building payment APIs at Brightbank.
        """
    static let jobDescription = """
        Platform Engineer, Northwind Freight.
        You will own our event-streaming platform and help teams move from batch jobs to real-time pipelines.
        Requirements: Kafka or similar, Kotlin or Java, production on-call experience.
        """

    private func liveStack(files: SessionFiles, provider: CopilotTestSupport.StubProvider) -> (InterviewScreenModel, CopilotSessionCoordinator) {
        provider.classifications = [DetectionResult(kind: .none, questionText: "", confidence: 0.9)]
        let coordinator = CopilotSessionCoordinator(
            project: files.fileContext, provider: provider,
            audio: InterviewAudioInput(makeService: { FakeTranscriptionService(results: []) }), generationMode: .manual)
        let model = InterviewScreenModel(mode: .live, feed: LiveInterviewFeed(coordinator: coordinator))
        model.files = files
        model.start()
        return (model, coordinator)
    }

    private func say(_ text: String, at time: TimeInterval, _ coordinator: CopilotSessionCoordinator, _ model: InterviewScreenModel) async throws {
        let before = model.transcript.count
        coordinator.ingest(CopilotTestSupport.finalDelta(text, at: time))
        try await CopilotTestSupport.waitUntil("“\(text)”") { model.transcript.count > before }
    }

    // MARK: Frozen at acceptance

    /// A request queued behind another keeps the excerpts it was accepted with, although the file is
    /// removed before it is sent.
    @Test
    func aQueuedRequestKeepsItsExcerptsAfterTheFileIsRemoved() async throws {
        let context = ModelContext(try S.container())
        let (files, _, _, _) = S.files(context: context)
        files.importData(Data(Self.cv.utf8), filename: "cv.txt", type: .plainText)
        await files.waitUntilIdle()
        let provider = CopilotTestSupport.StubProvider()
        provider.manualStreams = true
        let (model, coordinator) = liveStack(files: files, provider: provider)

        try await say("How does a HashMap handle collisions?", at: 1, coordinator, model)
        model.generate(now: Date(timeIntervalSince1970: 1_000))
        try await CopilotTestSupport.waitUntil("the first request") { provider.openStreamCount == 1 }
        try await say("And tell me about the Kafka migration at Zephyr.", at: 5, coordinator, model)
        model.generate(now: Date(timeIntervalSince1970: 1_010))
        #expect(model.queuedRequestIDs.count == 1, "the second request was not queued")

        files.remove(id: try #require(files.items.first).id)
        provider.push(.delta("Separate chaining. "))
        provider.push(.completed(usageOutputTokens: nil))
        provider.finishStream()
        try await CopilotTestSupport.waitUntil("the queued request") { provider.openStreamCount == 2 }
        let second = try #require(provider.lastAnswerRequest)
        #expect(second.passages.contains { $0.documentTitle == "cv.txt" && $0.text.contains("Zephyr") },
                "an accepted request lost the context it was accepted with")
        model.stop()
    }

    /// A failure keeps the answer's provenance; Retry re-sends the same excerpts after the file is gone.
    @Test
    func retryResendsTheSavedExcerptsAndAFailureKeepsProvenance() async throws {
        let context = ModelContext(try S.container())
        let (files, _, _, _) = S.files(context: context)
        files.importData(Data(Self.cv.utf8), filename: "cv.txt", type: .plainText)
        await files.waitUntilIdle()
        let provider = CopilotTestSupport.StubProvider()
        provider.manualStreams = true
        let (model, coordinator) = liveStack(files: files, provider: provider)

        try await say("Tell me about the Kafka migration at Zephyr.", at: 1, coordinator, model)
        model.generate(now: Date(timeIntervalSince1970: 1_000))
        try await CopilotTestSupport.waitUntil("the request") { provider.openStreamCount == 1 }
        let original = try #require(provider.lastAnswerRequest).passages.map(\.id)
        #expect(!original.isEmpty)
        provider.push(.delta("I led it. "))
        provider.finishStream(throwing: URLError(.networkConnectionLost))
        try await CopilotTestSupport.waitUntil("the failure") { model.questions.last?.selectedAnswer?.isIncomplete == true }
        let failed = try #require(model.questions.last?.selectedAnswer)
        #expect(failed.provenance?.included.map(\.passageID) == original, "a failed answer lost its provenance")

        files.remove(id: try #require(files.items.first).id)
        let questionID = try #require(model.questions.last?.id)
        #expect(model.canRetry(questionID: questionID))
        model.retry(questionID: questionID)
        try await CopilotTestSupport.waitUntil("the retry") { provider.openStreamCount == 2 }
        #expect(provider.lastAnswerRequest?.passages.map(\.id) == original, "Retry did not re-send the saved excerpts")
        model.stop()
    }

    /// Files still being read: the first tap says so and sends nothing; the second answers with the
    /// ready files and records which were left out.
    @Test
    func generatingWhileAFileIsStillBeingReadIsExplicit() async throws {
        let context = ModelContext(try S.container())
        let (files, _, _, _) = S.files(context: context)
        let (model, feed) = H.make()
        model.files = files
        let slow = await S.offMain { S.scannedPDF(Array(repeating: ["STILL READING"], count: 4)) }
        files.importData(slow, filename: "slow.pdf", type: .pdf)
        try await CopilotTestSupport.waitUntil("extraction under way") { files.isWorking && files.items.first?.status == .extracting }
        H.speak("Tell me about yourself.", in: model)

        model.generate(now: Date(timeIntervalSince1970: 1_000))
        #expect(feed.discussionRequests.isEmpty, "a request went out without the user choosing to skip the file")
        #expect(model.filesNotice?.contains("slow.pdf") == true)

        model.generate(now: Date(timeIntervalSince1970: 1_002))
        let request = try #require(feed.discussionRequests.first)
        #expect(request.discussion.filesStillProcessing == ["slow.pdf"])
        #expect(model.filesNotice == nil)
        await files.waitUntilIdle()
    }

    // MARK: Broad personal questions

    @Test
    func broadPersonalQuestionsReachTheCVAndTheJobDescription() async throws {
        let context = ModelContext(try S.container())
        let (files, _, fileContext, _) = S.files(context: context)
        files.importData(Data(Self.cv.utf8), filename: "cv.txt", type: .plainText)
        files.importData(Data(Self.jobDescription.utf8), filename: "job.txt", type: .plainText)
        await files.waitUntilIdle()

        let aboutYou = fileContext.passages(forQuestion: "Tell me about yourself.", limit: 3)
        #expect(aboutYou.contains { $0.documentTitle == "cv.txt" }, "“Tell me about yourself” reached no CV text")

        let fit = fileContext.passages(forQuestion: "Why am I a good fit?", limit: 3)
        #expect(fit.contains { $0.documentTitle == "cv.txt" } && fit.contains { $0.documentTitle == "job.txt" },
                "“Why am I a good fit?” did not reach both the CV and the job description: \(fit.map(\.documentTitle))")
        #expect(fit.count <= 3)

        #expect(fileContext.passages(forQuestion: "How does a HashMap work internally?", limit: 3).isEmpty,
                "personal files were sent for a general question")
    }
}
