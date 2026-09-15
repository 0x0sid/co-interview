import Testing
import Foundation
@testable import prompter

/// **M5.7 — automatic resumption after manual repositioning** (docs/DECISIONS.md).
///
/// Tests the rule directly rather than through a rendered view, so each clause of the owner's
/// contract has a named case that fails on its own.
struct ScrollOwnershipTests {

    // MARK: - The unmeasured-geometry guard, with its control
    //
    // These two run the SAME input sequence and differ only in whether the layout was measured when
    // the interaction settled. That pairing is what makes the guard load-bearing rather than
    // decorative: if the guard were removed, (a) would resume and the pair would disagree.

    /// The exact sequence that resumes in `readingTheNewlyVisiblePassageResumesAutomatically`.
    private static let resumingSequence = [310, 311, 312, 313]

    @Test
    func settlingWithoutGeometryDoesNotArmTheRuleAndNeverResumes() {
        var ownership = ScrollOwnership()
        ownership.beginManualInteraction()
        ownership.endManualInteraction(visibleTokens: nil)      // layout not measured

        #expect(!ownership.isArmed, "the rule armed itself without a measured region")
        let resumption = read(&ownership, tokens: Self.resumingSequence)
        #expect(resumption == nil, "resumed on an unmeasured layout")
        #expect(ownership.isManuallyDetached, "the page moved without a measured region")

        // The reader is never stranded: the explicit controls still work in this state.
        ownership.resumeAutomatically()
        #expect(!ownership.isManuallyDetached, "Resume following / Restart must work unarmed")
    }

    /// **Control for the case above** — identical input, geometry present.
    @Test
    func theSameSequenceResumesWhenGeometryIsPresent() {
        var ownership = ScrollOwnership()
        ownership.beginManualInteraction()
        ownership.endManualInteraction(visibleTokens: 300..<360)  // layout measured

        #expect(ownership.isArmed, "a measured region should arm the rule")
        let resumption = read(&ownership, tokens: Self.resumingSequence)
        #expect(resumption != nil, "the control must resume — otherwise the guard proves nothing")
        #expect(!ownership.isManuallyDetached)
    }

    /// An empty measured region is treated as no region, not as a region nothing can match.
    @Test
    func anEmptyMeasuredRegionDoesNotArmTheRule() {
        var ownership = ScrollOwnership()
        ownership.beginManualInteraction()
        ownership.endManualInteraction(visibleTokens: 300..<300)
        #expect(!ownership.isArmed)
        #expect(read(&ownership, tokens: Self.resumingSequence) == nil)
    }

    /// Drives a settled manual reposition to `region`, ready for evidence.
    private func detached(to region: Range<Int>) -> ScrollOwnership {
        var ownership = ScrollOwnership()
        ownership.beginManualInteraction()
        ownership.endManualInteraction(visibleTokens: region)
        return ownership
    }

    /// Feeds forward reading inside `region`, returning the first resumption produced.
    @discardableResult
    private func read(_ ownership: inout ScrollOwnership, tokens: [Int], idle: Bool = true) -> ScrollOwnership.Resumption? {
        var result: ScrollOwnership.Resumption?
        for token in tokens {
            if let resumption = ownership.observeCursor(token: token, isAdvancing: true, scrollIsIdle: idle), result == nil {
                result = resumption
            }
        }
        return result
    }

    // MARK: - The owner's six cases

    @Test
    func dragReleaseThenSilenceRemainsDetached() {
        var ownership = detached(to: 100..<160)
        // Silence: the cursor never changes, however often it is republished.
        for _ in 0..<20 {
            #expect(ownership.observeCursor(token: 120, isAdvancing: false, scrollIsIdle: true) == nil)
        }
        #expect(ownership.isManuallyDetached, "silence must not resume following")
    }

    @Test
    func recognitionStillTrackingTheOldPassageDoesNotSnapBack() {
        var ownership = detached(to: 300..<360)
        // The reader dragged far ahead; recognition is still confirming the passage they left.
        let resumption = read(&ownership, tokens: [120, 121, 122, 123, 124, 125])
        #expect(resumption == nil, "out-of-region matches must not resume")
        #expect(ownership.isManuallyDetached, "the view snapped back to the old passage")
    }

    @Test
    func readingTheNewlyVisiblePassageResumesAutomatically() {
        var ownership = detached(to: 300..<360)
        let resumption = read(&ownership, tokens: [310, 311, 312, 313])
        #expect(resumption != nil, "reading the chosen passage must resume following")
        #expect(!ownership.isManuallyDetached)
        #expect(resumption?.evidenceCount == ScrollOwnership.resumeEvidenceCount)
        #expect(resumption?.chosenRegion == 300..<360)
    }

