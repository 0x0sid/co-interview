import Testing
import Foundation
@testable import prompter

/// Reproduces the real on-device volatile-retraction bug found during the M4 retest (build
/// 0be5fb8, docs/ARCHITECTURE.md "Volatile reconciliation"): the first `.volatile` for a session
/// was a single truncated letter ("W" before "Welcome" resolved), fed immediately as a whole word
/// since `PromptViewModel` had nothing to compare it against — then revised into a different word
/// by the next volatile, permanently poisoning the matcher's ring buffer (no retraction) until
/// enough later words aged it out 13 real seconds later.
///
/// Text/order below is copied verbatim from that device trace's `[PromptDebug]` lines; only the
/// elapsed timings are compressed (the bug and its fix are both about word content/order, not
/// wall-clock duration — the real 13s delay was `.final` results arriving 2-15s apart in practice,
/// not something this mechanism depends on to reproduce).
@MainActor
struct VolatileReconciliationTests {
    @Test
    func firstUtteranceAdvancesCleanlyDespiteATruncatedFirstVolatile() async throws {
        let results: [FakeTranscriptionService.ScriptedResult] = [
            .init(text: "W", isFinal: false, elapsed: 0.05),
            .init(text: "Wel", isFinal: false, elapsed: 0.10),
            .init(text: "Welcome to", isFinal: false, elapsed: 0.15),
            .init(text: "Welcome to Pr", isFinal: false, elapsed: 0.20),
            .init(text: "Welcome to Prom", isFinal: false, elapsed: 0.22),
            .init(text: "Welcome to Promp", isFinal: false, elapsed: 0.24),
            .init(text: "Welcome to Prompter", isFinal: false, elapsed: 0.26),
            .init(text: "Welcome to Prompter.", isFinal: true, elapsed: 0.40),
        ]

        let viewModel = PromptViewModel(
            scriptText: PromptDemoFixture.defaultScriptText,
            makeService: { FakeTranscriptionService(results: results) }
        )

        viewModel.start()

        // Wait for the stream to be *observably finished*, using a signal the production path
        // itself produces, rather than a wall-clock proxy for it.
        //
        // Every earlier version of this wait sampled the cursor too early, and that — not
        // flakiness — is what made this test fail in full runs and pass in isolation. The original
        // fixed `Task.sleep(0.8)` budgeted 0.8 s for a script ending at 0.40 s, ample on an idle
        // machine and not ample under load. Two intermediate attempts anchored on the *test's*
        // clock, which drifts from the stream's whenever session setup is delayed: the last one
        // sampled at cursor 2 ("welcome to") with `confidence` and `state` both already correct,
        // failing only `tokenIndex >= 3` because the `.final` carrying "prompter" had not been
        // processed yet.
        //
        // `listeningText` is the honest signal: `PromptViewModel` sets it on every `.volatile` and
        // clears it on `.final`. Observing it go non-empty and then empty again means the final
        // delta has been reconciled. No production behaviour is touched — only how the test decides
        // it has waited long enough.
        try await Self.waitForFinalToBeProcessed(viewModel)

        // Gate: the FINAL for "Welcome to Prompter." must land as a confident real advance, not a
        // low-confidence stall — a poisoned ring buffer (the old "w" retraction bug) would score
        // this around 0.28 and leave the cursor at token 0.
        #expect(viewModel.cursor.confidence > 0.72)
        #expect(viewModel.cursor.state == .advancing)
        #expect(viewModel.cursor.tokenIndex >= 3)

        viewModel.stop()
    }

    /// Waits until the scripted stream's `.final` has been reconciled, then until the cursor stops
    /// changing, bounded by `timeout`. Returns rather than throwing on expiry so the caller's own
    /// assertions produce the failure message.
    ///
    /// The bound is generous because the diagnosis included CPU starvation as a secondary factor:
    /// the M5.2 measurement tests are expensive (`M1TimingAttributionTests` replays the whole
    /// 28-fixture suite four times) and Swift Testing runs tests in parallel, so trivial tests in
    /// the same run were observed taking 16 s. A generous bound costs nothing on an idle machine
    /// because the wait returns the moment the stream settles.
    private static func waitForFinalToBeProcessed(
        _ viewModel: PromptViewModel,
        timeout: TimeInterval = 90.0,
        pollInterval: TimeInterval = 0.01,
        quietPolls: Int = 10
    ) async throws {
        let start = Date()
        var lastCursor = viewModel.cursor
        var quiet = 0
        while Date().timeIntervalSince(start) < timeout {
            try await Task.sleep(for: .seconds(pollInterval))
            let current = viewModel.cursor
            if current == lastCursor {
                quiet += 1
            } else {
                quiet = 0
                lastCursor = current
            }
            // "The stream has moved the cursor, then gone quiet, with no volatile outstanding."
            //
            // An earlier version also required *observing* `listeningText` go non-empty, to stop
            // the empty-before-the-stream-starts case from satisfying this trivially at t = 0. The
            // `tokenIndex > 0` conjunct rules that case out just as well and does not depend on
            // catching a 100 ms volatile window with a 10 ms poll — which is what made this test
            // fail under the CPU starvation the measurement suites create, while passing in
            // isolation. The caller's assertions are unchanged.
            if viewModel.listeningText.isEmpty, current.tokenIndex > 0, quiet >= quietPolls { return }
        }
    }
}
