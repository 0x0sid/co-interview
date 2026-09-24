import Foundation
import Observation
import SwiftData
import UniformTypeIdentifiers

/// The files attached to one interview session: importing, extracting, listing and removing them.
///
/// - Originals go to the private `FileStore`, named by content; metadata to `SessionAttachmentRecord`;
///   extracted text to `FileExtractionRecord`, once per content.
/// - **One extraction at a time.** Imports queue; each runs off the main actor and reports progress,
///   and any one can be cancelled. The interview keeps running while they do.
/// - **Duplicates** in the same session are refused with a notice; the same content in another
///   session reuses the stored copy and its extraction instantly.
/// - Every ready file's chunks are handed to `SessionFileContext`, which is where requests find them.
@MainActor
@Observable
final class SessionFiles {
    struct Item: Identifiable, Equatable {
        let id: UUID
        var filename: String
        var kind: AttachmentKind
        var byteSize: Int
        var status: AttachmentStatus
        var detail: String?
        var progress: Double = 0
        var pageCount: Int = 0
        var chunkCount: Int = 0
        var preview: String?
        var thumbnail: Data?
        var contentHash: String

        var summary: String {
            var parts = [kind.typeLabel, byteSize.fileSizeLabel]
            if pageCount > 0 { parts.append("\(pageCount) page\(pageCount == 1 ? "" : "s")") }
            return parts.joined(separator: " · ")
        }
    }

    private(set) var items: [Item] = []
    /// One-off message for the sheet: a duplicate, the file limit.
    var notice: String?

    let fileContext: SessionFileContext
    private let context: ModelContext
    private let session: InterviewSessionRecord
    private let store: FileStore
    private var queue: [UUID] = []
    private var running: (id: UUID, task: Task<Void, Never>)?
    private var passagesByAttachment: [UUID: [ProjectPassage]] = [:]
    /// Called after anything that changes what requests may include.
    var onChange: (() -> Void)?

    init(context: ModelContext, session: InterviewSessionRecord, store: FileStore, fileContext: SessionFileContext) {
        self.context = context
        self.session = session
        self.store = store
        self.fileContext = fileContext
        for record in session.attachments.sorted(by: { $0.importedAt < $1.importedAt }) {
            items.append(Self.item(from: record))
            // An extraction the app was killed in the middle of is local work, not a request: it is
            // simply queued again. Nothing is sent anywhere by this.
            if record.statusRaw == AttachmentStatus.extracting.rawValue || record.statusRaw == AttachmentStatus.importing.rawValue {
                if record.storedFileName.isEmpty {
                    record.statusRaw = AttachmentStatus.failed.rawValue
                    record.statusDetail = "The import was interrupted. Add the file again."
                    update(record.id) { $0.status = .failed; $0.detail = record.statusDetail }
                } else {
                    enqueue(record.id)
                }
            }
        }
        for item in items where item.status == .ready { loadPassages(for: item.id) }
        publishPassages()
    }

    // MARK: Labels

    /// "1 file", "2 files" — images and documents counted together. Nil when there are none.
    var countLabel: String? {
        items.isEmpty ? nil : "\(items.count) file\(items.count == 1 ? "" : "s")"
    }

    var readyAttachmentIDs: [UUID] { items.filter { $0.status == .ready }.map(\.id) }
    var isWorking: Bool { items.contains { $0.status.isWorking } }

    // MARK: Import

    /// A file from the Files app (or any URL). The original stays where it is; a private copy is kept.
    func importFile(at url: URL) {
        let type = UTType(filenameExtension: url.pathExtension)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        begin(filename: url.lastPathComponent, type: type, byteSize: size) { store in
            try store.ingest(fileAt: url, fileExtension: url.pathExtension)
        }
    }

    /// Bytes already in memory — a photo from the library.
    func importData(_ data: Data, filename: String, type: UTType?) {
        let ext = type?.preferredFilenameExtension ?? (filename as NSString).pathExtension
        begin(filename: filename, type: type, byteSize: data.count) { store in
            try store.ingest(data: data, fileExtension: ext)
        }
    }

