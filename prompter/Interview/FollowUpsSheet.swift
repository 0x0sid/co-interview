import SwiftUI

/// What the interviewer is likely to ask next, ranked. A sheet rather than part of the page: it is a
/// glance, not something to read aloud.
///
/// The dots are green, amber and grey. **No red** — red on this screen means "recording", and a
/// follow-up being unlikely is not an alarm.
struct FollowUpsSheet: View {
    let question: InterviewQuestion

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(question.text)
                        .font(InterviewTheme.Font.ui(15, weight: .semibold, relativeTo: .subheadline))
                        .foregroundStyle(InterviewTheme.Color.muted)

                    ForEach(question.followUps, id: \.id) { followUp in
                        HStack(alignment: .top, spacing: 11) {
                            Circle()
                                .fill(followUp.likelihood.color)
                                .frame(width: 8, height: 8)
                                .padding(.top, 8)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(followUp.text)
                                    .font(InterviewTheme.Font.ui(16, relativeTo: .body))
                                    .foregroundStyle(InterviewTheme.Color.ink)
                                Text(followUp.likelihood.label)
                                    .font(InterviewTheme.Font.ui(12, weight: .medium, relativeTo: .caption1))
                                    .foregroundStyle(InterviewTheme.Color.muted)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(followUp.likelihood.label): \(followUp.text)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(InterviewTheme.Color.background)
            .navigationTitle("Follow-ups")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}
