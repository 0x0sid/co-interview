import Foundation
import SwiftUI
import Testing
@testable import prompter

/// The answer's closed format — lead, "- " points, `==anchor==` — parsed the way a stream delivers
/// it: the whole text so far is re-parsed on every chunk (`InterviewScreenModel.appendChunk`), so
/// every prefix of an answer has to look right, not only the finished one.
@MainActor
struct AnswerStructureTests {
    /// The shown paragraphs after each chunk: the text so far re-parsed, as `appendChunk` does. The
    /// chunks are raw slices (a live stream's), so they are concatenated as they are and can split a
    /// marker or a word anywhere.
    static func stream(_ chunks: [String]) -> [[AnswerStructure.Prose]] {
        var text = ""
        return chunks.map { chunk in
            text += chunk
            return AnswerStructure.prose(of: AnswerBlock.parsed(from: text))
        }
    }

    static func emphasised(_ prose: AnswerStructure.Prose) -> [String] {
        prose.emphasis.map { (prose.text as NSString).substring(with: $0) }
    }

    static func assertNoSyntaxShows(_ states: [[AnswerStructure.Prose]], sourceLocation: SourceLocation = #_sourceLocation) {
        for state in states {
            for prose in state {
                #expect(!prose.text.contains("=="), "a marker is visible: \(prose.text)", sourceLocation: sourceLocation)
                #expect(!prose.text.hasSuffix("="), "half a marker is visible: \(prose.text)", sourceLocation: sourceLocation)
                #expect(!prose.text.hasPrefix("- ") && prose.text != "-", "a bullet prefix is visible: \(prose.text)", sourceLocation: sourceLocation)
            }
        }
    }

    static let javaPython = """
    Java and Python are both general-purpose languages, but they trade ==type safety== for speed of writing.

    - Java is statically typed and ==runs on the JVM==, which catches many errors before runtime.
    - Python is dynamically typed and interpreted, so it is quicker to write.
    - Example: I'd pick Java for a large backend service and Python for data pipelines.
    """

    // MARK: Streaming

    @Test
    func anIncompleteOpeningMarkerRendersAsPlainText() {
        let states = Self.stream(["Java is =", "=statically"])
        #expect(states[0].map(\.text) == ["Java is"], "a lone '=' at the end may be half a marker")
        #expect(states[1].map(\.text) == ["Java is statically"])
        #expect(states[1][0].emphasis.isEmpty, "not highlighted until it closes")
        Self.assertNoSyntaxShows(states)
    }

    @Test
    func anIncompleteClosingMarkerKeepsThePhrasePlainThenHighlightsWithoutMovingText() {
        let states = Self.stream(["Java is ==statically typed=", "=, so errors show early."])
        #expect(states[0][0].text == "Java is statically typed")
        #expect(states[0][0].emphasis.isEmpty)
        #expect(states[1][0].text == "Java is statically typed, so errors show early.")
        #expect(Self.emphasised(states[1][0]) == ["statically typed"])
        // The highlighted phrase sits at the same offsets it had while it was still plain.
        #expect(states[1][0].emphasis.first?.location == ("Java is " as NSString).length)
        Self.assertNoSyntaxShows(states)
    }

