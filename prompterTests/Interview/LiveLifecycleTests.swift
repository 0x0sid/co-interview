import Foundation
import Testing
@testable import prompter

/// The lifecycle invariant: **no active interview session = no microphone, no transcription stream, no
/// detection loop.** Driven with fake transcribers whose start can be held at an explicit gate, so every
/// start/stop interleaving here is reproduced deterministically — no timing luck, no sleeps to "let the
/// race happen".
@MainActor
struct LiveLifecycleTests {
    typealias Support = CopilotTestSupport

    /// What every transcriber made for one test did, across instances.
    final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private var _starts = 0, _stops = 0, _live: [Int] = []
        /// Completed starts (the microphone was taken).
        var starts: Int { lock.withLock { _starts } }
        var stops: Int { lock.withLock { _stops } }
        /// Pipelines holding the microphone right now, by transcriber number.
        var live: [Int] { lock.withLock { _live } }
        var active: Int { live.count }
        func started(_ id: Int) { lock.withLock { _starts += 1; _live.append(id) } }
        func stopped(_ id: Int) { lock.withLock { _stops += 1; _live.removeAll { $0 == id } } }
    }

    /// Holds a start at a point the test chooses, and lets it continue when the test says so.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: CheckedContinuation<Void, Never>?
        private var isOpen = false
        private var _arrived = false
        var arrived: Bool { lock.withLock { _arrived } }

        func pass() async {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    _arrived = true
                    if isOpen { return true }
                    waiting = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func open() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                isOpen = true
                defer { waiting = nil }
                return waiting
            }
            continuation?.resume()
        }
    }

    /// Behaves like the real service where it matters: its stream stays open until it is stopped, and a
    /// `stop()` that arrives while `start()` is still preparing does **not** stop the start that follows
    /// (the real `TranscriptionService` goes on to take the microphone). Whoever started it must stop it.
    final class FakeTranscriber: Transcribing, @unchecked Sendable {
        let id: Int
        let ledger: Ledger
        let gate: Gate?
        private let lock = NSLock()
        private var continuation: AsyncStream<TranscriptDelta>.Continuation?
        private var isLive = false
        private var _startReturned = false
        var startReturned: Bool { lock.withLock { _startReturned } }

        init(id: Int, ledger: Ledger, gate: Gate?) {
            self.id = id
            self.ledger = ledger
            self.gate = gate
        }

        func start(locale: Locale, contextualStrings: [String]) async throws -> AsyncStream<TranscriptDelta> {
            if let gate { await gate.pass() }
            let (stream, continuation) = AsyncStream<TranscriptDelta>.makeStream()
            lock.withLock {
                self.continuation = continuation
                isLive = true
                _startReturned = true
            }
            ledger.started(id)
            return stream
        }

        func stop() async {
            let (wasLive, continuation) = lock.withLock { () -> (Bool, AsyncStream<TranscriptDelta>.Continuation?) in
                defer { isLive = false; self.continuation = nil }
                return (isLive, self.continuation)
            }
            if wasLive { ledger.stopped(id) }
            continuation?.finish()
        }

        func emit(_ delta: TranscriptDelta) { _ = lock.withLock { continuation }?.yield(delta) }
    }

    /// Makes transcribers in order; `gates[n]` holds the n-th start (0-based), none for the rest.
    final class Factory: @unchecked Sendable {
        let ledger: Ledger
        let gates: [Int: Gate]
        let made = LockedBox<[FakeTranscriber]>([])
        init(ledger: Ledger, gates: [Int: Gate] = [:]) {
            self.ledger = ledger
            self.gates = gates
        }
        func make() -> Transcribing {
            made.mutate { list in
                let transcriber = FakeTranscriber(id: list.count, ledger: ledger, gate: gates[list.count])
                list.append(transcriber)
                return transcriber
            }
        }
        subscript(_ index: Int) -> FakeTranscriber { made.value[index] }
    }

    struct Session {
        let model: InterviewScreenModel
        let feed: LiveInterviewFeed
        let coordinator: CopilotSessionCoordinator
        let provider: CopilotTestSupport.StubProvider
    }

    static func makeSession(factory: Factory) -> Session {
        let provider = LiveInterviewFeedTests.questionDetectingProvider()
        let coordinator = CopilotSessionCoordinator(
            project: SessionFileContext(language: .english),
            provider: provider,
            audio: InterviewAudioInput(makeService: factory.make),
            generationMode: .manual
        )
        let feed = LiveInterviewFeed(coordinator: coordinator)
        let model = InterviewScreenModel(mode: .live, feed: feed)
        return Session(model: model, feed: feed, coordinator: coordinator, provider: provider)
    }

    static func audio(_ factory: Factory) -> InterviewAudioInput { InterviewAudioInput(makeService: factory.make) }

    /// Waits for a condition expected to become true; returns whether it did (so a test records a
    /// failed expectation, with its own message, instead of throwing a timeout).
    static func eventually(_ timeout: Duration = .seconds(1), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// Lets main-actor work already scheduled (a released start resuming, a stop hopping off) run.
    static func drain() async {
        for _ in 0..<50 { await Task.yield() }
    }

    // MARK: - Proof 1: leaving the interview

    @Test
    func leavingAnInterviewStopsTheMicrophone() async throws {
        let factory = Factory(ledger: Ledger())
        let session = Self.makeSession(factory: factory)
        session.model.start()
        try await Support.waitUntil("listening") { session.coordinator.audio.state == .listening }
        #expect(factory.ledger.active == 1)

        // What leaving the interview screen does.
        session.model.stop()
        #expect(await Self.eventually { factory.ledger.active == 0 }, "a microphone pipeline is still running after leaving")
        #expect(session.coordinator.audio.state == .idle, "the audio input still reports \(session.coordinator.audio.state)")
        #expect(session.coordinator.state == .ended, "the coordinator still accepts speech after leaving")
    }

    @Test
    func speechAfterLeavingIsNeverClassified() async throws {
        let factory = Factory(ledger: Ledger())
        let session = Self.makeSession(factory: factory)
        session.model.start()
        try await Support.waitUntil("listening") { session.coordinator.audio.state == .listening }
        session.model.stop()
        await Self.drain()

        // Whatever the microphone still delivers — or a tick — must not reach detection.
        factory[0].emit(Support.finalDelta("How do you handle backpressure?", at: 1.0))
        session.coordinator.tick(now: 4.0)
        let classified = await Self.eventually(.milliseconds(1500)) { session.provider.classifyCallCount > 0 }
        #expect(!classified, "a classification request was sent after the interview was left")
    }

    @Test
    func threeInterviewsInARowLeaveNothingRunning() async throws {
        let factory = Factory(ledger: Ledger())
        weak var firstCoordinator: CopilotSessionCoordinator?
        weak var firstAudio: InterviewAudioInput?
        for round in 0..<3 {
            let session = Self.makeSession(factory: factory)
            if round == 0 { firstCoordinator = session.coordinator; firstAudio = session.coordinator.audio }
            session.model.start()
            try await Support.waitUntil("listening \(round)") { session.coordinator.audio.state == .listening }
            #expect(factory.ledger.active == 1, "round \(round): exactly one pipeline while an interview is open, found \(factory.ledger.active)")
            session.model.stop()
            #expect(await Self.eventually { factory.ledger.active == 0 }, "round \(round): \(factory.ledger.active) pipeline(s) still running after leaving")
        }
        #expect(factory.ledger.starts == 3)
        #expect(factory.ledger.active == 0, "\(factory.ledger.active) concurrent pipelines leaked across three interviews")
        await Self.drain()
        #expect(firstAudio == nil || firstAudio?.state == .idle, "the first interview's audio input is still \(String(describing: firstAudio?.state))")
        _ = firstCoordinator
    }

    @Test
    func endingTwiceIsHarmless() async throws {
        let factory = Factory(ledger: Ledger())
        let session = Self.makeSession(factory: factory)
        session.model.start()
        try await Support.waitUntil("listening") { session.coordinator.audio.state == .listening }
        session.model.stop()
        session.model.stop()
        session.feed.end()
        #expect(await Self.eventually { factory.ledger.active == 0 })
        #expect(factory.ledger.stops == 1, "the pipeline is stopped exactly once")
        #expect(session.coordinator.audio.state == .idle)
    }

    @Test
    func leavingWhileTheMicrophoneIsStillStartingLeavesNothingRunning() async throws {
        let gate = Gate()
        let factory = Factory(ledger: Ledger(), gates: [0: gate])
        let session = Self.makeSession(factory: factory)
        session.model.start()
        try await Support.waitUntil("start is pending") { gate.arrived }
        session.model.stop()
        gate.open()
        try await Support.waitUntil("the pending start returned") { factory[0].startReturned }
        #expect(await Self.eventually { factory.ledger.active == 0 }, "the late start took the microphone after the interview was left")
        #expect(session.coordinator.audio.state == .idle)
    }

    @Test
    func leavingWhilePausedLeavesNothingRunning() async throws {
        let factory = Factory(ledger: Ledger())
        let session = Self.makeSession(factory: factory)
        session.model.start()
        try await Support.waitUntil("listening") { session.coordinator.audio.state == .listening }
        session.feed.pause()
        #expect(await Self.eventually { factory.ledger.active == 0 }, "pausing releases the microphone")
        session.model.stop()
        #expect(session.coordinator.state == .ended)
        #expect(session.coordinator.audio.state == .idle)
        session.feed.resume()          // a late tap after leaving must not reopen the microphone
        await Self.drain()
        #expect(await Self.eventually { factory.ledger.starts == 1 && factory.ledger.active == 0 },
                "found \(factory.ledger.starts) starts, \(factory.ledger.active) live")
    }

    @Test
    func leavingRightAfterALanguageChangeLeavesNothingRunning() async throws {
        let gate = Gate()
        let factory = Factory(ledger: Ledger(), gates: [1: gate])
        let session = Self.makeSession(factory: factory)
        session.model.start()
        try await Support.waitUntil("listening") { session.coordinator.audio.state == .listening }
        session.model.changeLanguage(.french)       // restarts recognition; the new start is held
        try await Support.waitUntil("the French start is pending") { gate.arrived }
        session.model.stop()
        gate.open()
        try await Support.waitUntil("the French start returned") { factory[1].startReturned }
        #expect(await Self.eventually { factory.ledger.active == 0 }, "found \(factory.ledger.live)")
        #expect(session.coordinator.audio.state == .idle)
    }

    // MARK: - Proof 2: start/stop races in the audio input

    @Test
    func stopWhileStartIsPendingEndsStopped() async throws {
        let gate = Gate()
        let factory = Factory(ledger: Ledger(), gates: [0: gate])
        let audio = Self.audio(factory)

        audio.start(language: .english)           // begin start
        try await Support.waitUntil("start is suspended") { gate.arrived }
        audio.stop()                               // stop while it is pending
        gate.open()                                // the pending start completes
        try await Support.waitUntil("the pending start returned") { factory[0].startReturned }
        await Self.drain()

        #expect(audio.state == .idle, "FINAL STATE: \(audio.state)")
        #expect(await Self.eventually { factory.ledger.active == 0 }, "FINAL STATE: microphone held by \(factory.ledger.live)")
    }

    @Test
    func aLateStartNeverTakesOverTheNewerSession() async throws {
        let gateA = Gate(), gateB = Gate()
        let factory = Factory(ledger: Ledger(), gates: [0: gateA, 1: gateB])
        let audio = Self.audio(factory)

        audio.start(language: .english)            // start A
        try await Support.waitUntil("A is pending") { gateA.arrived }
        audio.stop()                                // stop A
        audio.start(language: .english)            // start B (it may wait for A to let go first)
        #expect(audio.state == .starting)
        gateA.open()                                // A completes late
        try await Support.waitUntil("A returned") { factory[0].startReturned }
        await Self.drain()
        #expect(audio.state == .starting, "A must not publish itself: state is \(audio.state) while B is still starting")
        #expect(await Self.eventually { !factory.ledger.live.contains(0) }, "A still holds the microphone")

        try await Support.waitUntil("B is pending") { gateB.arrived }
        #expect(factory.ledger.live.isEmpty, "B starts only once A has let go, found \(factory.ledger.live)")
        gateB.open()                                // B completes
        try await Support.waitUntil("B is listening") { audio.state == .listening }
        #expect(factory.ledger.live == [1], "only B is live, found \(factory.ledger.live)")

        audio.stop()
        #expect(await Self.eventually { factory.ledger.active == 0 })
        #expect(audio.state == .idle)
    }

    @Test
    func startStopStartEndsWithExactlyOnePipeline() async throws {
        let gateA = Gate()
        let factory = Factory(ledger: Ledger(), gates: [0: gateA])
        let audio = Self.audio(factory)
        audio.start(language: .english)
        try await Support.waitUntil("A is pending") { gateA.arrived }
        audio.stop()
        audio.start(language: .english)
        gateA.open()
        try await Support.waitUntil("A returned") { factory[0].startReturned }
        try await Support.waitUntil("B is listening") { audio.state == .listening }
        await Self.drain()
        #expect(audio.state == .listening, "the newer session keeps listening, state is \(audio.state)")
        #expect(await Self.eventually { factory.ledger.live == [1] }, "exactly B is live, found \(factory.ledger.live)")
        audio.stop()
        #expect(await Self.eventually { factory.ledger.active == 0 })
    }

    @Test
    func startStartEndsWithExactlyOnePipeline() async throws {
        let factory = Factory(ledger: Ledger())
        let audio = Self.audio(factory)
        audio.start(language: .english)
        audio.start(language: .english)
        try await Support.waitUntil("listening") { audio.state == .listening }
        await Self.drain()
        #expect(await Self.eventually { factory.ledger.active == 1 }, "found \(factory.ledger.live)")
        audio.stop()
        #expect(await Self.eventually { factory.ledger.active == 0 })
        #expect(audio.state == .idle)
    }

    @Test
    func stopStopIsHarmless() async throws {
        let factory = Factory(ledger: Ledger())
        let audio = Self.audio(factory)
        audio.stop()
        audio.start(language: .english)
        try await Support.waitUntil("listening") { audio.state == .listening }
        audio.stop()
        audio.stop()
        #expect(await Self.eventually { factory.ledger.active == 0 })
        #expect(factory.ledger.stops == 1)
        #expect(audio.state == .idle)
    }
}
