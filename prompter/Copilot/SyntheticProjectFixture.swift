import Foundation

/// A synthetic, entirely fictional project used by the prototype and the evaluation harness.
///
/// **Nothing here is real.** No personal data, no real organisation, no captured interview material —
/// the same rule that governs test fixtures in this repository (`CO_INTERVIEW_SNAPSHOT_NOTICE.md`).
/// It exists so the pipeline can be exercised and measured before the document-import system is built
/// (plan Increment 5); it is replaced by satisfying `ProjectContextProviding` with real documents.
///
/// The two subjects are deliberately different — a transport programme and a hospital service review —
/// so nothing in the design assumes a CV, a job description, or a software role.
struct SyntheticProject: ProjectContextProviding {
    let projectID: String
    let projectName: String
    let instructions: String
    let language: InterviewLanguage
    private let retriever: PassageRetriever

    init(projectID: String, projectName: String, instructions: String, language: InterviewLanguage, passages: [ProjectPassage]) {
        self.projectID = projectID
        self.projectName = projectName
        self.instructions = instructions
        self.language = language
        self.retriever = PassageRetriever(passages: passages)
    }

    var allPassages: [ProjectPassage] { retriever.passages }

    func passages(forQuestion question: String, limit: Int) -> [ProjectPassage] {
        retriever.topPassages(for: question, limit: limit)
    }
}

enum SyntheticProjectFixture {
    /// English: a fictional candidate interviewing to lead a city transport programme.
    static let transportProgramme = SyntheticProject(
        projectID: "fixture-transport-en",
        projectName: "Northbridge transport programme (fixture)",
        instructions: """
        I am interviewing for programme lead of the Northbridge bus corridor. Answer in the first \
        person, in a calm spoken register, and prefer concrete figures from my documents over general \
        claims. If a question needs a detail my documents do not contain, say so instead of inventing it.
        """,
        language: .english,
        passages: [
            ProjectPassage(
                id: "cv#1", documentID: "cv", documentTitle: "Summary of experience (fixture)",
                documentVersion: "2026-08-14", locator: "§ Roles",
                text: """
                Led the Eastgate corridor upgrade for four years: 14 kilometres of bus lane, a team of \
                nine, and a capital budget of 22 million. Before that, three years as service planner \
                for the regional operator.
                """),
            ProjectPassage(
                id: "cv#2", documentID: "cv", documentTitle: "Summary of experience (fixture)",
                documentVersion: "2026-08-14", locator: "§ Outcomes",
                text: """
                On Eastgate, average journey time fell by 18 per cent and on-time departures rose from \
                71 to 89 per cent over two years. Complaints about crowding fell by a third after the \
                timetable rewrite in the second year.
                """),
            ProjectPassage(
                id: "brief#1", documentID: "brief", documentTitle: "Northbridge programme brief (fixture)",
                documentVersion: "2026-09-01", locator: "p. 1",
                text: """
                The Northbridge corridor carries 40,000 passenger journeys a day. The programme must \
                deliver signal priority at 23 junctions and a new interchange at Mill Street by the end \
                of the second year, within a capital envelope of 31 million.
                """),
            ProjectPassage(
                id: "brief#2", documentID: "brief", documentTitle: "Northbridge programme brief (fixture)",
                documentVersion: "2026-09-01", locator: "p. 4",
                text: """
                Known risks: utility diversions under Mill Street, a contested compulsory purchase of \
                two frontages, and a depot power upgrade that the operator has not yet scheduled. The \
                board meets monthly and expects a single-page risk note each cycle.
                """),
            ProjectPassage(
                id: "notes#1", documentID: "notes", documentTitle: "Stakeholder notes (fixture)",
                documentVersion: "2026-09-10", locator: "§ Meetings",
                text: """
                The retailers' association objects to loading restrictions on Mill Street. The transport \
                committee chair has asked for evening service frequency to be protected in any \
                timetable change.
                """),
        ]
    )

    /// French: a fictional clinician answering a hospital service-review panel. Used to check that the
    /// pipeline handles a second language end to end, not to claim French support.
    static let hospitalReview = SyntheticProject(
        projectID: "fixture-hopital-fr",
        projectName: "Revue du service de cardiologie (fixture)",
        instructions: """
        Je passe un entretien devant le comité de revue du service de cardiologie. Réponds à la première \
        personne, dans un registre parlé et sobre, en privilégiant les chiffres de mes documents. Si une \
        question demande un détail absent des documents, dis-le au lieu de l'inventer.
        """,
        language: .french,
        passages: [
            ProjectPassage(
                id: "rapport#1", documentID: "rapport", documentTitle: "Rapport d'activité (fixture)",
                documentVersion: "2026-07-30", locator: "p. 2",
                text: """
                Le service a pris en charge 3 200 patients l'an dernier, dont 460 en urgence. Le délai \
                médian avant consultation est passé de 34 à 21 jours après la réorganisation des plages \
                horaires.
                """),
            ProjectPassage(
                id: "rapport#2", documentID: "rapport", documentTitle: "Rapport d'activité (fixture)",
                documentVersion: "2026-07-30", locator: "p. 5",
                text: """
                Deux postes d'infirmier restent vacants depuis neuf mois. Le taux d'occupation des lits \
                atteint 94 pour cent en hiver, contre 81 pour cent le reste de l'année.
                """),
            ProjectPassage(
                id: "protocole#1", documentID: "protocole", documentTitle: "Protocole de suivi (fixture)",
                documentVersion: "2026-08-22", locator: "§ 3",
                text: """
                Le protocole de suivi post-opératoire prévoit un appel à 48 heures, une consultation à \
                trois semaines et un contrôle à six mois. L'observance mesurée sur l'appel à 48 heures \
                est de 88 pour cent.
                """),
        ]
    )

    static let all: [SyntheticProject] = [transportProgramme, hospitalReview]

    static func project(id: String) -> SyntheticProject? {
        all.first { $0.projectID == id }
    }
}
