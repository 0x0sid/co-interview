import Foundation

// MARK: - What is sent

/// The bounded state one focused decision is made on (backend `decisions.mjs`, pipeline §18).
///
/// Built from the screen's own state — the transcript lines not yet covered by a request, a little of
/// what came before them, and the recent requests **by their own words** — never from generated
/// titles, earlier answers, documents or the note. It is only ever the input to a decision; the
/// answer request is built from the whole conversation exactly as before.
struct DecisionSnapshot: Sendable, Encodable, Equatable {
    struct Utterance: Sendable, Encodable, Equatable {
        let id: String
        let revision: Int
        let isFinal: Bool
        let text: String
    }

    struct Candidate: Sendable, Encodable, Equatable {
        enum Status: String, Sendable, Encodable { case pending, answered, superseded }
        let id: String
        let sourceText: String
        let status: Status
    }

    let sessionID: String
    let stateRevision: Int
    let snapshotID: String
    let language: String
    let newSpeech: [Utterance]
    let preceding: [String]
    let candidates: [Candidate]
    var requestActive: Bool = false
    var diagnosticsSessionID: String?
    var captureContent: Bool?

    /// Everything a decision depends on. A cached decision is usable only while this is unchanged —
    /// an utterance that still exists but was revised, or a request whose status changed, is
    /// different evidence, and the old decision is not about it.
    var key: String {
        let speech = newSpeech.map { "\($0.id)@\($0.revision)|\($0.isFinal)|\($0.text)" }.joined(separator: "\u{1F}")
        let requests = candidates.map { "\($0.id)|\($0.status.rawValue)" }.joined(separator: "\u{1F}")
        return "\(sessionID)\u{1E}\(speech)\u{1E}\(requests)"
    }

    enum CodingKeys: String, CodingKey {
        case sessionID, stateRevision, snapshotID, language, newSpeech, preceding, candidates
        case requestActive, diagnosticsSessionID, captureContent
    }
}

/// An accepted decision, as it travels in an answer request. Structured on purpose: the backend turns
/// it into fixed sentences, and the only free text in it is a request's own words.
struct RequestInterpretation: Sendable, Codable, Equatable {
    let relation: String
    let parentWords: String?
    let parentStatus: String?
}

/// What the backend decided. `apply` is its verdict on whether this session may use it at all.
struct DecisionOutcome: Sendable, Decodable, Equatable {
    struct Answer: Sendable, Decodable, Equatable {
        let choice: String?
        let confidence: Double?
    }

    var mode: String
    var apply: Bool
    var eligible: Bool
    var promptVersion: String?
    var answeredModel: String?
    var snapshotID: String?
    var relation: Answer?
    var parent: Answer?
    var combinedParentID: String?
    var interpretation: RequestInterpretation?
    var fallbackReason: String?
    var timedOut: Bool?
    var latencyMs: Int?

    enum CodingKeys: String, CodingKey {
        case mode, apply, eligible, relation, parent, interpretation
        case promptVersion = "prompt_version"
        case answeredModel = "answered_model"
        case snapshotID = "snapshot_id"
        case combinedParentID = "combined_parent_id"
        case fallbackReason = "fallback_reason"
        case timedOut = "timed_out"
        case latencyMs = "latency_ms"
    }

    init(mode: String, apply: Bool, eligible: Bool, interpretation: RequestInterpretation? = nil,
         combinedParentID: String? = nil, fallbackReason: String? = nil) {
        self.mode = mode
        self.apply = apply
        self.eligible = eligible
        self.interpretation = interpretation
        self.combinedParentID = combinedParentID
        self.fallbackReason = fallbackReason
    }
}

// MARK: - When it is asked

