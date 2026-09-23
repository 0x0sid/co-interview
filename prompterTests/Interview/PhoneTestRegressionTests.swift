import Testing
import Foundation
@testable import prompter

/// Regressions from the 2026-09-24 phone test: the typed note, the scope of a compound request, the
/// recovery offered when an answer asks for something, and inline code in the answer.
///
/// These pin down **what the app sends and shows**. Whether the model then uses it well is measured
/// separately, against the real provider (`backend/eval/phone-regressions.mjs`). All content here is
/// synthetic.
@MainActor
struct PhoneTestRegressionTests {
    private typealias H = ManualGenerationTests
    private typealias Support = CopilotTestSupport

    // MARK: - The note

    /// The note is typed — every keystroke goes through the field's change handler, keyboard still
    /// up — and Generate is tapped straight away. The snapshot must carry the note as typed.
    @Test
    func aNoteTypedWithTheKeyboardOpenTravelsWithTheNextGenerate() throws {
        let (model, feed) = H.make()
        H.speak("Could you tell me your secret, in fact?", in: model)
        // Exactly what `InterviewScreen` wires to the field: one call per edit, no commit step.
        for prefix in ["S", "Secret:", "Secret: I love", "Secret: I love pizza"] {
            model.context.note = prefix
            model.syncSessionNote()
        }

        H.tap(model, at: 0)

        let request = try #require(feed.discussionRequests.last)
        #expect(request.discussion.note == "Secret: I love pizza")
        #expect(request.discussion.newInput == ["Could you tell me your secret, in fact?"])
    }

    /// The request built from a tap carries the note **of that tap**. The coordinator used to read
    /// its live `sessionNote` instead, so a request queued behind another picked up an edit made
    /// after it was accepted.
    @Test
    func theRequestCarriesTheSnapshotsNoteNotTheLiveOne() async throws {
        let provider = Support.StubProvider()
        let (coordinator, _, _) = Support.makeCoordinator(provider: provider)
        coordinator.sessionNote = "Secret: edited later"

        coordinator.beginDiscussionAnswer(discussion: DiscussionSnapshot(
            newInput: ["Could you tell me your secret?"],
            note: "Secret: I love pizza"
        ))
        try await Support.waitUntil("the answer request") { provider.lastAnswerRequest != nil }

        #expect(provider.lastAnswerRequest?.extraContext == "Secret: I love pizza")
    }

    /// A note edited between two Generates: the first answer is left exactly as it was, nothing is
    /// regenerated on its own, and the next tap carries the new note.
    @Test
    func aNoteEditedBetweenGenerationsReachesOnlyTheNextOne() throws {
        let (model, feed) = H.make()
        H.speak("Could you tell me your secret?", in: model)
        model.context.note = "Secret: I love pizza"
        H.tap(model, at: 0)
        H.completeActiveRequest(model, feed)
        let firstAnswer = try #require(model.questions.first?.selectedAnswer)

        model.context.note = "Secret: I love pizza and chess"
        #expect(feed.discussionRequests.count == 1, "editing the note sent a request on its own")

        H.tap(model, at: 5)

        #expect(feed.discussionRequests.count == 2)
        #expect(feed.discussionRequests[0].discussion.note == "Secret: I love pizza")
        #expect(feed.discussionRequests[1].discussion.note == "Secret: I love pizza and chess")
        #expect(model.questions.first?.answers.first == firstAnswer, "the earlier answer changed")
    }

    // MARK: - Scope of a compound request

    private static let java = [
        "Could you compare Java 8 and Java 9?",
        "And Java 7.",
        "Could you compare Java 9 and Java 8 and Java 7?",
        "Java 10.",
    ]

    /// Everything before one tap is one request: nothing is dropped from it, in order.
    @Test
    func oneTapCarriesTheWholeCompoundRequest() throws {
        let (model, feed) = H.make()
        Self.java.forEach { H.speak($0, in: model) }
        H.tap(model, at: 0)

        let request = try #require(feed.discussionRequests.last)
        #expect(request.discussion.newInput == Self.java)
        #expect(request.discussion.background.isEmpty)
    }

    /// Tap after "And Java 7.", then again after "Java 10.": the second request's new input is the
    /// two later lines, and the first two travel with it as context — the comparison they set up is
    /// still there to be extended.
    @Test
    func aSecondTapKeepsTheComparisonItExtends() throws {
        let (model, feed) = H.make()
        H.speak(Self.java[0], in: model)
        H.speak(Self.java[1], in: model)
        H.tap(model, at: 0)
        H.completeActiveRequest(model, feed)
        let firstAnswer = model.questions.first?.selectedAnswer

        H.speak(Self.java[2], in: model)
        H.speak(Self.java[3], in: model)
        H.tap(model, at: 5)

        let second = try #require(feed.discussionRequests.last)
        #expect(second.discussion.background == Array(Self.java[0...1]))
        #expect(second.discussion.newInput == Array(Self.java[2...3]))
        #expect(second.discussion.allLines == Self.java, "the request lost part of the conversation")
        #expect(model.questions.first?.selectedAnswer == firstAnswer, "the earlier answer changed")
    }

