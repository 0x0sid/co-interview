import Testing
import Foundation
@testable import prompter

/// The requests the **real** request builder produces for the topic-change scenarios, captured so the
/// same bytes can be replayed against the deployed answer path.
///
/// Speech goes into the real `CopilotSessionCoordinator` through a `LiveInterviewFeed` and the real
/// `InterviewScreenModel`; only the provider is a stub, and it only records. Each tap's `AnswerRequest`
/// is kept, and written as JSON when `CAPTURE_REQUESTS_DIR` is set (pass it as
/// `TEST_RUNNER_CAPTURE_REQUESTS_DIR` to `xcodebuild`) for `backend/eval/topic-replay.mjs`.
///
/// What is asserted here is what the **app** is responsible for: which speech is new, which is
/// context, and which page a chip targets. What the model then does with it is measured by the replay.
@MainActor
struct RequestReplayCaptureTests {
    private typealias Support = CopilotTestSupport

    /// One scripted step: speech to say, or a tap.
    enum Step {
        case say(String)
        case generate(answer: String)
        case selectPage(Int)
        case chip(String, onPage: Int, answer: String)
    }

    struct Captured {
        let label: String
        let request: AnswerRequest
    }

    private func run(_ steps: [Step]) async throws -> [Captured] {
        let provider = Support.StubProvider()
        provider.classifications = [DetectionResult(kind: .none, questionText: "", confidence: 0.9)]
        let coordinator = CopilotSessionCoordinator(
            project: LiveSessionContext(language: .english),
            provider: provider,
            audio: InterviewAudioInput(makeService: { FakeTranscriptionService(results: []) }),
            generationMode: .manual
        )
        let feed = LiveInterviewFeed(coordinator: coordinator)
        let model = InterviewScreenModel(mode: .live, feed: feed)
        model.start()

        var captured: [Captured] = []
        var clock: TimeInterval = 1
        var tapTime: TimeInterval = 0
        for step in steps {
            switch step {
            case .say(let text):
                clock += 3
                let before = model.transcript.count
                coordinator.ingest(Support.finalDelta(text, at: clock))
                try await Support.waitUntil("“\(text)” in the transcript") { model.transcript.count > before }
            case .generate(let answer):
                provider.answerChunks = [answer]
                let before = provider.generateCallCount
                tapTime += 10
                model.generate(now: Date(timeIntervalSince1970: 10_000 + tapTime))
                try await Support.waitUntil("the request") { provider.generateCallCount > before }
                captured.append(Captured(label: "generate", request: try #require(provider.lastAnswerRequest)))
                try await Support.waitUntil("the answer") { model.currentQuestion?.selectedAnswer?.isComplete == true }
            case .selectPage(let index):
                model.select(questionID: model.questions[index].id)
            case .chip(let id, let page, let answer):
                let parent = model.questions[page]
                model.select(questionID: parent.id)
                let action = try #require(model.followUpActions.first { $0.id == id }, "no \(id) chip on page \(page)")
                provider.answerChunks = [answer]
                let before = provider.generateCallCount
                tapTime += 10
                model.generate(action: action, for: parent, now: Date(timeIntervalSince1970: 10_000 + tapTime))
                try await Support.waitUntil("the chip request") { provider.generateCallCount > before }
                captured.append(Captured(label: "chip:\(id)", request: try #require(provider.lastAnswerRequest)))
            }
        }
        return captured
    }

    private func write(_ scenario: String, _ captured: [Captured]) throws {
        guard let dir = ProcessInfo.processInfo.environment["CAPTURE_REQUESTS_DIR"], !dir.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let items = try captured.map { item -> [String: Any] in
            let body = try JSONSerialization.jsonObject(with: encoder.encode(item.request))
            return ["label": item.label, "body": body]
        }
        let data = try JSONSerialization.data(withJSONObject: ["scenario": scenario, "requests": items], options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(scenario).json"))
    }

    private static let javaAnswer = "Java 7 added try-with-resources and the diamond operator. Java 8 brought lambdas and streams. Java 9 introduced modules and JShell."
    private static let angularAnswer = "AngularJS 1.x is a JavaScript MVC framework built on two-way binding and scopes. Angular 2 and later is a rewrite in TypeScript built on components and a new change-detection model."

    // MARK: - A. An explicit topic change after a Java answer

    @Test
    func aTopicChangeIsNewInputBehindTheOldTopic() async throws {
        let captured = try await run([
            .say("Could you compare Java 8 and Java 9?"), .say("And Java 7."),
            .generate(answer: Self.javaAnswer),
            .say("No, we're not talking about Java anymore."),
            .say("We're talking about Angular."),
            .say("What's the difference between Angular one, two and the latest version?"),
            .generate(answer: Self.angularAnswer),
        ])
        try write("A-topic-change", captured)
        let second = try #require(captured.last?.request)
        #expect(second.newInput == [
            "No, we're not talking about Java anymore.",
            "We're talking about Angular.",
            "What's the difference between Angular one, two and the latest version?",
        ])
        #expect(Array(second.recentConversation.prefix(2)) == ["Could you compare Java 8 and Java 9?", "And Java 7."])
    }

    /// The same, with the phone's actual recognised wording, including a Java fragment said **after**
    /// the Java answer — so it is still unanswered when Angular is asked.
    @Test
    func thePhoneTranscriptKeepsEveryLineInOrder() async throws {
        let later = [
            "And Java 10.",
            "Okay, and can you tell me more about the difference between Ongula one Oula 2 and the latest version of Angura?",
            "which one it is?",
            "And what about Angura?",
            "Could you tell me the difference between Aguila one Angular?",
            "I'mura 2 and I'm gonna free.",
            "The 3rd version, not free.",
            "No, we're not talking about Java anymore.",
            "We're talking about Angura GS.",
            "Angula.",
            "Angular.",
            "GS.",
            "What's the difference between angular one, 2 and the latt version?",
            "Please tell me more.",
        ]
        let captured = try await run(
            [.say("Could you compare Java 8 and Java 9?"), .say("And Java 7."), .generate(answer: Self.javaAnswer)]
                + later.map(Step.say) + [.generate(answer: Self.angularAnswer)]
        )
        try write("A-phone-transcript", captured)
        let second = try #require(captured.last?.request)
        #expect(second.newInput == later, "the request builder dropped or reordered speech")
    }

    /// The phone's session with the taps it most likely had: the Angular pages were 4/4 and 6/6, so
    /// Generate was pressed while the transcript still ended in half-recognised Angular speech, and
    /// "And Java 10." — said after the Java answer — was the first unanswered line each time.
    @Test
    func thePhoneSessionWithItsIntermediateTaps() async throws {
        let captured = try await run([
            .say("Could you compare Java 8 and Java 9?"), .say("And Java 7."),
            .generate(answer: Self.javaAnswer),
            .say("And Java 10."),
            .say("Okay, and can you tell me more about the difference between Ongula one Oula 2 and the latest version of Angura?"),
            .say("which one it is?"),
            .say("And what about Angura?"),
            .say("Could you tell me the difference between Aguila one Angular?"),
            .generate(answer: "Could you please clarify which Java versions you would like me to compare?"),
            .say("I'mura 2 and I'm gonna free."),
            .say("The 3rd version, not free."),
            .say("No, we're not talking about Java anymore."),
            .say("We're talking about Angura GS."),
            .say("Angula."), .say("Angular."), .say("GS."),
            .say("What's the difference between angular one, 2 and the latt version?"),
            .say("Please tell me more."),
            .generate(answer: Self.angularAnswer),
        ])
        try write("A-phone-intermediate-taps", captured)
        #expect(captured.count == 3)
        #expect(captured[1].request.newInput.first == "And Java 10.")
        #expect(captured[2].request.newInput.first == "I'mura 2 and I'm gonna free.")
    }

    // MARK: - B, C, D. Garbled names, a follow-up, a second topic change

    @Test
    func garbledFrameworkNamesThenAFollowUpThenANewTopic() async throws {
        let captured = try await run([
            .say("Angular GS version one"), .say("Iura JS version two"), .say("Angular JS"),
            .say("Version one and version two, what's the difference?"),
            .generate(answer: Self.angularAnswer),
            .say("And the latest version?"),
            .generate(answer: "Recent Angular releases add standalone components and signals."),
            .say("Let's switch topics. How does Kubernetes handle rolling updates?"),
            .generate(answer: "Kubernetes replaces pods gradually."),
        ])
        try write("BCD-garbled-followup-newtopic", captured)
        #expect(captured.count == 3)
        #expect(captured[1].request.newInput == ["And the latest version?"])
        #expect(captured[2].request.newInput == ["Let's switch topics. How does Kubernetes handle rolling updates?"])
        #expect(captured[2].request.recentConversation.count == 6, "earlier conversation was dropped")
    }

    // MARK: - E. Browsing an old page does not retarget ordinary Generate; a chip on it does

    @Test
    func browsingAnOldPageLeavesOrdinaryGenerateOnTheLatestSpeech() async throws {
        let captured = try await run([
            .say("Could you compare Java 8 and Java 9?"),
            .generate(answer: Self.javaAnswer),
            .say("What's the difference between Angular one and Angular two?"),
            .generate(answer: Self.angularAnswer),
            .selectPage(0),                                    // back to the Java page
            .say("And how does routing work in Angular?"),
            .generate(answer: "Angular routing maps URLs to components."),
            .chip("example", onPage: 0, answer: "For example, a lambda in Java 8."),
        ])
        try write("E-old-page-and-chip", captured)
        let ordinary = try #require(captured.first { $0.label == "generate" && $0.request.newInput.contains("And how does routing work in Angular?") })
        #expect(ordinary.request.requestedAction == nil)
        #expect(ordinary.request.actionParentQuestion == nil, "ordinary Generate was retargeted at the page on screen")
        let chip = try #require(captured.last)
        #expect(chip.label == "chip:example")
        #expect(chip.request.actionParentAnswer == Self.javaAnswer, "the chip did not target the Java page")
        #expect(chip.request.newInput.isEmpty, "the chip consumed pending speech")
    }
}
