import SwiftUI

/// A saved interview's transcript, exactly as saved — local, no AI, available without Pro.
///
/// Lines keep their original wording and order. Saved lines carry no per-line time, so the header
/// gives the interview's start and last activity instead of inventing timestamps.
enum TranscriptExport {
    static func lines(of session: InterviewSessionRecord) -> [String] {
        session.utterances.sorted { $0.order < $1.order }.map(\.text).filter { !$0.isEmpty }
    }

    static func text(of session: InterviewSessionRecord) -> String {
        let started = session.createdAt.formatted(date: .long, time: .shortened)
        let last = session.lastActivityAt.formatted(date: .long, time: .shortened)
        var out = "\(session.title)\nStarted: \(started)\nLast activity: \(last)\nLanguage: \(session.language.displayName)\n"
        out += "(Lines are in the order they were said. Per-line times are not recorded.)\n\n"
        out += lines(of: session).joined(separator: "\n")
        out += "\n"
        return out
    }

    /// A plain-text file for sharing, in the temporary directory.
    static func file(for session: InterviewSessionRecord) -> URL? {
        let safe = session.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appending(path: "\(safe.isEmpty ? "Interview" : safe) — transcript.txt")
        do {
            try text(of: session).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

struct TranscriptViewer: View {
    let session: InterviewSessionRecord
    @Environment(\.dismiss) private var dismiss
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            let lines = TranscriptExport.lines(of: session)
            List {
                Section {
                    Text(InterviewHistoryCard<EmptyView>.whenAndHowLong(session))
                        .font(Typography.body(13))
                        .foregroundStyle(Theme.Color.secondary)
                }
                Section {
                    if lines.isEmpty {
                        Text("Nothing was transcribed in this interview.")
                            .foregroundStyle(Theme.Color.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(Typography.body(15))
                            .foregroundStyle(Theme.Color.ink)
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text("In the order it was said. Per-line times are not recorded.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Color.paper)
            .navigationTitle(session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("Export", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("transcript-export")
                    }
                }
            }
            .task { exportURL = TranscriptExport.file(for: session) }
        }
    }
}
