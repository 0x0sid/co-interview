import SwiftUI

/// One saved interview as its own card: title, date and duration, compact counts, and the actions
/// menu. Swiping left reveals a red **Delete** button; nothing is deleted by the swipe itself — the
/// button asks first, and a full swipe does nothing more than open it.
///
/// Built for the start screen's `ScrollView` (the stable history), so it carries its own swipe rather
/// than relying on `List`.
struct InterviewHistoryCard<Menu: View>: View {
    let session: InterviewSessionRecord
    let onOpen: () -> Void
    let onDelete: () -> Void
    @ViewBuilder let menu: () -> Menu

    @Environment(\.layoutMetrics) private var metrics
    @State private var offset: CGFloat = 0
    @State private var isOpen = false
    private static var revealWidth: CGFloat { 92 }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive) {
                close()
                onDelete()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash")
                    Text("Delete").font(Typography.body(12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(width: Self.revealWidth - 8)
                .frame(maxHeight: .infinity)
                .background(Color.red, in: RoundedRectangle(cornerRadius: metrics.cardCornerRadius))
            }
            .buttonStyle(.plain)
            .opacity(offset < -8 ? 1 : 0)
            .accessibilityIdentifier("history-delete")

            card
                .offset(x: offset)
                .gesture(swipe)
        }
        .accessibilityAction(named: "Delete") { onDelete() }
    }

    private var when: some View {
        Text(Self.whenAndHowLong(session))
            .font(Typography.body(metrics.isCompact ? 12 : 13))
            .foregroundStyle(Theme.Color.secondary)
            .lineLimit(1)
    }

    private var counts: some View {
        HStack(spacing: 10) {
            Label("\(session.answeredCount)", systemImage: "text.bubble")
                .accessibilityLabel("\(session.answeredCount) answer\(session.answeredCount == 1 ? "" : "s")")
            Label("\(session.fileCount)", systemImage: "paperclip")
                .accessibilityLabel("\(session.fileCount) file\(session.fileCount == 1 ? "" : "s")")
        }
        .font(Typography.body(metrics.isCompact ? 11 : 12, weight: .medium))
        .foregroundStyle(Theme.Color.secondary)
        .fixedSize()
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: { isOpen ? close() : onOpen() }) {
                VStack(alignment: .leading, spacing: metrics.isCompact ? 2 : 4) {
                    HStack(spacing: 6) {
                        Text(session.title)
                            .font(Typography.body(metrics.isCompact ? 15 : 16, weight: .semibold))
                            .foregroundStyle(Theme.Color.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if session.state == .interrupted {
                            Text("Interrupted")
                                .font(Typography.body(11, weight: .semibold))
                                .foregroundStyle(Theme.Color.warm)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .overlay(Capsule().stroke(Theme.Color.warm, lineWidth: 1))
                        }
                    }
                    // Date and counts share one line when they fit, and stack when they do not.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            when
                            counts
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            when
                            counts
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            menu()
        }
        .padding(.horizontal, metrics.cardPadding)
        .padding(.vertical, metrics.listCardVerticalPadding)
        .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: metrics.cardCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: metrics.cardCornerRadius).stroke(Theme.Color.hairline, lineWidth: 0.5))
    }

    /// Horizontal only: a mostly vertical drag is left to the scroll view.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let base: CGFloat = isOpen ? -Self.revealWidth : 0
                // Never further than the button: a full swipe does not delete.
                offset = min(0, max(-Self.revealWidth, base + value.translation.width))
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                withAnimation(.snappy(duration: 0.2)) {
                    isOpen = offset < -Self.revealWidth / 2
                    offset = isOpen ? -Self.revealWidth : 0
                }
            }
    }

    private func close() {
        withAnimation(.snappy(duration: 0.2)) { isOpen = false; offset = 0 }
    }

    static func whenAndHowLong(_ session: InterviewSessionRecord) -> String {
        let when = session.createdAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
        let minutes = Int(session.activeSeconds / 60)
        return "\(when) · \(minutes < 1 ? "under a minute" : "\(minutes) min")"
    }
}
