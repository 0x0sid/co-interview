import SwiftUI

/// Score interview: an explicit AI action (Pro) on a frozen snapshot of the saved transcript, saved
/// locally with that snapshot. **A score only** — no generated summary or coaching report.
///
/// The transcript does not say who spoke, so the candidate marks the lines they said. Only those are
/// scored; with too few of them there is nothing to score and no request is sent. The app's own
/// suggested answers are never part of it.
struct InterviewReviewSheet: View {
    let session: InterviewSessionRecord
    var store: InterviewReviewStore = .standard

    @Environment(\.dismiss) private var dismiss
    @Environment(EntitlementService.self) private var entitlements: EntitlementService?
    @Environment(AccessController.self) private var access: AccessController?

    @State private var saved: InterviewReviewRecord?
    @State private var marked: Set<Int> = []
    @State private var isMarking = false
    @State private var isGenerating = false
    @State private var failure: String?
    @State private var plansPaywall: AccessController.PaywallRequest?

    private var lines: [(order: Int, text: String)] {
        session.utterances.sorted { $0.order < $1.order }
            .filter { !$0.text.isEmpty }
            .map { ($0.order, $0.text) }
    }

    private var canScore: Bool {
        InterviewReviewClient.canScore(markedLines: lines.filter { marked.contains($0.order) }.map(\.text))
    }

    /// Pro, or a development build not using installation access (the backend still decides).
    private var mayGenerate: Bool { access?.usesServerAccess == false || access?.isPro == true }

