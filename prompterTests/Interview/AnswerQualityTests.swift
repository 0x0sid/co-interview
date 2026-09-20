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

    // MARK: - What the request carries

    // These replace a set of tests that asserted a *local* heuristic which turned the discussion
    // into one question string. That heuristic is gone: it dropped "and Java 9" / "and Java 7" from
    // a comparison because neither is interrogative, and once the opening question had been answered
    // it sent "And Java 9. And Java 7." with no subject at all. Deciding what is being asked needs
    // the whole conversation, so the client now sends the parts and the model resolves the request.
    // What can be asserted here — and what actually protects the fix — is that nothing is lost on
    // the way out.

    /// A fragment travels **with** the thing it continues, across the answered/new boundary.
    @Test
    func aFragmentKeepsTheQuestionItContinues() {
        let (model, feed) = ManualGenerationTests.make()
        ManualGenerationTests.speak("Could you tell me more about what's an Ash map and how to make it?", in: model)
        ManualGenerationTests.tap(model, at: 0)
        ManualGenerationTests.completeActiveRequest(model, feed)
        ManualGenerationTests.speak("In Java", in: model)
        ManualGenerationTests.tap(model, at: 30)

        let discussion = try! #require(feed.discussionRequests.last).discussion
        #expect(discussion.newLines == ["In Java"], "the fragment must be what is asked about")
        #expect(discussion.background.contains { $0.contains("Ash map") },
                "the fragment lost the question it belonged to")
        #expect(discussion.allLines.count == 2)
    }

    /// Background is context, never a question to request again — but it is still *sent*.
    @Test
    func answeredQuestionsStayAsContextWithoutBeingAskedAgain() {
        let (model, feed) = ManualGenerationTests.make()
        ManualGenerationTests.speak("How do I remove duplicates in Java?", in: model)
        ManualGenerationTests.tap(model, at: 0)
        ManualGenerationTests.completeActiveRequest(model, feed)
        ManualGenerationTests.speak("What is a lambda in Java?", in: model)
        ManualGenerationTests.tap(model, at: 30)

        let discussion = try! #require(feed.discussionRequests.last).discussion
        #expect(discussion.newLines == ["What is a lambda in Java?"])
        #expect(!discussion.newLines.contains { $0.contains("duplicates") },
                "an already-answered question was asked again")
        #expect(discussion.allLines.contains { $0.contains("duplicates") },
                "an already-answered question was deleted from the conversation")
    }

    /// Several questions asked in one breath travel together as one request.
    @Test
    func severalNewQuestionsTravelTogether() {
        let (model, feed) = ManualGenerationTests.make()
        ManualGenerationTests.speak("How do I remove duplicates in Java?", in: model)
        ManualGenerationTests.speak("And how do I preserve insertion order?", in: model)
        ManualGenerationTests.tap(model, at: 0)

        let discussion = try! #require(feed.discussionRequests.last).discussion
        #expect(discussion.newLines.count == 2)
        #expect(discussion.newLines.contains { $0.contains("duplicates") })
        #expect(discussion.newLines.contains { $0.contains("insertion order") })
    }

    /// With nothing new said, the tap is still about the discussion — not about nothing.
    @Test
    func noNewInputStillSendsTheDiscussion() {
        let (model, feed) = ManualGenerationTests.make()
        ManualGenerationTests.speak("We were discussing indexing strategies.", in: model)
        ManualGenerationTests.speak("Specifically partial indexes.", in: model)
        ManualGenerationTests.tap(model, at: 0)
        ManualGenerationTests.completeActiveRequest(model, feed)
        // Nothing new; only the note changed, which is what makes a second tap eligible at all.
        model.context.note = "focus on Postgres"
        model.syncSessionNote()
        ManualGenerationTests.tap(model, at: 30)

        let discussion = try! #require(feed.discussionRequests.last).discussion
        #expect(discussion.allLines.contains { $0.contains("partial indexes") })
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
