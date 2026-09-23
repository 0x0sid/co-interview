import Testing
import Foundation
@testable import prompter

/// The state rules around focused decisions (pipeline §18). Deterministic: a stub decides, a gate
/// holds it in flight, and nothing waits on a real clock. What Jev actually decides is measured
/// separately, against the real service (`backend/eval/decision-dialogues.mjs`).
@MainActor
struct RequestDecisionTests {
    private typealias H = ManualGenerationTests

    /// A decision service the test controls: it records every snapshot and answers only when released.
    final class StubDecider: @unchecked Sendable {
        private let lock = NSLock()
        private var _snapshots: [DecisionSnapshot] = []
        private var pending: [CheckedContinuation<DecisionOutcome, Error>] = []
        var outcome = DecisionOutcome(mode: "shadow", apply: false, eligible: true,
                                      interpretation: RequestInterpretation(relation: "continuation", parentWords: "Compare Java 8 and 9", parentStatus: "answered"))

        var snapshots: [DecisionSnapshot] { lock.withLock { _snapshots } }
        var waiting: Int { lock.withLock { pending.count } }

        func decide(_ snapshot: DecisionSnapshot) async throws -> DecisionOutcome {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    _snapshots.append(snapshot)
                    pending.append(continuation)
                }
            }
        }

        /// Answers the oldest waiting call.
        func release(_ outcome: DecisionOutcome? = nil) {
            let next: CheckedContinuation<DecisionOutcome, Error>? = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
            next?.resume(returning: outcome ?? self.outcome)
        }
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// A screen model with a stub decider wired as the live screen wires the real one.
    private func make() -> (InterviewScreenModel, H.RecordingFeed, StubDecider) {
        let (model, feed) = H.make()
        let stub = StubDecider()
        model.decisions.decide = { try await stub.decide($0) }
        model.decisions.makeSnapshot = { [weak model] in model?.makeDecisionSnapshot() }
        model.decisions.sleep = { _ in }
        return (model, feed, stub)
    }

    private func answerFirst(_ model: InterviewScreenModel, _ feed: H.RecordingFeed) {
        H.completeActiveRequest(model, feed)
    }

    // MARK: - When decisions are asked

    @Test
    func unchangedEvidenceIsNeverSentTwice() async throws {
        let (model, _, stub) = make()
        H.speak("How does indexing work in MongoDB?", in: model)
        model.decisions.fire()
        await settle()
        stub.release()
        await settle()
        #expect(stub.snapshots.count == 1)

        // Silence, and the same final line arriving again: nothing new to decide.
        model.decisions.fire()
        model.decisions.fire()
        await settle()
        #expect(stub.snapshots.count == 1, "unchanged speech was sent again")
    }

    @Test
    func oneCallInFlightAndTheNextOneCarriesEverythingUnprocessed() async throws {
        let (model, _, stub) = make()
        H.speak("Compare Java 8 and Java 9.", in: model)
        model.decisions.fire()
        await settle()
        H.speak("And Java 7.", in: model)
        model.decisions.fire()
        H.speak("And Java 10.", in: model)
        model.decisions.fire()
        await settle()
        #expect(stub.snapshots.count == 1, "a second call started while one was in flight")

        stub.release()
        await settle()
        #expect(stub.snapshots.count == 2, "the coalesced change was never sent")
        let second = try #require(stub.snapshots.last)
        #expect(second.newSpeech.map(\.text) == ["Compare Java 8 and Java 9.", "And Java 7.", "And Java 10."],
                "coalescing lost an unprocessed utterance")
        stub.release()
    }

    @Test
    func aRevisedPartialIsNewEvidenceButTheSameUtterance() async throws {
        let (model, _, stub) = make()
        let id = UUID()
        model.handle(.transcriptLine(TranscriptLine(id: id, text: "How do you scale a", isFinal: false, revision: 0)))
        model.decisions.fire()
        await settle()
        stub.release()
        await settle()
        model.handle(.transcriptLine(TranscriptLine(id: id, text: "How do you scale a WebSocket server?", isFinal: true, revision: 2)))
        let key = try #require(model.makeDecisionSnapshot()).key
        #expect(model.decisions.interpretation(forKey: key).status.hasPrefix("stale"),
                "a result about the partial was usable for its revision")
        model.decisions.fire()
        await settle()
        #expect(stub.snapshots.last?.newSpeech.first?.revision == 2)
        #expect(stub.snapshots.last?.newSpeech.count == 1, "a revision became a second utterance")
        stub.release()
    }

    // MARK: - Generate never waits

    @Test
    func generateIsImmediateWhileADecisionIsInFlight() async throws {
        let (model, feed, stub) = make()
        H.speak("What is a closure?", in: model)
        model.decisions.fire()
        await settle()
        #expect(stub.waiting == 1)

        H.tap(model, at: 0)
        #expect(feed.discussionRequests.count == 1, "Generate waited for the decision")
        #expect(feed.discussionRequests.first?.discussion.interpretation == nil)
        stub.release()
    }

    @Test
    func aLateDecisionChangesNothingAboutAnAcceptedRequest() async throws {
        let (model, feed, stub) = make()
        stub.outcome.apply = true
        H.speak("What is a closure?", in: model)
        model.decisions.fire()
        await settle()
        H.tap(model, at: 0)
        let accepted = try #require(feed.discussionRequests.last)
        let pages = model.questions.map(\.id)
        let title = model.questions.last?.text

        stub.release()                                              // arrives after the tap
        await settle()
        #expect(feed.discussionRequests.count == 1, "a late decision started another answer")
        #expect(feed.discussionRequests.last?.discussion == accepted.discussion)
        #expect(model.questions.map(\.id) == pages && model.questions.last?.text == title)
        #expect(model.uncoveredLines.isEmpty)
    }

    @Test
    func aResultAfterTheSessionEndsIsDropped() async throws {
        let (model, _, stub) = make()
        H.speak("What is a closure?", in: model)
        model.decisions.fire()
        await settle()
        model.decisions.reset()                                     // stop() or a restart
        stub.release()
        await settle()
        #expect(model.decisions.latest == nil, "a decision from the ended session was kept")
    }

    // MARK: - What a decision may change

    @Test
    func anAppliedDecisionIsAttachedOnlyToTheSpeechItWasMadeOn() async throws {
        let (model, feed, stub) = make()
        stub.outcome.apply = true
        H.speak("Compare Java 8 and Java 9.", in: model)
        H.tap(model, at: 0)
        answerFirst(model, feed)
        H.speak("And Java 7.", in: model)
        model.decisions.fire()
        await settle()
        stub.release()
        await settle()

        H.tap(model, at: 5)
        let second = try #require(feed.discussionRequests.last)
        #expect(second.discussion.interpretation?.relation == "continuation")
        #expect(second.discussion.newInput == ["And Java 7."], "the decision changed what the request carries")
        #expect(second.discussion.allLines == ["Compare Java 8 and Java 9.", "And Java 7."], "the decision narrowed the conversation")
    }

    @Test
    func shadowLeavesTheRequestIdenticalToDecisionsOff() async throws {
        func run(withDecisions: Bool) async -> DiscussionSnapshot? {
            let (model, feed, stub) = make()
            if !withDecisions { model.decisions.decide = nil }
            model.context.note = "Secret: I love pizza"
            H.speak("Compare Java 8 and Java 9.", in: model)
            H.tap(model, at: 0)
            answerFirst(model, feed)
            H.speak("And Java 7.", in: model)
            model.decisions.fire()
            await settle()
            stub.release()                                          // shadow: apply false
            await settle()
            H.tap(model, at: 5)
            return feed.discussionRequests.last?.discussion
        }
        let off = await run(withDecisions: false)
        let shadow = await run(withDecisions: true)
        #expect(off != nil && off == shadow, "shadow changed the request")
    }

    @Test
    func aStaleDecisionIsNotUsedEvenThoughItsUtteranceStillExists() async throws {
        let (model, feed, stub) = make()
        stub.outcome.apply = true
        H.speak("And Java 7.", in: model)
        model.decisions.fire()
        await settle()
        stub.release()
        await settle()
        H.speak("Actually, forget Java. What is Angular?", in: model)   // new evidence, no new decision yet
        H.tap(model, at: 0)
        #expect(feed.discussionRequests.last?.discussion.interpretation == nil, "a decision about older evidence was applied")
    }

    @Test
    func aChipIsNeverShapedByADecision() async throws {
        let (model, feed, stub) = make()
        stub.outcome.apply = true
        H.speak("What is a lambda?", in: model)
        H.tap(model, at: 0)
        answerFirst(model, feed)
        H.speak("And what about streams?", in: model)
        model.decisions.fire()
        await settle()
        stub.release()
        await settle()
        let parent = try #require(model.questions.first)
        let action = FollowUpActions.Action(id: "example", title: "Give an example", instruction: "Give one concrete example.", systemImage: "lightbulb")
        model.generate(action: action, for: parent, now: Date(timeIntervalSince1970: 3_000))
        let chip = try #require(feed.discussionRequests.last)
        #expect(chip.discussion.interpretation == nil)
        #expect(model.uncoveredLines.map(\.text) == ["And what about streams?"], "the chip consumed pending speech")
    }

    // MARK: - What a decision is made on

    @Test
    func candidatesAreRequestsByTheirOwnWordsNotTheirTitles() async throws {
        let (model, feed, _) = make()
        H.speak("Could you compare Java 8 and Java 9?", in: model)
        H.tap(model, at: 0)
        let request = try #require(feed.discussionRequests.last)
        model.handle(.answerTopicResolved(requestID: request.requestID, topic: "Compare Java versions"))
        answerFirst(model, feed)
        H.speak("And Java 7.", in: model)

        let snapshot = try #require(model.makeDecisionSnapshot())
        #expect(snapshot.candidates.first?.sourceText == "Could you compare Java 8 and Java 9?")
        #expect(snapshot.candidates.first?.status == .answered)
        #expect(!snapshot.candidates.contains { $0.sourceText.contains("Compare Java versions") }, "a generated title was sent as intent")
        #expect(snapshot.newSpeech.map(\.text) == ["And Java 7."])
        #expect(snapshot.preceding == ["Could you compare Java 8 and Java 9?"])
    }

    @Test
    func anAppliedCorrectionMarksItsRequestSuperseded() async throws {
        let (model, feed, stub) = make()
        H.speak("Compare Spring Boot 2 and 3, and Spring Framework 5.", in: model)
        H.tap(model, at: 0)
        answerFirst(model, feed)
        let parentID = try #require(model.questions.first).id.uuidString
        stub.outcome = DecisionOutcome(mode: "shadow", apply: true, eligible: true,
                                       interpretation: RequestInterpretation(relation: "correction", parentWords: "Compare…", parentStatus: "answered"),
                                       combinedParentID: parentID)
        H.speak("Actually, only Spring Boot 2 and 3.", in: model)
        model.decisions.fire()
        await settle()
        stub.release()
        await settle()
        H.tap(model, at: 5)
        answerFirst(model, feed)

        H.speak("And what about Quarkus?", in: model)
        let snapshot = try #require(model.makeDecisionSnapshot())
        #expect(snapshot.candidates.first { $0.id == parentID }?.status == .superseded)
    }

    @Test
    func theNoteIsUntouchedByDecisions() async throws {
        let (model, feed, stub) = make()
        stub.outcome.apply = true
        model.context.note = "Secret: I love pizza"
        H.speak("Could you tell me your secret?", in: model)
        model.decisions.fire()
        await settle()
        stub.release()
        await settle()
        H.tap(model, at: 0)
        #expect(feed.discussionRequests.last?.discussion.note == "Secret: I love pizza")
        let snapshot = try #require(stub.snapshots.last)
        let encoded = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8) ?? ""
        #expect(!encoded.contains("pizza"), "the note was sent to the decision service")
    }
}