    @Test
    func offScriptCommentaryRemainsDetached() {
        var ownership = detached(to: 300..<360)
        // Off-script speech does not advance the cursor; it holds or recovers.
        for token in [305, 306, 307, 308] {
            #expect(ownership.observeCursor(token: token, isAdvancing: false, scrollIsIdle: true) == nil)
        }
        #expect(ownership.isManuallyDetached, "commentary resumed following")
    }

    @Test
    func draggingAgainDuringResumedFollowingTakesControlImmediately() {
        var ownership = detached(to: 300..<360)
        read(&ownership, tokens: [310, 311, 312, 313])
        #expect(!ownership.isManuallyDetached, "precondition: following resumed")

        ownership.beginManualInteraction()
        #expect(ownership.isManuallyDetached, "a new drag must take control immediately")
        // Mid-gesture, nothing resumes however good the evidence looks.
        #expect(ownership.observeCursor(token: 311, isAdvancing: true, scrollIsIdle: false) == nil)
    }

    @Test
    func explicitResumeAndRestartStillWork() {
        var ownership = detached(to: 300..<360)
        ownership.resumeAutomatically()
        #expect(!ownership.isManuallyDetached, "the button override must work without any evidence")
        #expect(ownership.chosenRegion == nil)
        #expect(ownership.evidence.isEmpty)
    }

    // MARK: - The implementation constraints

    @Test
    func neverResumesWhileDraggingOrDecelerating() {
        var ownership = ScrollOwnership()
        ownership.beginManualInteraction()
        // Still interacting: no region captured yet, and evidence cannot accumulate.
        for token in [310, 311, 312, 313] {
            #expect(ownership.observeCursor(token: token, isAdvancing: true, scrollIsIdle: false) == nil)
        }
        // Settled, but the caller reports the view is still decelerating.
        ownership.endManualInteraction(visibleTokens: 300..<360)
        for token in [310, 311, 312, 313] {
            #expect(ownership.observeCursor(token: token, isAdvancing: true, scrollIsIdle: false) == nil,
                    "resumed while the view was still decelerating")
        }
        #expect(ownership.isManuallyDetached)
    }

    /// "Use fresh reading evidence … not a stale cursor, layout update, or confidence value alone."
    @Test
    func aRepublishedUnchangedCursorIsNotEvidence() {
        var ownership = detached(to: 300..<360)
        // A re-layout republishes the same advancing cursor many times.
        for _ in 0..<10 {
            #expect(ownership.observeCursor(token: 310, isAdvancing: true, scrollIsIdle: true) == nil)
        }
        #expect(ownership.isManuallyDetached, "an unchanged cursor resumed following")
    }

    /// Reading must be going forward through the chosen passage.
    @Test
    func backwardOrStationaryMatchesRestartTheEvidence() {
        var ownership = detached(to: 300..<360)
        read(&ownership, tokens: [310, 311])
        #expect(ownership.evidence == [311], "expected forward evidence, got \(ownership.evidence)")
        // A backward match restarts the run rather than completing it.
        _ = ownership.observeCursor(token: 305, isAdvancing: true, scrollIsIdle: true)
        #expect(ownership.isManuallyDetached)
        #expect(ownership.evidence == [305])
    }

    /// A single in-region match is not enough; the threshold is the whole point of the rule.
    @Test
    func oneMatchIsNotEnough() {
        var ownership = detached(to: 300..<360)
        let resumption = read(&ownership, tokens: [310, 311])
        #expect(resumption == nil, "resumed on fewer than \(ScrollOwnership.resumeEvidenceCount) observations")
        #expect(ownership.isManuallyDetached)
    }

    /// Evidence gathered before a second drag must not resume following after it.
    @Test
    func evidenceDoesNotSurviveANewInteraction() {
        var ownership = detached(to: 300..<360)
        read(&ownership, tokens: [310, 311])          // two of the three needed
        ownership.beginManualInteraction()
        ownership.endManualInteraction(visibleTokens: 300..<360)
        let resumption = read(&ownership, tokens: [312])
        #expect(resumption == nil, "stale evidence survived a new manual interaction")
        #expect(ownership.isManuallyDetached)
    }

    /// Leaving the chosen region clears the run: the reader is no longer reading what they chose.
    @Test
    func leavingTheChosenRegionClearsEvidence() {
        var ownership = detached(to: 300..<360)
        read(&ownership, tokens: [310, 311])
        _ = ownership.observeCursor(token: 500, isAdvancing: true, scrollIsIdle: true)
        #expect(ownership.evidence.isEmpty, "evidence survived leaving the chosen region")
        let resumption = read(&ownership, tokens: [312])
        #expect(resumption == nil)
    }
}
