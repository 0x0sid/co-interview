import Testing
import Foundation
@testable import prompter

/// Keyword emphasis and follow-up actions: what gets picked, and what deliberately does not.
///
/// All content is synthetic.
@MainActor
struct AnswerPresentationTests {
    // MARK: - Keywords

    private static func emphasised(_ text: String) -> [String] {
        AnswerKeywords.spans(in: text).map { span in
            let start = String.Index(utf16Offset: span.start, in: text)
            let end = String.Index(utf16Offset: span.end, in: text)
            return String(text[start..<end])
        }
    }

    /// The names a speaker must get exactly right are the ones emphasised.
    @Test
    func identifiersAcronymsAndVersionsAreEmphasised() {
        let words = Self.emphasised(
            "A HashMap stores key-value pairs. Java 8 added the Stream API, and JPMS arrived later."
        )
        #expect(words.contains("HashMap"))
        #expect(words.contains("Java 8"), "the version was not emphasised: \(words)")
        #expect(words.contains("JPMS"))
        // "Stream API" is the better span than "API" alone, so this asserts the acronym is covered
        // rather than that it stands by itself.
        #expect(words.contains { $0.contains("API") }, "the acronym was not emphasised: \(words)")
    }

    /// Ordinary prose is left alone. Emphasis only works while it is scarce.
    @Test
    func ordinaryProseIsNotEmphasised() {
        let words = Self.emphasised(
            "We bound the queue rather than the producer, so memory stays flat under load."
        )
        #expect(words.isEmpty, "plain prose was emphasised: \(words)")
    }

    /// A sentence opener is a capitalised word, not a keyword.
    @Test
    func aSentenceOpenerIsNotMistakenForAnIdentifier() {
        let words = Self.emphasised("Memory stays flat. Latency rises instead.")
        #expect(!words.contains("Memory"))
        #expect(!words.contains("Latency"))
    }

    /// Backticked code is emphasised without its backticks, so the span lands on the identifier.
    @Test
    func inlineCodeIsEmphasisedWithoutItsBackticks() {
        let text = "Call `queue.enqueue(batch)` and it suspends."
        let words = Self.emphasised(text)
        #expect(words.contains { $0.contains("queue.enqueue") })
        #expect(!words.contains { $0.contains("`") }, "the backticks were included in the span")
    }

    /// The longer, more specific span wins where two rules overlap.
    @Test
    func overlappingMatchesKeepTheLongerSpan() {
        let words = Self.emphasised("A ConcurrentHashMap is not a HashMap.")
        #expect(words.contains("ConcurrentHashMap"))
        // The nested "Hash"/"Map" shapes must not produce a second, overlapping span.
        let concurrent = words.filter { $0.contains("Concurrent") }
        #expect(concurrent.count == 1)
    }

    /// Spans never overlap and never run past the text, whatever the input.
    @Test
    func spansAreWellFormed() {
        let text = "HashMap, LinkedHashSet, TreeMap, JPMS, API, SQL, UDP, Java 8, Java 9, Java 17, 18 per cent, System.out."
        let spans = AnswerKeywords.spans(in: text)
        #expect(spans.count <= AnswerKeywords.maximumSpans, "the emphasis budget was exceeded")
        let utf16Count = text.utf16.count
        for span in spans {
            #expect(span.start >= 0 && span.end <= utf16Count, "a span ran outside the text")
            #expect(span.start < span.end)
        }
        for (a, b) in zip(spans, spans.dropFirst()) {
            #expect(a.end <= b.start, "two spans overlapped")
        }
    }

    @Test
    func emptyTextProducesNoSpans() {
        #expect(AnswerKeywords.spans(in: "").isEmpty)
    }

    // MARK: - Follow-up actions

    /// Code on screen means "explain the code" is worth offering.
    @Test
    func codeInTheAnswerOffersExplainingIt() {
        let actions = FollowUpActions.actions(
            question: "How do you bound a queue?",
            blocks: [.prose("We bound the queue."), .code("let queue = BoundedQueue(capacity: 512)")],
            language: .english
        )
        #expect(actions.contains { $0.id == "explain-code" })
    }

