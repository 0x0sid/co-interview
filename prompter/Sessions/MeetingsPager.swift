import Foundation
import Observation
import SwiftData

/// The Home screen's Meetings: the newest few, and the next batch when the reader scrolls to the end.
///
/// Local SwiftData pagination — deterministic and cheap. It fetches only `limit` records (newest
/// first) plus a count, so a long history is never loaded or rendered all at once. Deleting keeps the
/// limit, so the next meeting moves up to fill the page.
@MainActor
@Observable
final class MeetingsPager {
    static let homeBatchSize = 5

    let batchSize: Int
    private(set) var meetings: [InterviewSessionRecord] = []
    private(set) var total = 0
    private(set) var limit: Int

    init(batchSize: Int = MeetingsPager.homeBatchSize) {
        self.batchSize = batchSize
        self.limit = batchSize
    }

    var hasMore: Bool { meetings.count < total }

    private static var liveMeetings: Predicate<InterviewSessionRecord> { #Predicate { $0.modeRaw == "live" } }

    /// Re-reads the current page: after a meeting ends, is renamed or deleted, or on appear.
    func reload(in context: ModelContext) {
        var descriptor = FetchDescriptor(predicate: Self.liveMeetings,
                                         sortBy: [SortDescriptor(\.lastActivityAt, order: .reverse)])
        descriptor.fetchLimit = limit
        meetings = (try? context.fetch(descriptor)) ?? []
        total = (try? context.fetchCount(FetchDescriptor(predicate: Self.liveMeetings))) ?? meetings.count
    }

    /// The next batch, when there is one. Nothing happens once every meeting is loaded.
    func loadMore(in context: ModelContext) {
        guard hasMore else { return }
        limit += batchSize
        reload(in: context)
    }

    /// The most recent interrupted meeting, if any — called out above the list.
    static func interrupted(in context: ModelContext) -> InterviewSessionRecord? {
        let live = "live", interrupted = InterviewSessionRecord.State.interrupted.rawValue
        let predicate = #Predicate<InterviewSessionRecord> { record in
            record.modeRaw == live && record.stateRaw == interrupted
        }
        var descriptor = FetchDescriptor<InterviewSessionRecord>(predicate: predicate,
                                                                sortBy: [SortDescriptor(\.lastActivityAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
