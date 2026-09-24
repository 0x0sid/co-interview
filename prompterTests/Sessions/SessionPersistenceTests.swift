import Foundation
import SwiftData
import Testing
@testable import prompter

/// Sessions are saved as they happen, survive the app stopping, and come back as they were —
/// without the microphone starting and without anything being sent again.
@MainActor
struct SessionPersistenceTests {
    private typealias H = ManualGenerationTests
    private typealias S = SessionTestSupport

    /// A session written by one "launch" and read by the next, through an on-disk store.
    @Test
    func terminationAndRelaunchRestoreTheSessionWithAPartialAnswerInterrupted() throws {
        let storeURL = S.temporaryDirectory().appending(path: "relaunch.store")
        var sessionID: UUID
        var questionID: UUID
        do {
            let container = try S.container(at: storeURL)
            let context = ModelContext(container)
            let session = InterviewSessionStore.create(in: context, language: .english, preference: .system)
            sessionID = session.id
            let recorder = SessionRecorder(session: session, context: context)
            let (model, feed) = H.make()
            recorder.attach(to: model)
            H.speak("Tell me about the payments platform.", in: model)
            model.context.note = "Led it in 2023"
            model.syncSessionNote()
            H.tap(model, at: 0)
            let request = try #require(feed.discussionRequests.last)
            questionID = request.questionID
            model.handle(.answerStarted(requestID: request.requestID, questionID: request.questionID))
            model.handle(.answerChunk(requestID: request.requestID, text: "We rebuilt the ledger first."))
            // The app is killed here: the last flush is the one the chunk's debounce would have made.
            recorder.flush()
        }

        let container = try S.container(at: storeURL)
        let context = ModelContext(container)
        #expect(InterviewSessionStore.markInterruptedSessions(in: context) == 1)
        let session = try #require(try context.fetch(FetchDescriptor<InterviewSessionRecord>()).first { $0.id == sessionID })
        #expect(session.state == .interrupted)

        let restored = InterviewSessionStore.restore(session)
        #expect(restored.transcript.map(\.text) == ["Tell me about the payments platform."])
        #expect(restored.note == "Led it in 2023")
        let question = try #require(restored.questions.first { $0.id == questionID })
        let answer = try #require(question.selectedAnswer)
        #expect(answer.proseText == "We rebuilt the ledger first.")
        #expect(answer.isInterrupted, "a partial answer was restored as if it had finished")
        #expect(restored.retainedSnapshots[questionID] != nil, "Retry would have nothing to send")
        #expect(restored.coveredLines.isEmpty == false, "restored speech would be treated as new")
    }

    /// Reopening shows the content and does nothing else: no listening, no request. Retry sends one.
    @Test
    func aRestoredPartialAnswerIsNotResentAndRetrySendsItOnce() throws {
        let container = try S.container()
        let context = ModelContext(container)
        let session = InterviewSessionStore.create(in: context, language: .english, preference: .system)
        let recorder = SessionRecorder(session: session, context: context)
        let (model, feed) = H.make()
        recorder.attach(to: model)
        H.speak("How do you handle retries?", in: model)
        H.tap(model, at: 0)
        let request = try #require(feed.discussionRequests.last)
        model.handle(.answerStarted(requestID: request.requestID, questionID: request.questionID))
        model.handle(.answerChunk(requestID: request.requestID, text: "Idempotency keys."))
        recorder.flush()
        InterviewSessionStore.markInterruptedSessions(in: context)

        let reopened = H.RecordingFeed()
        let restoredModel = InterviewScreenModel(mode: .live, feed: reopened, restored: InterviewSessionStore.restore(session))
        restoredModel.start()
        #expect(restoredModel.isAwaitingResume)
        #expect(restoredModel.recording == .off, "the microphone mark claimed listening")
        #expect(reopened.discussionRequests.isEmpty && reopened.questionRequests.isEmpty, "a request was re-sent on reopen")
        #expect(restoredModel.hasNewInputToAnswer == false, "restored speech became new input")

        let questionID = request.questionID
        #expect(restoredModel.canRetry(questionID: questionID))
        restoredModel.retry(questionID: questionID)
        #expect(reopened.discussionRequests.count == 1, "Retry did not send exactly one request")
        #expect(reopened.discussionRequests.first?.discussion.allLines == ["How do you handle retries?"])
        restoredModel.stop()
    }

