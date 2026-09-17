import Foundation

/// Scripted, entirely synthetic interviews used to drive the pipeline without a microphone.
///
/// **No captured speech.** Every line is written for this fixture, in the spirit of the repository's
/// rule that no real utterance may enter the public tree (`CO_INTERVIEW_SNAPSHOT_NOTICE.md`). The
/// scenarios deliberately cover the cases that break naive detection: requests with no question mark,
/// questions spread over several sentences, follow-ups that reuse the answer's own words, corrections,
/// the user reading a suggestion that itself contains a question, overlapping speech, and two
/// questions in quick succession.
struct SyntheticInterview: Sendable {
    struct Line: Sendable {
        let text: String
        /// Seconds from the start of the interview.
        let at: TimeInterval
        /// What this line is, for the evaluation harness's expectations.
        let expectation: Expectation

        enum Expectation: String, Sendable {
            /// Should produce exactly one new card.
            case question
            /// Should attach to the newest card rather than creating one.
            case continuation
            /// Should produce no card at all.
            case noQuestion
        }
    }

    let name: String
    let language: InterviewLanguage
    let lines: [Line]

    var expectedQuestionCount: Int { lines.filter { $0.expectation == .question }.count }

    /// Converts the script into transcript events, including the volatile revisions a real transcriber
    /// produces — so the deduplication and detection-policy paths are exercised, not bypassed.
    func scriptedResults(volatileSteps: Int = 2) -> [FakeTranscriptionService.ScriptedResult] {
        var results: [FakeTranscriptionService.ScriptedResult] = []
        for line in lines {
            let words = line.text.split(separator: " ").map(String.init)
            guard !words.isEmpty else { continue }
            let duration = max(0.6, Double(words.count) * 0.28)
            let start = max(0, line.at - duration)
            for step in 1...volatileSteps {
                let fraction = Double(step) / Double(volatileSteps + 1)
                let count = max(1, Int(Double(words.count) * fraction))
                results.append(.init(
                    text: words.prefix(count).joined(separator: " "),
                    isFinal: false,
                    elapsed: start + duration * fraction
                ))
            }
            results.append(.init(text: line.text, isFinal: true, elapsed: line.at))
        }
        return results.sorted { $0.elapsed < $1.elapsed }
    }

    static func forLanguage(_ language: InterviewLanguage) -> SyntheticInterview {
        switch language {
        case .english: english
        case .french: french
        }
    }

    static let all: [SyntheticInterview] = [english, french]

    /// English, against `SyntheticProjectFixture.transportProgramme`.
    static let english = SyntheticInterview(
        name: "transport-panel-en",
        language: .english,
        lines: [
            .init(text: "Right, shall we start.", at: 2.0, expectation: .noQuestion),
            // A request with no question mark.
            .init(text: "Tell me about the corridor you ran before this one.", at: 7.0, expectation: .question),
            // Multi-sentence question.
            .init(text: "I want to understand the risks. What worries you most about Mill Street?", at: 26.0, expectation: .question),
            // A follow-up that reuses the answer's vocabulary — must still be recognised.
            .init(text: "And what about the depot power upgrade you just mentioned?", at: 44.0, expectation: .question),
            // Correction of the question just asked.
            .init(text: "Sorry, I meant the utility diversions, not the depot.", at: 58.0, expectation: .continuation),
            // Backchannel, not a question.
            .init(text: "Right. Understood.", at: 70.0, expectation: .noQuestion),
            // Document-specific fact.
            .init(text: "How many journeys a day does the corridor carry?", at: 76.0, expectation: .question),
            // Nothing in the documents supports this.
            .init(text: "Explain how the pension scheme transfer would work for the team.", at: 92.0, expectation: .question),
            // Two questions in quick succession.
            .init(text: "What is your timetable for signal priority?", at: 110.0, expectation: .question),
            .init(text: "And who signs off the risk note each month?", at: 114.0, expectation: .question),
        ]
    )

    /// French, against `SyntheticProjectFixture.hospitalReview`. Evaluation scope only — this is not a
    /// claim that French is supported (Q7).
    static let french = SyntheticInterview(
        name: "revue-service-fr",
        language: .french,
        lines: [
            .init(text: "Bien, nous pouvons commencer.", at: 2.0, expectation: .noQuestion),
            .init(text: "Parlez-moi de l'activité du service l'an dernier.", at: 7.0, expectation: .question),
            .init(text: "Je voudrais comprendre les délais. Comment ont-ils évolué après la réorganisation ?", at: 26.0, expectation: .question),
            .init(text: "Et pour les postes vacants dont vous parlez ?", at: 44.0, expectation: .question),
            .init(text: "En fait, je pensais au taux d'occupation, pas aux postes.", at: 58.0, expectation: .continuation),
            .init(text: "D'accord. Très bien.", at: 70.0, expectation: .noQuestion),
            .init(text: "Expliquez le protocole de suivi après l'opération.", at: 76.0, expectation: .question),
            .init(text: "Expliquez comment le budget d'investissement est voté par la région.", at: 92.0, expectation: .question),
        ]
    )

    /// A script where the **user reads a suggestion aloud** and that suggestion contains a question.
    /// Nothing here may create a card: the words are the answer text being read, not a new request.
    /// Used by `CopilotReadingOverlapTests`.
    static func userReadingAloud(of answerText: String, startingAt: TimeInterval = 5) -> [FakeTranscriptionService.ScriptedResult] {
        let sentences = answerText
            .split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var results: [FakeTranscriptionService.ScriptedResult] = []
        var time = startingAt
        for sentence in sentences {
            results.append(.init(text: sentence, isFinal: true, elapsed: time))
            time += max(1.0, Double(sentence.split(separator: " ").count) * 0.3)
        }
        return results
    }
}
