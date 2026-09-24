import SwiftUI

// Saved-interview history is shown **inline on the start screen** (`CopilotStartScreen.savedInterviews`),
// not as a pushed screen. A pushed history list re-rendered without end: the list's preference
// updates made the NavigationStack re-set the pushed view, which updated the list again. It looped
// even with a minimal body over the same @Query, and the cause inside SwiftUI is unresolved (see
// docs/CO_INTERVIEW_SESSION_HANDOFF.md). The start screen already queries the sessions and renders
// them without trouble, so history lives there.

/// One saved interview: title, when, how long, what is in it, and whether it was interrupted.
struct SessionRow: View {
    let session: InterviewSessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(session.title)
                    .font(Typography.body(15, weight: .semibold))
                    .foregroundStyle(Theme.Color.ink)
                    .lineLimit(2)
                if session.state == .interrupted {
                    Text("Interrupted")
                        .font(Typography.body(11, weight: .semibold))
                        .foregroundStyle(Theme.Color.warm)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(Capsule().stroke(Theme.Color.warm, lineWidth: 1))
                }
            }
            Text(details)
                .font(Typography.body(12))
                .foregroundStyle(Theme.Color.secondary)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        let when = session.lastActivityAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        let minutes = Int(session.activeSeconds / 60)
        let duration = minutes < 1 ? "under a minute" : "\(minutes) min"
        let answers = session.answeredCount
        let files = session.fileCount
        var parts = [when, duration, "\(answers) answer\(answers == 1 ? "" : "s")", session.language.displayName]
        if files > 0 { parts.append("\(files) file\(files == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}
