import Foundation
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import prompter

/// Real answers from the configured backend, grounded in session files. Opt-in
/// (`TEST_RUNNER_COINTERVIEW_LIVE_GROUNDING=1`): two small billed requests. The CV and the job
/// description are synthetic.
@MainActor
struct LiveGroundingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COINTERVIEW_LIVE_GROUNDING"] == "1"))
    func answersUseTheCVAndTheJobDescription() async throws {
        let configuration = ProviderConfiguration.resolve()
        guard case .backend = configuration.availability else {
            Issue.record("no backend configured in this build")
            return
        }
        let context = ModelContext(try SessionTestSupport.container())
        let (files, _, _, _) = SessionTestSupport.files(context: context)
        files.importData(Data(FileContextRequestTests.cv.utf8), filename: "cv.txt", type: .plainText)
        files.importData(Data(FileContextRequestTests.jobDescription.utf8), filename: "job.txt", type: .plainText)
        await files.waitUntilIdle()

        let coordinator = CopilotSessionCoordinator(
            project: files.fileContext, provider: configuration.makeProvider(),
            audio: InterviewAudioInput(makeService: { FakeTranscriptionService(results: []) }), generationMode: .manual)
        let model = InterviewScreenModel(mode: .live, feed: LiveInterviewFeed(coordinator: coordinator))
        model.files = files
        model.start()

        var report: [String] = []
        for (index, question) in ["Tell me about yourself.", "Why am I a good fit for this role?"].enumerated() {
            let before = model.transcript.count
            coordinator.ingest(CopilotTestSupport.finalDelta(question, at: TimeInterval(1 + index * 10)))
            try await CopilotTestSupport.waitUntil("the line") { model.transcript.count > before }
            model.generate(now: Date(timeIntervalSince1970: 1_000 + Double(index) * 20))
            let deadline = ContinuousClock.now + .seconds(60)
            while ContinuousClock.now < deadline,
                  !(model.questions.filter { $0.selectedAnswer?.isComplete == true }.count > index || model.generationFailure != nil) {
                try await Task.sleep(for: .milliseconds(200))
            }
            if ContinuousClock.now >= deadline {
                let versions = coordinator.cards.flatMap(\.versions).map { "\($0.status) committed=\($0.committedText.count) route=\(String(describing: $0.route))" }
                print("STATE questions=\(model.questions.map { "\($0.text) answers=\($0.answers.count) complete=\($0.selectedAnswer?.isComplete ?? false)" }) versions=\(versions) notice=\(coordinator.lastProviderNotice ?? "-")")
                Issue.record("no answer within 60 s"); return
            }
            if let failure = model.generationFailure { Issue.record("generation failed: \(failure)"); print("FAILURE: \(failure)"); return }
            // The real detector may add a detected-question page after the Generate page; the answer
            // is on the page that has one.
            let answeredPages = model.questions.filter { $0.selectedAnswer?.isComplete == true }
            let answer = try #require(answeredPages[index].selectedAnswer)
            let provenance = answer.provenance
            report.append("Q: \(question)\nincluded: \(provenance?.included.map { "\($0.filename) \($0.locator)" } ?? [])\ncited: \(provenance?.citedPassageIDs ?? [])")
            #expect(provenance?.included.contains { $0.filename == "cv.txt" } == true, "the CV was not in the request")
        }
        print("LIVE GROUNDING\n" + report.joined(separator: "\n\n"))
        let answered = model.questions.compactMap { $0.selectedAnswer?.isComplete == true ? $0.selectedAnswer?.proseText : nil }
        print("FINAL ANSWERS\n" + model.questions.map { "[\($0.text)] \($0.selectedAnswer?.proseText ?? "-")" }.joined(separator: "\n"))
        let first = answered.first ?? ""
        #expect(first.contains("Zephyr") || first.contains("Kafka") || first.contains("Brightbank"), "the answer did not use the CV")
        let second = answered.last ?? ""
        #expect(second.contains("Northwind") || second.localizedCaseInsensitiveContains("event") || second.contains("Kafka"),
                "the fit answer did not use the job description")
        model.stop()
    }
}
