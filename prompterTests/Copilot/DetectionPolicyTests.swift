import Testing
import Foundation
@testable import prompter

/// When the detector may be called at all (§4). Every rule here exists to stop the model being asked
/// on every partial token, every sentence, or every silence.
struct DetectionPolicyTests {
    private let policy = DetectionPolicy()

    private func input(
        text: String,
        didFinalize: Bool = false,
        now: TimeInterval = 10,
        lastChange: TimeInterval = 10,
        lastClassification: TimeInterval? = nil,
        lastClassifiedText: String? = nil,
        inFlight: Bool = false,
        allOverlap: Bool = false,
        manual: Bool = false
    ) -> DetectionPolicy.Input {
        .init(
            pendingText: text,
            didFinalize: didFinalize,
            now: now,
            lastChangeTime: lastChange,
            lastClassificationTime: lastClassification,
            lastClassifiedText: lastClassifiedText,
            isClassificationInFlight: inFlight,
            allPendingOverlapsReading: allOverlap,
            isManualRequest: manual
        )
    }

    @Test
    func aPartialFragmentDoesNotCallTheModel() {
        let decision = policy.decide(input(text: "Tell me", now: 10, lastChange: 9.95))
        #expect(!decision.shouldClassify)
        #expect(!decision.shouldStartRetrieval)
    }

    @Test
    func aFinalizedUtteranceIsAStableTrigger() {
        let decision = policy.decide(input(text: "Tell me about the corridor you ran", didFinalize: true))
        #expect(decision.shouldClassify)
        #expect(decision.trigger == .finalized)
    }

    /// Streaming volatile text that has stopped changing is stable enough, even before the transcriber
    /// finalizes — which matters because finalization can lag by seconds.
    @Test
    func volatileTextThatStoppedChangingIsStable() {
        let stillMoving = policy.decide(input(text: "What worries you about Mill Street", now: 20.0, lastChange: 19.8))
        #expect(!stillMoving.shouldClassify)
        #expect(stillMoving.shouldStartRetrieval)   // plausible question forming — retrieval may start

        let settled = policy.decide(input(text: "What worries you about Mill Street", now: 20.6, lastChange: 19.8))
        #expect(settled.shouldClassify)
        #expect(settled.trigger == .stablePause)
    }

    @Test
    func identicalTextIsNeverReclassified() {
        let text = "How many journeys a day"
        let decision = policy.decide(input(text: text, didFinalize: true, lastClassifiedText: text))
        #expect(!decision.shouldClassify)
    }

    @Test
    func aClassificationInFlightBlocksAnother() {
        let decision = policy.decide(input(text: "And who signs off the risk note", didFinalize: true, inFlight: true))
        #expect(!decision.shouldClassify)
    }

    @Test
    func theCooldownStopsABurstOfFinalsFanningOut() {
        let decision = policy.decide(input(
            text: "And who signs off the risk note",
            didFinalize: true,
            now: 30.0,
            lastClassification: 29.9
        ))
        #expect(!decision.shouldClassify)

        let later = policy.decide(input(
            text: "And who signs off the risk note",
            didFinalize: true,
            now: 30.5,
            lastClassification: 29.9
        ))
        #expect(later.shouldClassify)
    }

    /// Silence alone is not a trigger: with nothing new said, there is nothing to classify.
    @Test
    func silenceWithNoNewWordsNeverTriggers() {
        let decision = policy.decide(input(text: "", didFinalize: false, now: 60, lastChange: 20))
        #expect(!decision.shouldClassify)
        #expect(!decision.shouldStartRetrieval)
    }

    /// Speech that the reader confirmed word-for-word against the answer being read is the user
    /// reading aloud, so it is not a question signal.
    @Test
    func speechThatIsEntirelyTheUserReadingIsNotClassified() {
        let decision = policy.decide(input(
            text: "Average journey time fell by eighteen per cent over two years",
            didFinalize: true,
            allOverlap: true
        ))
        #expect(!decision.shouldClassify)
    }

    /// Manual is the escape hatch for everything detection misses, so it bypasses the gates.
    @Test
    func manualRequestsAlwaysClassify() {
        let decision = policy.decide(input(
            text: "budget",
            didFinalize: false,
            now: 10,
            lastChange: 9.99,
            lastClassification: 9.99,
            inFlight: true,
            allOverlap: true,
            manual: true
        ))
        #expect(decision.shouldClassify)
        #expect(decision.trigger == .manual)
    }
}
