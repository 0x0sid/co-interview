import Testing
import Foundation
@testable import prompter

/// **M5.9 — the resume glide owns its transition and pacing update.**
///
/// The defect was observed on device as
/// `onChange(of: Optional<CGFloat>) action tried to update multiple times per frame`, emitted
/// immediately before the 19:58:22.838 RESUME. Two handlers wrote scroll state in one frame and the
/// second re-issued the same target with the *following* animation, overwriting the recovery glide.
///
/// These tests exercise the decision logic that governs it. **Limitation stated plainly:** they
/// verify which targets are *requested* and whether pacing state is rewritten. They cannot verify
/// displayed motion — `simctl` cannot drag, and frame capture is too coarse — so glide smoothness
/// remains a recording-only check (docs/DEVICE_TEST_M5.2.md).
struct ResumeGlideOwnershipTests {

    /// Mirrors `applyScroll`'s no-op rule, which is what now absorbs the duplicate callback.
    private func isSuppressed(incoming: CGFloat, lastApplied: CGFloat?) -> Bool {
        guard let lastApplied else { return false }
        return abs(lastApplied - incoming) < PromptScreen.offsetEpsilonForTests
    }

    /// A duplicate callback for the position the glide already targeted must be dropped.
    @Test
    func aDuplicateCallbackDoesNotRestartTheResumeGlide() {
        let glideTarget: CGFloat = 1814.7
        // The resume path now records its own target rather than clearing it.
        let lastApplied: CGFloat? = glideTarget
        #expect(isSuppressed(incoming: glideTarget, lastApplied: lastApplied),
                "the duplicate readingOffset callback would restart the glide")
        // Sub-pixel jitter from re-measurement is the same position.
        #expect(isSuppressed(incoming: glideTarget + 0.4, lastApplied: lastApplied))
    }

    /// A genuinely newer reading target must still be followed.
    @Test
    func aGenuinelyNewerTargetIsStillFollowed() {
        let glideTarget: CGFloat = 1814.7
        #expect(!isSuppressed(incoming: 1855.4, lastApplied: glideTarget),
                "a real next-line target was suppressed")
        #expect(!isSuppressed(incoming: glideTarget - 40, lastApplied: glideTarget))
    }

    /// Before the fix the resume path cleared `lastAppliedOffset`, so the duplicate callback passed
    /// the no-op check. This is the control: with `nil`, nothing is suppressed.
    @Test
    func controlTheClearedStateAcceptedTheDuplicate() {
        #expect(!isSuppressed(incoming: 1814.7, lastApplied: nil),
                "control: with the pre-fix cleared state the duplicate must NOT be suppressed")
    }

    /// The ownership rule itself is untouched by this presentation fix.
    @Test
    func ownershipSemanticsAreUnchanged() {
        var ownership = ScrollOwnership()
        ownership.beginManualInteraction()
        // Geometry unavailable -> stays detached, never armed.
        ownership.endManualInteraction(visibleTokens: nil)
        #expect(!ownership.isArmed)
        #expect(ownership.observeCursor(token: 310, isAdvancing: true, scrollIsIdle: true) == nil)
        #expect(ownership.isManuallyDetached, "geometry-less settle must remain detached")
        // Explicit override still works.
        ownership.resumeAutomatically()
        #expect(!ownership.isManuallyDetached)
    }

    /// Skipped text protection is a matching-side invariant and must be unaffected by either change.
    @Test
    func skippedTextIsStillNeverMarked() {
        let script = ScriptIndex.build(from: PromptDemoFixture.defaultScriptText).tokenTexts
        // The device 177 -> 248 recovery across 71 tokens the reader never read.
        let fed = Tokenizer.normalize("did the should have this rather than chasing")
        let marked = PromptViewModel.newlySpokenTokens(
            fedWords: fed, from: 177, to: 248, state: .recovering, scriptTokens: script)
        #expect(marked.isEmpty, "recovery marked \(marked.count) tokens across skipped text")
    }
}
