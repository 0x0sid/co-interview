import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Everything one interview screen needs from storage: its record, its files, its file context and,
/// for a live session, the recorder that saves it.
@MainActor
struct InterviewLaunch: Identifiable {
    let id = UUID()
    let mode: InterviewMode
    let session: InterviewSessionRecord
    let fileContext: SessionFileContext
    let files: SessionFiles
    /// Nil in Demo: a scripted interview is not saved to history.
    let recorder: SessionRecorder?
    /// Set when reopening a saved session.
    let restored: RestoredInterview?

    var language: InterviewLanguage { fileContext.language }

    /// A new live interview, saved from the first word.
    static func newLive(context: ModelContext, preference: InterviewLanguagePreference, store: FileStore = .standard) -> InterviewLaunch {
        let language = preference.resolved()
        let session = InterviewSessionStore.create(in: context, language: language, preference: preference)
        let fileContext = SessionFileContext(language: language)
        return InterviewLaunch(mode: .live, session: session, fileContext: fileContext,
                               files: SessionFiles(context: context, session: session, store: store, fileContext: fileContext),
                               recorder: SessionRecorder(session: session, context: context), restored: nil)
    }

    /// A saved interview, reopened in **its own** language, with its content and files — and with the
    /// microphone off until Resume interview is tapped.
    static func reopen(_ session: InterviewSessionRecord, context: ModelContext, store: FileStore = .standard) -> InterviewLaunch {
        let restored = InterviewSessionStore.restore(session)
        session.state = .open
        try? context.save()
        let fileContext = SessionFileContext(language: session.language)
        return InterviewLaunch(mode: .live, session: session, fileContext: fileContext,
                               files: SessionFiles(context: context, session: session, store: store, fileContext: fileContext),
                               recorder: SessionRecorder(session: session, context: context), restored: restored)
    }

    /// The scripted demo: files work, in memory only, and nothing is kept.
    static func demo() -> InterviewLaunch {
        let context = ModelContext(demoContainer)
        let session = InterviewSessionRecord(title: "Demo", mode: "demo", language: .english, preference: .english)
        context.insert(session)
        let fileContext = SessionFileContext(language: .english)
        let store = FileStore(root: URL.temporaryDirectory.appending(path: "NeverblankDemoFiles", directoryHint: .isDirectory))
        let files = SessionFiles(context: context, session: session, store: store, fileContext: fileContext)
        #if DEBUG
        // Screenshot support: two plainly synthetic text files, ready at once.
        if ProcessInfo.processInfo.arguments.contains("-InterviewSyntheticFiles") {
            files.importData(Data("Demo notes: Java 17 migration, virtual threads, records.\nTeam of six; release every two weeks.".utf8),
                             filename: "demo-notes.txt", type: .plainText)
            files.importData(Data("# Demo CV\nSenior backend engineer. Kotlin and Java since 2015.\nLed the payments platform rewrite.".utf8),
                             filename: "demo-cv.md", type: .init(filenameExtension: "md"))
        }
        #endif
        return InterviewLaunch(mode: .demo, session: session, fileContext: fileContext, files: files, recorder: nil, restored: nil)
    }

    private static let demoContainer: ModelContainer = {
        let schema = Schema(AppEnvironment.sessionModels)
        // Force-unwrapped on purpose: an in-memory container with this schema cannot fail at runtime
        // unless the schema itself is broken, which the unit tests would already have caught.
        return try! ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }()
}
