import Foundation
import SwiftData
import Testing
@testable import prompter

@MainActor
struct HistoryReviewTests {
    typealias S = SessionTestSupport

    private func session(_ context: ModelContext, lines: [String]) -> InterviewSessionRecord {
        let record = InterviewSessionStore.create(in: context, language: .english, preference: .system)
        for (order, text) in lines.enumerated() {
            let utterance = SessionUtteranceRecord(line: TranscriptLine(text: text, isFinal: true), order: order)
            utterance.session = record
            record.utterances.append(utterance)
        }
        try? context.save()
        return record
    }

    @Test
    func theTranscriptExportKeepsWordingAndOrderAndInventsNoTimes() throws {
        let context = ModelContext(try S.container())
        let record = session(context, lines: ["Why Kafka?", "Because we needed replay — and ordering.", "Thanks."])
        let text = TranscriptExport.text(of: record)
        let body = text.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n")
        #expect(body == "Why Kafka?\nBecause we needed replay — and ordering.\nThanks.\n")
        #expect(text.contains("Per-line times are not recorded"))
        let url = try #require(TranscriptExport.file(for: record))
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }

    @Test
    func aSavedReviewRoundTripsAndKnowsWhenTheInterviewContinued() throws {
        let context = ModelContext(try S.container())
        let record = session(context, lines: ["Why Kafka?", "Replay and ordering."])
        let store = InterviewReviewStore(folder: S.temporaryDirectory())
        let report = InterviewReviewReport(version: "v", attributed: false, topics: ["Kafka"], questions: [], key_points: [],
                                           strengths: [], improvements: [], practice_questions: [], scores: nil,
                                           score_note: "Unscored conversation summary", disclaimer: "AI coaching feedback, not a hiring prediction.")
        let saved = InterviewReviewRecord(sessionID: record.id, createdAt: .now, sourceLineCount: 2,
                                          sourceLastActivity: record.lastActivityAt, candidateLineOrders: [1], report: report)
        try store.save(saved)
        #expect(store.load(record.id) == saved)
        #expect(!saved.coversEarlierSnapshot(of: record))

        let more = SessionUtteranceRecord(line: TranscriptLine(text: "And Kafka Streams?", isFinal: true), order: 2)
        more.session = record
        record.utterances.append(more)
        #expect(saved.coversEarlierSnapshot(of: record), "the interview continued: the report is marked as earlier")

        store.delete(record.id)
        #expect(store.load(record.id) == nil)
    }
}
