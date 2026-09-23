import Testing
import Foundation
@testable import prompter

/// Runs the evaluation dialogues (`backend/eval/dialogues`) through the **real** app pipeline and
/// records, at every tap, the decision snapshot the tracker would send and the answer request the
/// screen actually built — so the evaluation judges exactly what the phone would send.
///
/// Opt-in: `TEST_RUNNER_DIALOGUES_DIR=<eval/dialogues>` and `TEST_RUNNER_CAPTURE_REQUESTS_DIR=<out>`.
/// Without them it does nothing. Only the provider is a stub, and it only records.
@MainActor
struct DialogueCaptureTests {
    private typealias Support = CopilotTestSupport

    private struct Dialogue: Decodable {
        struct Step: Decodable {
            var say: String?
            var final: Bool?
            var revise: Bool?
            var note: String?
            var tap: AnyJSON?
            var select: Int?
            var chip: String?
            var page: Int?
            var expect: AnyJSON?
        }
        let id: String
        let split: String
        let language: String
        let steps: [Step]
    }

    /// Opaque JSON carried through untouched: the labels belong to the evaluation, not to the app.
    struct AnyJSON: Decodable {
        let value: Any
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let object = try? container.decode([String: AnyJSON].self) { value = object.mapValues(\.value) }
            else if let array = try? container.decode([AnyJSON].self) { value = array.map(\.value) }
            else if let string = try? container.decode(String.self) { value = string }
            else if let number = try? container.decode(Double.self) { value = number }
            else if let bool = try? container.decode(Bool.self) { value = bool }
            else { value = NSNull() }
        }
    }

    @Test
    func captureEveryDialogue() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["DIALOGUES_DIR"], let out = env["CAPTURE_REQUESTS_DIR"] else { return }
        let fm = FileManager.default
        var count = 0
        for split in ["dev", "heldout", "regression"] {
            let folder = URL(fileURLWithPath: dir).appendingPathComponent(split)
            for file in try fm.contentsOfDirectory(atPath: folder.path).filter({ $0.hasSuffix(".json") }).sorted() {
                let dialogue = try JSONDecoder().decode(Dialogue.self, from: Data(contentsOf: folder.appendingPathComponent(file)))
                let taps = try await run(dialogue)
                let outFolder = URL(fileURLWithPath: out).appendingPathComponent(split)
                try fm.createDirectory(at: outFolder, withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: ["id": dialogue.id, "split": split, "language": dialogue.language, "taps": taps],
                                                      options: [.prettyPrinted, .sortedKeys])
                try data.write(to: outFolder.appendingPathComponent(file))
                count += 1
            }
        }
        #expect(count > 0)
    }

    private func run(_ dialogue: Dialogue) async throws -> [[String: Any]] {
        let provider = Support.StubProvider()
        provider.classifications = [DetectionResult(kind: .none, questionText: "", confidence: 0.9)]
        provider.answerChunks = ["(captured request; answer not generated here)"]
        let language: InterviewLanguage = dialogue.language == "fr" ? .french : .english
        let coordinator = CopilotSessionCoordinator(
            project: LiveSessionContext(language: language),
            provider: provider,
            audio: InterviewAudioInput(makeService: { FakeTranscriptionService(results: []) }),
            generationMode: .manual
        )
        let model = InterviewScreenModel(mode: .live, feed: LiveInterviewFeed(coordinator: coordinator))
        model.start()
        model.decisions.decide = nil                     // the evaluation asks for decisions itself

        let encoder = JSONEncoder()
        var clock: TimeInterval = 1
        var tapTime: TimeInterval = 0
        var requestLabels: [String: String] = [:]
        var taps: [[String: Any]] = []

        for step in dialogue.steps {
            if let text = step.say {
                if step.revise != true { clock += 3 } else { clock += 0.5 }
                let before = model.transcript.map(\.text)
                let delta = step.final == false ? Support.volatileDelta(text, at: clock) : Support.finalDelta(text, at: clock)
                coordinator.ingest(delta)
                try await Support.waitUntil("“\(text)” reached the screen") { model.transcript.map(\.text) != before }
            } else if let note = step.note {
                model.context.note = note
                model.syncSessionNote()
            } else if let index = step.select {
                model.select(questionID: model.questions[index].id)
            } else if step.tap != nil || step.chip != nil {
                let decisionSnapshot = step.tap != nil ? model.makeDecisionSnapshot() : nil
                // The stub's "answer" names what it was asked about, so a later chip's parent answer —
                // and every later request's earlier suggestions — carry their real subject, as on the
                // phone. A placeholder here sent chips a parent with no subject at all.
                let asked = model.uncoveredLines.map(\.text).joined(separator: " ")
                provider.answerChunks = [step.chip != nil
                    ? "An example about the earlier answer."
                    : "In answer to “\(asked)”: an explanation of that."]
                let before = provider.generateCallCount
                tapTime += 10
                var parentLabel: String?
                if let chip = step.chip, let page = step.page {
                    let parent = model.questions[page]
                    parentLabel = requestLabels[parent.id.uuidString]
                    model.select(questionID: parent.id)
                    let action = try #require(model.followUpActions.first { $0.id == chip }, "no \(chip) chip in \(dialogue.id)")
                    model.generate(action: action, for: parent, now: Date(timeIntervalSince1970: 50_000 + tapTime))
                } else {
                    model.generate(now: Date(timeIntervalSince1970: 50_000 + tapTime))
                }
                try await Support.waitUntil("the request in \(dialogue.id)") { provider.generateCallCount > before }
                let request = try #require(provider.lastAnswerRequest)
                if step.tap != nil, let page = model.questions.last {
                    requestLabels[page.id.uuidString] = "req\(requestLabels.count + 1)"
                    // The page title the model would report: its own words, since no model titled it here.
                    if let requestID = model.requestIDForTesting(questionID: page.id) {
                        model.handle(.answerTopicResolved(requestID: requestID, topic: asked))
                    }
                }
                var tap: [String: Any] = [
                    "kind": step.chip != nil ? "chip" : "tap",
                    "request": try JSONSerialization.jsonObject(with: encoder.encode(request)),
                    "candidateLabels": requestLabels,
                ]
                if let decisionSnapshot { tap["decisionSnapshot"] = try JSONSerialization.jsonObject(with: encoder.encode(decisionSnapshot)) }
                if let expect = step.tap?.value ?? step.expect?.value { tap["expect"] = expect }
                if let parentLabel { tap["chipParent"] = parentLabel }
                taps.append(tap)
                try await Support.waitUntil("the answer in \(dialogue.id)") {
                    model.questions.last?.selectedAnswer?.isComplete == true
                }
            }
        }
        model.stop()
        return taps
    }
}
