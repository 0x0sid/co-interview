import Foundation
import SwiftData
import Testing
@testable import prompter

/// The interview language chosen in Settings is the language of every answer request, on every path,
/// and the same locale the transcriber uses. Driven through the real feed, coordinator and model.
@MainActor
struct AnswerLanguagePathTests {
    typealias Support = CopilotTestSupport

    final class RecordingTranscriber: Transcribing, @unchecked Sendable {
        let locales = LockedBox<[String]>([])
        func start(locale: Locale, contextualStrings: [String]) async throws -> AsyncStream<TranscriptDelta> {
            locales.mutate { $0.append(locale.identifier(.bcp47)) }
            return AsyncStream { _ in }
        }
        func stop() async {}
    }

    struct Session {
        let model: InterviewScreenModel
        let coordinator: CopilotSessionCoordinator
        let provider: CopilotTestSupport.StubProvider
        let transcriber: RecordingTranscriber
    }

    static func session(_ identifier: String, manualStreams: Bool = false) -> Session {
        let provider = CopilotTestSupport.StubProvider()
        provider.manualStreams = manualStreams
        let transcriber = RecordingTranscriber()
        let coordinator = CopilotSessionCoordinator(
            project: SessionFileContext(language: InterviewLanguage(identifier: identifier)),
            provider: provider,
            audio: InterviewAudioInput(makeService: { transcriber }),
            generationMode: .manual
        )
        let model = InterviewScreenModel(mode: .live, feed: LiveInterviewFeed(coordinator: coordinator))
        model.start()
        return Session(model: model, coordinator: coordinator, provider: provider, transcriber: transcriber)
    }

    static func say(_ text: String, at time: TimeInterval, in session: Session) async throws {
        session.coordinator.ingest(Support.finalDelta(text, at: time))
        try await Support.waitUntil("\"\(text)\" is on screen") { session.model.transcript.contains { $0.text == text } }
    }

    static func sent(_ session: Session, count: Int) async throws -> AnswerRequest {
        try await Support.waitUntil("request \(count) is sent") { session.provider.generateCallCount == count }
        return try #require(session.provider.lastAnswerRequest)
    }

    // MARK: Settings → session

    @Test
    func aNewInterviewSnapshotsThePersistedLanguage() throws {
        let context = ModelContext(try SessionTestSupport.container())
        let spanish = InterviewLanguage(identifier: "es-CL")
        let launch = InterviewLaunch.newLive(context: context, preference: .language(spanish),
                                             store: FileStore(root: SessionTestSupport.temporaryDirectory()))
        #expect(launch.fileContext.language == spanish)
        #expect(launch.session.language == spanish, "the saved interview records the language it used")
    }

    // MARK: Every path keeps the selected language

    @Test
    func everyGenerationPathSendsTheSelectedLanguage() async throws {
        let session = Self.session("es-CL")
        // Asked in English on purpose: the selection decides, not the speech.
        try await Self.say("Can you explain the Stream API in Java 8?", at: 1, in: session)

        session.model.generate(now: Date())                                            // normal Generate
        #expect(try await Self.sent(session, count: 1).answerLanguage == "es-CL")
        try await Support.waitUntil("answered") { session.model.questions.first?.selectedAnswer?.isComplete == true }
        let page = try #require(session.model.questions.first)

        session.model.regenerate()                                                     // Regenerate
        #expect(try await Self.sent(session, count: 2).answerLanguage == "es-CL")
        try await Support.waitUntil("regenerated") { !session.model.isGenerating(questionID: page.id) }

        session.model.generate(for: page)                                              // page-specific
        #expect(try await Self.sent(session, count: 3).answerLanguage == "es-CL")
        try await Support.waitUntil("page answered") { !session.model.isGenerating(questionID: page.id) }

        let shorter = FollowUpActions.Action(id: "shorter", title: "Shorter", instruction: "Make it shorter.", systemImage: "scissors")
        session.model.generate(action: shorter, for: page, now: Date().addingTimeInterval(10))   // follow-up action
        let followUp = try await Self.sent(session, count: 4)
        #expect(followUp.answerLanguage == "es-CL")
        #expect(followUp.requestedAction == "Make it shorter.")

        session.coordinator.askTyped("¿Qué es un HashMap?")                          // typed question
        let typed = try #require(session.coordinator.cards.last)
        session.coordinator.startGeneration(for: typed.id)
        #expect(try await Self.sent(session, count: 5).answerLanguage == "es-CL")
    }

    @Test
    func aQueuedRequestKeepsTheSelectedLanguage() async throws {
        let session = Self.session("es-CL", manualStreams: true)
        try await Self.say("¿Cuál es la diferencia entre Java 8 y Java 6?", at: 1, in: session)
        session.model.generate(now: Date())
        _ = try await Self.sent(session, count: 1)
        try await Self.say("And the Stream API?", at: 8, in: session)
        session.model.generate(now: Date().addingTimeInterval(5))                   // queued behind the first
        #expect(session.model.isQueued(questionID: try #require(session.model.questions.last?.id)))
        session.provider.push(.delta("Uno. "))
        session.provider.push(.completed(usageOutputTokens: nil))
        session.provider.finishStream()
        #expect(try await Self.sent(session, count: 2).answerLanguage == "es-CL")
    }

    @Test
    func aSavedQuestionRetryKeepsItsInterviewsLanguage() async throws {
        let provider = CopilotTestSupport.StubProvider()
        provider.generationError = CopilotProviderError.timedOut
        let coordinator = CopilotSessionCoordinator(
            project: SessionFileContext(language: InterviewLanguage(identifier: "es-CL")),
            provider: provider,
            audio: InterviewAudioInput(makeService: { RecordingTranscriber() }),
            generationMode: .manual
        )
        let saved = InterviewQuestion(text: "¿Por qué quieres unirte a esta empresa?")
        var restored = RestoredInterview()
        restored.transcript = [TranscriptLine(text: saved.text, isFinal: true)]
        restored.questions = [saved]
        let model = InterviewScreenModel(mode: .live, feed: LiveInterviewFeed(coordinator: coordinator), restored: restored)
        model.start()
        model.generate(for: saved)
        try await Support.waitUntil("the first attempt fails") { model.canRetry(questionID: saved.id) }
        #expect(provider.lastAnswerRequest?.answerLanguage == "es-CL")
        provider.generationError = nil
        model.retry(questionID: saved.id)
        try await Support.waitUntil("retried") { provider.generateCallCount == 2 }
        #expect(provider.lastAnswerRequest?.answerLanguage == "es-CL")
    }

    // MARK: One locale per session

    @Test(arguments: ["en-US", "fr-FR", "es-CL", "zh-TW"])
    func theTranscriberLocaleAndTheAnswerLanguageAreTheSame(_ identifier: String) async throws {
        let session = Self.session(identifier)
        try await Support.waitUntil("listening started") { !session.transcriber.locales.value.isEmpty }
        try await Self.say("Java 8 streams", at: 1, in: session)
        session.model.generate(now: Date())
        let request = try await Self.sent(session, count: 1)
        #expect(session.transcriber.locales.value == [identifier])
        #expect(request.answerLanguage == identifier, "speech in \(identifier), answer in \(request.answerLanguage ?? "nil")")
    }
}
