import Testing
import Foundation
@testable import prompter

/// How the app treats the route metadata and failure signals the backend sends (§6, §7 of
/// docs/CO_INTERVIEW_AI_PIPELINE.md). The gateway choice lives on the backend; what the app must get
/// right is recording what actually served an answer and never losing text a reader can already see.
@MainActor
struct ProviderRouteTests {
    private typealias Support = CopilotTestSupport

    private func question(_ text: String) -> DetectionResult {
        DetectionResult(kind: .newQuestion, questionText: text, confidence: 0.9)
    }

    private func makeCard(_ provider: Support.StubProvider) async throws -> CopilotSessionCoordinator {
        provider.classifications = [question("What worries you about Mill Street?")]
        let (coordinator, _, _) = Support.makeCoordinator(provider: provider)
        coordinator.ingest(Support.finalDelta("What worries you most about Mill Street", at: 5))
        try await Support.waitUntil("a card") { coordinator.cards.count == 1 }
        return coordinator
    }

    @Test
    func theServingRouteIsRecordedOnTheVersion() async throws {
        let provider = Support.StubProvider()
        provider.manualStreams = true
        let coordinator = try await makeCard(provider)

        provider.push(.route(AnswerRoute(
            attempt: 1, gateway: "openrouter", requestedModel: "nvidia/nemotron-3.5-lightning",
            resolvedModel: "nvidia/nemotron-3.5-lightning", servingProvider: "CoreWeave", generationID: "gen-1"
        )))
        try await Support.waitUntil("route recorded") { coordinator.cards[0].latestVersion?.route != nil }

        let route = try #require(coordinator.cards[0].latestVersion?.route)
        #expect(route.servingProvider == "CoreWeave")
        #expect(route.generationID == "gen-1")
        #expect(route.summary.contains("CoreWeave"))
    }

    /// When the gateway does not say who served the request, the app must not put the first
    /// preference in its place.
    @Test
    func anUnreportedProviderIsShownAsUnknown() async throws {
        let provider = Support.StubProvider()
        provider.manualStreams = true
        let coordinator = try await makeCard(provider)

        provider.push(.route(AnswerRoute(attempt: 1, gateway: "openrouter", requestedModel: "deepseek/deepseek-v4.1-flash")))
        try await Support.waitUntil("route recorded") { coordinator.cards[0].latestVersion?.route != nil }
        #expect(coordinator.cards[0].latestVersion?.route?.servingProvider == "unknown")
    }

    /// A fallback happening before any visible text is reported, and does not disturb the card.
    @Test
    func aFallbackBeforeVisibleTextIsReportedAndKeepsOneVersion() async throws {
        let provider = Support.StubProvider()
        provider.manualStreams = true
        let coordinator = try await makeCard(provider)

        provider.push(.attemptFailed(detail: "primary route unavailable", fallingBackTo: "google/gemini-2.5-flash-lite"))
        try await Support.waitUntil("failure surfaced") { coordinator.lastProviderError != nil }

        #expect(coordinator.lastProviderError?.contains("gemini") == true)
        #expect(coordinator.cards[0].versions.count == 1, "a backend-side fallback is one answer version, not two")
        #expect(coordinator.cards[0].latestVersion?.status == .streaming)
    }

    /// Text already shown must survive a mid-stream failure, and Retry must add a version rather than
    /// replace the one being read.
    @Test
    func anIncompleteAnswerKeepsItsTextAndRetryAddsAVersion() async throws {
        let provider = Support.StubProvider()
        provider.manualStreams = true
        let coordinator = try await makeCard(provider)

        provider.push(.delta("The main risks are utility diversions under Mill Street. "))
        try await Support.waitUntil("committed text") { !(coordinator.cards[0].latestVersion?.committedText.isEmpty ?? true) }
        provider.push(.incomplete(reason: "stream ended before completion"))
        try await Support.waitUntil("marked incomplete") { coordinator.cards[0].latestVersion?.incompleteReason != nil }

        let version = try #require(coordinator.cards[0].latestVersion)
        #expect(version.committedText.contains("utility diversions"))
        #expect(version.readableSegments.first?.contains("utility diversions") == true)

        let versionIDBefore = version.id
        coordinator.regenerate(cardID: coordinator.cards[0].id)
        try await Support.waitUntil("a second version") { coordinator.cards[0].versions.count == 2 }

        #expect(coordinator.cards[0].versions[0].id == versionIDBefore, "retry replaced the version being read")
        #expect(coordinator.cards[0].versions[0].committedText.contains("utility diversions"), "retry destroyed readable text")
        // The reader is not moved to the new version automatically.
        #expect(coordinator.cards[0].selectedVersionID == versionIDBefore)
    }

    /// Listening is unaffected by anything the provider does.
    @Test
    func listeningContinuesThroughAProviderFailure() async throws {
        let provider = Support.StubProvider()
        provider.generationError = CopilotProviderError.provider("gateway exploded")
        provider.classifications = [question("What worries you about Mill Street?")]
        let (coordinator, audio, service) = Support.makeCoordinator(provider: provider)
        coordinator.startListening()
        try await Support.waitUntil("listening") { audio.state == .listening }

        service.emit(Support.finalDelta("What worries you most about Mill Street", at: 5))
        try await Support.waitUntil("failure") {
            if case .failed = coordinator.cards.first?.latestVersion?.status { return true }
            return false
        }

        #expect(audio.state == .listening)
        service.emit(Support.finalDelta("Let us move on.", at: 20))
        try await Support.waitUntil("speech still flowing") { coordinator.conversation.utterances.count >= 2 }
    }
}
