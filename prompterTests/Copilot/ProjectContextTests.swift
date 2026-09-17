import Testing
import Foundation
@testable import prompter

/// Retrieval behaviour and project isolation (§5).
struct ProjectContextTests {
    @Test
    func retrievalFindsThePassageThatAnswersTheQuestion() {
        let project = SyntheticProjectFixture.transportProgramme
        let passages = project.passages(forQuestion: "How many journeys a day does the corridor carry?", limit: 2)
        #expect(passages.first?.id == "brief#1")
        #expect(passages.first?.text.contains("40,000") == true)
    }

    @Test
    func distinctiveWordsOutweighCommonOnes() {
        let project = SyntheticProjectFixture.transportProgramme
        let passages = project.passages(forQuestion: "What worries you about the utility diversions at Mill Street?", limit: 1)
        #expect(passages.first?.id == "brief#2")
    }

    /// A question nothing in the project covers must return nothing, so the answer can be honestly
    /// marked as not coming from the documents rather than citing an irrelevant passage.
    @Test
    func anUnsupportedQuestionRetrievesNothing() {
        let project = SyntheticProjectFixture.transportProgramme
        let passages = project.passages(forQuestion: "Explain how the pension scheme transfer would work", limit: 3)
        #expect(passages.isEmpty)
    }

    @Test
    func frenchRetrievalWorksOnTheFrenchFixture() {
        let project = SyntheticProjectFixture.hospitalReview
        let passages = project.passages(forQuestion: "Expliquez le protocole de suivi après l'opération.", limit: 1)
        #expect(passages.first?.id == "protocole#1")
    }

    /// Projects are isolated by construction: a retriever only ever sees its own passages.
    @Test
    func projectsNeverReturnEachOthersPassages() {
        let transport = SyntheticProjectFixture.transportProgramme
        let hospital = SyntheticProjectFixture.hospitalReview

        let crossQuery = transport.passages(forQuestion: "protocole de suivi cardiologie patients", limit: 5)
        #expect(crossQuery.allSatisfy { $0.id.hasPrefix("cv") || $0.id.hasPrefix("brief") || $0.id.hasPrefix("notes") })

        let hospitalIDs = Set(hospital.allPassages.map(\.id))
        #expect(crossQuery.allSatisfy { !hospitalIDs.contains($0.id) })
    }

    @Test
    func everyPassageCarriesADocumentVersionAndLocator() {
        for project in SyntheticProjectFixture.all {
            for passage in project.allPassages {
                #expect(!passage.documentVersion.isEmpty)
                #expect(!passage.locator.isEmpty)
                #expect(!passage.id.isEmpty)
            }
        }
    }

    /// The synthetic interview scripts must stay consistent with what the evaluation expects.
    @Test
    func syntheticInterviewsProduceVolatileThenFinalEvents() {
        let results = SyntheticInterview.english.scriptedResults()
        #expect(results.contains { !$0.isFinal }, "no volatile revisions — the dedupe path would not be exercised")
        #expect(results.filter(\.isFinal).count == SyntheticInterview.english.lines.count)
        // Monotonic timing, so replay order is deterministic.
        #expect(zip(results, results.dropFirst()).allSatisfy { $0.elapsed <= $1.elapsed })
    }
}