    /// `=`, then `=important`, then the closing `==`: the words never move, only the highlight appears.
    @Test
    func aMarkerArrivingOneEqualsSignAtATime() {
        let states = Self.stream(["Remember the ", "=", "=important", "=", "=", " point."])
        #expect(states.map { $0[0].text } == ["Remember the", "Remember the", "Remember the important",
                                              "Remember the important", "Remember the important",
                                              "Remember the important point."])
        #expect(states.map { $0[0].emphasis.count } == [0, 0, 0, 0, 1, 1])
        #expect(Self.emphasised(states[5][0]) == ["important"])
        Self.assertNoSyntaxShows(states)
    }

    @Test
    func aHighlightSpanningChunksAppearsOnlyWhenClosed() {
        let states = Self.stream(["Kafka keeps an ==ordered ", "log== that consumers replay."])
        #expect(states[0][0].text == "Kafka keeps an ordered" && states[0][0].emphasis.isEmpty)
        #expect(Self.emphasised(states[1][0]) == ["ordered log"])
        Self.assertNoSyntaxShows(states)
    }

    @Test
    func aBulletPrefixSplitAcrossChunksIsABulletFromItsFirstWord() {
        let states = Self.stream(["Two differences matter.", "\n-", " Java is compiled."])
        #expect(states[1].map(\.text) == ["Two differences matter."], "a lone '-' shows nothing")
        #expect(states[2].map(\.role) == [.lead, .bullet])
        #expect(states[2][1].text == "Java is compiled.")
        Self.assertNoSyntaxShows(states)
    }

    @Test
    func multipleBulletsStreamAsSeparatePoints() {
        let states = Self.stream(["Lead sentence.\n- First point", " goes on.\n- Second", " point.\n- Third point."])
        let final = states.last!
        #expect(final.map(\.role) == [.lead, .bullet, .bullet, .bullet])
        #expect(final.map(\.text) == ["Lead sentence.", "First point goes on.", "Second point.", "Third point."])
        Self.assertNoSyntaxShows(states)
    }

    /// Character by character, the shown text only ever grows: nothing appears and then vanishes,
    /// and no marker or prefix is ever on screen.
    @Test
    func everyPrefixOfAStructuredAnswerOnlyGrows() {
        let final = AnswerStructure.spokenText(of: AnswerBlock.parsed(from: Self.javaPython))
        var states: [[AnswerStructure.Prose]] = []
        var text = ""
        for character in Self.javaPython {
            text.append(character)
            let prose = AnswerStructure.prose(of: AnswerBlock.parsed(from: text))
            states.append(prose)
            let spoken = prose.map(\.text).joined(separator: "\n\n")
            #expect(final.hasPrefix(spoken), "shown text was retracted at: \(text.suffix(20))")
        }
        Self.assertNoSyntaxShows(states)
    }

    // MARK: Malformed and restraint

    @Test
    func anUnclosedMarkerIsHiddenAndNothingIsHighlighted() {
        let prose = AnswerStructure.prose(of: [.prose("Java is ==statically typed and Python is not.")])
        #expect(prose[0].text == "Java is statically typed and Python is not.")
        #expect(prose[0].emphasis.isEmpty)
    }

    @Test
    func aComparisonWithSpacesIsLiteralText() {
        let prose = AnswerStructure.prose(of: [.prose("It holds when x == y and y == z.")])
        #expect(prose[0].text == "It holds when x == y and y == z.")
        #expect(prose[0].emphasis.isEmpty)
    }

    @Test
    func moreThanFourHighlightsAreCappedAtFourFirstComeFirstKept() {
        let blocks = AnswerBlock.parsed(from: """
        ==One== and ==two== matter.
        - ==Three== here, ==four== here.
        - And ==five==.
        """)
        let prose = AnswerStructure.prose(of: blocks)
        #expect(prose.flatMap(Self.emphasised) == ["One", "two", "Three", "four"])
        #expect(prose.map(\.text) == ["One and two matter.", "Three here, four here.", "And five."])
    }

    @Test
    func aWholePointASentenceOrALongPhraseIsNotHighlighted() {
        let prose = AnswerStructure.prose(of: AnswerBlock.parsed(from: """
        Lead with ==a phrase that runs on and on for far too many words to count== here.
        - ==Java is statically typed.==
        - It is ==fast. Python is== flexible.
        """))
        #expect(prose.allSatisfy { $0.emphasis.isEmpty })
        #expect(prose[1].text == "Java is statically typed.")
    }

    /// The lead's highlight is the answer itself, so it may run to a short clause.
    @Test
    func theLeadHighlightCarriesTheAnswer() {
        let prose = AnswerStructure.prose(of: AnswerBlock.parsed(from: """
        ==Lambdas, the Stream API and default methods== arrived in Java 8.
        - ==Default methods== let interfaces evolve.
        """))
        #expect(prose.flatMap(Self.emphasised) == ["Lambdas, the Stream API and default methods", "Default methods"])
    }

    @Test
    func codeContainingEqualsSignsIsNeverHighlighted() {
        let blocks = AnswerBlock.parsed(from: """
        Compare values with `a==b==c` in the ==guard clause==.

        ```java
        if (a == b && ==c==) { return; }
        ```
        """)
        #expect(blocks.contains(.code("if (a == b && ==c==) { return; }")), "code is kept verbatim")
        let prose = AnswerStructure.prose(of: blocks)
        #expect(prose.count == 1)
        #expect(prose[0].text == "Compare values with `a==b==c` in the guard clause.")
        #expect(Self.emphasised(prose[0]) == ["guard clause"])
    }

    // MARK: Old answers, persistence, speech

    @Test
    func anOldPlainAnswerIsUnchanged() {
        let plain = "Kafka keeps an ordered log. Consumers replay it from any offset, which RabbitMQ does not do."
        let answer = InterviewAnswer(version: 1, blocks: [.prose(plain), .prose("Second paragraph.")], isComplete: true)
        #expect(!AnswerStructure.isStructured(answer.blocks))
        #expect(answer.proseText == plain + "\n\nSecond paragraph.")
        #expect(AnswerStructure.prose(of: answer.blocks).map(\.role) == [.lead, .body])
        #expect(AnswerStructure.prose(of: answer.blocks).allSatisfy { $0.emphasis.isEmpty })
    }

    @Test
    func theSavedSourceReopensWithTheSamePointsAndHighlights() {
        let blocks = AnswerBlock.parsed(from: Self.javaPython)
        let reopened = StoredBlock.decode(StoredBlock.encode(blocks))
        #expect(reopened == blocks, "the stored source keeps the prefix and markers")
        #expect(AnswerStructure.prose(of: reopened) == AnswerStructure.prose(of: blocks))
        #expect(blocks.contains(.prose("- Java is statically typed and ==runs on the JVM==, which catches many errors before runtime.")))
    }

    @Test
    func speechGetsCleanTextWithNoMarkers() {
        let answer = InterviewAnswer(version: 1, blocks: AnswerBlock.parsed(from: Self.javaPython), isComplete: true)
        let spoken = answer.proseText
        #expect(!spoken.contains("=="))
        #expect(!spoken.split(separator: "\n").contains { $0.hasPrefix("- ") })
        #expect(spoken.hasPrefix("Java and Python are both general-purpose languages, but they trade type safety"))
        let alignment = ReadingAlignment(text: spoken)
        let tokens = alignment.scriptIndex.tokens.map { (spoken as NSString).substring(with: NSRange(location: $0.rangeStart, length: $0.rangeEnd - $0.rangeStart)) }
        #expect(!tokens.contains { $0.contains("=") || $0 == "-" })
        #expect(Set(alignment.scriptIndex.sentences.map(\.paragraphIndex)).count == 4, "the lead and three points")
    }

    // MARK: Languages

    @Test
    func frenchHighlightedPhrase() {
        let prose = AnswerStructure.prose(of: AnswerBlock.parsed(from: """
        Java est ==typé statiquement==, alors que Python est dynamique.
        - Python est plus rapide à écrire, surtout pour les ==scripts==.
        """))
        #expect(prose.map(\.text) == ["Java est typé statiquement, alors que Python est dynamique.",
                                      "Python est plus rapide à écrire, surtout pour les scripts."])
        #expect(prose.flatMap(Self.emphasised) == ["typé statiquement", "scripts"])
    }

    @Test
    func traditionalChineseHighlightedPhrase() {
        let states = Self.stream(["Java 是==靜態", "型別==語言，Python 是動態型別。\n- Python 更適合==資料處理==。"])
        #expect(states[0][0].text == "Java 是靜態" && states[0][0].emphasis.isEmpty)
        let final = states.last!
        #expect(final.map(\.text) == ["Java 是靜態型別語言，Python 是動態型別。", "Python 更適合資料處理。"])
        #expect(final.flatMap(Self.emphasised) == ["靜態型別", "資料處理"])
        Self.assertNoSyntaxShows(states)
    }

    // MARK: Rendering

    /// The highlight is drawn behind laid-out text, so closing a marker cannot rewrap anything: the
    /// paragraph measures the same plain, while the marker is open, and highlighted.
    @Test
    func closingAHighlightDoesNotChangeTheLayout() throws {
        func size(_ raw: String) throws -> CGSize {
            let prose = try #require(AnswerStructure.prose(of: [.prose(raw)]).first)
            var attributed = AttributedString(prose.text)
            AnswerStructure.mark(&attributed, ranges: prose.emphasis, in: prose.text)
            let view = AnswerStructure.text(attributed)
                .font(InterviewTheme.Font.answer())
                .lineSpacing(InterviewTheme.Metric.answerLineSpacing)
                .textRenderer(AnswerHighlightRenderer(color: .green, outline: false))
                .frame(width: 280, alignment: .leading)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            return try #require(renderer.uiImage?.size)
        }
        let open = try size("Java is ==statically typed and compiled to bytecode that runs on the JVM")
        let closed = try size("Java is ==statically typed== and compiled to bytecode that runs on the JVM")
        let plain = try size("Java is statically typed and compiled to bytecode that runs on the JVM")
        #expect(open == closed && closed == plain)
    }
}