    /// With no code, that chip is not offered — it would refer to nothing.
    @Test
    func noCodeMeansNoExplainCodeAction() {
        let actions = FollowUpActions.actions(
            question: "What is a lambda?",
            blocks: [.prose("A lambda is an anonymous function.")],
            language: .english
        )
        #expect(!actions.contains { $0.id == "explain-code" })
    }

    /// An answer that already gives an example is not offered one.
    @Test
    func anAnswerThatAlreadyHasAnExampleIsNotOfferedOne() {
        let actions = FollowUpActions.actions(
            question: "What is a lambda?",
            blocks: [.prose("A lambda is an anonymous function. For example, a Runnable.")],
            language: .english
        )
        #expect(!actions.contains { $0.id == "example" })
    }

    /// Depth and brevity are opposites, so only one of them is ever offered.
    @Test
    func depthAndBrevityAreNeverOfferedTogether() {
        let shortAnswer = FollowUpActions.actions(
            question: "q", blocks: [.prose("Short answer.")], language: .english)
        #expect(shortAnswer.contains { $0.id == "deeper" })
        #expect(!shortAnswer.contains { $0.id == "shorter" })

        let longProse = String(repeating: "word ", count: FollowUpActions.longAnswerWords + 10)
        let longAnswer = FollowUpActions.actions(
            question: "q", blocks: [.prose(longProse)], language: .english)
        #expect(longAnswer.contains { $0.id == "shorter" })
        #expect(!longAnswer.contains { $0.id == "deeper" })
    }

    /// Never more chips than a person can take in without stopping.
    @Test
    func theNumberOfActionsIsBounded() {
        let longProse = String(repeating: "word ", count: FollowUpActions.longAnswerWords + 10)
        let actions = FollowUpActions.actions(
            question: "q",
            blocks: [.prose(longProse), .code("code()")],
            language: .english
        )
        #expect(actions.count <= FollowUpActions.maximumActions)
    }

    /// A French interview gets French chips and French instructions.
    @Test
    func aFrenchInterviewGetsFrenchActions() {
        let actions = FollowUpActions.actions(
            question: "Qu'est-ce qu'une lambda ?",
            blocks: [.prose("Une lambda est une fonction anonyme."), .code("() -> {}")],
            language: .french
        )
        #expect(actions.contains { $0.title == "Expliquer le code" })
        #expect(actions.allSatisfy { !$0.instruction.isEmpty })
        #expect(!actions.contains { $0.title == "Give an example" })
    }

    /// Emphasis is not only for code. The phrases an answer turns on are marked too.
    @Test
    func ordinaryImportantPhrasesAreEmphasised() {
        let quantities = Self.emphasised("A BoundedQueue of 512 items holds the batch for two years.")
        #expect(quantities.contains { $0.contains("512 items") }, "a quoted quantity was not emphasised: \(quantities)")

        let proper = Self.emphasised("On the Mill Street rollout we used Project Jigsaw.")
        #expect(proper.contains { $0.contains("Mill Street") }, "a named thing was not emphasised: \(proper)")

        let defined = Self.emphasised("That behaviour is called back pressure, and it is the whole point.")
        #expect(defined.contains { $0.contains("back pressure") }, "a defined term was not emphasised: \(defined)")

        let quoted = Self.emphasised("They asked about \u{201C}exactly once\u{201D} delivery.")
        #expect(quoted.contains { $0.contains("exactly once") }, "a quoted phrase was not emphasised: \(quoted)")
    }

