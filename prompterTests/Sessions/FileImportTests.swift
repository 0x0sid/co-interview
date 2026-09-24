import Foundation
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import prompter

/// Importing, extracting and using session files — and every way that can go wrong, said out loud.
@MainActor
struct FileImportTests {
    private typealias S = SessionTestSupport

    private func imported(_ data: Data, _ name: String, _ type: UTType?) async throws -> (SessionFiles, SessionFiles.Item, ModelContext) {
        let context = ModelContext(try S.container())
        let (files, _, _, _) = S.files(context: context)
        files.importData(data, filename: name, type: type)
        await files.waitUntilIdle()
        return (files, try #require(files.items.first), context)
    }

    private func text(_ context: ModelContext, _ item: SessionFiles.Item) -> String {
        let hash = item.contentHash
        let record = try? context.fetch(FetchDescriptor<FileExtractionRecord>(predicate: #Predicate { $0.contentHash == hash })).first
        return record?.chunks.map(\.text).joined(separator: " ") ?? ""
    }

    // MARK: Supported formats

    @Test
    func aPhotoIsReadWithOnDeviceTextRecognition() async throws {
        let (_, item, context) = try await imported(S.textImage(["NEVERBLANK OCR CHECK", "Kafka migration 2023"]), "Photo.png", .png)
        #expect(item.status == .ready, "\(item.detail ?? "")")
        let extracted = text(context, item).uppercased()
        #expect(extracted.contains("NEVERBLANK") && extracted.contains("KAFKA"), "OCR read: \(extracted)")
        #expect(item.thumbnail != nil, "no thumbnail for the list")
    }

    @Test
    func aTextPDFUsesItsTextLayerPageByPage() async throws {
        let pdf = S.textPDF(["Page one talks about Kotlin coroutines.", "Page two covers the payments ledger rewrite."])
        let (_, item, context) = try await imported(pdf, "cv.pdf", .pdf)
        #expect(item.status == .ready)
        #expect(item.pageCount == 2)
        let hash = item.contentHash
        let record = try #require(try context.fetch(FetchDescriptor<FileExtractionRecord>(predicate: #Predicate { $0.contentHash == hash })).first)
        #expect(record.method == "pdf-text")
        #expect(record.chunks.map(\.locator) == ["p. 1", "p. 2"])
        #expect(record.chunks[1].text.contains("payments ledger"))
    }

    @Test
    func aScannedPDFIsRecognisedPageByPage() async throws {
        let pdf = S.scannedPDF([["SCANNED PAGE ONE", "Kubernetes"], ["SCANNED PAGE TWO", "Terraform"]])
        let (_, item, context) = try await imported(pdf, "scan.pdf", .pdf)
        #expect(item.status == .ready, "\(item.detail ?? "")")
        let hash = item.contentHash
        let record = try #require(try context.fetch(FetchDescriptor<FileExtractionRecord>(predicate: #Predicate { $0.contentHash == hash })).first)
        #expect(record.method == "pdf-ocr")
        let extracted = record.chunks.map(\.text).joined(separator: " ").uppercased()
        #expect(extracted.contains("KUBERNETES") && extracted.contains("TERRAFORM"), "OCR read: \(extracted)")
        #expect(record.chunks.first?.locator == "p. 1")
    }

    @Test
    func plainTextAndMarkdownAreReadWithParagraphLocations() async throws {
        let (_, item, context) = try await imported(Data("# Notes\n\nFirst point about Rust.\n\nSecond point about Go.".utf8), "notes.md", UTType(filenameExtension: "md"))
        #expect(item.kind == .text)
        #expect(item.status == .ready)
        #expect(text(context, item).contains("Second point about Go"))
    }

    @Test
    func aWordDocumentIsRead() async throws {
        let data = try Data(contentsOf: S.docxFixture)
        let (_, item, context) = try await imported(data, "sample.docx", UTType(filenameExtension: "docx"))
        #expect(item.kind == .docx)
        #expect(item.status == .ready, "\(item.detail ?? "")")
        let extracted = text(context, item)
        #expect(extracted.contains("Kafka migration in 2023"))
        #expect(extracted.contains("virtual threads"))
    }

    // MARK: Failures, stated

    @Test
    func anUnsupportedTypeIsListedAndExplained() async throws {
        let (_, item, _) = try await imported(Data([0x50, 0x4B, 0x03, 0x04]), "slides.key", UTType(filenameExtension: "key"))
        #expect(item.status == .unsupported)
        #expect(item.detail?.contains("isn't supported") == true)
        #expect(item.detail?.contains("PDF") == true, "the explanation does not say what would work")
    }

    @Test
    func anOversizedFileIsRefusedWithTheLimit() async throws {
        let (_, item, _) = try await imported(Data(count: AttachmentLimits.maximumFileBytes + 1), "huge.txt", .plainText)
        #expect(item.status == .failed)
        #expect(item.detail?.contains("limit") == true)
    }

    @Test
    func aCorruptFileFailsWithAReason() async throws {
        let (_, item, _) = try await imported(Data("definitely not a pdf".utf8), "broken.pdf", .pdf)
        #expect(item.status == .failed)
        #expect(item.detail?.contains("could not be opened as a PDF") == true)
    }

    @Test
    func anImageWithNoTextSaysSoInsteadOfBeingEmpty() async throws {
        let (_, item, _) = try await imported(S.blankImage(), "Photo.png", .png)
        #expect(item.status == .failed)
        #expect(item.detail?.contains("No text was found") == true)
    }

    @Test
    func aDuplicateInTheSameSessionIsRefused() async throws {
        let context = ModelContext(try S.container())
        let (files, _, _, _) = S.files(context: context)
        let data = Data("Same content twice.".utf8)
        files.importData(data, filename: "a.txt", type: .plainText)
        await files.waitUntilIdle()
        files.importData(data, filename: "b.txt", type: .plainText)
        await files.waitUntilIdle()
        #expect(files.items.map(\.filename) == ["a.txt"])
        #expect(files.notice?.contains("already attached") == true)
    }

    /// The same content in another session reuses the stored copy and the extraction; deleting one
    /// session keeps the file for the other, deleting both removes it.
    @Test
    func contentIsSharedAcrossSessionsAndReleasedWhenUnreferenced() async throws {
        let context = ModelContext(try S.container())
        let store = FileStore(root: S.temporaryDirectory())
        let (first, firstSession, _, _) = S.files(context: context, store: store)
        let data = S.textPDF(["Shared CV content about Elixir."])
        first.importData(data, filename: "cv.pdf", type: .pdf)
        await first.waitUntilIdle()
        let (second, secondSession, _, _) = S.files(context: context, store: store)
        second.importData(data, filename: "cv-copy.pdf", type: .pdf)
        await second.waitUntilIdle()
        #expect(second.items.first?.status == .ready)
        #expect(second.lastExtractionDuration == nil, "the second import extracted again instead of reusing")
        #expect(try context.fetchCount(FetchDescriptor<FileExtractionRecord>()) == 1)

        let hash = try #require(first.items.first?.contentHash)
        let storedFile = store.url(forStoredName: "\(hash).pdf")
        InterviewSessionStore.delete(firstSession, in: context, store: store)
        #expect(FileManager.default.fileExists(atPath: storedFile.path), "a file still in use was deleted")
        InterviewSessionStore.delete(secondSession, in: context, store: store)
        #expect(!FileManager.default.fileExists(atPath: storedFile.path), "an unreferenced file was kept")
        #expect(try context.fetchCount(FetchDescriptor<FileExtractionRecord>()) == 0)
    }

    /// The original can disappear: the private copy and its text stay, across a reopen.
    @Test
    func anImportedFileStaysAvailableWhenTheOriginalIsGone() async throws {
        let context = ModelContext(try S.container())
        let store = FileStore(root: S.temporaryDirectory())
        let (files, session, _, _) = S.files(context: context, store: store)
        let source = S.write(Data("Offline notes about Haskell.".utf8), named: "notes.txt")
        files.importFile(at: source)
        await files.waitUntilIdle()
        try FileManager.default.removeItem(at: source)

        let reopenedContext = SessionFileContext(language: .english)
        let reopened = SessionFiles(context: context, session: session, store: store, fileContext: reopenedContext)
        #expect(reopened.items.first?.status == .ready)
        #expect(reopenedContext.passages(forQuestion: "Haskell", limit: 3).count == 1)
    }

    @Test
    func aQueuedImportCanBeCancelled() async throws {
        let context = ModelContext(try S.container())
        let (files, _, _, _) = S.files(context: context)
        files.importData(S.scannedPDF(Array(repeating: ["SLOW PAGE"], count: 6)), filename: "slow.pdf", type: .pdf)
        files.importData(Data("Queued behind it.".utf8), filename: "queued.txt", type: .plainText)
        try await CopilotTestSupport.waitUntil("both extracting") { files.items.allSatisfy { $0.status == .extracting } }
        let queued = try #require(files.items.last)
        files.cancel(id: queued.id)
        await files.waitUntilIdle()
        #expect(files.items.last?.status == .cancelled)
        #expect(files.items.first?.status == .ready, "cancelling one import affected another")
    }

    // MARK: Files in requests

    /// A removed file is out of the very next request; excerpts carry filename and location.
    @Test
    func removingAFileTakesItOutOfLaterRequests() async throws {
        let context = ModelContext(try S.container())
        let (files, _, fileContext, _) = S.files(context: context)
        let provider = CopilotTestSupport.StubProvider()
        let coordinator = CopilotSessionCoordinator(
            project: fileContext, provider: provider,
            audio: InterviewAudioInput(makeService: { FakeTranscriptionService(results: []) }), generationMode: .manual)
        files.importData(S.textPDF(["The Kafka migration moved 40 services in 2023."]), filename: "cv.pdf", type: .pdf)
        await files.waitUntilIdle()

        coordinator.beginDiscussionAnswer(discussion: DiscussionSnapshot(newInput: ["Tell me about the Kafka migration."]))
        try await CopilotTestSupport.waitUntil("the first request") { provider.generateCallCount == 1 }
        let passage = try #require(provider.lastAnswerRequest?.passages.first)
        #expect(passage.documentTitle == "cv.pdf")
        #expect(passage.locator == "p. 1")
        #expect(passage.text.contains("40 services"))

        files.remove(id: try #require(files.items.first).id)
        coordinator.beginDiscussionAnswer(discussion: DiscussionSnapshot(newInput: ["And the Kafka migration timeline?"]))
        try await CopilotTestSupport.waitUntil("the second request") { provider.generateCallCount == 2 }
        #expect(provider.lastAnswerRequest?.passages.isEmpty == true, "a removed file was still sent")
    }

    /// What the answer says it included is exactly what the request carried, and "cited" is only
    /// what the model reported.
    @Test
    func answerProvenanceMatchesTheActualRequest() async throws {
        let context = ModelContext(try S.container())
        let (files, _, fileContext, _) = S.files(context: context)
        files.importData(Data("Kafka migration: 40 services.\n\nKafka lag dashboards built in Grafana.".utf8), filename: "notes.txt", type: .plainText)
        files.importData(S.textPDF(["Kafka consumer groups tuned for the migration."]), filename: "cv.pdf", type: .pdf)
        await files.waitUntilIdle()

        let provider = CopilotTestSupport.StubProvider()
        provider.classifications = [DetectionResult(kind: .none, questionText: "", confidence: 0.9)]
        provider.manualStreams = true
        let coordinator = CopilotSessionCoordinator(
            project: fileContext, provider: provider,
            audio: InterviewAudioInput(makeService: { FakeTranscriptionService(results: []) }), generationMode: .manual)
        let model = InterviewScreenModel(mode: .live, feed: LiveInterviewFeed(coordinator: coordinator))
        model.files = files
        model.start()
        coordinator.ingest(CopilotTestSupport.finalDelta("How did the Kafka migration go?", at: 1))
        try await CopilotTestSupport.waitUntil("the line") { !model.transcript.isEmpty }
        model.generate(now: Date(timeIntervalSince1970: 1_000))
        try await CopilotTestSupport.waitUntil("the request") { provider.openStreamCount == 1 }
        let sent = try #require(provider.lastAnswerRequest).passages.map(\.id)
        #expect(sent.count >= 2, "the request carried \(sent)")
        provider.push(.delta("It went well. "))
        provider.push(.sources([sent[0]]))
        provider.push(.completed(usageOutputTokens: nil))
        provider.finishStream()
        try await CopilotTestSupport.waitUntil("the answer") { model.questions.last?.selectedAnswer?.isComplete == true }

        let provenance = try #require(model.questions.last?.selectedAnswer?.provenance)
        #expect(provenance.included.map(\.passageID) == sent, "the answer claims different excerpts than were sent")
        #expect(provenance.citedPassageIDs == [sent[0]], "citations were invented or dropped")
        #expect(Set(provenance.included.map(\.filename)).isSubset(of: ["notes.txt", "cv.pdf"]))
        model.stop()
    }

    // MARK: Measurement

    /// Import time and peak memory for representative files, and the main actor's longest stall while
    /// they extract. The numbers are printed for the report; the assertions are loose ceilings.
    @Test
    func importTimeMemoryAndResponsiveness() async throws {
        let context = ModelContext(try S.container())
        let (files, _, _, _) = S.files(context: context)
        let samples: [(String, Data, UTType)] = [
            ("text-120-pages.pdf", S.textPDF((1...120).map { "Page \($0). " + String(repeating: "Distributed systems interview notes. ", count: 40) }), .pdf),
            ("scanned-5-pages.pdf", S.scannedPDF((1...5).map { ["SCANNED PAGE \($0)", "Event sourcing and CQRS"] }), .pdf),
            ("photo-12mp.png", S.textImage(["WHITEBOARD PHOTO", "Consistent hashing"], size: CGSize(width: 4000, height: 3000)), .png),
            ("sample.docx", try Data(contentsOf: S.docxFixture), UTType(filenameExtension: "docx")!),
        ]

        var maxStall: Duration = .zero
        let ticker = Task { @MainActor in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                let now = ContinuousClock.now
                maxStall = max(maxStall, now - last - .milliseconds(10))
                last = now
            }
        }
        var report: [String] = []
        for (name, data, type) in samples {
            let baseline = S.memoryFootprint()
            let sampler = Task.detached {
                var local = baseline
                while !Task.isCancelled {
                    local = max(local, SessionTestSupport.memoryFootprint())
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return local
            }
            let started = ContinuousClock.now
            files.importData(data, filename: name, type: type)
            await files.waitUntilIdle(timeout: .seconds(120))
            let elapsed = ContinuousClock.now - started
            sampler.cancel()
            let peak = await sampler.value
            let item = try #require(files.items.last)
            #expect(item.status == .ready, "\(name): \(item.detail ?? "")")
            report.append("\(name) \(data.count.fileSizeLabel): \(elapsed.formatted(.units(allowed: [.milliseconds]))) · peak +\((peak > baseline ? peak - baseline : 0) / 1_048_576) MB · \(item.status.rawValue)")
        }
        ticker.cancel()
        report.append("longest main-actor stall during extraction: \(maxStall.formatted(.units(allowed: [.milliseconds])))")
        print("IMPORT MEASUREMENTS\n" + report.joined(separator: "\n"))
        try report.joined(separator: "\n").write(toFile: NSTemporaryDirectory() + "neverblank-import-measurements.txt", atomically: true, encoding: .utf8)
        // A ceiling that catches real blocking (synchronous OCR on the main actor takes many seconds).
        // Swift Testing runs other @MainActor suites in parallel, and their work lands in this number
        // too, so the isolated figure is taken by running this test on its own.
        #expect(maxStall < .seconds(2), "the interview would have frozen for \(maxStall)")
    }
}