/// The same format through the screen model: streamed, finished, regenerated, followed up, and
/// reopened — and what speech-following is given at each step.
@MainActor
struct StructuredAnswerFlowTests {
    typealias Support = ManualGenerationTests
    static let structured = """
    Kafka keeps an ==ordered log==, RabbitMQ routes messages to queues.

    - Kafka consumers replay from any offset.
    - RabbitMQ deletes a message once it is acknowledged.
    """

    /// Streams `text` the way the live feed does: 7-character model deltas go through the real
    /// `StreamingAnswerAssembler`, and only the growth of its committed text reaches the model
    /// (`LiveInterviewFeed`). Then it finishes with `AnswerBlock.parsed` of the whole text.
    static func deliver(_ text: String, _ model: InterviewScreenModel, _ feed: Support.RecordingFeed,
                        checkEachStep: (InterviewAnswer) -> Void = { _ in }) throws {
        let active = try #require(feed.discussionRequests.last)
        model.handle(.answerStarted(requestID: active.requestID, questionID: active.questionID))
        var assembler = StreamingAnswerAssembler()
        var emitted = 0
        func emit() {
            let visible = assembler.committedText
            guard visible.count > emitted else { return }
            let addition = String(visible.dropFirst(emitted))
            emitted = visible.count
            model.handle(.answerChunk(requestID: active.requestID, text: addition))
            if let answer = model.questions.first(where: { $0.id == active.questionID })?.selectedAnswer {
                checkEachStep(answer)
            }
        }
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 7, limitedBy: text.endIndex) ?? text.endIndex
            assembler.append(String(text[index..<end]))
            emit()
            index = end
        }
        assembler.finish()
        emit()
        model.handle(.answerCompleted(requestID: active.requestID, blocks: AnswerBlock.parsed(from: assembler.committedText), highlight: nil))
    }

    static func assertClean(_ answer: InterviewAnswer, sourceLocation: SourceLocation = #_sourceLocation) {
        let spoken = answer.proseText
        #expect(!spoken.contains("=="), sourceLocation: sourceLocation)
        #expect(!spoken.split(separator: "\n").contains { $0.hasPrefix("- ") || $0 == "-" }, sourceLocation: sourceLocation)
    }

    @Test
    func streamingIsStructuredFromTheFirstWordAndSpeechNeverSeesMarkers() throws {
        let (model, feed) = Support.make()
        Support.speak("What is the difference between Kafka and RabbitMQ?", in: model)
        Support.tap(model, at: 0)
        try Self.deliver(Self.structured, model, feed) { answer in
            #expect(answer.usesStructuredPresentation, "no legacy-to-structured flip mid-stream")
            Self.assertClean(answer)
        }
        let page = try #require(model.questions.first)
        let answer = try #require(page.selectedAnswer)
        #expect(answer.isComplete && answer.usesStructuredPresentation)
        let alignment = try #require(model.alignment(for: page))
        #expect(alignment.text == "Kafka keeps an ordered log, RabbitMQ routes messages to queues.\n\nKafka consumers replay from any offset.\n\nRabbitMQ deletes a message once it is acknowledged.")
        #expect(AnswerStructure.prose(of: answer.blocks).map(\.role) == [.lead, .bullet, .bullet])
    }

    @Test
    func regenerateAndFollowUpsKeepTheStructure() throws {
        let (model, feed) = Support.make()
        model.accessGate = FakeGate(allows: true)
        Support.speak("What is the difference between Kafka and RabbitMQ?", in: model)
        Support.tap(model, at: 0)
        try Self.deliver(Self.structured, model, feed)

        model.regenerate()
        try Self.deliver(Self.structured.replacingOccurrences(of: "ordered log", with: "append-only log"), model, feed) {
            #expect($0.usesStructuredPresentation); Self.assertClean($0)
        }
        var answer = try #require(model.questions.first?.selectedAnswer)
        #expect(answer.version == 2 && answer.usesStructuredPresentation)
        #expect(AnswerStructure.prose(of: answer.blocks).flatMap { p in p.emphasis.map { (p.text as NSString).substring(with: $0) } } == ["append-only log"])

        let page = try #require(model.questions.first)
        model.generate(action: QuotaIdentityTests.shorter, for: page, now: Date().addingTimeInterval(20))
        try Self.deliver("Kafka keeps a ==replayable log==.\n- RabbitMQ forgets acknowledged messages.", model, feed) {
            #expect($0.usesStructuredPresentation); Self.assertClean($0)
        }
        answer = try #require(model.questions.last?.selectedAnswer)
        #expect(answer.usesStructuredPresentation)
        #expect(AnswerStructure.prose(of: answer.blocks).map(\.role) == [.lead, .bullet])
    }

    @Test
    func aStructuredSavedAnswerReopensStructuredAndAPlainOneReopensLegacy() throws {
        let structured = InterviewAnswer(version: 1, blocks: StoredBlock.decode(StoredBlock.encode(AnswerBlock.parsed(from: Self.structured))), isComplete: true)
        #expect(structured.usesStructuredPresentation)
        #expect(AnswerStructure.prose(of: structured.blocks) == AnswerStructure.prose(of: AnswerBlock.parsed(from: Self.structured)))
        Self.assertClean(structured)

        let plain = InterviewAnswer(version: 1, blocks: StoredBlock.decode(StoredBlock.encode([.prose("Kafka keeps an ordered log. RabbitMQ routes to queues.")])), isComplete: true)
        #expect(!plain.usesStructuredPresentation, "an old saved answer keeps its old rendering")
        #expect(plain.proseText == "Kafka keeps an ordered log. RabbitMQ routes to queues.")
    }

    @Test
    func codeFencesAreUnchangedAndStayOutOfSpeech() {
        let text = """
        Use a ==guard clause== to return early.

        ```swift
        guard a == b else { return }
        - not a bullet
        ```

        - It keeps the happy path unindented.
        """
        let blocks = AnswerBlock.parsed(from: text)
        #expect(blocks == [.prose("Use a ==guard clause== to return early."),
                           .code("guard a == b else { return }\n- not a bullet"),
                           .prose("- It keeps the happy path unindented.")])
        let answer = InterviewAnswer(version: 1, blocks: blocks, isComplete: true)
        #expect(answer.proseText == "Use a guard clause to return early.\n\nIt keeps the happy path unindented.")
    }
}