/// Asks for a decision in the background while speech arrives, and never at Generate.
///
/// - **Not per character.** A change schedules one call after `stabilityInterval`; further changes
///   inside that window push it back.
/// - **One in flight.** A change while a call is running marks the tracker dirty; when the call ends,
///   one new call is made on the state *as it is then* — which still contains every unprocessed
///   utterance, because the snapshot is rebuilt rather than queued. Nothing obsolete accumulates.
/// - **Unchanged evidence, no call.** A snapshot whose key matches the latest result or the call in
///   flight is not sent again: silence and repeated identical partials cost nothing.
/// - **Stale results are never used.** A result is kept with the key it was made for, and is usable
///   only while the screen's key still matches. A session change discards everything.
/// - **No retries.** A failure is recorded, and the next change asks again.
@MainActor
final class RequestDecisionTracker {
    typealias Decide = @Sendable (DecisionSnapshot) async throws -> DecisionOutcome

    /// Nil when there is no backend to ask; the tracker then does nothing at all.
    var decide: Decide?
    var stabilityInterval: Duration = .milliseconds(700)
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Supplied by the screen: the snapshot of the state right now, or nil when there is nothing new.
    var makeSnapshot: () -> DecisionSnapshot? = { nil }
    /// Every finished call, for diagnostics. Observation only.
    var onFinished: ((DecisionSnapshot, Result<DecisionOutcome, Error>, Duration) -> Void)?

    private(set) var latest: (key: String, snapshotID: String, outcome: DecisionOutcome)?
    private(set) var disabledReason: String?
    private(set) var callCount = 0
    private(set) var isInFlight = false
    private var inFlightKey: String?
    private var dirty = false
    private var scheduled: Task<Void, Never>?
    private var generation = UUID()

    /// Something the decision depends on changed: speech, a revision, or a request's status.
    func stateChanged() {
        guard decide != nil, disabledReason == nil else { return }
        scheduled?.cancel()
        let interval = stabilityInterval
        let sleep = self.sleep
        scheduled = Task { [weak self] in
            do { try await sleep(interval) } catch { return }
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    /// Makes a call now if one is due. Not private: tests drive it without timers.
    func fire() {
        guard let decide, disabledReason == nil, let snapshot = makeSnapshot(), !snapshot.newSpeech.isEmpty else { return }
        let key = snapshot.key
        guard key != latest?.key, key != inFlightKey else { return }
        guard !isInFlight else {
            dirty = true
            return
        }
        isInFlight = true
        inFlightKey = key
        callCount += 1
        let generation = self.generation
        let started = ContinuousClock.now
        Task { [weak self] in
            let result: Result<DecisionOutcome, Error>
            do { result = .success(try await decide(snapshot)) } catch { result = .failure(error) }
            guard let self, generation == self.generation else { return }      // the session moved on
            self.isInFlight = false
            self.inFlightKey = nil
            if case .success(let outcome) = result {
                if outcome.mode == "off" {
                    self.disabledReason = "decisions are off on the backend"
                } else {
                    self.latest = (key, snapshot.snapshotID, outcome)
                }
            }
            self.onFinished?(snapshot, result, ContinuousClock.now - started)
            if self.dirty {
                self.dirty = false
                self.fire()
            }
        }
    }

    /// Whether a decision can be used for the request being made now, and why not when it cannot.
    func interpretation(forKey key: String) -> (interpretation: RequestInterpretation?, parentID: String?, status: String) {
        guard decide != nil else { return (nil, nil, "no decision service") }
        if let disabledReason { return (nil, nil, disabledReason) }
        guard let latest else { return (nil, nil, isInFlight ? "decision still in flight" : "no decision yet") }
        guard latest.key == key else {
            return (nil, nil, isInFlight ? "decision for the current speech still in flight" : "stale: the speech or requests changed since")
        }
        let outcome = latest.outcome
        guard outcome.eligible, let interpretation = outcome.interpretation else {
            return (nil, nil, "fallback: \(outcome.fallbackReason ?? "not accepted")")
        }
        guard outcome.apply else { return (nil, nil, "shadow: \(interpretation.relation) not applied") }
        return (interpretation, outcome.combinedParentID, "applied: \(interpretation.relation)")
    }

    /// Session end or restart: in-flight and cached results are dropped, and late ones are ignored.
    func reset() {
        generation = UUID()
        scheduled?.cancel()
        scheduled = nil
        latest = nil
        inFlightKey = nil
        isInFlight = false
        dirty = false
        disabledReason = nil
    }
}
