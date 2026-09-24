import Foundation

/// A live session's project context: its language and the extracted text of its ready files.
///
/// This fills the hook `LiveSessionContext` left empty for document import. The coordinator asks it
/// for passages when a request is built; it answers with the few chunks that best match the request,
/// by the same local lexical scoring the pipeline already uses (`PassageRetriever`). No embeddings, no
/// network, and nothing but the selected excerpts leaves the device.
///
/// A class, because files become ready — and get removed — while the session runs; the coordinator
/// holds this one instance and always sees the current set. With no files it returns nothing, which
/// makes every request exactly what it was before files existed.
final class SessionFileContext: ProjectContextProviding, @unchecked Sendable {
    /// The same identity `LiveSessionContext` used, so the backend's prompt-cache affinity is unchanged.
    let projectID = "live-session"
    let projectName = "Live session"
    let instructions = ""

    private let lock = NSLock()
    private var currentLanguage: InterviewLanguage
    private var currentPassages: [ProjectPassage] = []
    private var retriever = PassageRetriever(passages: [])

    init(language: InterviewLanguage) {
        currentLanguage = language
    }

    var language: InterviewLanguage { lock.withLock { currentLanguage } }

    func setLanguage(_ language: InterviewLanguage) { lock.withLock { currentLanguage = language } }

    /// Replaces the searchable passages — called when a file becomes ready or is removed. A removed
    /// file is out of every request built after this returns.
    func setPassages(_ passages: [ProjectPassage]) {
        lock.withLock {
            currentPassages = passages
            retriever = PassageRetriever(passages: passages)
        }
    }

    var passageCount: Int { lock.withLock { currentPassages.count } }

    func passages(forQuestion question: String, limit: Int) -> [ProjectPassage] {
        lock.withLock { retriever }.topPassages(for: question, limit: limit)
    }
}
