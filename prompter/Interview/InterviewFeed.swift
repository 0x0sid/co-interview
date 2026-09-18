import Foundation

/// What the interview screen consumes. One seam, so the screen has no idea whether an interview is
/// scripted, replayed or live.
///
/// **Detection and generation are separate.** A feed may announce questions on its own — that is what
/// listening does — but it never writes an answer unless the screen asks for one through
/// `requestAnswer`. Nothing on this screen produces an answer without a deliberate tap on Generate.
///
/// Every answer exchange carries a `requestID`. It is what makes a late chunk from a cancelled or
/// superseded generation identifiable and therefore ignorable: the screen drops anything whose
/// request it is no longer waiting for, so a stale event can never write into the page the user is
/// reading now.
enum InterviewFeedEvent: Sendable {
    /// A line of interview speech.
    case transcriptLine(TranscriptLine)
    /// A question was detected. It has **no answer** — generating one is a separate, manual action.
    case questionDetected(InterviewQuestion)
    /// A requested generation has begun. The screen creates the answer version at this point.
    case answerStarted(requestID: UUID, questionID: UUID)
    /// More answer text, revealed progressively.
    case answerChunk(requestID: UUID, text: String)
    /// The answer is finished: its final blocks **in their original order**, code cards included
    /// where they belong between paragraphs.
    case answerCompleted(requestID: UUID, blocks: [AnswerBlock], highlight: String?)
    /// The generation did not produce an answer. Said plainly rather than left spinning.
    case answerFailed(requestID: UUID, message: String)
}

@MainActor
protocol InterviewFeed: AnyObject {
    /// One stream per feed; the screen consumes it for the life of the session.
    var events: AsyncStream<InterviewFeedEvent> { get }
    var isPaused: Bool { get }

    func start()
    func pause()
    func resume()
    func restart()
    /// 0.5 or 1.0 in the demo controls.
    func setSpeed(_ multiplier: Double)

    /// Asks for an answer to one question. The feed replies with `answerStarted`, `answerChunk`…,
    /// then `answerCompleted` or `answerFailed`, all carrying this `requestID`.
    func requestAnswer(requestID: UUID, question: InterviewQuestion, isRegeneration: Bool)
    /// Abandons a request. Any event already in flight for it is still tagged with its id, so the
    /// screen can recognise and discard it.
    func cancelAnswer(requestID: UUID)
}
