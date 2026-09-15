import Foundation
import FoundationModels

/// §12.3's "Optimize for speaking" — on-device `FoundationModels`, feature-flagged OFF by
/// default (`AppSettings.aiRewriteEnabled`). Never auto-applies; the editor shows a diff and the
/// user accepts/rejects. Verified against the installed iOS 26 SDK's FoundationModels.swiftinterface:
/// `SystemLanguageModel.default.isAvailable`, `LanguageModelSession.init(instructions:)`,
/// `.respond(to:)`.
enum AIRewriteService {
    enum RewriteError: Error, Sendable {
        case modelUnavailable
    }

    /// §12.3: "If model unavailable → button hidden (graceful absence, no error)" — checked by
    /// the editor before showing the button at all.
    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    static func rewrite(_ scriptText: String) async throws -> String {
        guard isAvailable else { throw RewriteError.modelUnavailable }

        let session = LanguageModelSession(
            instructions: """
            You rewrite scripts for spoken teleprompter delivery. Keep the same meaning, length, \
            and paragraph structure. Prefer shorter sentences and natural spoken phrasing over \
            written phrasing. Do not add commentary, headers, or quotation marks — return only \
            the rewritten script text.
            """
        )
        let response = try await session.respond(to: scriptText)
        return response.content
    }
}
