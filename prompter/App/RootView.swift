import SwiftUI
import SwiftData

/// M5: the app's real root is now `ScriptListScreen` (§12.1 Home) — this used to be a debug-link
/// placeholder (§16 M0-M4); that debug list moved behind a single gear icon on Home
/// (`DebugMenuScreen`), `#if DEBUG`-gated, so it survives for device testing without being part
/// of the real product surface.
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsQuery: [AppSettings]
    @Environment(EntitlementService.self) private var entitlements

    /// Applied once at the root so every screen — including sheets and the reader — follows the
    /// stored preference. `nil` means "follow the system", which is the default (M5.10).
    ///
    /// Reading it from the `@Query` rather than a fetch keeps it reactive without re-creating any
    /// session state: changing appearance re-renders the view tree, it does **not** rebuild the
    /// matcher, reset the cursor, clear spoken history or restart speech recognition.
    private var preferredScheme: ColorScheme? {
        (settingsQuery.first?.appearance ?? .system).colorScheme
    }

    var body: some View {
        NavigationStack {
            #if DEBUG
            if CopilotReplayHarness.isEnabled {
                CopilotReplayHarness.screen
            } else if PromptReplayHarness.isEnabled {
                PromptReplayHarness.screen
            } else {
                ScriptListScreen()
            }
            #else
            ScriptListScreen()
            #endif
        }
        .preferredColorScheme(preferredScheme)
        .task {
            // Configure once, honouring any cached entitlement so a premium reader opening offline
            // is not downgraded while the network call is in flight.
            let settings = AppSettings.fetchOrCreate(in: modelContext)
            entitlements.onVerifiedEntitlementChange = { active, at in
                settings.premiumCachedActive = active
                settings.premiumCachedAt = at
                try? modelContext.save()
            }
            entitlements.configure(cachedPremium: settings.premiumCachedActive, cachedAt: settings.premiumCachedAt)
        }
    }
}

#if DEBUG
/// Launches `PromptScreen` — the **real production view** — against a scripted
/// `FakeTranscriptionService`, so the presentation contract (fading, scroll anchoring, fast
/// repositioning) can be inspected visually in the Simulator.
///
/// It exists because there was no way to see this screen work without a device: `DemoScreen` and
/// `ScriptEditorScreen` both construct a real `TranscriptionService`, and real Speech does not run
/// in the Simulator (§11.6). Every presentation bug therefore cost a device round to observe, which
/// is what happened on 2026-09-10 and 2026-09-11.
///
/// Debug-only and entered only via the `-promptReplay` launch argument, so it is not part of the
/// product surface. It changes no production behaviour: `PromptScreen` and `PromptViewModel` are
/// used exactly as shipped, and only the injected `Transcribing` differs — which is the same seam
/// `VolatileReconciliationTests` already uses.
enum PromptReplayHarness {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-promptReplay") }

    /// A read of the bundled script that exercises every clause of the contract in one pass:
    /// ordinary reading, a pause, off-script commentary, then a **distant skip** to the last
    /// paragraph followed by continued reading.
    static let script: [FakeTranscriptionService.ScriptedResult] = [
        .init(text: "Welcome to", isFinal: false, elapsed: 1.0),
        .init(text: "Welcome to Prompter. This is a", isFinal: false, elapsed: 2.0),
        .init(text: "Welcome to Prompter. This is a longer test script, written", isFinal: false, elapsed: 3.2),
        .init(text: "Welcome to Prompter. This is a longer test script, written specifically so you have enough material", isFinal: false, elapsed: 4.6),
        .init(text: "Welcome to Prompter. This is a longer test script, written specifically so you have enough material to read aloud and actually see the cursor", isFinal: false, elapsed: 6.0),
        .init(text: "Welcome to Prompter. This is a longer test script, written specifically so you have enough material to read aloud and actually see the cursor track your voice across several paragraphs, not just one or two lines.", isFinal: true, elapsed: 7.6),
        // Pause, then off-script commentary — nothing may grey, and the page must hold.
        .init(text: "okay so I want to check the colours here", isFinal: true, elapsed: 12.0),
        // Distant skip to the final paragraph, then continued reading.
        .init(text: "That's the whole test.", isFinal: true, elapsed: 15.0),
        .init(text: "Thanks for reading all the way to the end.", isFinal: true, elapsed: 17.0),
    ]

    @MainActor
    static var screen: some View {
        PromptScreen(
            scriptText: PromptDemoFixture.defaultScriptText,
            makeService: { FakeTranscriptionService(results: script) }
        )
    }
}
#endif

#Preview {
    RootView()
        .modelContainer(for: [Script.self, PromptSession.self, UsageLedger.self, AppSettings.self], inMemory: true)
}
