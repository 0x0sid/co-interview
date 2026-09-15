import SwiftUI

/// **Prompter Premium — informational only (M5.12).**
///
/// Deliberately has no Subscribe button, no price confirmation and no purchase path: billing is not
/// implemented, and a button that cannot buy anything would be worse than none. Nothing here implies
/// a subscription is active.
struct PremiumAnnouncementScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Prompter Premium")
                    .font(Typography.display(28))
                    .foregroundStyle(Theme.Color.ink)

                Text("Coming soon")
                    .font(Typography.body(15, weight: .semibold))
                    .foregroundStyle(Theme.Color.action)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.Color.currentSentence))

                Text("Subscriptions aren\u{2019}t available yet. Everything in Prompter is free to use right now, and nothing has been charged.")
                    .font(Typography.body(16))
                    .foregroundStyle(Theme.Color.ink)

                VStack(alignment: .leading, spacing: 10) {
                    Text("What we\u{2019}re working on")
                        .font(Typography.body(14, weight: .semibold))
                        .foregroundStyle(Theme.Color.secondary)
                    Label("Unlimited reading time", systemImage: "infinity")
                    Label("Longer scripts", systemImage: "doc.text")
                }
                .font(Typography.body(15))
                .foregroundStyle(Theme.Color.ink)

                Text("Everything runs on your iPhone. We can\u{2019}t see your scripts \u{2014} there\u{2019}s no server to send them to.")
                    .font(Typography.body(13))
                    .foregroundStyle(Theme.Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .background(Theme.Color.paper)
        .navigationTitle("Prompter Premium")
        .navigationBarTitleDisplayMode(.inline)
    }
}
