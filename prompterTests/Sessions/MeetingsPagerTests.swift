import Foundation
import SwiftData
import Testing
@testable import prompter

/// Home's Meetings: newest five first, then five more at a time, no duplicates, and a deletion
/// refilled from the next meeting.
@MainActor
struct MeetingsPagerTests {
    typealias S = SessionTestSupport

    static func context(meetings count: Int) throws -> (ModelContext, [InterviewSessionRecord]) {
        let context = ModelContext(try S.container())
        var made: [InterviewSessionRecord] = []
        for n in 0..<count {
            let record = InterviewSessionStore.create(in: context, language: .english, preference: .system)
            record.title = "Meeting \(n)"
            record.lastActivityAt = Date(timeIntervalSince1970: 1_790_000_000 + Double(n) * 60)   // n = newer
            made.append(record)
        }
        try context.save()
        return (context, made)
    }

    @Test(arguments: [0, 1, 4, 5, 6, 12])
    func homeShowsAtMostFiveNewestFirst(_ count: Int) throws {
        let (context, _) = try Self.context(meetings: count)
        let pager = MeetingsPager()
        pager.reload(in: context)
        #expect(pager.meetings.count == min(5, count))
        #expect(pager.total == count)
        #expect(pager.hasMore == (count > 5), "no loader when everything fits — exactly 5 shows none")
        let dates = pager.meetings.map(\.lastActivityAt)
        #expect(dates == dates.sorted(by: >), "newest first")
    }

    @Test
    func scrollingLoadsFiveMoreUntilEveryMeetingIsShown() throws {
        let (context, made) = try Self.context(meetings: 12)
        let pager = MeetingsPager()
        pager.reload(in: context)
        pager.loadMore(in: context)
        #expect(pager.meetings.count == 10)
        pager.loadMore(in: context)
        #expect(pager.meetings.count == 12, "the last batch is smaller than five")
        #expect(!pager.hasMore)
        pager.loadMore(in: context)
        #expect(pager.meetings.count == 12, "loading stops once exhausted")
        #expect(Set(pager.meetings.map(\.id)).count == 12, "no duplicates")
        #expect(pager.meetings.first?.id == made.last?.id, "the newest is first")
    }

    @Test
    func deletingRefillsThePageFromTheNextMeeting() throws {
        let (context, made) = try Self.context(meetings: 7)
        let pager = MeetingsPager()
        pager.reload(in: context)
        let shown = pager.meetings.map(\.id)
        InterviewSessionStore.delete(made[6], in: context)             // the newest, on screen
        pager.reload(in: context)
        #expect(pager.meetings.count == 5, "still a full page")
        #expect(!pager.meetings.contains { $0.id == made[6].id })
        #expect(pager.meetings.last?.id == made[1].id, "the next meeting moved up")
        #expect(pager.total == 6)
        #expect(Set(shown).subtracting([made[6].id]).isSubset(of: Set(pager.meetings.map(\.id))))
    }

    @Test
    func seeAllUsesLargerBatchesOverTheSameHistory() throws {
        let (context, _) = try Self.context(meetings: 12)
        let all = MeetingsPager(batchSize: 20)
        all.reload(in: context)
        #expect(all.meetings.count == 12 && !all.hasMore, "every meeting, complete")
    }
}
