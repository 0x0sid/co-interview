import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// The app's private copy of every attached file.
///
/// **Content-addressed.** A file is stored once under its SHA-256, so attaching the same document to
/// two interviews keeps one copy and one extraction, and a copy stays available after the original is
/// moved, renamed or deleted elsewhere. Nothing here leaves the device.
struct FileStore: Sendable {
    let root: URL

    /// Application Support/NeverblankFiles — private to the app, not visible in Files.
    static var standard: FileStore {
        FileStore(root: URL.applicationSupportDirectory.appending(path: "NeverblankFiles", directoryHint: .isDirectory))
    }

    func url(forStoredName name: String) -> URL { root.appending(path: name) }

    struct Ingested: Sendable {
        let contentHash: String
        let storedName: String
        let byteSize: Int
    }

    enum IngestError: LocalizedError {
        case tooLarge(Int)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                "This file is \(bytes.fileSizeLabel). The limit is \(AttachmentLimits.maximumFileBytes.fileSizeLabel)."
            case .unreadable(let reason):
                "The file could not be read: \(reason)"
            }
        }
    }

    /// Copies an external file in (Files import). Size is checked before anything is copied, the hash
    /// is computed while streaming, and the security-scoped access is released straight after.
    func ingest(fileAt source: URL, fileExtension: String) throws -> Ingested {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= AttachmentLimits.maximumFileBytes else { throw IngestError.tooLarge(size) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appending(path: "staging-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: source, to: staging)
        } catch {
            throw IngestError.unreadable(error.localizedDescription)
        }
        return try settle(staging: staging, fileExtension: fileExtension)
    }

    /// Stores bytes that are already in memory (a photo from the library).
    func ingest(data: Data, fileExtension: String) throws -> Ingested {
        guard data.count <= AttachmentLimits.maximumFileBytes else { throw IngestError.tooLarge(data.count) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appending(path: "staging-\(UUID().uuidString)")
        try data.write(to: staging, options: .atomic)
        return try settle(staging: staging, fileExtension: fileExtension)
    }

    /// Moves a staged copy to its content address, or drops it when that content is already stored.
    private func settle(staging: URL, fileExtension: String) throws -> Ingested {
        defer { try? FileManager.default.removeItem(at: staging) }
        let (hash, size) = try Self.sha256(of: staging)
        guard size <= AttachmentLimits.maximumFileBytes else { throw IngestError.tooLarge(size) }
        let ext = fileExtension.isEmpty ? "bin" : fileExtension.lowercased()
        let name = "\(hash).\(ext)"
        let destination = url(forStoredName: name)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        return Ingested(contentHash: hash, storedName: name, byteSize: size)
    }

    /// Deletes a stored original. The caller decides it is no longer referenced.
    func remove(storedName: String) {
        guard !storedName.isEmpty else { return }
        try? FileManager.default.removeItem(at: url(forStoredName: storedName))
    }

    /// Streams the file through SHA-256 a megabyte at a time, so hashing never holds it whole.
    static func sha256(of url: URL) throws -> (hash: String, size: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += chunk.count
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (hash, size)
    }
}
