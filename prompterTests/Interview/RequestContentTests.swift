import Testing
import Foundation
@testable import prompter

/// What actually leaves the device when Generate is tapped.
///
/// These exist because the previous bug was invisible from every other angle. The transcript on
/// screen was complete, the session was healthy, the request succeeded — and the model was answering
/// a two-word fragment, because the request had been reduced to one before it was sent. Asserting on
/// the answer would not have caught it; asserting on the request does.
///
/// The reproduction throughout is the reported one:
///
///     "Could you explain the difference between Java and Java 8?"
///     "And Java 9."
///     "And Java 7."
///     [Generate]
///
/// All content is synthetic.
@MainActor
struct RequestContentTests {
    private typealias H = ManualGenerationTests

    private static func lastDiscussion(_ feed: H.RecordingFeed) throws -> DiscussionSnapshot {
        try #require(feed.discussionRequests.last).discussion
    }

    // MARK: - The reported reproduction

    /// Every fragment of the comparison reaches the request, in order.
    ///
    /// This is the case that failed. "And Java 9." and "And Java 7." are not interrogative, so the
    /// old local heuristic kept only the first line and the other two versions never left the phone.
    @Test
    func allJavaFragmentsTravelTogether() throws {
        let (model, feed) = H.make()
        H.speak("Could you explain the difference between Java and Java 8?", in: model)
        H.speak("And Java 9.", in: model)
        H.speak("And Java 7.", in: model)
        H.tap(model, at: 0)

        let discussion = try Self.lastDiscussion(feed)
        #expect(discussion.newLines.count == 3, "a fragment of the comparison was dropped")
        #expect(discussion.newLines.contains { $0.contains("Java 8") })
        #expect(discussion.newLines.contains { $0.contains("Java 9") })
        #expect(discussion.newLines.contains { $0.contains("Java 7") })
        #expect(discussion.newLines == discussion.allLines, "nothing was answered before this tap")
    }

