import SwiftData
import SwiftUI

/// Every meeting, newest first — what "See all" opens. The same cards and actions as Home (open,
/// rename, transcript, export, score, delete), loaded a batch at a time as the list is scrolled.
struct MeetingsListScreen<Card: View>: View {
    let pager: MeetingsPager
    @ViewBuilder let card: (InterviewSessionRecord) -> Card

    @Environment(\.modelContext) private var modelContext
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        ScrollView {
            LazyVStack(spacing: metrics.listCardSpacing) {
                ForEach(pager.meetings) { session in
                    card(session)
                }
                if pager.hasMore {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .onAppear { pager.loadMore(in: modelContext) }
                        .accessibilityLabel("Loading more meetings")
                }
            }
            .padding(.horizontal, metrics.screenPadding)
            .padding(.vertical, metrics.isCompact ? 8 : 12)
        }
        .background(Theme.Color.paper)
        .navigationTitle(pager.total > 0 ? "Meetings · \(pager.total)" : "Meetings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear { pager.reload(in: modelContext) }
        .accessibilityIdentifier("meetings-list")
    }
}
