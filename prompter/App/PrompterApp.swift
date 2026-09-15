import SwiftUI
import SwiftData

@main
struct PrompterApp: App {
    let modelContainer = AppEnvironment.makeModelContainer()
    /// One entitlement service for the whole app (M5.13). Configured once on launch; safe when no
    /// key is present — it simply reports `.unconfigured` and Premium is unpurchasable.
    @State private var entitlements = EntitlementService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(entitlements)
                // **The hard `.preferredColorScheme(.light)` lock is gone (M5.10.)**
                //
                // It existed because the v2 palette was light-only: system chrome followed the
                // device's Dark Mode while every `Theme.Color` stayed hardcoded light, so a nav
                // title could render white on light paper. The v3 palette is fully adaptive —
                // every token resolves per appearance — so the mismatch it defended against can no
                // longer occur, and locking the app to light would make the approved dark design
                // unreachable.
                //
                // `RootView` now applies the stored System / Light / Dark preference instead,
                // defaulting to System. (Outdoor mode remains a separate high-contrast override
                // applied only on the prompt screen; this does not touch it.)
        }
        .modelContainer(modelContainer)
    }
}