    var body: some View {
        NavigationStack {
            List {
                if let saved {
                    if saved.coversEarlierSnapshot(of: session) {
                        Section {
                            Label("This score covers an earlier point in the interview. Score again to include what was said since.",
                                  systemImage: "clock.arrow.circlepath")
                                .font(Typography.body(13))
                                .foregroundStyle(Theme.Color.warm)
                        }
                    }
                    ScoreSections(report: saved.report, createdAt: saved.createdAt)
                }

                Section {
                    Button(isMarking ? "Done marking" : (marked.isEmpty ? "Mark the lines you said" : "Marked \(marked.count) line\(marked.count == 1 ? "" : "s") as yours")) {
                        isMarking.toggle()
                    }
                    .accessibilityIdentifier("review-mark")
                    if isMarking {
                        ForEach(lines, id: \.order) { line in
                            Button {
                                if marked.contains(line.order) { marked.remove(line.order) } else { marked.insert(line.order) }
                            } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: marked.contains(line.order) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(marked.contains(line.order) ? Theme.Color.action : Theme.Color.secondary)
                                    Text(line.text).foregroundStyle(Theme.Color.ink)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } footer: {
                    Text("The transcript doesn't record who spoke. Only the lines you mark are scored.")
                }

                Section {
                    if lines.isEmpty {
                        Text("Nothing was transcribed in this interview, so there is nothing to score.")
                            .foregroundStyle(Theme.Color.secondary)
                    } else if !mayGenerate {
                        Button(entitlements?.expiredAt == nil ? "Unlock Pro to score interviews"
                                                              : "Pro expired — renew to score interviews") { plansPaywall = .init(trigger: .settings) }
                            .accessibilityIdentifier("review-unlock")
                        Text("Viewing and exporting the transcript stay free.")
                            .font(Typography.body(12))
                            .foregroundStyle(Theme.Color.secondary)
                    } else {
                        Button {
                            Task { await generate() }
                        } label: {
                            HStack(spacing: 8) {
                                if isGenerating { ProgressView() }
                                Text(isGenerating ? "Scoring…" : saved == nil ? "Score interview" : "Score again")
                            }
                        }
                        .disabled(isGenerating || !canScore)
                        .accessibilityIdentifier("review-generate")
                        if !canScore {
                            Text("Mark at least three of your answers (about 60 words) to get a score.")
                                .font(Typography.body(12))
                                .foregroundStyle(Theme.Color.secondary)
                        }
                    }
                    if let failure {
                        Text(failure).font(Typography.body(13)).foregroundStyle(Theme.Color.error)
                        if !isGenerating, mayGenerate, canScore {
                            Button("Retry") { Task { await generate() } }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Color.paper)
            .navigationTitle(saved == nil ? "Score interview" : "Interview score")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                saved = store.load(session.id)
                if let saved { marked = Set(saved.candidateLineOrders) }
            }
            .sheet(item: $plansPaywall) { request in
                if let entitlements, let access {
                    NeverblankPaywallView(trigger: request.trigger, entitlements: entitlements, access: access) { _ in plansPaywall = nil }
                }
            }
        }
    }

    /// Freezes the transcript and the marks now; later speech is not part of this score.
    private func generate() async {
        let snapshot = lines
        let body = InterviewReviewClient.Body(
            title: session.title,
            language: session.language.bcp47,
            lines: snapshot.map { InterviewReviewClient.Line(text: $0.text, candidate: marked.contains($0.order)) }
        )
        let lastActivity = session.lastActivityAt
        isGenerating = true
        failure = nil
        defer { isGenerating = false }
        do {
            let report = try await InterviewReviewClient.request(body)
            let record = InterviewReviewRecord(sessionID: session.id, createdAt: .now, sourceLineCount: snapshot.count,
                                               sourceLastActivity: lastActivity, candidateLineOrders: marked.sorted(), report: report)
            try store.save(record)
            saved = record
            isMarking = false
        } catch InterviewReviewClient.Failure.proRequired {
            if let expired = entitlements?.expiredAt {
                failure = "Your Neverblank Pro subscription expired on \(expired.formatted(date: .abbreviated, time: .shortened)). Become Pro to score interviews; the transcript stays free to view and export."
            } else {
                failure = "Scoring interviews needs Neverblank Pro."
            }
            plansPaywall = .init(trigger: .settings)
        } catch InterviewReviewClient.Failure.backendUnavailable {
            failure = "Neverblank's service isn't reachable right now, so the interview can't be scored. Check your connection and try again later."
        } catch InterviewReviewClient.Failure.generationFailed {
            failure = "The score couldn't be generated this time. Nothing was saved or changed — tap Retry."
        } catch {
            failure = "The score could not be saved on this iPhone."
        }
    }
}

/// The saved score: overall, then each criterion with its evidence.
private struct ScoreSections: View {
    let report: InterviewReviewReport
    let createdAt: Date

    var body: some View {
        if let scores = report.scores {
            Section {
                if let overall = report.overallScore {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Overall").font(Typography.body(17, weight: .semibold)).foregroundStyle(Theme.Color.ink)
                        Spacer()
                        Text("\(overall.formatted(.number.precision(.fractionLength(1)))) / 4")
                            .font(Typography.body(22, weight: .semibold))
                            .foregroundStyle(Theme.Color.ink)
                            .accessibilityIdentifier("review-overall")
                    }
                }
                row("Relevance", scores.relevance, report.evidence?.relevance)
                row("Clarity", scores.clarity, report.evidence?.clarity)
                row("Structure", scores.structure, report.evidence?.structure)
                row("Supporting examples", scores.examples, report.evidence?.examples)
            } footer: {
                Text(report.score_note)
            }
        } else {
            Section { Text(report.score_note).foregroundStyle(Theme.Color.secondary) }
        }
        Section {
            Text(report.disclaimer).font(Typography.body(12)).foregroundStyle(Theme.Color.secondary)
            Text("Scored \(createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(Typography.body(12)).foregroundStyle(Theme.Color.secondary)
        }
    }

    private func row(_ name: String, _ value: Int, _ evidence: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(name).foregroundStyle(Theme.Color.ink); Spacer(); Text("\(value) / 4").foregroundStyle(Theme.Color.secondary) }
            if let evidence, !evidence.isEmpty {
                Text("“\(evidence)”").font(Typography.body(13)).foregroundStyle(Theme.Color.secondary)
            }
        }
    }
}
