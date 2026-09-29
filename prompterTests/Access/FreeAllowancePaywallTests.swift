import Foundation
import Testing
@testable import prompter

/// Once the 3 free answers are used, the paywall opens **by itself** only once — on the first blocked
/// new question. After it is dismissed, later blocked questions get the quiet inline lock ("Upgrade to
/// continue"), never another modal; tapping Upgrade opens it on purpose, as often as asked. Pages that
/// already used their credit (Regenerate, follow-ups, reopened pages) are never blocked at all.
@MainActor
struct FreeAllowancePaywallTests {
    typealias Support = ManualGenerationTests
    typealias Request = QuotaIdentityTests.Request

    static func ask(_ text: String, _ model: InterviewScreenModel, _ feed: Support.RecordingFeed, at offset: TimeInterval) -> Request? {
        QuotaIdentityTests.ask(text, model, feed, at: offset)
    }

    /// A live model with its free answers used on pages A, B and C.
    static func exhausted(_ gate: FakeGate) throws -> (InterviewScreenModel, Support.RecordingFeed) {
        let (model, feed) = Support.make()
        model.accessGate = gate
        for (n, text) in ["A?", "B?", "C?"].enumerated() {
            _ = try #require(ask(text, model, feed, at: Double(n * 10)))
            Support.completeActiveRequest(model, feed)
        }
        return (model, feed)
    }

    /// The screen's own close: `InterviewScreen` clears the sheet and abandons what waited on it.
    static func dismiss(_ gate: FakeGate, _ model: InterviewScreenModel) {
        gate.dismissPaywall()
        model.abandonHeldRequests()
    }

    // 1–5: three free answers, one automatic paywall, then only the inline lock.
    @Test
    func theFirstBlockedNewQuestionOpensThePaywallOnceAndLaterOnesDoNot() throws {
        let gate = FakeGate(allows: true, freeRemaining: 3)
        let (model, feed) = try Self.exhausted(gate)
        #expect(feed.discussionRequests.count == 3 && gate.freeRemaining == 0, "three free new answers succeed")
        #expect(gate.paywalls.isEmpty)

        _ = Self.ask("D?", model, feed, at: 40)                               // the 4th new question
        #expect(gate.paywalls == [.generate], "the first blocked new question opens the paywall")
        #expect(model.pendingNewQuestion != nil, "held for the open paywall")
        Self.dismiss(gate, model)
        #expect(model.pendingNewQuestion == nil && model.freeAllowanceBlockedAt == nil)

        _ = Self.ask("E?", model, feed, at: 50)
        #expect(gate.paywalls == [.generate], "the second blocked question: no modal")
        #expect(model.freeAllowanceBlockedAt != nil, "the inline lock says Upgrade to continue")
        _ = Self.ask("F?", model, feed, at: 60)
        #expect(gate.paywalls == [.generate], "nor the third")
        #expect(model.pendingNewQuestion == nil, "nothing waits for a paywall that is not coming")
        #expect(feed.discussionRequests.count == 3 && model.questions.count == 3, "nothing sent, no empty page")
    }

    // 6: explicit Upgrade is intent, not an automatic presentation.
    @Test
    func tappingUpgradeOpensThePaywallEveryTime() {
        let h = AccessControllerTests.make(ledger: .inMemory(FreeAnswersRecord(used: 3, automaticPaywallSeen: true)))
        #expect(h.controller.requestAutomaticPaywall(.generate) == .suppressed)
        #expect(h.controller.paywall == nil)
        h.controller.requestPaywall(.freeAnswersExhausted)
        #expect(h.controller.paywall?.trigger == .freeAnswersExhausted, "Upgrade opens it")
        h.controller.paywall = nil                                             // closed
        h.controller.requestPaywall(.freeAnswersExhausted)
        #expect(h.controller.paywall != nil, "and again, because the user asked")
    }

