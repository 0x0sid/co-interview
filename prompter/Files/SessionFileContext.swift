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

    /// The best keyword matches — and, for a personal or broad question, the opening excerpts of
    /// each file to fill the remaining places.
    ///
    /// "Tell me about yourself" or "Why am I a good fit?" share almost no words with a CV or a job
    /// description, so keyword scoring alone sends nothing. For questions about the candidate, the
    /// start of each file (a CV's summary, a job description's role) is added, one file at a time
    /// in turn, never more than `limit` in all. A general question ("How does a HashMap work?")
    /// does not trigger it, so personal files are not sent where nothing asks for them. The model is
    /// still told never to invent experience the excerpts do not support.
    func passages(forQuestion question: String, limit: Int) -> [ProjectPassage] {
        lock.lock()
        let retriever = self.retriever
        let all = currentPassages
        lock.unlock()
        var picked = retriever.topPassages(for: question, limit: limit)
        guard picked.count < limit, Self.isAboutTheCandidate(question) else { return picked }
        var byFile: [String: [ProjectPassage]] = [:]
        var order: [String] = []
        for passage in all {
            if byFile[passage.documentID] == nil { order.append(passage.documentID) }
            byFile[passage.documentID, default: []].append(passage)
        }
        var depth = 0
        while picked.count < limit, depth < Self.openingDepth {
            for file in order where picked.count < limit {
                guard let openings = byFile[file], depth < openings.count else { continue }
                let candidate = openings[depth]
                if !picked.contains(where: { $0.id == candidate.id }) { picked.append(candidate) }
            }
            depth += 1
        }
        return picked
    }

    /// How many opening excerpts per file the fallback may use.
    static let openingDepth = 2

    /// Questions about the candidate, in English and French (accents folded by the tokenizer).
    static func isAboutTheCandidate(_ question: String) -> Bool {
        !Set(Tokenizer.normalize(question)).isDisjoint(with: candidateWords)
    }

    private static let candidateWords: Set<String> = [
        "you", "your", "yourself", "yours", "i", "me", "my", "myself", "background", "experience", "experiences",
        "cv", "resume", "fit", "role", "position", "job", "strength", "strengths", "weakness", "weaknesses",
        "hire", "motivation", "motivated", "career", "projects", "achievement", "achievements",
        "vous", "votre", "vos", "parcours", "experience", "poste", "candidature", "moi", "mon", "ma", "mes", "je",
        "profil", "competences", "forces", "faiblesses",
    ]
}
