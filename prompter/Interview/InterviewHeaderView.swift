import SwiftUI

/// The v2.5 header: a round Back button, a navigation pill carrying the interview's name and the
/// recording mark, and a round Settings button.
///
/// The chevrons inside the pill move between question pages and disable themselves at the ends, so
/// the pill is the whole of question navigation — there is no second set of controls elsewhere.
struct InterviewHeaderView: View {
    let title: String
    let recording: RecordingState
    /// True when the transcript is coming from a script rather than a microphone. The mark then
    /// reads "Demo playback" to VoiceOver and is drawn in the muted tone, never the recording red:
    /// scripted playback must never look like the device is listening.
    let isSimulatedSource: Bool
    /// In Live, the capture session's own words ("Listening", "Interrupted", "Paused"). VoiceOver
    /// reads this instead of a generic label, so the mark can never overstate what the microphone is
    /// doing. Nil in Demo.
    var listeningLabel: String? = nil
    let canGoToPrevious: Bool
    let canGoToNext: Bool
    let onBack: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            roundButton(systemImage: "chevron.left", label: "Close interview", action: onBack)

            HStack(spacing: 6) {
                navButton(systemImage: "chevron.left", label: "Previous question", isEnabled: canGoToPrevious, action: onPrevious)
                HStack(spacing: 7) {
                    Text(title)
                        .font(InterviewTheme.Font.ui(14.5, weight: .semibold, relativeTo: .subheadline))
                        .foregroundStyle(InterviewTheme.Color.ink)
                        .lineLimit(1)
                    RecordingMark(
                        state: recording,
                        isSimulatedSource: isSimulatedSource,
                        liveLabel: listeningLabel
                    )
                }
                .frame(maxWidth: .infinity)
                navButton(systemImage: "chevron.right", label: "Next question", isEnabled: canGoToNext, action: onNext)
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(InterviewTheme.Color.surface, in: Capsule())
            .overlay(Capsule().stroke(InterviewTheme.Color.hairline, lineWidth: 1))

            roundButton(systemImage: "gearshape", label: "Interview settings", action: onSettings)
        }
        .padding(.horizontal, 14)
    }

    private func roundButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(InterviewTheme.Color.ink.opacity(0.8))
                .frame(width: 38, height: 38)
                .background(InterviewTheme.Color.surface, in: Circle())
                .overlay(Circle().stroke(InterviewTheme.Color.hairline, lineWidth: 1))
        }
        .accessibilityLabel(label)
    }

    private func navButton(systemImage: String, label: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(InterviewTheme.Color.muted.opacity(isEnabled ? 1 : 0.35))
                .frame(width: 26, height: 26)
        }
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}
