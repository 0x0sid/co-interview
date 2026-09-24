import Foundation
import UniformTypeIdentifiers

/// What kind of file an attachment is, which decides how its text is extracted.
enum AttachmentKind: String, Codable, Sendable {
    case image
    case pdf
    case text
    case rtf
    case docx
    case unsupported

    var systemImage: String {
        switch self {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .text: "doc.plaintext"
        case .rtf, .docx: "doc.text"
        case .unsupported: "doc.questionmark"
        }
    }

    var typeLabel: String {
        switch self {
        case .image: "Image"
        case .pdf: "PDF"
        case .text: "Text"
        case .rtf: "RTF"
        case .docx: "Word document"
        case .unsupported: "Unsupported"
        }
    }

    /// Decided from the type, never guessed from content: a file that claims to be a PDF and is not
    /// fails loudly at extraction instead of being read as something else.
    static func classify(_ type: UTType?) -> AttachmentKind {
        guard let type else { return .unsupported }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .rtf) { return .rtf }
        if type.identifier == "org.openxmlformats.wordprocessingml.document" { return .docx }
        // Markdown ("net.daringfireball.markdown") conforms to plain text; so do .txt, .csv-less text.
        if type.conforms(to: .plainText) { return .text }
        return .unsupported
    }

    /// Named, so an unsupported file says what it is and what would work instead.
    static func unsupportedExplanation(for type: UTType?, filename: String) -> String {
        let name = type?.localizedDescription ?? (filename as NSString).pathExtension.uppercased()
        return "\(name.isEmpty ? "This file type" : name) isn't supported yet. Supported: images, PDF, text, Markdown, RTF and Word (.docx)."
    }
}

/// Where an attachment is in its life. Every state is shown; nothing is silently treated as empty.
enum AttachmentStatus: String, Codable, Sendable {
    case importing
    case extracting
    case ready
    case failed
    case unsupported
    case cancelled

    var label: String {
        switch self {
        case .importing: "Importing…"
        case .extracting: "Extracting text…"
        case .ready: "Ready"
        case .failed: "Failed"
        case .unsupported: "Not supported"
        case .cancelled: "Cancelled"
        }
    }

    var isUsable: Bool { self == .ready }
    var isWorking: Bool { self == .importing || self == .extracting }
}

/// One identifiable piece of extracted text: where it came from, and what it says.
struct ExtractedChunk: Codable, Equatable, Sendable {
    /// 0-based, stable for a given extraction.
    let index: Int
    /// "p. 3", "¶ 4–9", "image" — shown with the excerpt and sent as its locator.
    let locator: String
    let text: String
}

/// The documented limits. Each one produces a stated message when reached, never a silent cut.
enum AttachmentLimits {
    /// Largest file accepted, in bytes.
    static let maximumFileBytes = 25 * 1024 * 1024
    /// Files per session.
    static let maximumFilesPerSession = 20
    /// PDF pages whose text is read.
    static let maximumPDFPages = 300
    /// PDF pages that may be OCR'd because they have no text layer (scans). OCR is the slow part.
    static let maximumOCRPages = 40
    /// Characters of extracted text kept per file.
    static let maximumCharacters = 400_000
    /// Longest edge an image is decoded to for OCR, so a 48-megapixel photo never lands in memory whole.
    static let ocrMaximumEdge: CGFloat = 3000
    /// Size of a retrieval chunk, in characters.
    static let chunkCharacters = 900

    static var summary: String {
        "Up to \(maximumFileBytes / 1024 / 1024) MB per file and \(maximumFilesPerSession) files per interview. PDFs: text from up to \(maximumPDFPages) pages; scanned pages are read with on-device text recognition, up to \(maximumOCRPages) pages."
    }
}

extension Int {
    /// "340 KB", "2.1 MB".
    var fileSizeLabel: String { ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file) }
}
