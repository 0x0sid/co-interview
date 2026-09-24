import Compression
import Foundation

/// Reads the text of a Word .docx: the `word/document.xml` inside its ZIP container.
///
/// iOS has no public .docx reader (`NSAttributedString`'s Office type is macOS-only), so this takes
/// the small, well-specified part it needs: the ZIP central directory, one entry, raw DEFLATE through
/// Apple's Compression framework, and `XMLParser` for the paragraphs. Text only — no formatting,
/// tables are read cell by cell, headers, footers and comments are not included. ZIP64 and encrypted
/// documents are refused with a stated reason.
enum DocxReader {
    enum Failure: LocalizedError {
        case notAZip
        case missingDocument
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .notAZip: "it is not a valid .docx container"
            case .missingDocument: "it contains no document body"
            case .unsupported(let reason): reason
            }
        }
    }

    static func text(from url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let xml = try entry(named: "word/document.xml", in: data)
        return try paragraphs(fromDocumentXML: xml)
    }

    // MARK: ZIP

    static func entry(named wanted: String, in data: Data) throws -> Data {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { at + 1 < bytes.count ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : 0 }
        func u32(_ at: Int) -> Int { at + 3 < bytes.count ? u16(at) | u16(at + 2) << 16 : 0 }

        // End of central directory: the last 0x06054b50 within the final 64 KB + 22 bytes.
        guard bytes.count >= 22 else { throw Failure.notAZip }
        var eocd = -1
        var position = bytes.count - 22
        let floor = max(0, bytes.count - 22 - 65_535)
        while position >= floor {
            if u32(position) == 0x0605_4b50 { eocd = position; break }
            position -= 1
        }
        guard eocd >= 0 else { throw Failure.notAZip }
        let entryCount = u16(eocd + 10)
        var cursor = u32(eocd + 16)
        guard entryCount != 0xFFFF, cursor != 0xFFFF_FFFF else { throw Failure.unsupported("ZIP64 documents aren't supported") }

        for _ in 0..<entryCount {
            guard u32(cursor) == 0x0201_4b50 else { throw Failure.notAZip }
            let flags = u16(cursor + 8)
            let method = u16(cursor + 10)
            let compressedSize = u32(cursor + 20)
            let uncompressedSize = u32(cursor + 24)
            let nameLength = u16(cursor + 28)
            let extraLength = u16(cursor + 30)
            let commentLength = u16(cursor + 32)
            let localOffset = u32(cursor + 42)
            let nameStart = cursor + 46
            guard nameStart + nameLength <= bytes.count else { throw Failure.notAZip }
            let name = String(decoding: bytes[nameStart..<nameStart + nameLength], as: UTF8.self)
            cursor = nameStart + nameLength + extraLength + commentLength
            guard name == wanted else { continue }

            guard flags & 1 == 0 else { throw Failure.unsupported("password-protected documents aren't supported") }
            guard u32(localOffset) == 0x0403_4b50 else { throw Failure.notAZip }
            let dataStart = localOffset + 30 + u16(localOffset + 26) + u16(localOffset + 28)
            guard dataStart + compressedSize <= bytes.count, uncompressedSize < 64 * 1024 * 1024 else { throw Failure.notAZip }
            let payload = data.subdata(in: dataStart..<dataStart + compressedSize)
            switch method {
            case 0:
                return payload
            case 8:
                return try inflate(payload, expectedSize: uncompressedSize)
            default:
                throw Failure.unsupported("compression method \(method) isn't supported")
            }
        }
        throw Failure.missingDocument
    }

    /// Raw DEFLATE (what ZIP stores), which is what `COMPRESSION_ZLIB` decodes.
    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        var output = Data(count: max(expectedSize, 1))
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw Failure.notAZip }
        return output
    }

    // MARK: XML

    static func paragraphs(fromDocumentXML xml: Data) throws -> String {
        let collector = TextCollector()
        let parser = XMLParser(data: xml)
        parser.delegate = collector
        guard parser.parse() else { throw Failure.notAZip }
        return collector.paragraphs.joined(separator: "\n")
    }

    /// `w:t` is text, `w:tab` a tab, `w:br` a line break, and each `w:p` one paragraph.
    private final class TextCollector: NSObject, XMLParserDelegate {
        var paragraphs: [String] = []
        private var current = ""
        private var inText = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "w:t": inText = true
            case "w:tab": current += "\t"
            case "w:br", "w:cr": current += " "
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { current += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "w:t": inText = false
            case "w:p":
                let line = current.trimmingCharacters(in: .whitespaces)
                if !line.isEmpty { paragraphs.append(line) }
                current = ""
            default: break
            }
        }
    }
}
