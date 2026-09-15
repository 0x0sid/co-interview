import SwiftUI

/// §13's mascot: "minimal geometric CRT, two simple eyes, no face/cartoon." Pure SwiftUI shapes,
/// no image assets or gradients (§13's hard bans). Appears ONLY on Home (idle/loading/success) —
/// **never on the prompt screen** (§13, §25's instant-rejection list repeats this explicitly).
struct MascotView: View {
    enum Expression {
        /// Home idle.
        case idle
        /// Loading — eyes scan side to side.
        case loading
        /// Success — eyes become crescents.
        case success
    }

    var expression: Expression = .idle
    var size: CGFloat = 64

    @State private var scanPhase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22)
            .stroke(Theme.Color.ink, lineWidth: max(2, size * 0.045))
            .background(
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(Theme.Color.card)
            )
            .frame(width: size, height: size * 0.78)
            .overlay(eyes)
            .onAppear {
                guard expression == .loading else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    scanPhase = 1
                }
            }
    }

    private var eyes: some View {
        HStack(spacing: size * 0.22) {
            eye
            eye
        }
        .offset(x: expression == .loading ? scanPhase * size * 0.08 : 0)
    }

    @ViewBuilder
    private var eye: some View {
        switch expression {
        case .idle, .loading:
            Circle()
                .fill(Theme.Color.ink)
                .frame(width: size * 0.11, height: size * 0.11)
        case .success:
            // A crescent, not a curved smiley mouth — stays an eye shape, not a face.
            Capsule()
                .fill(Theme.Color.ink)
                .frame(width: size * 0.16, height: size * 0.05)
                .rotationEffect(.degrees(-8))
        }
    }
}

#Preview {
    HStack(spacing: 24) {
        MascotView(expression: .idle)
        MascotView(expression: .loading)
        MascotView(expression: .success)
    }
    .padding(40)
    .background(Theme.Color.paper)
}
