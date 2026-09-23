import Foundation

/// A scripted interview, played back on a timer. **No microphone, no network, no provider.**
///
/// It exists so the v2.5 screen can be built, reviewed and tested as UI before any live pipeline is
/// wired to it. The timing is deliberately slow enough to watch: a transcript line every two or
/// three seconds, and the question detected about a second after the line that asked it.
///
/// **It detects; it does not answer.** Playing the script produces transcript lines and detected
/// questions and stops there. An answer is written only when the screen calls `requestAnswer`, which
/// only happens when someone taps Generate. That is the whole point of the split: nothing on this
/// screen can produce an answer by itself, in the demo or later in a live session.
///
/// The content is synthetic — an invented candidate talking about an invented service. Nothing here
/// came from a real interview.
@MainActor
final class DemoInterviewFeed: InterviewFeed {
    let events: AsyncStream<InterviewFeedEvent>
    private let continuation: AsyncStream<InterviewFeedEvent>.Continuation

    private(set) var isPaused = false
    private var speed: Double = 1
    private let script: [Exchange]
    private var task: Task<Void, Never>?
    /// In-flight generations, so cancelling one actually stops its text arriving.
    private var generations: [UUID: Task<Void, Never>] = [:]
    /// Which script entry answers which question, matched on the question's text.
    private var answersByQuestionText: [String: Exchange] = [:]

    init(script: [Exchange] = Exchange.demoScript) {
        self.script = script
        (events, continuation) = AsyncStream<InterviewFeedEvent>.makeStream(bufferingPolicy: .unbounded)
        for exchange in script + Exchange.generatedExtras {
            answersByQuestionText[exchange.question] = exchange
        }
    }

    deinit {
        continuation.finish()
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.play() }
    }

    func pause() { isPaused = true }
    func resume() { isPaused = false }

    func restart() {
        task?.cancel()
        task = nil
        for generation in generations.values { generation.cancel() }
        generations = [:]
        isPaused = false
        start()
    }

    /// 0.5× is the slow setting; waits are divided by this, so a larger number plays faster.
    func setSpeed(_ multiplier: Double) {
        speed = max(0.25, min(4, multiplier))
    }

    // MARK: - Generation, only when asked

    func requestAnswer(requestID: UUID, question: InterviewQuestion, isRegeneration: Bool) {
        let exchange = answersByQuestionText[question.text]
        generations[requestID] = Task { [weak self] in
            await self?.generate(requestID: requestID, question: question, exchange: exchange, isRegeneration: isRegeneration)
        }
    }

    /// The demo answers the discussion by picking the scripted exchange whose question appears in
    /// the transcript, so Generate behaves the same way it does live: no detection required.
    func requestAnswerForDiscussion(requestID: UUID, discussion: DiscussionSnapshot, questionID: UUID) {
        let joined = discussion.allLines.joined(separator: " ")
        let exchange = script.first { joined.contains($0.question) } ?? Exchange.generatedExtras.first
        let question = exchange?.question ?? "The discussion so far"
        continuation.yield(.answerTopicResolved(requestID: requestID, topic: question))
        generations[requestID] = Task { [weak self] in
            await self?.generate(
                requestID: requestID,
                question: InterviewQuestion(id: questionID, text: question),
                exchange: exchange,
                isRegeneration: false
            )
        }
    }

    func cancelAnswer(requestID: UUID) {
        generations[requestID]?.cancel()
        generations[requestID] = nil
    }

    private func generate(requestID: UUID, question: InterviewQuestion, exchange: Exchange?, isRegeneration: Bool) async {
        continuation.yield(.answerStarted(requestID: requestID, questionID: question.id))

        guard let exchange else {
            // A question the script has no answer for. Saying so is better than inventing one.
            guard await wait(seconds: 0.6) else { return }
            continuation.yield(.answerFailed(
                requestID: requestID,
                message: "The demo script has no answer for this question."
            ))
            generations[requestID] = nil
            return
        }

        // Reveal the prose in chunks over roughly three seconds. The code card arrives whole with
        // the completion event — a half-written code sample would be worse than none.
        let chunks = exchange.proseChunks
        let perChunk = chunks.isEmpty ? 0 : 3.0 / Double(chunks.count)
        for chunk in chunks {
            guard await wait(seconds: perChunk) else { return }
            continuation.yield(.answerChunk(requestID: requestID, text: chunk))
        }
        guard !Task.isCancelled else { return }
        continuation.yield(.answerCompleted(
            requestID: requestID,
            blocks: isRegeneration ? exchange.regeneratedBlocks : exchange.blocks,
            highlight: exchange.highlight
        ))
        generations[requestID] = nil
    }

    // MARK: - Playback

    private func play() async {
        for exchange in script {
            if Task.isCancelled { return }
            await announce(exchange)
        }
    }

    private func announce(_ exchange: Exchange) async {
        for line in exchange.leadIn {
            guard await wait(seconds: 2.4) else { return }
            continuation.yield(.transcriptLine(TranscriptLine(text: line)))
        }
        guard await wait(seconds: 2.4) else { return }

        let question = InterviewQuestion(text: exchange.question, followUps: exchange.followUps)
        continuation.yield(.transcriptLine(TranscriptLine(
            text: exchange.question,
            isDetectedQuestion: true,
            questionID: question.id
        )))
        guard await wait(seconds: 1.0) else { return }
        continuation.yield(.questionDetected(question))
    }

    /// Sleeps, honouring pause and speed. Returns false if the task was cancelled.
    private func wait(seconds: Double) async -> Bool {
        var remaining = seconds / speed
        let step = 0.1
        while remaining > 0 {
            if Task.isCancelled { return false }
            if isPaused {
                // Paused means nothing new arrives; hold without consuming the wait.
                try? await Task.sleep(for: .seconds(step))
                continue
            }
            try? await Task.sleep(for: .seconds(step))
            remaining -= step
        }
        return !Task.isCancelled
    }
}

