import SwiftUI

/// The floating pill: pause, Generate, more. **Icons only** — the labels live in VoiceOver, not on
/// screen, so the pill stays small enough to leave the answer room to breathe.
///
/// Generate is the one filled, primary-coloured control on the screen, and the only one with a
/// sparkle: the mark means "this makes something".
struct ActionPillView<MenuContent: View>: View {
    let recording: RecordingState
    let isGenerating: Bool
    let canGenerate: Bool
    let onToggleRecording: () -> Void
    let onGenerate: () -> Void
    @ViewBuilder let menu: () -> MenuContent
    @Environment(\.ultraContrast) private var ultraContrast

    /// Secondary icons are softened in light and dark; Ultra Contrast keeps them pure white.
    private var iconOpacity: Double { ultraContrast ? 1 : 0.72 }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onToggleRecording) {
                Image(systemName: recording == .live ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(InterviewTheme.Color.ink.opacity(iconOpacity))
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel(recording == .live ? "Pause listening" : "Resume listening")

            Button(action: onGenerate) {
                ZStack {
                    if ultraContrast && !(canGenerate || isGenerating) {
                        // Disabled without a grey: an outlined circle and a white mark.
                        Circle().strokeBorder(InterviewTheme.Color.primary, lineWidth: 2)
                    } else {
                        Circle().fill(InterviewTheme.Color.primary.opacity(canGenerate || isGenerating ? 1 : 0.4))
                    }
                    if isGenerating, !InterviewTestingFlags.quietMotion {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(InterviewTheme.Color.onPrimary)
                    } else {
                        SparkleShape()
                            .fill(ultraContrast && !canGenerate ? InterviewTheme.Color.primary : InterviewTheme.Color.onPrimary)
                            .frame(width: 26, height: 26)
                    }
                }
                .frame(width: InterviewTheme.Metric.generateDiameter, height: InterviewTheme.Metric.generateDiameter)
            }
            .disabled(!canGenerate)
            .accessibilityLabel("Generate an answer")

            Menu {
                menu()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(InterviewTheme.Color.ink.opacity(iconOpacity))
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("More actions")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(InterviewTheme.Color.pillSurface, in: Capsule())
        .ultraContrastOutline(Capsule())
        .shadow(color: .black.opacity(0.16), radius: 14, x: 0, y: 12)
    }
}

/// "Q3 ready →" — the nudge shown when a question arrives on a page the user is not looking at.
/// Tapping it goes there; it never moves the page on its own.
struct ReadyChipView: View {
    let questionNumber: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("Q\(questionNumber) ready")
                    .font(InterviewTheme.Font.ui(13, weight: .semibold, relativeTo: .footnote))
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(InterviewTheme.Color.onPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(InterviewTheme.Color.primary, in: Capsule())
            .shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Question \(questionNumber) is ready")
    }
}