    /// The same, when the opening question was answered by an earlier tap.
    ///
    /// The subject then lives in the background half. It must still be sent: without it "And Java 9.
    /// And Java 7." names no subject at all, which is exactly what the model was being given.
    @Test
    func theSubjectSurvivesWhenTheOpeningQuestionWasAlreadyAnswered() throws {
        let (model, feed) = H.make()
        H.speak("Could you explain the difference between Java and Java 8?", in: model)
        H.tap(model, at: 0)
        H.completeActiveRequest(model, feed)
        H.speak("And Java 9.", in: model)
        H.speak("And Java 7.", in: model)
        H.tap(model, at: 30)

        let discussion = try Self.lastDiscussion(feed)
        #expect(discussion.newLines == ["And Java 9.", "And Java 7."])
        #expect(discussion.background.contains { $0.contains("Java 8") },
                "the comparison's subject never left the device")
        #expect(discussion.allLines.count == 3)
    }

    // MARK: - Nothing is silently dropped for length

    /// A fact stated far more than twelve lines ago still reaches the request.
    ///
    /// There were two independent twelve-line cuts, one on the device and one in the backend. A
    /// session only has to run a couple of minutes to pass twelve lines.
    @Test
    func anImportantFactFromLongBeforeTheWindowStillTravels() throws {
        let (model, feed) = H.make()
        H.speak("My most recent project was the Mill Street rollout.", in: model)
        for index in 1...30 { H.speak("Filler line number \(index).", in: model) }
        H.speak("Which project did I just mention?", in: model)
        H.tap(model, at: 0)

        let discussion = try Self.lastDiscussion(feed)
        #expect(discussion.allLines.contains { $0.contains("Mill Street") },
                "the fact the question is about was dropped before sending")
        #expect(discussion.allLines.count == 32, "the transcript was trimmed on its way into the request")
    }

    // MARK: - The utterance still being spoken

    /// The in-progress line travels, marked provisional, and exactly once.
    @Test
    func theCurrentPartialUtteranceIsIncludedOnce() throws {
        let (model, feed) = H.make()
        H.speak("So, about persistence.", in: model)
        H.speak("What would you use for caching", in: model, final: false)
        H.tap(model, at: 0)

        let discussion = try Self.lastDiscussion(feed)
        #expect(discussion.provisional == "What would you use for caching")
        #expect(!discussion.newInput.contains("What would you use for caching"),
                "the provisional line was also counted as settled speech")
        #expect(discussion.allLines.filter { $0.contains("caching") }.count == 1,
                "the in-progress utterance was sent twice")
    }

    /// Finalizing that utterance does not turn it into a second line.
    ///
    /// The recogniser revises an open utterance in place under a stable id; a snapshot taken after
    /// finalization must therefore contain one copy of the sentence, not the partial and the final.
    @Test
    func finalizingThePartialDoesNotDuplicateIt() throws {
        let (model, feed) = H.make()
        let id = UUID()
        model.handle(.transcriptLine(TranscriptLine(id: id, text: "What would you use for cach", isFinal: false)))
        model.handle(.transcriptLine(TranscriptLine(id: id, text: "What would you use for caching?", isFinal: true)))
        H.tap(model, at: 0)

        let discussion = try Self.lastDiscussion(feed)
        #expect(discussion.provisional == nil)
        #expect(discussion.allLines == ["What would you use for caching?"],
                "a partial and its finalized copy were both sent")
    }

    // MARK: - The interface cannot change the request

    /// Collapsing or expanding the transcript strip changes nothing about what is sent.
    ///
    /// The strip shows a couple of lines; the request is the session. They were never the same list,
    /// and this pins that they cannot become the same list by accident.
    @Test
    func collapsingTheTranscriptDoesNotChangeTheRequest() throws {
        let (expandedModel, expandedFeed) = H.make()
        let (collapsedModel, collapsedFeed) = H.make()
        for model in [expandedModel, collapsedModel] {
            H.speak("Let's talk about the ingestion service.", in: model)
            H.speak("How did you handle retries?", in: model)
            H.speak("And idempotency.", in: model)
        }
        expandedModel.isTranscriptExpanded = true
        expandedModel.isContextPanelOpen = true
        collapsedModel.isTranscriptExpanded = false
        collapsedModel.isContextPanelOpen = false
        H.tap(expandedModel, at: 0)
        H.tap(collapsedModel, at: 0)

        #expect(try Self.lastDiscussion(expandedFeed).allLines == Self.lastDiscussion(collapsedFeed).allLines)
        #expect(try Self.lastDiscussion(expandedFeed).newLines == Self.lastDiscussion(collapsedFeed).newLines)
    }

    // MARK: - Context the speaker added

    /// The typed note and prepared attachments travel with the request.
    @Test
    func theSessionNoteTravelsWithTheRequest() throws {
        let (model, feed) = H.make()
        H.speak("What would you improve about the design?", in: model)
        model.context.note = "Focus on Java 17"
        model.syncSessionNote()
        H.tap(model, at: 0)

        #expect(try Self.lastDiscussion(feed).note == "Focus on Java 17")
    }

    // MARK: - Earlier suggestions are available, and labelled

    /// A previous answer is carried as context for a follow-up that refers to it.
    ///
    /// "Give me an example" needs the thing it is an example *of*, and after one tap that thing is
    /// often only in the answer, not in anything the speaker said.
    @Test
    func previousSuggestionsAreCarriedForAFollowUp() throws {
        let (model, feed) = H.make()
        H.speak("What is a lambda in Java?", in: model)
        H.tap(model, at: 0)
        guard let first = feed.discussionRequests.last else { return }
        model.handle(.answerStarted(requestID: first.requestID, questionID: first.questionID))
        model.handle(.answerCompleted(
            requestID: first.requestID,
            blocks: [.prose("A lambda is an anonymous function you can pass around.")],
            highlight: nil
        ))
        H.speak("Give me an example.", in: model)
        H.tap(model, at: 30)

        let discussion = try Self.lastDiscussion(feed)
        #expect(discussion.newLines == ["Give me an example."])
        #expect(discussion.priorSuggestions.contains { $0.contains("anonymous function") },
                "the follow-up lost the suggestion it refers to")
    }

    // MARK: - Duplicate prevention still holds

    /// Silence and an unchanged transcript still produce no second request.
    ///
    /// Sending the whole session must not weaken this: "already answered" means do not *request* it
    /// again, and it is a separate idea from what the request carries as context.
    @Test
    func repeatedTapsWithNothingNewMakeNoSecondRequest() throws {
        let (model, feed) = H.make()
        H.speak("How would you scale the writer?", in: model)
        H.tap(model, at: 0)
        H.completeActiveRequest(model, feed)
        H.tap(model, at: 30)
        H.tap(model, at: 60)

        #expect(feed.discussionRequests.count == 1, "silence produced a duplicate request")
    }

    /// New speech after the snapshot is still eligible for the next tap.
    @Test
    func speechAfterTheSnapshotIsEligibleNextTime() throws {
        let (model, feed) = H.make()
        H.speak("How would you scale the writer?", in: model)
        H.tap(model, at: 0)
        H.speak("And the reader?", in: model)
        H.completeActiveRequest(model, feed)
        H.tap(model, at: 30)

        #expect(feed.discussionRequests.count == 2)
        #expect(try Self.lastDiscussion(feed).newLines == ["And the reader?"])
        #expect(try Self.lastDiscussion(feed).background.contains { $0.contains("scale the writer") })
    }
}
