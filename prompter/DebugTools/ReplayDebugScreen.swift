// Developer-only. Compiled out of Release entirely (M5.11): these screens are unreachable from
// the app UI after the debug menu was removed, and must not exist in a shipping binary.
#if DEBUG
import SwiftUI

/// §10.5's debug-only matcher replay screen: plays a fixture transcript through the real
/// `SlidingWindowMatcher` and renders the three-state text styling from §12.4 (spoken / current
/// sentence / future) so the cursor's behavior — including the paragraph-skip recovery and the
/// ad-lib hold — is visible without a microphone or any speech code. Compiled out of Release
/// builds.
struct ReplayDebugScreen: View {
    @State private var player = ReplayPlayer(fixture: DemoReplayFixtures.paragraphSkipAndAdLib)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                styledScript
                    .padding(20)
            }
            statusBar
            controls
        }
        .background(Theme.Color.paper)
        .navigationTitle(player.fixture.title)
    }

    private var styledScript: Text {
        ScriptStyling.styledText(
            rawText: player.fixture.scriptText,
            scriptIndex: player.scriptIndex,
            cursor: player.cursor
        )
        .font(Typography.body(18))
    }

    private var statusBar: some View {
        HStack {
            Text(stateLabel)
                .font(Typography.mono(13, weight: .medium))
                .foregroundStyle(Theme.Color.action)
            Spacer()
            Text("confidence \(Int(player.cursor.confidence * 100))%")
                .font(Typography.mono(13))
                .foregroundStyle(Theme.Color.spoken)
            Text("\(player.eventsPlayed)/\(player.fixture.events.count) events")
                .font(Typography.mono(13))
                .foregroundStyle(Theme.Color.spoken)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.Color.paper)
        .overlay(Rectangle().frame(height: Theme.Shape.borderWidth).foregroundStyle(Theme.Color.hairline), alignment: .top)
    }

    private var stateLabel: String {
        switch player.cursor.state {
        case .advancing: "advancing"
        case .holding: "holding"
        case .recovering: "recovering"
        case .frozen: "frozen"
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(player.isPlaying ? "Restart" : "Play") {
                player.play()
            }
            .buttonStyle(ReplayButtonStyle(prominent: true))

            Button("Stop") {
                player.stop()
            }
            .buttonStyle(ReplayButtonStyle(prominent: false))
            .disabled(!player.isPlaying)
        }
        .padding(20)
    }
}

struct ReplayButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.body(16, weight: .medium))
            .foregroundStyle(prominent ? Theme.Color.onDark : Theme.Color.action)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.Shape.cornerRadius)
                    .fill(prominent ? Theme.Color.action : Theme.Color.paper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Shape.cornerRadius)
                    .stroke(Theme.Color.action, lineWidth: Theme.Shape.borderWidth)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

#Preview {
    NavigationStack {
        ReplayDebugScreen()
    }
}

#endif
