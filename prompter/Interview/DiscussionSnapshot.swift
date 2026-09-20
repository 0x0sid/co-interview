import Foundation

/// What one Generate tap is answering, with the answered/new boundary kept intact.
///
/// **Why the boundary is part of the snapshot.** A single flat list of transcript lines cannot
/// express the two things a request needs at once, and collapsing them broke the answer both ways:
///
/// - Sending only the *new* lines threw away the discussion they belong to. "In Java" — spoken a
///   moment after "could you tell me more about what's an Ash map and how to make it" — arrived at
///   the model as a complete question on its own, and came back as a standalone answer about Java in
///   general, with an invented first-person introduction attached.
/// - Sending *everything* made every tap re-answer the whole session. Each new tap picked up every
///   interrogative line in the window, including the ones already answered on earlier pages.
///
/// So the snapshot carries both, labelled. `background` is discussion already covered by an earlier
/// request: context, never a question to answer again. `newInput` is what has been said since, and
/// is the only thing this request is asked to answer — read, when it is a fragment or a correction,
/// against the background behind it.
struct DiscussionSnapshot: Sendable, Equatable {
    /// Lines already covered by an earlier request, oldest first. Context only.
    var background: [String] = []
    /// Lines not yet covered by any request, oldest first. What this request answers.
    var newInput: [String] = []

    /// The whole window, oldest first — what the model sees as the conversation.
    var allLines: [String] { background + newInput }

    var isEmpty: Bool { background.isEmpty && newInput.isEmpty }

    /// A snapshot with no answered history behind it, for a first tap or a test.
    init(background: [String] = [], newInput: [String] = []) {
        self.background = background
        self.newInput = newInput
    }

    /// Everything as new input. Convenience for callers that have no coverage information.
    init(_ lines: [String]) {
        self.init(background: [], newInput: lines)
    }
}
