import SwiftUI

/// M5's real Home screen (`ScriptListScreen`) replaced the old debug-list root — these three
/// entries survive behind a single gear icon instead (§16 M5 instruction), so device testing
/// against the raw matcher/transcript/arbitrary-text paths stays available without cluttering
/// the real product surface.
#if DEBUG
struct DebugMenuScreen: View {
    var body: some View {
        List {
            NavigationLink("Debug: Matcher Replay") {
                ReplayDebugScreen()
            }
            NavigationLink("Debug: Live Transcript") {
                DebugTranscriptScreen()
            }
            NavigationLink("Debug: Prompt Screen (arbitrary text)") {
                PromptTextInputScreen()
            }
        }
        .navigationTitle("Debug")
        .safeAreaInset(edge: .bottom) {
            Text(BuildInfo.footer)
                .font(Typography.mono(11))
                .foregroundStyle(Theme.Color.spoken)
                .padding(.bottom, 12)
        }
    }
}

/// Git short-hash + build date, stamped into the built `Info.plist` by the "Stamp Build Info"
/// Run Script build phase (`GitCommitHash`/`BuildDate` keys) — every device test report should
/// start with this, so which build a report describes is never ambiguous.
enum BuildInfo {
    static var footer: String {
        let info = Bundle.main.infoDictionary
        let hash = info?["GitCommitHash"] as? String ?? "unknown"
        let date = info?["BuildDate"] as? String ?? "unknown"
        return "build \(hash) · \(date)"
    }
}

#Preview {
    NavigationStack {
        DebugMenuScreen()
    }
}
#endif
