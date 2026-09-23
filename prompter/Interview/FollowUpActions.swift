import Foundation

/// The next thing a speaker is likely to want, offered as one tap.
///
/// **Why this exists.** After an answer arrives the useful next move is almost always one of a very
/// short list — an example, more depth, less length, the code explained. Saying any of those aloud
/// means saying it *to the interviewer*, which is not something you can do. Typing it means typing
/// during an interview. A chip is the only channel that is neither.
///
/// **These are requests, not speech.** A tapped action never enters the transcript: the transcript
/// is the record of what was said in the room, and putting words there that nobody said would
/// corrupt the one thing the session is a witness to. It travels as its own field, and the prompt
/// labels it as something the speaker asked the assistant for.
///
/// **Chosen from the answer, not from a fixed list.** "Explain the code" is only offered when there
/// is code; "make it shorter" only when the answer is long enough for that to mean anything.
enum FollowUpActions {
    struct Action: Identifiable, Equatable, Sendable {
        /// Stable across rebuilds of the same answer, so SwiftUI does not animate chips around.
        let id: String
        /// What the chip says. Short enough to read without stopping.
        let title: String
        /// What is sent. Written as an instruction because that is what it is.
        let instruction: String
        let systemImage: String
    }

    /// How long an answer has to be before shortening it is a sensible thing to offer, in words.
    static let longAnswerWords = 70

    /// At most this many chips. A row of options to weigh up is the opposite of useful mid-interview.
    static let maximumActions = 3

    /// The actions worth offering for this answer.
    ///
    /// - Parameters:
    ///   - question: the entry's title — what the request was understood to be.
    ///   - blocks: the answer as shown.
    ///   - language: the interview language, so the chips read in it.
    static func actions(
        question: String,
        blocks: [AnswerBlock],
        language: InterviewLanguage
    ) -> [Action] {
        let prose = blocks.compactMap { block -> String? in
            if case .prose(let text) = block { return text }
            return nil
        }.joined(separator: " ")
        let hasCode = blocks.contains { if case .code = $0 { return true } else { return false } }
        let wordCount = prose.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let french = language == .french

        var actions: [Action] = []

        // Code first when there is code: it is the densest thing on screen and the least readable
        // aloud, so "what does this do" is the most likely next question from the room.
        if hasCode {
            actions.append(Action(
                id: "explain-code",
                title: french ? "Expliquer le code" : "Explain the code",
                instruction: french
                    ? "Explique le code que tu viens de donner, ligne par ligne, brièvement et à voix haute."
                    : "Walk through the code you just gave, briefly, in a way that reads aloud.",
                systemImage: "curlybraces"
            ))
        }

        // An example is the commonest follow-up in an interview, and it is only worth offering when
        // there is not obviously one already.
        if !mentionsExample(prose, french: french) {
            actions.append(Action(
                id: "example",
                title: french ? "Un exemple" : "Give an example",
                instruction: french
                    ? "Donne un exemple concret de ce que tu viens d'expliquer."
                    : "Give one concrete example of what you just explained.",
                systemImage: "lightbulb"
            ))
        }

        // Depth or brevity, never both: they are opposite requests and offering the pair asks the
        // speaker to make a decision they have no time to make.
        if wordCount >= longAnswerWords {
            actions.append(Action(
                id: "shorter",
                title: french ? "Plus court" : "Make it shorter",
                instruction: french
                    ? "Redis la même réponse en deux phrases au maximum."
                    : "Say the same answer again in two sentences at most.",
                systemImage: "arrow.down.right.and.arrow.up.left"
            ))
        } else {
            actions.append(Action(
                id: "deeper",
                title: french ? "Plus en détail" : "Go deeper",
                instruction: french
                    ? "Approfondis la réponse précédente : donne le détail technique qui manque."
                    : "Go deeper on that answer — add the technical detail it left out.",
                systemImage: "arrow.down.right.and.arrow.up.left.rectangle"
            ))
        }

        return Array(actions.prefix(maximumActions))
    }

    /// Whether the answer already carries an example, so the chip is not offered for something the
    /// speaker is already looking at.
    private static func mentionsExample(_ prose: String, french: Bool) -> Bool {
        let needles = french
            ? ["par exemple", "exemple :", "un exemple"]
            : ["for example", "for instance", "an example", "e.g."]
        let lowered = prose.lowercased()
        return needles.contains { lowered.contains($0) }
    }
}