    /// Emphasis changes appearance only. The text the reader-following engine aligns against must be
    /// byte-for-byte what it was, or the cursor would land on the wrong word.
    @Test
    func emphasisDoesNotAlterTheTextItStylesOrItsAlignment() {
        let text = "A BoundedQueue of 512 items keeps memory flat on the Mill Street rollout."
        let attributed = AnswerKeywords.emphasised(text)
        #expect(String(attributed.characters) == text, "emphasis changed the answer's characters")

        let plain = ScriptIndex.build(from: text)
        let styled = ScriptIndex.build(from: String(attributed.characters))
        #expect(plain.tokens.count == styled.tokens.count, "emphasis changed the token count")
        #expect(plain.tokens.map { $0.rangeStart } == styled.tokens.map { $0.rangeStart },
                "emphasis moved token boundaries")
    }

    // MARK: - What a tapped action sends

    private typealias H = ManualGenerationTests

    /// A tapped action produces a request carrying the instruction — and never touches the
    /// transcript, because nobody said it.
    @Test
    func aTappedActionTravelsAsARequestNotAsSpeech() throws {
        let (model, feed) = H.make()
        H.speak("What is a lambda in Java?", in: model)
        H.tap(model, at: 0)
        H.completeActiveRequest(model, feed)

        let action = FollowUpActions.Action(
            id: "example", title: "Give an example",
            instruction: "Give one concrete example of what you just explained.",
            systemImage: "lightbulb"
        )
        model.generate(action: action, now: Date(timeIntervalSince1970: 1_030))

        let discussion = try #require(feed.discussionRequests.last).discussion
        #expect(discussion.requestedAction == action.instruction)
        #expect(!discussion.allLines.contains { $0.contains("concrete example") },
                "the tapped action was written into the transcript")
        #expect(model.transcript.allSatisfy { !$0.text.contains("concrete example") },
                "the tapped action reached the transcript")
    }

    /// The chips work during silence — which is exactly when they are needed.
    ///
    /// An ordinary tap with nothing new said is refused as a duplicate. A tapped action is itself
    /// the new input, so it is not.
    @Test
    func aTappedActionWorksWhenNothingNewWasSaid() throws {
        let (model, feed) = H.make()
        H.speak("What is a lambda in Java?", in: model)
        H.tap(model, at: 0)
        H.completeActiveRequest(model, feed)

        // An ordinary tap here is refused.
        H.tap(model, at: 30)
        #expect(feed.discussionRequests.count == 1, "silence produced a duplicate request")

        let action = FollowUpActions.Action(
            id: "deeper", title: "Go deeper", instruction: "Go deeper on that answer.",
            systemImage: "arrow.down"
        )
        model.generate(action: action, now: Date(timeIntervalSince1970: 1_060))
        #expect(feed.discussionRequests.count == 2, "a tapped action was refused as a duplicate")
        #expect(try #require(feed.discussionRequests.last).discussion.requestedAction == action.instruction)
    }

    /// A tapped action still carries the whole conversation, like any other request.
    @Test
    func aTappedActionStillCarriesTheWholeConversation() throws {
        let (model, feed) = H.make()
        H.speak("Let's talk about the ingestion service.", in: model)
        H.speak("What is a lambda in Java?", in: model)
        H.tap(model, at: 0)
        H.completeActiveRequest(model, feed)

        model.generate(
            action: FollowUpActions.Action(id: "example", title: "t", instruction: "Give an example.", systemImage: "x"),
            now: Date(timeIntervalSince1970: 1_030)
        )
        let discussion = try #require(feed.discussionRequests.last).discussion
        #expect(discussion.allLines.count == 2, "the conversation was trimmed for an action request")
        #expect(discussion.allLines.contains { $0.contains("ingestion service") })
    }

    /// Actions are offered only for a finished answer on the page being read.
    @Test
    func actionsAppearOnlyForACompletedAnswer() throws {
        let (model, feed) = H.make()
        H.speak("What is a lambda in Java?", in: model)
        #expect(model.followUpActions.isEmpty, "actions were offered with no answer at all")

        H.tap(model, at: 0)
        let request = try #require(feed.discussionRequests.last)
        model.handle(.answerStarted(requestID: request.requestID, questionID: request.questionID))
        #expect(model.followUpActions.isEmpty, "actions were offered while the answer was still writing")

        model.handle(.answerCompleted(
            requestID: request.requestID,
            blocks: [.prose("A lambda is an anonymous function.")],
            highlight: nil
        ))
        #expect(!model.followUpActions.isEmpty, "a finished answer offered nothing to do next")
    }

    // MARK: - An action belongs to the page whose chip was tapped

    /// Tapping a chip on an older page targets *that* question and answer version.
    @Test
    func anActionTargetsThePageItsChipWasOn() throws {
        let (model, feed) = H.make()
        H.speak("What is a lambda in Java?", in: model)
        H.tap(model, at: 0)
        let first = try #require(feed.discussionRequests.last)
        model.handle(.answerStarted(requestID: first.requestID, questionID: first.questionID))
        model.handle(.answerTopicResolved(requestID: first.requestID, topic: "What a lambda is"))
        model.handle(.answerCompleted(requestID: first.requestID,
                                      blocks: [.prose("A lambda is an anonymous function.")], highlight: nil))

        // A second, more recent answer on its own page.
        H.speak("And what is a method reference?", in: model)
        H.tap(model, at: 30)
        let second = try #require(feed.discussionRequests.last)
        model.handle(.answerStarted(requestID: second.requestID, questionID: second.questionID))
        model.handle(.answerCompleted(requestID: second.requestID,
                                      blocks: [.prose("A method reference is shorthand.")], highlight: nil))

        // The reader browses back to the first page and taps its chip.
        let olderPage = try #require(model.questions.first { $0.id == first.questionID })
        let action = FollowUpActions.Action(id: "example", title: "Give an example",
                                            instruction: "Give one concrete example.", systemImage: "x")
        model.generate(action: action, for: olderPage, now: Date(timeIntervalSince1970: 1_060))

        let discussion = try #require(feed.discussionRequests.last).discussion
        #expect(discussion.requestedAction == action.instruction)
        #expect(discussion.actionParentQuestion == olderPage.text,
                "the action was aimed at a different question than the chip's page")
        #expect(discussion.actionParentAnswer?.contains("anonymous function") == true,
                "the action carried the wrong answer — it targeted the newest one")
        #expect(discussion.actionParentAnswer?.contains("method reference") != true)
        #expect(discussion.actionParentAnswerVersion == 1)
    }

    /// Speech arriving while the reader browses does not retarget the action, and is not consumed
    /// by it — it is still there for the next ordinary Generate.
    @Test
    func newSpeechDoesNotRedirectOrGetSwallowedByAnAction() throws {
        let (model, feed) = H.make()
        H.speak("What is a lambda in Java?", in: model)
        H.tap(model, at: 0)
        let first = try #require(feed.discussionRequests.last)
        model.handle(.answerStarted(requestID: first.requestID, questionID: first.questionID))
        model.handle(.answerCompleted(requestID: first.requestID,
                                      blocks: [.prose("A lambda is an anonymous function.")], highlight: nil))

        // The room keeps talking while the reader looks at that page.
        H.speak("Actually, tell me about your last project.", in: model)

        let olderPage = try #require(model.questions.first { $0.id == first.questionID })
        model.generate(
            action: FollowUpActions.Action(id: "deeper", title: "Go deeper",
                                           instruction: "Go deeper.", systemImage: "x"),
            for: olderPage,
            now: Date(timeIntervalSince1970: 1_030)
        )

        let actionRequest = try #require(feed.discussionRequests.last).discussion
        #expect(actionRequest.actionParentQuestion == olderPage.text)
        #expect(actionRequest.newLines.isEmpty,
                "the action claimed spoken words as the thing it was answering")
        #expect(actionRequest.allLines.contains { $0.contains("last project") },
                "the new speech was dropped from context entirely")

        // The new speech is still unanswered, so an ordinary Generate still picks it up.
        H.completeActiveRequest(model, feed)
        H.tap(model, at: 60)
        let afterwards = try #require(feed.discussionRequests.last).discussion
        #expect(afterwards.newLines.contains { $0.contains("last project") },
                "the action swallowed speech that nobody had answered")
    }

    /// Every action carries something to send. A chip that sends nothing is a dead control.
    @Test
    func everyActionCarriesAnInstruction() {
        for language in [InterviewLanguage.english, .french] {
            let actions = FollowUpActions.actions(
                question: "q", blocks: [.prose("Some answer."), .code("x")], language: language)
            #expect(!actions.isEmpty)
            for action in actions {
                #expect(!action.title.isEmpty)
                #expect(!action.instruction.isEmpty)
                #expect(!action.id.isEmpty)
            }
        }
    }
}
