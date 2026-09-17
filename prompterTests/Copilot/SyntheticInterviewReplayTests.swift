import Testing
import Foundation
@testable import prompter

/// Runs the scripted synthetic interviews through the **whole** pipeline — audio input, conversation
/// log, turn segmentation, detection policy, detector, retrieval, generation, reader.
///
/// The detector is scripted (`ScriptedDetectorProvider`), so what is asserted is the pipeline's own
/// guarantee: every turn the detector calls a question becomes exactly one card, in order, with none
/// lost and none duplicated — regardless of how transcript events happen to arrive.
///
/// Playback is faster than real time, but the scripted **timestamps are untouched**: compressing them
/// would erase the pauses between turns and test an interview nobody could hold.
@MainActor
struct SyntheticInterviewReplayTests {
    private func runReplay(
        _ interview: SyntheticInterview,
        project: SyntheticProject,
        provider: any CopilotProviding,
        playbackRate: Double = 40,
        until condition: @escaping (CopilotSessionCoordinator) -> Bool
    ) async throws -> CopilotSessionCoordinator {
        let results = interview.scriptedResults()
        let audio = InterviewAudioInput(makeService: {
            FakeTranscriptionService(results: results, playbackRate: playbackRate)
        })
        let coordinator = CopilotSessionCoordinator(project: project, provider: provider, audio: audio)
        coordinator.startListening()
        try await CopilotTestSupport.waitUntil("\(interview.name) replay to finish", timeout: .seconds(25)) {
            condition(coordinator)
        }
        return coordinator
    }

    /// The cards a scripted interview should produce: one per question, in order, with a correction
    /// **replacing the wording of the card it corrects** rather than opening a card of its own.
    private func expectedCardQuestions(_ interview: SyntheticInterview) -> [String] {
        var expected: [String] = []
        for line in interview.lines {
            switch line.expectation {
            case .question: expected.append(line.text)
            case .continuation: if !expected.isEmpty { expected[expected.count - 1] = line.text }
            case .noQuestion: continue
            }
        }
        return expected
    }

    @Test
    func everyScriptedQuestionBecomesExactlyOneCardInOrder() async throws {
        let interview = SyntheticInterview.english
        let expected = expectedCardQuestions(interview)
        let coordinator = try await runReplay(
            interview,
            project: SyntheticProjectFixture.transportProgramme,
            provider: CopilotTestSupport.ScriptedDetectorProvider(interview: interview)
        ) { $0.cards.count >= expected.count }

        #expect(coordinator.cards.count == expected.count, "expected one card per scripted question")
        #expect(coordinator.cards.map(\.questionText) == expected, "cards are out of order or wrong")
        #expect(Set(coordinator.cards.map(\.questionText)).count == expected.count, "a question was duplicated")
        // Focus stays where the reader left it while the rest of the interview arrives.
        #expect(coordinator.selectedCardIndex == 0)
    }

    @Test
    func theFrenchInterviewProducesACardPerScriptedQuestion() async throws {
        let interview = SyntheticInterview.french
        let expected = expectedCardQuestions(interview)
        let coordinator = try await runReplay(
            interview,
            project: SyntheticProjectFixture.hospitalReview,
            provider: CopilotTestSupport.ScriptedDetectorProvider(interview: interview)
        ) { $0.cards.count >= expected.count }

        #expect(coordinator.cards.map(\.questionText) == expected)
    }

    /// A correction attaches to the card it corrects instead of opening a new one.
    @Test
    func aScriptedCorrectionAttachesToTheExistingCard() async throws {
        let interview = SyntheticInterview.english
        let questions = interview.lines.filter { $0.expectation == .question }.count
        let coordinator = try await runReplay(
            interview,
            project: SyntheticProjectFixture.transportProgramme,
            provider: CopilotTestSupport.ScriptedDetectorProvider(interview: interview)
        ) { $0.cards.count >= questions }

        // The scripted correction follows the third question, so that card carries a second version.
        let corrected = coordinator.cards.first { $0.versions.count > 1 }
        #expect(corrected != nil, "the correction did not produce a new version on an existing card")
        #expect(coordinator.cards.count == questions, "the correction created a card of its own")
    }

    @Test
    func replayAnswersCiteOnlyPassagesThatExist() async throws {
        let interview = SyntheticInterview.english
        let project = SyntheticProjectFixture.transportProgramme
        let questions = interview.lines.filter { $0.expectation == .question }.count
        let coordinator = try await runReplay(
            interview,
            project: project,
            provider: CopilotTestSupport.ScriptedDetectorProvider(interview: interview)
        ) { $0.cards.count >= questions }

        let known = Set(project.allPassages.map(\.id))
        for card in coordinator.cards {
            for version in card.versions {
                #expect(version.sources.allSatisfy { known.contains($0.id) })
            }
        }
    }

    /// The development fake is a crude keyword stand-in, not a detector. This only checks that the
    /// harness path runs end to end and produces cards — never how many, which is a property of the
    /// stand-in rather than of the pipeline.
    @Test
    func theDevelopmentHarnessPathProducesCards() async throws {
        let interview = SyntheticInterview.english
        let coordinator = try await runReplay(
            interview,
            project: SyntheticProjectFixture.transportProgramme,
            provider: FakeCopilotProvider(firstDeltaDelay: .zero, interDeltaDelay: .zero, classificationDelay: .zero)
        ) { $0.cards.count >= 3 }

        #expect(coordinator.cards.allSatisfy { $0.latestVersion?.isDevelopmentFake == true })
    }
}
