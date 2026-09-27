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
        let report = InterviewReviewReport(version: "v", attributed: true,
                                           scores: .init(relevance: 3, clarity: 2, structure: 3, examples: 2), overall: 2.5,
                                           evidence: .init(relevance: "Replay and ordering.", clarity: "", structure: "", examples: ""),
                                           score_note: "Scored 0–4", disclaimer: "AI coaching feedback, not a hiring prediction.")
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

    /// A review saved before scores replaced the report: its narrative keys are ignored, and it opens
    /// with its score. Nothing on disk is rewritten.
    @Test
    func aReviewSavedBeforeScoreOnlyStillOpensWithItsScore() throws {
        let legacy = """
        {"sessionID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","createdAt":780000000,"sourceLineCount":4,
         "sourceLastActivity":780000000,"candidateLineOrders":[1,2,3],
         "report":{"version":"review-2026-09-27.1","attributed":true,"topics":["Kafka"],"questions":["Why Kafka?"],
           "key_points":["Replay"],"strengths":[{"point":"p","evidence":"e"}],"improvements":[{"point":"p","example":"x"}],
           "practice_questions":["q"],"scores":{"relevance":4,"clarity":3,"structure":2,"examples":3},
           "score_note":"Scored 0–4","disclaimer":"AI coaching feedback, not a hiring prediction."}}
        """
        let folder = S.temporaryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = try #require(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        let file = folder.appending(path: "\(id.uuidString).json")
        try Data(legacy.utf8).write(to: file)

        let record = try #require(InterviewReviewStore(folder: folder).load(id), "an old review must still decode")
        #expect(record.report.scores == .init(relevance: 4, clarity: 3, structure: 2, examples: 3))
        #expect(record.report.overallScore == 3.0, "the overall score is computed for an old review")
        #expect(record.report.evidence == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == legacy, "opening it does not rewrite it")
    }

    @Test
    func aScoreFromTheBackendDecodesWithItsOverallAndEvidence() throws {
        let json = """
        {"version":"score-2026-09-27.1","attributed":true,"scores":{"relevance":3,"clarity":3,"structure":2,"examples":3},
         "overall":2.8,"evidence":{"relevance":"we needed replay","clarity":"","structure":"first","examples":"forty services"},
         "score_note":"Scored 0–4","disclaimer":"AI coaching feedback, not a hiring prediction."}
        """
        let report = try JSONDecoder().decode(InterviewReviewReport.self, from: Data(json.utf8))
        #expect(report.overallScore == 2.8)
        #expect(report.evidence?.examples == "forty services")
    }

    @Test
    func tooLittleMarkedSpeechIsNotSentForScoring() {
        let long = "I led the migration of forty services to Kafka and cut delivery latency over two quarters"
        #expect(!InterviewReviewClient.canScore(markedLines: []))
        #expect(!InterviewReviewClient.canScore(markedLines: [long, long]), "two lines are too few")
        #expect(!InterviewReviewClient.canScore(markedLines: ["Yes.", "No.", "Kafka."]), "three short lines are too few words")
        #expect(InterviewReviewClient.canScore(markedLines: [long, long, long, long]))
    }
}