    private func begin(filename: String, type: UTType?, byteSize: Int,
                       ingest: @escaping @Sendable (FileStore) throws -> FileStore.Ingested) {
        guard items.count < AttachmentLimits.maximumFilesPerSession else {
            notice = "An interview can have up to \(AttachmentLimits.maximumFilesPerSession) files. Remove one to add another."
            return
        }
        let kind = AttachmentKind.classify(type)
        let record = SessionAttachmentRecord(filename: filename, typeIdentifier: type?.identifier ?? "",
                                             kind: kind, byteSize: byteSize, contentHash: "", storedFileName: "",
                                             status: kind == .unsupported ? .unsupported : .importing)
        if kind == .unsupported {
            // Said, not swallowed: nothing is copied, and the row explains what would work instead.
            record.statusDetail = AttachmentKind.unsupportedExplanation(for: type, filename: filename)
        }
        record.session = session
        context.insert(record)
        session.attachments.append(record)
        items.append(Self.item(from: record))
        save()
        guard kind != .unsupported else { return }
        guard byteSize <= AttachmentLimits.maximumFileBytes else {
            fail(record, "This file is \(byteSize.fileSizeLabel). The limit is \(AttachmentLimits.maximumFileBytes.fileSizeLabel).")
            return
        }

        let store = self.store
        let id = record.id
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<FileStore.Ingested, Error> in
                Result { try ingest(store) }
            }.value
            self?.finishIngest(id: id, outcome: outcome)
        }
    }

    private func finishIngest(id: UUID, outcome: Result<FileStore.Ingested, Error>) {
        guard let record = record(id) else { return }      // removed while copying
        switch outcome {
        case .failure(let error):
            fail(record, error.localizedDescription)
        case .success(let ingested):
            if let existing = session.attachments.first(where: { $0.id != id && $0.contentHash == ingested.contentHash }) {
                notice = "“\(record.filename)” is already attached as “\(existing.filename)”."
                remove(id: id)
                return
            }
            record.contentHash = ingested.contentHash
            record.storedFileName = ingested.storedName
            record.byteSize = ingested.byteSize
            update(id) { $0.contentHash = ingested.contentHash; $0.byteSize = ingested.byteSize }
            if let cached = extraction(for: ingested.contentHash) {
                // Same content seen before (in any session): its extraction is reused, not redone.
                record.thumbnail = record.thumbnail ?? FileExtractor.thumbnail(url: store.url(forStoredName: ingested.storedName),
                                                                                kind: AttachmentKind(rawValue: record.kindRaw) ?? .unsupported)
                markReady(record, extraction: cached)
            } else {
                record.statusRaw = AttachmentStatus.extracting.rawValue
                update(id) { $0.status = .extracting }
                save()
                enqueue(id)
            }
        }
    }

    // MARK: Extraction queue

    private func enqueue(_ id: UUID) {
        guard !queue.contains(id), running?.id != id else { return }
        queue.append(id)
        runNext()
    }

    private func runNext() {
        guard running == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        guard let record = record(id) else { runNext(); return }
        let url = store.url(forStoredName: record.storedFileName)
        let kind = AttachmentKind(rawValue: record.kindRaw) ?? .unsupported
        record.statusRaw = AttachmentStatus.extracting.rawValue
        update(id) { $0.status = .extracting; $0.progress = 0 }
        // Progress arrives from the extraction thread; a weak box carries it back without keeping
        // the manager alive or capturing it across actors.
        let sink = WeakFiles(self)
        let progress: FileExtractor.Progress = { value in
            Task { @MainActor in sink.files?.update(id) { $0.progress = value } }
        }
        let task = Task { [weak self] in
            let started = ContinuousClock.now
            let outcome: Result<(FileExtractor.Result, Data), Error>
            do {
                let result = try await FileExtractor.extract(url: url, kind: kind, progress: progress)
                let encoded = await Task.detached(priority: .utility) { result.encodedChunks }.value
                outcome = .success((result, encoded))
            } catch {
                outcome = .failure(error)
            }
            let thumbnail = await Task.detached(priority: .utility) { FileExtractor.thumbnail(url: url, kind: kind) }.value
            self?.finishExtraction(id: id, outcome: outcome, thumbnail: thumbnail, elapsed: ContinuousClock.now - started)
        }
        running = (id, task)
    }

    /// How long the last extraction took, for measurement.
    private(set) var lastExtractionDuration: Duration?

    private func finishExtraction(id: UUID, outcome: Result<(FileExtractor.Result, Data), Error>, thumbnail: Data?, elapsed: Duration) {
        running = nil
        lastExtractionDuration = elapsed
        defer { runNext() }
        guard let record = record(id) else { return }
        record.thumbnail = thumbnail
        update(id) { $0.thumbnail = thumbnail }
        switch outcome {
        case .success(let (result, encoded)):
            let extraction = FileExtractionRecord(contentHash: record.contentHash, chunks: result.chunks, chunksData: encoded,
                                                  pageCount: result.pageCount, method: result.method, note: result.note)
            context.insert(extraction)
            markReady(record, extraction: extraction, chunks: result.chunks)
        case .failure(let error) where error is CancellationError:
            record.statusRaw = AttachmentStatus.cancelled.rawValue
            record.statusDetail = "Cancelled. Remove it, or add the file again."
            update(id) { $0.status = .cancelled; $0.detail = record.statusDetail }
            save()
        case .failure(let error):
            fail(record, error.localizedDescription)
        }
    }

    private func markReady(_ record: SessionAttachmentRecord, extraction: FileExtractionRecord, chunks known: [ExtractedChunk]? = nil) {
        record.statusRaw = AttachmentStatus.ready.rawValue
        record.statusDetail = extraction.note
        record.pageCount = extraction.pageCount
        let chunks = known ?? extraction.chunks
        update(record.id) {
            $0.status = .ready
            $0.detail = extraction.note
            $0.pageCount = extraction.pageCount
            $0.chunkCount = chunks.count
            $0.preview = chunks.first.map { String($0.text.prefix(280)) }
            $0.thumbnail = record.thumbnail
            $0.progress = 1
        }
        save()
        loadPassages(for: record.id, chunks: chunks)
        publishPassages()
    }

    private func fail(_ record: SessionAttachmentRecord, _ reason: String) {
        record.statusRaw = AttachmentStatus.failed.rawValue
        record.statusDetail = reason
        update(record.id) { $0.status = .failed; $0.detail = reason }
        save()
    }

    /// Stops an import or extraction. The row stays, marked cancelled, until it is removed.
    func cancel(id: UUID) {
        if let running, running.id == id {
            running.task.cancel()
        } else if let index = queue.firstIndex(of: id) {
            queue.remove(at: index)
            if let record = record(id) {
                record.statusRaw = AttachmentStatus.cancelled.rawValue
                record.statusDetail = "Cancelled. Remove it, or add the file again."
                update(id) { $0.status = .cancelled; $0.detail = record.statusDetail }
                save()
            }
        }
    }

    // MARK: Remove

    /// Takes a file out of this session. It is out of every later request at once; answers that
    /// already used it keep their labels. The stored copy and its extraction are deleted when no other
    /// session still has the same content.
    func remove(id: UUID) {
        cancel(id: id)
        items.removeAll { $0.id == id }
        passagesByAttachment[id] = nil
        publishPassages()
        guard let record = record(id) else { return }
        let hash = record.contentHash
        let storedName = record.storedFileName
        session.attachments.removeAll { $0.id == id }
        context.delete(record)
        save()
        FileReferences.releaseIfUnreferenced(hash: hash, storedName: storedName, context: context, store: store)
    }

    // MARK: Passages

    private func loadPassages(for id: UUID, chunks: [ExtractedChunk]? = nil) {
        guard let record = record(id) else { return }
        let chunks = chunks ?? extraction(for: record.contentHash)?.chunks ?? []
        let short = String(id.uuidString.prefix(8)).lowercased()
        passagesByAttachment[id] = chunks.map { chunk in
            ProjectPassage(id: "f\(short)#\(chunk.index)", documentID: id.uuidString, documentTitle: record.filename,
                           documentVersion: String(record.contentHash.prefix(12)), locator: chunk.locator, text: chunk.text)
        }
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].chunkCount = chunks.count
            items[index].preview = items[index].preview ?? chunks.first.map { String($0.text.prefix(280)) }
        }
    }

    private func publishPassages() {
        let ordered = items.filter { $0.status == .ready }.flatMap { passagesByAttachment[$0.id] ?? [] }
        fileContext.setPassages(ordered)
        onChange?()
    }

    // MARK: Helpers

    private func record(_ id: UUID) -> SessionAttachmentRecord? {
        session.attachments.first { $0.id == id }
    }

    private func extraction(for hash: String) -> FileExtractionRecord? {
        guard !hash.isEmpty else { return nil }
        var descriptor = FetchDescriptor<FileExtractionRecord>(predicate: #Predicate { $0.contentHash == hash })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func save() {
        if session.fileCount != session.attachments.count { session.fileCount = session.attachments.count }
        try? context.save()
    }

    private static func item(from record: SessionAttachmentRecord) -> Item {
        Item(id: record.id, filename: record.filename, kind: AttachmentKind(rawValue: record.kindRaw) ?? .unsupported,
             byteSize: record.byteSize, status: AttachmentStatus(rawValue: record.statusRaw) ?? .failed,
             detail: record.statusDetail, progress: record.statusRaw == AttachmentStatus.ready.rawValue ? 1 : 0,
             pageCount: record.pageCount, thumbnail: record.thumbnail, contentHash: record.contentHash)
    }

    #if DEBUG
    /// Waits until nothing is importing or extracting. Tests only.
    func waitUntilIdle(timeout: Duration = .seconds(60)) async {
        let deadline = ContinuousClock.now + timeout
        while (isWorking || running != nil) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    #endif
}

private final class WeakFiles: @unchecked Sendable {
    weak var files: SessionFiles?
    init(_ files: SessionFiles) { self.files = files }
}

/// Deletes a stored original and its extraction once nothing references the content any more.
enum FileReferences {
    @MainActor
    static func releaseIfUnreferenced(hash: String, storedName: String, context: ModelContext, store: FileStore) {
        guard !hash.isEmpty else { return }
        let stillUsed = (try? context.fetchCount(FetchDescriptor<SessionAttachmentRecord>(predicate: #Predicate { $0.contentHash == hash }))) ?? 1
        guard stillUsed == 0 else { return }
        store.remove(storedName: storedName)
        if let extraction = try? context.fetch(FetchDescriptor<FileExtractionRecord>(predicate: #Predicate { $0.contentHash == hash })).first {
            context.delete(extraction)
        }
        try? context.save()
    }
}
