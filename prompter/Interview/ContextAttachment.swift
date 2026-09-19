import Foundation
import UIKit

/// An image the user attached, and what actually happened to it.
///
/// **Every attachment is visibly in one of these states**, because the failure modes are real: a
/// photo can fail to decode, a model can be text-only, and a picture that was silently ignored is
/// worse than one that was never attached — the user would believe the answer had seen it.
struct ContextAttachment: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// Being decoded and downscaled off the main actor.
        case preparing
        /// Ready to send, with its encoded size.
        case ready(bytes: Int)
        /// Could not be prepared at all.
        case failed(reason: String)
        /// Prepared, but the configured model cannot read images.
        case notSupported

        var label: String {
            switch self {
            case .preparing: "Preparing…"
            case .ready(let bytes): "Ready · \(bytes / 1024) KB"
            case .failed(let reason): "Not usable — \(reason)"
            case .notSupported: "Not sent — this model reads text only"
            }
        }

        var isSendable: Bool { if case .ready = self { true } else { false } }
    }

    let id: UUID
    /// The original data, kept for the thumbnail.
    let originalData: Data
    var state: State
    /// JPEG bytes actually sent, set when preparation succeeds.
    var preparedJPEG: Data?

    init(id: UUID = UUID(), originalData: Data, state: State = .preparing, preparedJPEG: Data? = nil) {
        self.id = id
        self.originalData = originalData
        self.state = state
        self.preparedJPEG = preparedJPEG
    }

    /// Longest edge after downscaling. Large enough to read a screenshot of code, small enough that
    /// five of them stay inside the backend's answer-body ceiling.
    static let maximumEdge: CGFloat = 1280
    /// Hard ceiling per attachment after encoding. Five of these still fit the backend's 3 MB limit.
    static let maximumBytes = 400_000

    /// Decodes and downscales, off the main actor.
    ///
    /// Bounded twice: by pixel size, then by re-encoding at falling quality until it fits. If it
    /// still does not fit, it fails **loudly** rather than sending something the backend will reject.
    static func prepare(_ data: Data) async -> (state: State, jpeg: Data?) {
        await Task.detached(priority: .userInitiated) { () -> (State, Data?) in
            guard let image = UIImage(data: data) else {
                return (.failed(reason: "the file could not be read as an image"), nil)
            }
            let scale = min(1, maximumEdge / max(image.size.width, image.size.height))
            let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: target)
            let scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }

            for quality in [0.7, 0.5, 0.35, 0.25] {
                guard let jpeg = scaled.jpegData(compressionQuality: quality) else { continue }
                if jpeg.count <= maximumBytes {
                    return (.ready(bytes: jpeg.count), jpeg)
                }
            }
            return (.failed(reason: "too large to send even after downscaling"), nil)
        }.value
    }
}
