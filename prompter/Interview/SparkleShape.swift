import SwiftUI

/// The four-pointed star. In v2.5 it means exactly one thing: **Generate** — the button that makes
/// something. It is not used for status, and nothing else in the screen borrows it.
///
/// The control points are the design board's own SVG path on a 24×24 box, scaled into whatever
/// frame it is given.
struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let originX = rect.midX - 12 * scale
        let originY = rect.midY - 12 * scale
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }
        var path = Path()
        path.move(to: point(12, 2))
        path.addLine(to: point(13.8, 8.2))
        path.addLine(to: point(20, 10))
        path.addLine(to: point(13.8, 11.8))
        path.addLine(to: point(12, 18))
        path.addLine(to: point(10.2, 11.8))
        path.addLine(to: point(4, 10))
        path.addLine(to: point(10.2, 8.2))
        path.closeSubpath()
        return path
    }
}

/// The waveform: five rounded bars, tallest in the middle. This is the **listening** mark, and the
/// only red thing on the screen.
///
/// It is a waveform rather than a dot or a sparkle because a dot reads as a generic status light and
/// the sparkle already means Generate. A waveform says "audio is being listened to" with no label,
/// which is why there is no REC badge and no timer anywhere on this screen.
///
/// `levels` are 0...1 bar heights. Passing different levels is how the mark moves.
struct WaveformShape: Shape {
    var levels: [CGFloat] = [0.45, 0.75, 1.0, 0.65, 0.35]

    /// Lets the bars animate smoothly between level sets.
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get {
            AnimatablePair(
                AnimatablePair(level(0), level(1)),
                AnimatablePair(level(2), AnimatablePair(level(3), level(4)))
            )
        }
        set {
            levels = [
                newValue.first.first,
                newValue.first.second,
                newValue.second.first,
                newValue.second.second.first,
                newValue.second.second.second
            ]
        }
    }

    private func level(_ index: Int) -> CGFloat {
        index < levels.count ? levels[index] : 0.5
    }

    func path(in rect: CGRect) -> Path {
        let barCount = 5
        let spacing = rect.width / CGFloat(barCount * 2 - 1)
        let barWidth = spacing
        var path = Path()
        for index in 0..<barCount {
            let height = max(rect.height * min(max(level(index), 0.12), 1), barWidth)
            let x = rect.minX + CGFloat(index) * spacing * 2
            let y = rect.midY - height / 2
            path.addRoundedRect(
                in: CGRect(x: x, y: y, width: barWidth, height: height),
                cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2)
            )
        }
        return path
    }
}

/// The listening mark in the header.
///
/// - `.live` — the red waveform, moving gently.
/// - `.paused` — the same waveform, flattened and grey. **Never red**: red means audio is being
///   listened to right now.
/// - `.off` — absent entirely, so there is no mark to misread.
///
/// The movement honours Reduce Motion: with it on, the bars simply hold a static shape.
struct RecordingMark: View {
    let state: RecordingState
    /// Scripted playback rather than a microphone. The mark still moves — something is arriving —
    /// but it is never red, because nothing is being listened to.
    var isSimulatedSource = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0

    private static let animationLevels: [[CGFloat]] = [
        [0.40, 0.80, 1.00, 0.60, 0.30],
        [0.70, 0.35, 0.65, 1.00, 0.55],
        [0.30, 1.00, 0.45, 0.70, 0.85]
    ]

    var body: some View {
        if state == .off {
            EmptyView()
        } else {
            WaveformShape(levels: levels)
                .fill(color)
                .frame(width: 16, height: 13)
                .animation(isStill ? nil : .easeInOut(duration: 0.55), value: phase)
                .task(id: state == .live && !isStill) {
                    guard state == .live, !isStill else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(550))
                        guard !Task.isCancelled else { return }
                        phase = (phase + 1) % Self.animationLevels.count
                    }
                }
                .accessibilityLabel(accessibilityLabel ?? "")
                .accessibilityHidden(accessibilityLabel == nil)
        }
    }

    /// Never claims the microphone is open when it is not.
    private var accessibilityLabel: String? {
        guard let base = state.accessibilityLabel else { return nil }
        return isSimulatedSource ? (state == .live ? "Demo playback" : "Demo playback paused") : base
    }

    /// Reduce Motion, or a UI test that needs the app to reach idle.
    private var isStill: Bool { reduceMotion || InterviewTestingFlags.quietMotion }

    private var levels: [CGFloat] {
        guard state == .live else { return [0.22, 0.30, 0.34, 0.30, 0.22] }   // paused: flattened
        guard !isStill else { return Self.animationLevels[0] }
        return Self.animationLevels[phase]
    }

    private var color: Color {
        // Red is reserved for a microphone that is genuinely open. Scripted playback gets the muted
        // tone, so the demo can never be mistaken for a recording.
        guard !isSimulatedSource else { return InterviewTheme.Color.recordingPaused }
        return state == .live ? InterviewTheme.Color.recording : InterviewTheme.Color.recordingPaused
    }
}