extension DemoInterviewFeed {
    /// One scripted question and the answer the demo will give **if asked**.
    struct Exchange: Sendable {
        /// Transcript lines spoken before the question, so the strip has something to show.
        var leadIn: [String]
        var question: String
        /// Prose and code **in the order they are meant to appear**. A code card that belongs
        /// between two paragraphs stays between them.
        var blocks: [AnswerBlock]
        var highlight: String?
        var followUps: [FollowUp]
        /// What a second attempt says. Different text, so "v2" is visibly a new answer rather than
        /// the same words relabelled.
        var regenerated: [AnswerBlock]?

        var regeneratedBlocks: [AnswerBlock] { regenerated ?? blocks }

        /// The prose, cut into revealing chunks.
        var proseChunks: [String] {
            blocks.compactMap { block -> String? in
                if case .prose(let text) = block { return text }
                return nil
            }
            .flatMap { paragraph in
                paragraph
                    .split(separator: " ")
                    .chunked(into: 12)
                    .map { $0.joined(separator: " ") }
            }
        }
    }
}

extension DemoInterviewFeed.Exchange {
    /// Three technical questions plus one project discussion, as the design board shows.
    /// Entirely invented content.
    static let demoScript: [Self] = [
        Self(
            leadIn: [
                "Thanks for making the time today — I'll keep this fairly practical.",
                "I've read through the service you described in your notes."
            ],
            question: "How do you handle backpressure when the upstream produces faster than you can write?",
            blocks: [
                .prose("We bound the queue rather than the producer. A BoundedQueue of 512 items gives the writer somewhere to pull batches from, and when it reaches its limit the producer blocks instead of buffering without limit."),
                .code("""
                let queue = BoundedQueue(capacity: 512)

                for await batch in upstream {
                    try await queue.enqueue(batch)   // suspends when full
                }
                """),
                .prose("So memory stays flat under load, and slowness shows up as latency rather than as an out-of-memory crash at three in the morning. The capacity is a deliberate choice: we sized it from the p99 write time.")
            ],
            highlight: "bound the queue",
            followUps: [
                FollowUp(likelihood: .likely, text: "What happens to in-flight batches when the writer fails?"),
                FollowUp(likelihood: .possible, text: "How did you pick 512?"),
                FollowUp(likelihood: .lessLikely, text: "Have you considered dropping instead of blocking?")
            ],
            regenerated: [
                .prose("The producer is never the thing we slow down by hand. The queue has a fixed capacity, and enqueueing suspends once it is full, so backpressure travels upstream on its own."),
                .code("""
                let queue = BoundedQueue(capacity: 512)
                try await queue.enqueue(batch)       // suspends when full
                """),
                .prose("What that buys us is a flat memory profile and an honest latency number. A slow writer becomes visible as waiting, which is something we can alert on.")
            ]
        ),
        Self(
            leadIn: [
                "That makes sense. Let's stay on the data path for a moment."
            ],
            question: "How do you make sure a retry doesn't write the same record twice?",
            blocks: [
                .prose("Every record carries an idempotency key derived from its source offset, and the writer upserts on that key. A retry of a batch that partially landed converges to the same final state instead of duplicating the half that succeeded."),
                .prose("We keep the keys for a week, comfortably longer than the longest retry window we allow, and we measure duplicate-key hits so a rise in retries is visible before anyone reports it.")
            ],
            highlight: "idempotency key",
            followUps: [
                FollowUp(likelihood: .likely, text: "What's the cost of that upsert at your write volume?"),
                FollowUp(likelihood: .possible, text: "How do you handle a source that replays offsets?")
            ]
        ),
        Self(
            leadIn: [
                "Good. One more on the technical side before we talk about the project itself."
            ],
            question: "How would you debug a job that's slow only in production?",
            blocks: [
                .prose("I start by refusing to guess. The first move is to get the production job to tell me where its time goes — a span per stage, sampled, not a full trace — and compare the shape against a local run of the same input."),
                .prose("Nine times out of ten the difference isn't the code, it's the data: a skewed partition, a cold cache, or a neighbour on the same host. That distinction is what decides whether you optimise or reschedule.")
            ],
            highlight: "refusing to guess",
            followUps: [
                FollowUp(likelihood: .likely, text: "What if the slowdown doesn't reproduce with sampling on?"),
                FollowUp(likelihood: .lessLikely, text: "Which tracing tools have you used?")
            ]
        ),
        Self(
            leadIn: [
                "Let's switch. I'd like to hear about the project in your portfolio."
            ],
            question: "Tell me about the ingestion project — what were you actually responsible for?",
            blocks: [
                .prose("I owned the write path end to end: the queue, the writer, the schema migrations and the on-call runbook that went with them. Three of us worked on the service; the parts either side of mine were the connector library and the query layer."),
                .prose("The part I'd point at is the migration. We moved a live table without a maintenance window by writing to both shapes for a fortnight, backfilling behind it, and cutting reads over once the row counts agreed."),
                .prose("It was slower than a big-bang switch, and nobody had to be awake for it.")
            ],
            highlight: "owned the write path",
            followUps: [
                FollowUp(likelihood: .likely, text: "What would you do differently next time?"),
                FollowUp(likelihood: .possible, text: "Who decided the fortnight?"),
                FollowUp(likelihood: .lessLikely, text: "How big was the table?")
            ]
        )
    ]

    /// Kept for questions outside the four scripted ones, so a question typed or detected late still
    /// has something to say rather than failing.
    static let generatedExtras: [Self] = [
        Self(
            leadIn: [],
            question: "What would you want to know before joining the team?",
            blocks: [
                .prose("Two things: what the on-call load actually looks like in a normal week, and who decides when something is finished. The first tells me whether the system is healthy; the second tells me how the team makes decisions.")
            ],
            highlight: "who decides when something is finished",
            followUps: [
                FollowUp(likelihood: .possible, text: "What's your read on our on-call from the outside?")
            ]
        )
    ]
}

private extension Array {
    /// Even-sized slices, last one short. Used only to cut the demo answer into reveal chunks.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