    // 7: relaunch — the flag is persisted with the free-answer record.
    @Test
    func aRelaunchRemembersTheAutomaticPaywallWasSeen() {
        let ledger = FreeAnswersLedger.inMemory(FreeAnswersRecord(used: 3))
        let first = AccessControllerTests.make(ledger: ledger)
        #expect(!first.controller.hasSeenFreeAllowancePaywall)
        #expect(first.controller.requestAutomaticPaywall(.generate) == .presented)
        first.controller.paywall = nil
        let relaunched = AccessControllerTests.make(ledger: ledger)             // a new process, same Keychain
        #expect(relaunched.controller.hasSeenFreeAllowancePaywall)
        #expect(relaunched.controller.requestAutomaticPaywall(.generate) == .suppressed)
        #expect(relaunched.controller.paywall == nil)
        #expect(relaunched.controller.freeAnswersUsed == 3, "presentation state only: usage untouched")
    }

    /// A record saved before the flag existed still reads — with its usage intact.
    @Test
    func aRecordSavedBeforeTheFlagExistedKeepsItsUsage() throws {
        let old = try JSONDecoder().decode(FreeAnswersRecord.self, from: Data(#"{"used":2,"exhaustionLogged":false}"#.utf8))
        #expect(old == FreeAnswersRecord(used: 2, exhaustionLogged: false, automaticPaywallSeen: false))
        // An installation that had used all three before this update: still three, never back to 0.
        let spent = try JSONDecoder().decode(FreeAnswersRecord.self, from: Data(#"{"used":3,"exhaustionLogged":true}"#.utf8))
        #expect(spent.used == 3 && spent.exhaustionLogged && !spent.automaticPaywallSeen)
        let updated = AccessControllerTests.make(ledger: FreeAnswersLedger(load: { spent }, save: { _ in }))
        #expect(updated.controller.freeAnswersUsed == 3 && updated.controller.areFreeAnswersUsed)
        #expect(updated.controller.requestAutomaticPaywall(.generate) == .presented,
                "it still gets its one automatic paywall after the update")
        let round = try JSONDecoder().decode(FreeAnswersRecord.self, from: JSONEncoder().encode(FreeAnswersRecord(used: 3, automaticPaywallSeen: true)))
        #expect(round.automaticPaywallSeen && round.used == 3)
    }

    // 8: a new meeting uses the same app-wide gate.
    @Test
    func aNewMeetingDoesNotOpenItAgain() throws {
        let gate = FakeGate(allows: true, freeRemaining: 3)
        let (first, firstFeed) = try Self.exhausted(gate)
        _ = Self.ask("D?", first, firstFeed, at: 40)
        Self.dismiss(gate, first)
        #expect(gate.paywalls.count == 1)

        let (meeting, feed) = Support.make()                                   // a new meeting
        meeting.accessGate = gate
        _ = Self.ask("New meeting, first question?", meeting, feed, at: 0)
        #expect(gate.paywalls.count == 1, "no automatic paywall in the new meeting")
        #expect(meeting.freeAllowanceBlockedAt != nil && feed.discussionRequests.isEmpty)
    }

    // 9–10: credited pages stay usable, with no paywall.
    @Test
    func regenerateAndFollowUpsOnACreditedPageNeverShowThePaywall() throws {
        let gate = FakeGate(allows: true, freeRemaining: 3)
        let (model, feed) = try Self.exhausted(gate)
        _ = Self.ask("D?", model, feed, at: 40)
        Self.dismiss(gate, model)

        model.select(index: 1)
        model.regenerate()
        #expect(feed.discussionRequests.count == 4, "Regenerate B is sent")
        Support.completeActiveRequest(model, feed)
        let page = try #require(model.questions.first)
        model.generate(action: QuotaIdentityTests.shorter, for: page, now: Date().addingTimeInterval(90))
        #expect(feed.discussionRequests.count == 5, "a follow-up on A is sent")
        Support.completeActiveRequest(model, feed)
        #expect(gate.paywalls == [.generate], "only the one automatic paywall, from D")
        #expect(model.freeAllowanceBlockedAt == nil, "nothing here was blocked")
    }

    // 11: a reopened credited page.
    @Test
    func aReopenedCreditedPageNeverShowsThePaywall() {
        let feed = Support.RecordingFeed()
        var question = InterviewQuestion(text: "Why Kafka?")
        question.answers = [InterviewAnswer(version: 1, blocks: [.prose("Replay and ordering.")], isComplete: true)]
        var restored = RestoredInterview()
        restored.questions = [question]
        var saved = DiscussionSnapshot(newInput: ["Why Kafka?"])
        saved.generationKey = "page-key-A"
        restored.retainedSnapshots = [question.id: saved]
        let model = InterviewScreenModel(mode: .live, feed: feed, restored: restored)
        let gate = FakeGate(allows: false, freeRemaining: 0)
        gate.automaticPaywallSeen = true
        model.accessGate = gate
        model.generate(for: question)
        #expect(gate.paywalls.isEmpty && model.freeAllowanceBlockedAt == nil)
        #expect(feed.discussionRequests.last?.discussion.generationKey == "page-key-A")
    }

    // 12: rapid taps — one presentation at most.
    @Test
    func rapidGenerateTapsOpenOnePaywall() throws {
        let gate = FakeGate(allows: true, freeRemaining: 3)
        let (model, feed) = try Self.exhausted(gate)
        for n in 0..<5 { _ = Self.ask("D\(n)?", model, feed, at: 40 + Double(n)) }
        #expect(gate.paywalls == [.generate], "five taps, one sheet")
        #expect(feed.discussionRequests.count == 3)

        let h = AccessControllerTests.make(ledger: .inMemory(FreeAnswersRecord(used: 3)))
        #expect(h.controller.requestAutomaticPaywall(.generate) == .presented)
        let shown = h.controller.paywall
        #expect(h.controller.requestAutomaticPaywall(.generate) == .alreadyShowing)
        h.controller.requestPaywall(.freeAnswersExhausted)
        #expect(h.controller.paywall == shown, "no second sheet replaces or stacks on the first")
    }

    // 13: a purchase lifts the lock inside the same meeting.
    @Test
    func aPurchaseRemovesTheLockAndNewAnswersFlow() throws {
        let gate = FakeGate(allows: true, freeRemaining: 3)
        let (model, feed) = try Self.exhausted(gate)
        let pagesBefore = model.questions.map(\.id)
        _ = Self.ask("D?", model, feed, at: 40)
        Self.dismiss(gate, model)
        _ = Self.ask("E?", model, feed, at: 50)
        #expect(model.freeAllowanceBlockedAt != nil)

        gate.requestPaywall(.freeAnswersExhausted)                              // Upgrade
        gate.becomePro()                                                        // purchase verified
        model.releaseHeldRequests()                                             // the screen, on verified access
        #expect(model.freeAllowanceBlockedAt == nil, "the inline lock is gone")
        _ = Self.ask("F?", model, feed, at: 70)
        #expect(feed.discussionRequests.count == 4, "a new question is answered without restarting")
        #expect(model.questions.count == 4 && Array(model.questions.prefix(3).map(\.id)) == pagesBefore,
                "the meeting and its pages are intact")
    }

    // 14: Pro never meets any of this.
    @Test
    func proNeverHitsTheFlow() throws {
        let (model, feed) = Support.make()
        let gate = FakeGate(allows: true)
        model.accessGate = gate
        for n in 0..<6 {
            _ = Self.ask("Question \(n)?", model, feed, at: Double(n * 10))
            Support.completeActiveRequest(model, feed)
        }
        #expect(gate.paywalls.isEmpty && !gate.automaticPaywallSeen && model.freeAllowanceBlockedAt == nil)

        let h = AccessControllerTests.make(ledger: .inMemory(FreeAnswersRecord(used: 3)), pro: LockedBox(true))
        #expect(h.controller.requestAutomaticPaywall(.generate) == .suppressed)
        #expect(h.controller.paywall == nil && !h.controller.hasSeenFreeAllowancePaywall, "Pro does not spend the one-time paywall")
    }
}
