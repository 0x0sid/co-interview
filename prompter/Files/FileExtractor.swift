import Foundation
import ImageIO
import PDFKit
import UIKit
import UniformTypeIdentifiers
import Vision

/// Reads the text out of an attached file, on the device, once.
///
/// - Images: on-device text recognition (Vision). Only the recognised text is ever used — the picture
///   itself is not sent anywhere.
/// - PDF: the embedded text layer, page by page; a page with no text (a scan) is rendered and
///   recognised instead, up to `AttachmentLimits.maximumOCRPages`.
/// - Plain text and Markdown; RTF (the system reader); Word .docx (`DocxReader`).
///
/// Everything runs off the main actor, one page at a time inside an autorelease pool, and checks for
/// cancellation between pages. Memory is bounded by never decoding more than one page or one
/// downsampled image at once.
enum FileExtractor {
    struct Result: Sendable {
        let chunks: [ExtractedChunk]
        /// The chunks already encoded for storage — done here, off the main actor.
        var encodedChunks: Data { (try? JSONEncoder().encode(chunks)) ?? Data() }
        let pageCount: Int
        let method: String
        /// What was left out, said once ("Pages 301–450 were not read.").
        let note: String?
    }

    enum Failure: LocalizedError {
        case unreadable(String)
        case noText(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let reason), .noText(let reason): reason
            }
        }
    }

    typealias Progress = @Sendable (Double) -> Void

    /// A stop request the page loop checks between pages.
    final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }

    /// **One serial queue for the whole app, off Swift's cooperative pool.** OCR and PDF parsing are
    /// long synchronous calls; run inside a Task they would hold cooperative threads that answer
    /// streaming and everything else async share. Here they run one at a time on their own thread.
    private static let queue = DispatchQueue(label: "neverblank.file-extraction", qos: .utility)

    static func extract(url: URL, kind: AttachmentKind, progress: @escaping Progress = { _ in }) async throws -> Result {
        let flag = CancellationFlag()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                queue.async {
                    continuation.resume(with: Swift.Result { try extractSync(url: url, kind: kind, progress: progress, flag: flag) })
                }
            }
        } onCancel: {
            flag.cancel()
        }
        if flag.isCancelled { throw CancellationError() }
        return result
    }

    static func extractSync(url: URL, kind: AttachmentKind, progress: Progress, flag: CancellationFlag = CancellationFlag()) throws -> Result {
        switch kind {
        case .image: return try image(url: url, progress: progress)
        case .pdf: return try pdf(url: url, progress: progress, flag: flag)
        case .text: return try plainText(url: url)
        case .rtf: return try rtf(url: url)
        case .docx: return try docx(url: url)
        case .unsupported: throw Failure.unreadable("This file type isn't supported.")
        }
    }

    // MARK: Images

    private static func image(url: URL, progress: Progress) throws -> Result {
        guard let image = downsampledImage(url: url, maximumEdge: AttachmentLimits.ocrMaximumEdge) else {
            throw Failure.unreadable("The file could not be read as an image.")
        }
        progress(0.3)
        let text = try recognizeText(in: image)
        progress(1)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.noText("No text was found in this image. Only text in images can be used — the picture itself is not sent.")
        }
        let (kept, note) = capped(text)
        return Result(chunks: chunk(sections: [("image", kept)]), pageCount: 1, method: "ocr", note: note)
    }

    // MARK: PDF

    private static func pdf(url: URL, progress: Progress, flag: CancellationFlag) throws -> Result {
        guard let document = PDFDocument(url: url) else {
            throw Failure.unreadable("The file could not be opened as a PDF.")
        }
        guard !document.isLocked else {
            throw Failure.unreadable("This PDF is password-protected.")
        }
        let total = document.pageCount
        let readable = min(total, AttachmentLimits.maximumPDFPages)
        var sections: [(String, String)] = []
        var ocrPages = 0
        var skippedScans = 0
        var characters = 0
        for index in 0..<readable {
            if flag.isCancelled { throw CancellationError() }
            guard characters < AttachmentLimits.maximumCharacters else { break }
            let text: String = try autoreleasepool {
                guard let page = document.page(at: index) else { return "" }
                let embedded = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if embedded.count >= 25 { return embedded }
                // No usable text layer: a scanned page. Render it and read it, within the OCR budget.
                guard ocrPages < AttachmentLimits.maximumOCRPages else {
                    skippedScans += 1
                    return embedded
                }
                ocrPages += 1
                let bounds = page.bounds(for: .mediaBox)
                let scale = min(2200 / max(bounds.width, bounds.height, 1), 3)
                let rendered = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                guard let cgImage = rendered.cgImage else { return embedded }
                let recognised = try recognizeText(in: cgImage)
                return recognised.isEmpty ? embedded : recognised
            }
            if !text.isEmpty {
                sections.append(("p. \(index + 1)", text))
                characters += text.count
            }
            progress(Double(index + 1) / Double(readable))
        }
        var notes: [String] = []
        if total > readable { notes.append("Pages \(readable + 1)–\(total) were not read (limit \(AttachmentLimits.maximumPDFPages) pages).") }
        if skippedScans > 0 { notes.append("\(skippedScans) scanned page\(skippedScans == 1 ? " was" : "s were") not read (text recognition limit \(AttachmentLimits.maximumOCRPages) pages).") }
        if characters >= AttachmentLimits.maximumCharacters { notes.append("Only the first \(AttachmentLimits.maximumCharacters / 1000)k characters were kept.") }
        guard !sections.isEmpty else {
            throw Failure.noText("No text was found in this PDF.")
        }
        let method = ocrPages == 0 ? "pdf-text" : (ocrPages == sections.count ? "pdf-ocr" : "pdf-text+ocr")
        return Result(chunks: chunk(sections: sections), pageCount: total, method: method,
                      note: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    // MARK: Text formats

    private static func plainText(url: URL) throws -> Result {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let text = decodeText(data) else {
            throw Failure.unreadable("This file isn't readable text.")
        }
        return try textResult(text, method: "text")
    }

    private static func rtf(url: URL) throws -> Result {
        guard let attributed = try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else {
            throw Failure.unreadable("The RTF file could not be read.")
        }
        return try textResult(attributed.string, method: "rtf")
    }

    private static func docx(url: URL) throws -> Result {
        let text: String
        do {
            text = try DocxReader.text(from: url)
        } catch {
            throw Failure.unreadable("The Word document could not be read: \(error.localizedDescription)")
        }
        return try textResult(text, method: "docx")
    }

    /// Paragraph-located chunks ("¶ 4–9") for formats with no pages.
    private static func textResult(_ text: String, method: String) throws -> Result {
        let (kept, note) = capped(text)
        let paragraphs = kept.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { throw Failure.noText("This file contains no text.") }
        var chunks: [ExtractedChunk] = []
        var buffer: [String] = []
        var bufferStart = 0
        var bufferEnd = 0
        var length = 0
        func flush() {
            guard !buffer.isEmpty else { return }
            let locator = bufferStart == bufferEnd ? "¶ \(bufferStart)" : "¶ \(bufferStart)–\(bufferEnd)"
            chunks.append(ExtractedChunk(index: chunks.count, locator: locator, text: buffer.joined(separator: "\n")))
            buffer = []
            length = 0
        }
        for (offset, paragraph) in paragraphs.enumerated() {
            let number = offset + 1
            for piece in split(paragraph, limit: AttachmentLimits.chunkCharacters) {
                if length + piece.count > AttachmentLimits.chunkCharacters { flush() }
                if buffer.isEmpty { bufferStart = number }
                buffer.append(piece)
                bufferEnd = number
                length += piece.count + 1
            }
        }
        flush()
        return Result(chunks: chunks, pageCount: 0, method: method, note: note)
    }

    // MARK: Helpers

    /// UTF-8, then UTF-16 with a byte-order mark. Anything with NUL bytes is binary, not text.
    static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        guard !data.prefix(8192).contains(0) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
    }

    private static func capped(_ text: String) -> (String, String?) {
        guard text.count > AttachmentLimits.maximumCharacters else { return (text, nil) }
        return (String(text.prefix(AttachmentLimits.maximumCharacters)),
                "Only the first \(AttachmentLimits.maximumCharacters / 1000)k characters were kept.")
    }

    /// Page- or image-located chunks: each section split to the chunk size, keeping its locator.
    static func chunk(sections: [(locator: String, text: String)]) -> [ExtractedChunk] {
        var chunks: [ExtractedChunk] = []
        for section in sections {
            let pieces = split(section.text, limit: AttachmentLimits.chunkCharacters)
            for (part, piece) in pieces.enumerated() {
                let locator = pieces.count == 1 ? section.locator : "\(section.locator), part \(part + 1)"
                chunks.append(ExtractedChunk(index: chunks.count, locator: locator, text: piece))
            }
        }
        return chunks
    }

    /// Splits at line or sentence boundaries where possible, never mid-word unless a word is longer
    /// than the limit.
    static func split(_ text: String, limit: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed.isEmpty ? [] : [trimmed] }
        var pieces: [String] = []
        var current = ""
        for word in trimmed.split(omittingEmptySubsequences: false, whereSeparator: { $0 == " " || $0 == "\n" }) {
            if current.count + word.count + 1 > limit, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            current += current.isEmpty ? String(word) : " " + word
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// Decodes an image straight to at most `maximumEdge` pixels, orientation applied.
    static func downsampledImage(url: URL, maximumEdge: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Text in reading order: top to bottom, then left to right within a line.
    static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "fr-FR"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = (request.results ?? []).sorted { lhs, rhs in
            let dy = lhs.boundingBox.midY - rhs.boundingBox.midY
            if abs(dy) > 0.01 { return dy > 0 }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// A small JPEG for lists — never the full image.
    static func thumbnail(url: URL, kind: AttachmentKind) -> Data? {
        switch kind {
        case .image:
            guard let image = downsampledImage(url: url, maximumEdge: 180) else { return nil }
            return UIImage(cgImage: image).jpegData(compressionQuality: 0.7)
        case .pdf:
            guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
            return page.thumbnail(of: CGSize(width: 180, height: 180), for: .mediaBox).jpegData(compressionQuality: 0.7)
        default:
            return nil
        }
    }
}
