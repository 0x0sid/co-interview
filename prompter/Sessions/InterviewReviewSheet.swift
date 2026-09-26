import SwiftUI

/// Summary & feedback for a saved interview: an explicit AI action (Pro) on a frozen snapshot of its
/// transcript, saved locally with that snapshot.
///
/// The transcript does not say who spoke, so the candidate can mark the lines they said. Only those are
/// judged; without them the report is an unscored conversation summary, and with too few of them it
/// says "Not enough evidence to score". The app's own suggested answers are never part of it.
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

    /// Pro, or a development build not using installation access (the backend still decides).
    private var mayGenerate: Bool { access?.usesServerAccess == false || access?.isPro == true }

    var body: some View {
        NavigationStack {
            List {
                if let saved {
                    if saved.coversEarlierSnapshot(of: session) {
                        Section {
                            Label("This report covers an earlier point in the interview. Generate again to include what was said since.",
                                  systemImage: "clock.arrow.circlepath")
                                .font(Typography.body(13))
                                .foregroundStyle(Theme.Color.warm)
                        }
                    }
                    ReportSections(report: saved.report, createdAt: saved.createdAt)
                } else {
                    Section {
                        Text("A summary of what was discussed, with coaching feedback on your own answers. It uses this interview's saved transcript as it is now, and never rewrites it.")
                            .font(Typography.body(14))
                            .foregroundStyle(Theme.Color.ink)
                    }
                }

                Section {
                    Button(isMarking ? "Done marking" : (marked.isEmpty ? "Mark the lines you said (for feedback and a score)" : "Marked \(marked.count) line\(marked.count == 1 ? "" : "s") as yours")) {
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
                    Text("The transcript doesn't record who spoke. Without marked lines you get an unscored summary of the conversation.")
                }

                Section {
                    if lines.isEmpty {
                        Text("Nothing was transcribed in this interview, so there is nothing to review.")
                            .foregroundStyle(Theme.Color.secondary)
                    } else if !mayGenerate {
                        Button("Unlock Pro to generate summary & feedback") { plansPaywall = .init(trigger: .settings) }
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
                                Text(isGenerating ? "Reviewing the interview…" : saved == nil ? "Generate summary & feedback" : "Generate again")
                            }
                        }
                        .disabled(isGenerating)
                        .accessibilityIdentifier("review-generate")
                    }
                    if let failure {
                        Text(failure).font(Typography.body(13)).foregroundStyle(Theme.Color.error)
                        if !isGenerating, mayGenerate {
                            Button("Retry") { Task { await generate() } }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Color.paper)
            .navigationTitle("Summary & feedback")
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

    /// Freezes the transcript and the marks now; later speech is not part of this report.
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
            failure = "Summary & feedback needs Neverblank Pro."
            plansPaywall = .init(trigger: .settings)
        } catch InterviewReviewClient.Failure.unavailable(let message) {
            failure = message
        } catch {
            failure = "The review could not be saved on this iPhone."
        }
    }
}

/// The saved report.
private struct ReportSections: View {
    let report: InterviewReviewReport
    let createdAt: Date

    var body: some View {
        Section {
            Text(report.disclaimer).font(Typography.body(12)).foregroundStyle(Theme.Color.secondary)
            Text("Generated \(createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(Typography.body(12)).foregroundStyle(Theme.Color.secondary)
        }
        list("Topics", report.topics)
        list("Questions discussed", report.questions)
        list("Your key points", report.key_points)
        if !report.strengths.isEmpty {
            Section("Strengths") {
                ForEach(report.strengths, id: \.point) { strength in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(strength.point).foregroundStyle(Theme.Color.ink)
                        Text("“\(strength.evidence)”").font(Typography.body(13)).foregroundStyle(Theme.Color.secondary)
                    }
                }
            }
        }
        if !report.improvements.isEmpty {
            Section("To improve") {
                ForEach(report.improvements, id: \.point) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.point).foregroundStyle(Theme.Color.ink)
                        Text(item.example).font(Typography.body(13)).foregroundStyle(Theme.Color.secondary)
                    }
                }
            }
        }
        list("Practice next", report.practice_questions)
        Section("Coaching score") {
            if let scores = report.scores {
                row("Relevance", scores.relevance)
                row("Clarity", scores.clarity)
                row("Structure", scores.structure)
                row("Supporting examples", scores.examples)
            }
            Text(report.score_note).font(Typography.body(13)).foregroundStyle(Theme.Color.secondary)
        }
    }

    @ViewBuilder
    private func list(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            Section(title) { ForEach(items, id: \.self) { Text($0).foregroundStyle(Theme.Color.ink) } }
        }
    }

    private func row(_ name: String, _ value: Int) -> some View {
        HStack { Text(name); Spacer(); Text("\(value) / 4").foregroundStyle(Theme.Color.secondary) }
    }
}