    /// A revision rewrites one row; a streamed addition rewrites one row.
    @Test
    func savesAreIncremental() throws {
        let container = try S.container()
        let context = ModelContext(container)
        let session = InterviewSessionStore.create(in: context, language: .english, preference: .system)
        let recorder = SessionRecorder(session: session, context: context)
        let (model, feed) = H.make()
        recorder.attach(to: model)
        for index in 0..<30 { H.speak("Line number \(index) of the interview.", in: model) }
        H.tap(model, at: 0)
        let request = try #require(feed.discussionRequests.last)
        model.handle(.answerStarted(requestID: request.requestID, questionID: request.questionID))
        recorder.flush()
        #expect(recorder.lastWriteCount == 0, "a flush with nothing new wrote rows")

        var revised = model.transcript[12]
        revised.text = "Line number twelve, corrected."
        revised.revision += 1
        model.handle(.transcriptLine(revised))
        recorder.flush()
        #expect(recorder.lastWriteCount == 1, "a single revision rewrote \(recorder.lastWriteCount) rows")

        model.handle(.answerChunk(requestID: request.requestID, text: "Streaming text."))
        recorder.flush()
        #expect(recorder.lastWriteCount == 1, "a streamed chunk rewrote \(recorder.lastWriteCount) rows")
        #expect(session.utterances.count == 30)
    }

    /// Noisy changes are coalesced; transitions are not.
    @Test
    func transcriptUpdatesAreDebouncedAndTransitionsAreImmediate() async throws {
        let container = try S.container()
        let context = ModelContext(container)
        let session = InterviewSessionStore.create(in: context, language: .english, preference: .system)
        let recorder = SessionRecorder(session: session, context: context, debounce: .milliseconds(120))
        let (model, _) = H.make()
        recorder.attach(to: model)
        for index in 0..<25 { H.speak("Partial \(index)", in: model, final: false) }
        #expect(recorder.flushCount == 0, "transcript updates were written one by one")
        try await CopilotTestSupport.waitUntil("the debounced save") { recorder.flushCount > 0 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.flushCount == 1, "the debounce did not coalesce (\(recorder.flushCount) flushes)")

        H.tap(model, at: 0)
        #expect(recorder.flushCount == 2, "an accepted request was not saved at once")
    }

    /// Adding the session tables to an existing store keeps every row it had.
    @Test
    func anExistingStoreOpensWithTheNewSchemaAndKeepsItsRows() throws {
        let url = S.temporaryDirectory().appending(path: "old.store")
        do {
            let oldSchema = Schema([Script.self, PromptSession.self, UsageLedger.self, AppSettings.self])
            let old = try ModelContainer(for: oldSchema, configurations: [ModelConfiguration(schema: oldSchema, url: url)])
            let context = ModelContext(old)
            context.insert(AppSettings(fontScale: 1.3, appearanceRaw: "dark"))
            try context.save()
        }
        let upgraded = try S.container(at: url)
        let settings = try #require(try ModelContext(upgraded).fetch(FetchDescriptor<AppSettings>()).first)
        #expect(settings.fontScale == 1.3)
        #expect(settings.appearanceRaw == "dark")
        #expect(settings.interviewLanguageRaw == "system")
    }