    /// A fragment arriving after the previous tap: it is the new input, and the whole comparison it
    /// refers to travels as context.
    @Test
    func aFragmentAfterTheTapCarriesItsAntecedents() throws {
        let (model, feed) = H.make()
        Self.java.prefix(3).forEach { H.speak($0, in: model) }
        H.tap(model, at: 0)
        H.completeActiveRequest(model, feed)

        H.speak("Java 10.", in: model)
        H.tap(model, at: 5)

        let second = try #require(feed.discussionRequests.last)
        #expect(second.discussion.newInput == ["Java 10."])
        #expect(second.discussion.background == Array(Self.java.prefix(3)))
    }

    /// An explicit narrowing is sent as spoken, after what it narrows — the words that remove the
    /// other versions are in the request, and the versions they remove are there to be removed.
    @Test
    func anExplicitNarrowingTravelsWithWhatItNarrows() throws {
        let (model, feed) = H.make()
        Self.java.prefix(3).forEach { H.speak($0, in: model) }
        H.tap(model, at: 0)
        H.completeActiveRequest(model, feed)

        H.speak("Actually, only Java 8 and Java 10.", in: model)
        H.tap(model, at: 5)

        let second = try #require(feed.discussionRequests.last)
        #expect(second.discussion.newInput == ["Actually, only Java 8 and Java 10."])
        #expect(second.discussion.background == Array(Self.java.prefix(3)))
    }

    /// Still being recognised at the tap: the unfinished line travels as provisional, never dropped.
    @Test
    func aLineStillBeingRecognisedTravelsAsProvisional() throws {
        let (model, feed) = H.make()
        Self.java.prefix(3).forEach { H.speak($0, in: model) }
        H.speak("Java 10", in: model, final: false)
        H.tap(model, at: 0)

        let request = try #require(feed.discussionRequests.last)
        #expect(request.discussion.provisional == "Java 10")
        #expect(request.discussion.newLines == Array(Self.java.prefix(3)) + ["Java 10"])
    }

    // MARK: - Recovery instead of elaboration

    @Test
    func anAnswerThatAsksForContextOffersOnlyAddContext() {
        let actions = FollowUpActions.actions(
            question: "Speaker's secret",
            blocks: [.prose("Add your secret to the session note and I'll answer this.")],
            need: .context,
            language: .english
        )
        #expect(actions.map(\.id) == ["add-context"])
        #expect(actions.first?.kind == .addContext)
    }

    @Test
    func anOrdinaryAnswerKeepsItsFollowUps() {
        let actions = FollowUpActions.actions(
            question: "What a lambda is",
            blocks: [.prose("A lambda is an anonymous function you can pass around as a value.")],
            language: .english
        )
        #expect(actions.map(\.id).contains("example"))
        #expect(actions.allSatisfy { $0.kind == .request })
    }

    /// The model's report can arrive before the answer exists; it must still land on that answer.
    /// Tapping "Add context" then opens the note and sends nothing — pending speech stays pending.
    @Test
    func addContextOpensTheNoteAndSendsNothing() throws {
        let (model, feed) = H.make()
        H.speak("Could you tell me your secret?", in: model)
        H.tap(model, at: 0)
        let request = try #require(feed.discussionRequests.last)
        model.handle(.answerNeedsInput(requestID: request.requestID, need: .context))
        model.handle(.answerStarted(requestID: request.requestID, questionID: request.questionID))
        model.handle(.answerCompleted(requestID: request.requestID,
                                      blocks: [.prose("Add your secret to the session note.")], highlight: nil))
        #expect(model.questions.first?.selectedAnswer?.need == .context)
        let addContext = try #require(model.followUpActions.first)
        #expect(addContext.kind == .addContext)

        H.speak("And what about your hobbies?", in: model)
        let focusBefore = model.noteFocusRequest
        model.generate(action: addContext, for: model.questions.first, now: Date(timeIntervalSince1970: 2_000))

        #expect(feed.discussionRequests.count == 1, "Add context sent a request")
        #expect(model.noteFocusRequest == focusBefore + 1)
        #expect(model.isTranscriptExpanded && model.isContextPanelOpen)
        #expect(model.uncoveredLines.map(\.text) == ["And what about your hobbies?"], "pending speech was consumed")
    }

    // MARK: - Inline code

    @Test
    func inlineCodeIsShownWithoutBackticksAndKeepsItsEmphasis() {
        let text = "Java 10 added `var` for local variables."
        let shown = AnswerKeywords.emphasised(text, font: InterviewTheme.Font.answer(weight: .semibold))
        #expect(String(shown.characters) == "Java 10 added var for local variables.")
        let bold = shown.runs.filter { $0.font != nil }.map { String(shown.characters[$0.range]) }
        #expect(bold.contains("var"), "the inline code lost its emphasis")
    }

    /// The reader follows the original text; hiding the markers must not change a single spoken token.
    @Test
    func hidingInlineCodeMarkersLeavesSpeechTokensUnchanged() {
        let original = "Use `var` or `final var` for local variables."
        let displayed = "Use var or final var for local variables."
        #expect(Tokenizer.normalize(original) == Tokenizer.normalize(displayed))
    }
}
