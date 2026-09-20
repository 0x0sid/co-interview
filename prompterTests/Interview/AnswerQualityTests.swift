import Testing
import Foundation
@testable import prompter

/// The answer-quality failures reported from the device, pinned as tests.
///
/// Five things came back wrong, and every one of them was decided *before* the provider was reached:
/// what context the request carried, and what it claimed the question was. That is what these cover.
/// Whether the resulting answer is any good is a question about a model, and no assertion here can
/// settle it — that is measured separately against the real provider and recorded in
/// `docs/evidence/`.
@MainActor
struct AnswerQualityTests {
    // MARK: - A live session carries no invented project

    /// Live ran on `SyntheticProjectFixture`: a fictional transport programme, with instructions
    /// telling the model to answer in the first person and prefer the fixture's figures. Every live
    /// answer was personalised to a person who does not exist.
    @Test
    func liveSessionContextHasNoInstructionsAndNoPassages() {
        let context = LiveSessionContext(language: .english)
        #expect(context.instructions.isEmpty, "a live session sent speaker instructions nobody wrote")
        #expect(context.passages(forQuestion: "Tell me about your experience", limit: 8).isEmpty,
                "a live session sent fabricated passages")
        #expect(context.projectID != SyntheticProjectFixture.transportProgramme.projectID)
    }

    /// The fixture itself is unchanged — it is still what Demo and the evaluation harness use. The
    /// fix was to stop *live* reaching for it, not to empty it out.
    @Test
    func theSampleProjectStillExistsForDemo() {
        #expect(!SyntheticProjectFixture.transportProgramme.instructions.isEmpty)
        #expect(SyntheticProjectFixture.transportProgramme.allPassages.count == 5)
    }

    // MARK: - Reconstructing the question from the discussion

    /// "In Java", spoken after a question that had already been answered, reached the model as a
    /// complete question on its own.
    @Test
    func aFragmentIsAttachedToTheQuestionItContinues() {
        let question = LiveInterviewFeed.questionFromDiscussion(DiscussionSnapshot(
            background: ["Could you tell me more about what's an Ash map and how to make it?"],
            newInput: ["In Java"]
        ))
        #expect(question.contains("Ash map"), "the fragment lost the question it belonged to")
        #expect(question.contains("In Java"))
    }

    /// The same, when the question it continues has *not* been answered yet and is still new input.
    @Test
    func aFragmentIsAttachedWithinNewInputToo() {
        let question = LiveInterviewFeed.questionFromDiscussion(DiscussionSnapshot(
            newInput: ["Could you tell me more about what's an Ash map and how to make it", "In Java"]
        ))
        #expect(question.contains("Ash map"))
        #expect(question.contains("In Java"))
    }

    /// "Of France", in a comparison already under way, narrows the question rather than starting one.
    @Test
    func aCorrectionKeepsTheComparisonItNarrows() {
        let question = LiveInterviewFeed.questionFromDiscussion(DiscussionSnapshot(
            background: ["So is it better to invest in France or in Indonesia right now?"],
            newInput: ["Of France"]
        ))
        #expect(question.contains("Indonesia"), "the correction was cut off from the comparison")
        #expect(question.contains("Of France"))
    }

    /// Background is context, never a question to answer again. Otherwise every tap re-answers the
    /// whole session, and page three repeats pages one and two.
    @Test
    func answeredQuestionsAreNotAskedAgain() {
        let question = LiveInterviewFeed.questionFromDiscussion(DiscussionSnapshot(
            background: [
                "How do I remove duplicates in Java?",
                "And what about performance?",
            ],
            newInput: ["What is a lambda in Java?"]
        ))
        #expect(question.contains("lambda"))
        #expect(!question.contains("duplicates"), "an already-answered question was asked again")
        #expect(!question.contains("performance"), "an already-answered question was asked again")
    }

    /// Several questions asked in one breath are still answered together.
    @Test
    func severalNewQuestionsTravelTogether() {
        let question = LiveInterviewFeed.questionFromDiscussion(DiscussionSnapshot(
            newInput: [
                "How do I remove duplicates in Java?",
                "And how do I preserve insertion order?",
            ]
        ))
        #expect(question.contains("duplicates"))
        #expect(question.contains("insertion order"))
    }

    /// A substantial imperative request is a question in its own right — it has no question mark and
    /// no interrogative opener, and must not be glued onto the line before it.
    @Test
    func aSubstantialRequestStandsOnItsOwn() {
        let question = LiveInterviewFeed.questionFromDiscussion(DiscussionSnapshot(
            background: ["Thanks, that's clear."],
            newInput: ["Walk me through how you would design a rate limiter for this service."]
        ))
        #expect(question.contains("rate limiter"))
        #expect(!question.contains("Thanks"), "a complete request was treated as a fragment")
    }

    /// With nothing new said, the tap is about the discussion itself — not about nothing.
    @Test
    func noNewInputFallsBackToTheDiscussion() {
        let question = LiveInterviewFeed.questionFromDiscussion(DiscussionSnapshot(
            background: ["We were discussing indexing strategies.", "Specifically partial indexes."]
        ))
        #expect(question.contains("partial indexes"))
    }

    // MARK: - The snapshot the screen takes

    /// The screen must hand the feed both halves: what is new, and what it follows on from.
    @Test
    func generateSendsAnsweredLinesAsBackgroundAndNewSpeechAsInput() throws {
        let (model, feed) = ManualGenerationTests.make()
        model.handle(.transcriptLine(TranscriptLine(text: "Could you tell me what an Ash map is?")))
        model.generate(now: Date(timeIntervalSince1970: 1_000))

        let first = try #require(feed.discussionRequests.first)
        #expect(first.discussion.background.isEmpty, "nothing had been answered yet")
        #expect(first.discussion.newInput.count == 1)

        // Answered. Now a fragment arrives and a second tap is made.
        Self.completeActiveRequest(model, feed)
        model.handle(.transcriptLine(TranscriptLine(text: "In Java")))
        model.generate(now: Date(timeIntervalSince1970: 1_100))

        let second = try #require(feed.discussionRequests.last)
        #expect(second.discussion.newInput == ["In Java"], "the second request did not isolate the new speech")
        #expect(second.discussion.background.contains { $0.contains("Ash map") },
                "the answered question was dropped, so the fragment had nothing to attach to")
    }

    static func completeActiveRequest(_ model: InterviewScreenModel, _ feed: ManualGenerationTests.RecordingFeed) {
        guard let request = feed.discussionRequests.last else { return }
        model.handle(.answerStarted(requestID: request.requestID, questionID: request.questionID))
        model.handle(.answerCompleted(requestID: request.requestID, blocks: [.prose("Done.")], highlight: nil))
    }

    // MARK: - Control markers never reach the reader

    /// The streamed answer used to be accumulated straight into a prose block, so the model's own
    /// fence markers sat in the text the user was reading until completion re-parsed them away.
    @Test
    func fenceMarkersNeverAppearInStreamedText() throws {
        let (model, feed) = ManualGenerationTests.make()
        model.handle(.transcriptLine(TranscriptLine(text: "Could you make a simple main in Java?")))
        model.generate(now: Date(timeIntervalSince1970: 1_000))
        let request = try #require(feed.discussionRequests.first)
        model.handle(.answerStarted(requestID: request.requestID, questionID: request.questionID))

        for chunk in ["Here is a minimal one.\n\n", "```java\n", "public class Main {\n", "}\n", "```"] {
            model.handle(.answerChunk(requestID: request.requestID, text: chunk))
            let visible = model.questions[0].answers.last?.proseText ?? ""
            #expect(!visible.contains("```"), "a fence marker was visible in the answer text")
        }

        // And the code arrived as a code card, not as prose.
        let answer = try #require(model.questions[0].answers.last)
        #expect(answer.codeBlocks.contains { $0.contains("public class Main") },
                "streamed code never became a code card")
    }

    /// Chunk joining must not corrupt code or double the spaces in prose.
    @Test
    func chunksJoinWithoutInventingOrLosingWhitespace() {
        #expect(InterviewScreenModel.joinedChunk("Use", "a HashMap") == "Use a HashMap")
        #expect(InterviewScreenModel.joinedChunk("Use ", "a HashMap") == "Use a HashMap")
        #expect(InterviewScreenModel.joinedChunk("Use", " a HashMap") == "Use a HashMap")
        #expect(InterviewScreenModel.joinedChunk("public class Main {\n", "    public static void main") ==
                "public class Main {\n    public static void main")
        #expect(InterviewScreenModel.joinedChunk("", "Start") == "Start")
    }

    // MARK: - Answer length

    /// Sized for speech, and counted excluding code.
    @Test
    func theAnswerTargetIsSpokenLength() {
        #expect(CopilotSessionCoordinator.targetMinimumWords == 40)
        #expect(CopilotSessionCoordinator.targetMaximumWords == 100)
    }

    // MARK: - Layout

    /// Expanding the transcript is not a request to open Context, and the answer keeps its room.
    @Test
    func contextStartsClosed() {
        let (model, _) = ManualGenerationTests.make()
        #expect(model.isTranscriptExpanded == false)
        #expect(model.isContextPanelOpen == false, "Context opened itself and took the answer's space")

        model.isTranscriptExpanded = true
        #expect(model.isContextPanelOpen == false, "expanding the transcript opened Context too")
    }
}