    /// Upgrades a **copy** of a real device store (opt-in: `TEST_RUNNER_COINTERVIEW_REAL_STORE=<dir>` holding
    /// CoInterview.store and its -wal/-shm). Every existing row survives; nothing is reset.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COINTERVIEW_REAL_STORE"] != nil))
    func aRealDeviceStoreUpgradesWithEveryRowIntact() throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["COINTERVIEW_REAL_STORE"]!)
        func copy() throws -> URL {
            let folder = S.temporaryDirectory()
            for suffix in ["", "-wal", "-shm"] {
                let from = source.appending(path: "CoInterview.store" + suffix)
                if FileManager.default.fileExists(atPath: from.path) {
                    try FileManager.default.copyItem(at: from, to: folder.appending(path: "CoInterview.store" + suffix))
                }
            }
            return folder.appending(path: "CoInterview.store")
        }
        func counts(_ context: ModelContext) throws -> [Int] {
            [try context.fetchCount(FetchDescriptor<Script>()), try context.fetchCount(FetchDescriptor<PromptSession>()),
             try context.fetchCount(FetchDescriptor<UsageLedger>()), try context.fetchCount(FetchDescriptor<AppSettings>())]
        }
        let oldSchema = Schema([Script.self, PromptSession.self, UsageLedger.self, AppSettings.self])
        let before = try counts(ModelContext(try ModelContainer(for: oldSchema, configurations: [ModelConfiguration(schema: oldSchema, url: try copy())])))
        let upgraded = ModelContext(try S.container(at: try copy()))
        let after = try counts(upgraded)
        print("REAL STORE rows before \(before) after \(after)")
        #expect(before == after, "rows changed in the upgrade")
        #expect(try upgraded.fetchCount(FetchDescriptor<InterviewSessionRecord>()) == 0)
    }

    @Test
    func renameAndDelete() throws {
        let container = try S.container()
        let context = ModelContext(container)
        let session = InterviewSessionStore.create(in: context, language: .french, preference: .french)
        InterviewSessionStore.rename(session, to: "  Acme — final round ", in: context)
        #expect(session.title == "Acme — final round")
        #expect(session.isTitleCustom)
        #expect(InterviewSessionStore.history(in: context).count == 1)
        InterviewSessionStore.delete(session, in: context, store: FileStore(root: S.temporaryDirectory()))
        #expect(InterviewSessionStore.history(in: context).isEmpty)
    }

    // MARK: Language

    @Test
    func systemLanguageResolvesAndExplainsItsFallback() {
        let french = InterviewLanguagePreference.resolveSystem(preferredLanguages: ["fr-FR", "en-GB"])
        #expect(french.language == .french && french.fallbackNote == nil)

        let japanese = InterviewLanguagePreference.resolveSystem(preferredLanguages: ["ja-JP", "fr-CA"])
        #expect(japanese.language == .french, "a supported second language was skipped")
        #expect(japanese.fallbackNote?.contains("Français") == true)

        let unsupported = InterviewLanguagePreference.resolveSystem(preferredLanguages: ["de-DE"])
        #expect(unsupported.language == .english)
        #expect(unsupported.fallbackNote != nil, "a fallback happened silently")
        #expect(InterviewLanguagePreference.system.label(preferredLanguages: ["en-US"]) == "System language (English)")
    }

    /// An old session opens in the language it used, whatever the preference is now.
    @Test
    func aSavedSessionKeepsItsLanguage() throws {
        let container = try S.container()
        let context = ModelContext(container)
        let session = InterviewSessionStore.create(in: context, language: .french, preference: .system)
        let settings = AppSettings.fetchOrCreate(in: context)
        settings.interviewLanguageRaw = InterviewLanguagePreference.english.rawValue
        let launch = InterviewLaunch.reopen(session, context: context, store: FileStore(root: S.temporaryDirectory()))
        #expect(launch.language == .french)
        #expect(launch.session.languagePreferenceRaw == "system")
    }

    /// Changing language mid-interview keeps every line and answer, translates nothing, and the next
    /// request is in the new language.
    @Test
    func changingLanguageMidInterviewPreservesHistory() async throws {
        let provider = CopilotTestSupport.StubProvider()
        provider.classifications = [DetectionResult(kind: .none, questionText: "", confidence: 0.9)]
        let fileContext = SessionFileContext(language: .english)
        let coordinator = CopilotSessionCoordinator(
            project: fileContext, provider: provider,
            audio: InterviewAudioInput(makeService: { FakeTranscriptionService(results: []) }),
            generationMode: .manual)
        let model = InterviewScreenModel(mode: .live, feed: LiveInterviewFeed(coordinator: coordinator))
        model.start()
        coordinator.ingest(CopilotTestSupport.finalDelta("Tell me about your last project.", at: 1))
        try await CopilotTestSupport.waitUntil("the line", timeout: .seconds(15)) { !model.transcript.isEmpty }
        model.generate(now: Date(timeIntervalSince1970: 1_000))
        try await CopilotTestSupport.waitUntil("the answer", timeout: .seconds(15)) { model.questions.last?.selectedAnswer?.isComplete == true }
        let before = (model.transcript, model.questions.map(\.selectedAnswer?.proseText))
        #expect(provider.lastAnswerRequest?.language == "en")

        model.changeLanguage(.french)
        #expect(model.transcript == before.0, "the transcript changed")
        #expect(model.questions.map(\.selectedAnswer?.proseText) == before.1, "an answer changed")
        #expect(model.liveLanguage == .french)

        coordinator.ingest(CopilotTestSupport.finalDelta("Et votre rôle exact ?", at: 5))
        try await CopilotTestSupport.waitUntil("the second line", timeout: .seconds(15)) { model.transcript.count == 2 }
        model.generate(now: Date(timeIntervalSince1970: 1_010))
        try await CopilotTestSupport.waitUntil("the second request", timeout: .seconds(15)) { provider.generateCallCount == 2 }
        #expect(provider.lastAnswerRequest?.language == "fr")
        model.stop()
    }
}
