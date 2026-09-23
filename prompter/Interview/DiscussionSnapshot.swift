import Foundation

/// What one Generate tap is answering: the whole session, with the answered/new boundary kept.
///
/// **Why the boundary is part of the snapshot.** A single flat list of transcript lines cannot
/// express the two things a request needs at once, and collapsing them broke the answer both ways:
///
/// - Sending only the *new* lines threw away the discussion they belong to. "And Java 9." — spoken
///   after "could you explain the difference between Java and Java 8" — arrived at the model as the
///   whole request, and came back as an answer about Java 9 alone.
/// - Sending *everything* as new made every tap re-answer the whole session. Each new tap picked up
///   every interrogative line in the window, including ones already answered on earlier pages.
///
/// So the snapshot carries both, labelled. `background` is discussion already covered by an earlier
/// request: context, never a question to answer again. `newInput` is what has been said since, and
/// is what this request is asked to resolve — read against the background behind it.
///
/// **Already answered means "do not request it twice", not "forget it".** Background is sent in
/// full. It is what makes "and Java 7" a third item in a comparison rather than a topic of its own.
struct DiscussionSnapshot: Sendable, Equatable {
    /// Lines already covered by an earlier request, oldest first. Context only.
    var background: [String] = []
    /// Lines not yet covered by any request, oldest first. What this request resolves.
    var newInput: [String] = []
    /// The utterance still being spoken when the tap happened, if any.
    ///
    /// Kept apart from `newInput` because it is *provisional*: the recogniser may still revise it.
    /// It travels so that tapping mid-sentence answers the sentence being said rather than the one
    /// before it, and it is carried **once** — when the recogniser finalizes it, it becomes an
    /// ordinary `newInput` line on the next snapshot rather than a second copy of the same speech.
    var provisional: String?
    /// Answers already suggested in this session, oldest first.
    ///
    /// Labelled to the model as its own earlier suggestions, never as something the speaker said:
    /// they were on screen, they may have been read aloud, and a follow-up like "give me an example"
    /// often refers to one — but they are not evidence about the speaker.
    var priorSuggestions: [String] = []
    /// A note the speaker typed for this session.
    var note: String = ""
    /// Identifiers of images prepared for this request.
    var attachmentIDs: [String] = []
    /// A follow-up the speaker tapped ("give an example"), rather than something they said.
    ///
    /// Kept apart from speech for the same reason background is kept apart from new input: the
    /// transcript is the record of what was said in the room, and a tapped chip was not said.
    var requestedAction: String?
    /// Which answer the tapped action was about.
    ///
    /// **The chip belongs to a page, not to "the latest answer".** Browsing back to question two and
    /// tapping "give an example" means an example of *that* answer, and speech arriving in the room
    /// meanwhile must not silently retarget it. The page's own question and answer version travel
    /// with the request so the model resolves the action against the right thing.
    var actionParentQuestion: String?
    var actionParentAnswer: String?
    var actionParentAnswerVersion: Int?
    /// An accepted, applicable decision about `newInput`, taken from the tracker **at the tap** and
    /// fixed with the rest of the snapshot. Nil means the request is built as with decisions off.
    var interpretation: RequestInterpretation?

    /// The whole conversation, oldest first — speech only, in the order it was said.
    var allLines: [String] { background + newInput + (provisional.map { [$0] } ?? []) }

    /// What this request is being asked to resolve, oldest first.
    var newLines: [String] { newInput + (provisional.map { [$0] } ?? []) }

    var isEmpty: Bool { allLines.isEmpty }

    init(
        background: [String] = [],
        newInput: [String] = [],
        provisional: String? = nil,
        priorSuggestions: [String] = [],
        note: String = "",
        attachmentIDs: [String] = [],
        requestedAction: String? = nil,
        actionParentQuestion: String? = nil,
        actionParentAnswer: String? = nil,
        actionParentAnswerVersion: Int? = nil
    ) {
        self.background = background
        self.newInput = newInput
        self.provisional = provisional
        self.priorSuggestions = priorSuggestions
        self.note = note
        self.attachmentIDs = attachmentIDs
        self.requestedAction = requestedAction
        self.actionParentQuestion = actionParentQuestion
        self.actionParentAnswer = actionParentAnswer
        self.actionParentAnswerVersion = actionParentAnswerVersion
    }

    /// Everything as new input. Convenience for callers with no coverage information.
    init(_ lines: [String]) {
        self.init(background: [], newInput: lines)
    }
}
