import Foundation
import SwiftData

// Local persistence for interview sessions.
//
// **Rows, not a blob.** A session is split into utterances, questions, answers and attachments so a
// transcription revision or a streamed sentence updates one small row; nothing rewrites the whole
// session for every change. Raw audio is never stored.

/// One interview, as it is kept on this device.
@Model
final class InterviewSessionRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    /// Set once the user renames it; the automatic title never overwrites a chosen one.
    var isTitleCustom: Bool = false
    var createdAt: Date
    var lastActivityAt: Date
    /// Time the interview screen was open and in the foreground with this session running.
    var activeSeconds: Double = 0
    /// "live" or "demo". Only live sessions are listed in history.
    var modeRaw: String = "live"
    /// The language this session actually used (`InterviewLanguage.rawValue`). Snapshotted: opening
    /// an old session never re-resolves it from the current preference.
    var languageRaw: String
    /// What was chosen when it started ("system", "english", "french"), for the record.
    var languagePreferenceRaw: String
    /// The typed note, exactly as it was.
    var note: String = ""
    /// "open" while the interview screen has it, "ended" when it was closed normally, and
    /// "interrupted" when the app stopped without closing it (found on the next launch).
    var stateRaw: String = "open"
    /// Kept up to date by the recorder and the file list, so history rows never walk relationships.
    var answeredCount: Int = 0
    var fileCount: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \SessionUtteranceRecord.session)
    var utterances: [SessionUtteranceRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \SessionQuestionRecord.session)
    var questions: [SessionQuestionRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \SessionAttachmentRecord.session)
    var attachments: [SessionAttachmentRecord] = []

    init(id: UUID = UUID(), title: String, createdAt: Date = .now, mode: String = "live",
         language: InterviewLanguage, preference: InterviewLanguagePreference) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.lastActivityAt = createdAt
        self.modeRaw = mode
        self.languageRaw = language.rawValue
        self.languagePreferenceRaw = preference.rawValue
    }

    var language: InterviewLanguage { InterviewLanguage(rawValue: languageRaw) ?? .english }

    enum State: String { case open, ended, interrupted }
    var state: State {
        get { State(rawValue: stateRaw) ?? .ended }
        set { stateRaw = newValue.rawValue }
    }

    static func defaultTitle(for date: Date) -> String {
        "Interview · " + date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

/// One transcript line: the recogniser's utterance identity, its order, and its latest wording.
/// Corrections update this row in place, as they do on screen.
@Model
final class SessionUtteranceRecord {
    var id: UUID
    var order: Int
    var text: String
    var isFinal: Bool
    var revision: Int
    var isDetectedQuestion: Bool
    var questionID: UUID?
    /// The wording a request already covered, so a restored session does not treat it as new speech.
    var coveredWording: String?
    var session: InterviewSessionRecord?

    init(line: TranscriptLine, order: Int) {
        id = line.id
        self.order = order
        text = line.text
        isFinal = line.isFinal
        revision = line.revision
        isDetectedQuestion = line.isDetectedQuestion
        questionID = line.questionID
    }
}

/// One question page and the request snapshot needed to retry it.
@Model
final class SessionQuestionRecord {
    var id: UUID
    var order: Int
    var text: String
    var selectedAnswerID: UUID?
    /// `[StoredFollowUp]` as JSON.
    var followUpsData: Data?
    /// The `DiscussionSnapshot` the page's request answered, as JSON — Retry re-sends exactly this.
    var snapshotData: Data?
    var session: InterviewSessionRecord?
    @Relationship(deleteRule: .cascade, inverse: \SessionAnswerRecord.question)
    var answers: [SessionAnswerRecord] = []

    init(id: UUID, order: Int, text: String) {
        self.id = id
        self.order = order
        self.text = text
    }
}

/// One answer version with its generation status and what went into its request.
@Model
final class SessionAnswerRecord {
    var id: UUID
    var version: Int
    /// `[StoredBlock]` as JSON, in the order written.
    var blocksData: Data = Data()
    var highlight: String?
    /// "streaming", "complete", "incomplete", "failed" or "interrupted".
    var stateRaw: String = "streaming"
    var failureMessage: String?
    var needRaw: String?
    var createdAt: Date
    /// `AnswerProvenance` as JSON: which files and excerpts were in the request, and what was cited.
    var provenanceData: Data?
    var question: SessionQuestionRecord?

    init(id: UUID, version: Int, createdAt: Date) {
        self.id = id
        self.version = version
        self.createdAt = createdAt
    }
}

/// A file attached to a session. The original lives in the app's private file store, named by its
/// content hash; the extracted text lives in `FileExtractionRecord`, shared by every attachment of
/// the same content.
@Model
final class SessionAttachmentRecord {
    var id: UUID
    var filename: String
    var typeIdentifier: String
    /// `AttachmentKind.rawValue`.
    var kindRaw: String
    var byteSize: Int
    var contentHash: String
    /// File name inside the file store, or empty when nothing was stored (an unsupported type).
    var storedFileName: String
    /// `AttachmentStatus.rawValue`.
    var statusRaw: String
    /// Why it failed or what was left out ("pages 41–120 not read").
    var statusDetail: String?
    var pageCount: Int = 0
    var importedAt: Date
    @Attribute(.externalStorage) var thumbnail: Data?
    var session: InterviewSessionRecord?

    init(id: UUID = UUID(), filename: String, typeIdentifier: String, kind: AttachmentKind, byteSize: Int,
         contentHash: String, storedFileName: String, status: AttachmentStatus, importedAt: Date = .now) {
        self.id = id
        self.filename = filename
        self.typeIdentifier = typeIdentifier
        self.kindRaw = kind.rawValue
        self.byteSize = byteSize
        self.contentHash = contentHash
        self.storedFileName = storedFileName
        self.statusRaw = status.rawValue
        self.importedAt = importedAt
    }
}

/// Extracted text for one file content, extracted once and reused by every attachment of it.
@Model
final class FileExtractionRecord {
    @Attribute(.unique) var contentHash: String
    /// `[ExtractedChunk]` as JSON.
    @Attribute(.externalStorage) var chunksData: Data
    var pageCount: Int
    var method: String
    var characterCount: Int
    var note: String?
    var extractedAt: Date

    /// `chunksData` may be passed pre-encoded, so a large extraction is never encoded on the main actor.
    init(contentHash: String, chunks: [ExtractedChunk], chunksData: Data? = nil, pageCount: Int, method: String, note: String?, extractedAt: Date = .now) {
        self.contentHash = contentHash
        self.chunksData = chunksData ?? (try? JSONEncoder().encode(chunks)) ?? Data()
        self.pageCount = pageCount
        self.method = method
        self.characterCount = chunks.reduce(0) { $0 + $1.text.count }
        self.note = note
        self.extractedAt = extractedAt
    }

    var chunks: [ExtractedChunk] { (try? JSONDecoder().decode([ExtractedChunk].self, from: chunksData)) ?? [] }
}

// MARK: - Stored value shapes

struct StoredBlock: Codable, Equatable {
    let kind: String
    let text: String

    static func encode(_ blocks: [AnswerBlock]) -> Data {
        let stored = blocks.map { block -> StoredBlock in
            switch block {
            case .prose(let text): StoredBlock(kind: "prose", text: text)
            case .code(let text): StoredBlock(kind: "code", text: text)
            }
        }
        return (try? JSONEncoder().encode(stored)) ?? Data()
    }

    static func decode(_ data: Data) -> [AnswerBlock] {
        guard let stored = try? JSONDecoder().decode([StoredBlock].self, from: data) else { return [] }
        return stored.map { $0.kind == "code" ? .code($0.text) : .prose($0.text) }
    }
}

struct StoredFollowUp: Codable, Equatable {
    let likelihood: String
    let text: String
}

/// What an answer's request carried from the session's files, and what the model then cited.
///
/// **Included is not cited.** `included` is exactly the excerpts that travelled in the request.
/// `citedPassageIDs` is only what the backend reported the model cited — validated there against the
/// passages it was sent. An answer is never shown as having used a file merely because it was attached.
struct AnswerProvenance: Codable, Equatable, Sendable {
    struct Excerpt: Codable, Equatable, Sendable, Identifiable {
        let passageID: String
        let fileID: String
        /// Snapshotted, so the label survives the file being removed later.
        let filename: String
        let locator: String
        var id: String { passageID }
    }

    var included: [Excerpt] = []
    var citedPassageIDs: [String] = []
    /// Files that were still being read when the request was accepted, and so were not included.
    var filesStillProcessing: [String]? = nil

    var isEmpty: Bool { included.isEmpty && (filesStillProcessing ?? []).isEmpty }
    func isCited(_ excerpt: Excerpt) -> Bool { citedPassageIDs.contains(excerpt.passageID) }
}
