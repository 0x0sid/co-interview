import Foundation

/// The project context of a **live** session that has no imported documents.
///
/// Live sessions used to run on `SyntheticProjectFixture` — the fictional Northbridge transport
/// programme, or the fictional cardiology review in French. That fixture exists so the pipeline and
/// the evaluation harness have something to chew on; it was never meant to reach a real interview.
/// It did, and the consequences were exactly what you would expect: every live answer request
/// carried a stranger's instructions ("I am interviewing for programme lead of the Northbridge bus
/// corridor. Answer in the first person…") and five fictional passages the model was told to prefer
/// over general claims. Answers were personalised to a person who does not exist.
///
/// So live sends this instead: a real project identity, no instructions, and no passages. The
/// backend represents that as the ordinary case — a session with no imported documents — rather than
/// as a deficiency, so general questions are still answered normally while claims about the speaker
/// still require evidence.
///
/// **This is not document import.** It is the honest empty state that import will later fill: when
/// `passages(forQuestion:limit:)` has real documents behind it, nothing else in the coordinator, the
/// generator or the screen needs to change. Text the speaker types and images they attach are
/// carried separately, as the session note and attachments, and are unaffected by this.
struct LiveSessionContext: ProjectContextProviding {
    let projectID = "live-session"
    let projectName = "Live session"

    /// Empty on purpose. A live session has no speaker-written instructions until there is a place
    /// to write them; the backend falls back to a neutral register rather than inventing a role.
    let instructions = ""

    let language: InterviewLanguage

    /// Always empty: there are no imported documents yet, and inventing some is the bug this type
    /// exists to prevent.
    func passages(forQuestion question: String, limit: Int) -> [ProjectPassage] { [] }
}
