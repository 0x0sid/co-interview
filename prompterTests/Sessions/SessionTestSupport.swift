import Foundation
import SwiftData
import UIKit
@testable import prompter

/// Stores, containers and generated files for the session and file tests. Every file here is made
/// by the test itself (or is the committed .docx fixture) — no personal data.
enum SessionTestSupport {
    static func temporaryDirectory() -> URL {
        let url = URL.temporaryDirectory.appending(path: "neverblank-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var fullSchema: Schema {
        Schema([Script.self, PromptSession.self, UsageLedger.self, AppSettings.self] + AppEnvironment.sessionModels)
    }

    static func container(at url: URL? = nil) throws -> ModelContainer {
        let configuration = url.map { ModelConfiguration(schema: fullSchema, url: $0) }
            ?? ModelConfiguration(schema: fullSchema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: fullSchema, configurations: [configuration])
    }

    @MainActor
    static func files(context: ModelContext, session: InterviewSessionRecord? = nil, store: FileStore? = nil,
                      language: InterviewLanguage = .english) -> (SessionFiles, InterviewSessionRecord, SessionFileContext, FileStore) {
        let session = session ?? InterviewSessionStore.create(in: context, language: language, preference: .system)
        let store = store ?? FileStore(root: temporaryDirectory())
        let fileContext = SessionFileContext(language: language)
        return (SessionFiles(context: context, session: session, store: store, fileContext: fileContext), session, fileContext, store)
    }

    // MARK: Generated files

    /// Black text on white, large enough for OCR to be unambiguous.
    static func textImage(_ lines: [String], size: CGSize = CGSize(width: 1600, height: 900)) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 64), .foregroundColor: UIColor.black]
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 60, y: 80 + CGFloat(index) * 110), withAttributes: attributes)
            }
        }.pngData()!
    }

    static func blankImage() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }.pngData()!
    }

    /// A PDF with a real text layer, one string per page.
    static func textPDF(_ pages: [String]) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for text in pages {
                context.beginPage()
                (text as NSString).draw(in: bounds.insetBy(dx: 54, dy: 54),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            }
        }
    }

    /// A "scanned" PDF: each page is only a picture of text, with no text layer.
    static func scannedPDF(_ pages: [[String]]) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for lines in pages {
                context.beginPage()
                let image = UIImage(data: textImage(lines, size: CGSize(width: 1600, height: 2070)))!
                image.draw(in: bounds)
            }
        }
    }

    static func write(_ data: Data, named name: String) -> URL {
        let url = temporaryDirectory().appending(path: name)
        try? data.write(to: url)
        return url
    }

    static var docxFixture: URL {
        Bundle(for: BundleToken.self).url(forResource: "sample", withExtension: "docx")!
    }

    private final class BundleToken {}

    /// The process's physical memory footprint, as Xcode's memory gauge reports it.
    static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
