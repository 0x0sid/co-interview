import SwiftUI
import SwiftData

/// **Prompter Premium** — the customer-facing name. RevenueCat is the implementation provider and is
/// never shown to the reader (M5.13).
///
/// Advertises only what is implemented: unlimited reading time. **No filming, no AI writing tools.**
struct PaywallScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Query private var settingsQuery: [AppSettings]

    let entitlements: EntitlementService

    @State private var message: String?
    @State private var isRestoring = false

    private var settings: AppSettings { AppSettings.fetchOrCreate(in: modelContext) }
    private var isPremium: Bool {
        if case .premium = entitlements.status { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if isPremium {
                    subscribedBody
                } else {
                    offerBody
                }

                if let message {
                    Text(message)
                        .font(Typography.body(14))
                        .foregroundStyle(Theme.Color.error)
                }

                legalFooter
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .background(Theme.Color.paper)
        .navigationTitle("Prompter Premium")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await entitlements.loadOffering()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompter Premium")
                .font(Typography.display(28))
                .foregroundStyle(Theme.Color.ink)
            Text("Unlimited reading time. Everything else stays free.")
                .font(Typography.body(16))
                .foregroundStyle(Theme.Color.secondary)
        }
    }

    // MARK: Subscribed — status, manage, restore. No second invitation to buy.

    private var subscribedBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Premium is active", systemImage: "checkmark.seal.fill")
                .font(Typography.body(17, weight: .semibold))
                .foregroundStyle(Theme.Color.action)

            if case .premium(let expiration, let willRenew) = entitlements.status, let expiration {
                Text(willRenew
                     ? "Renews on \(expiration.formatted(date: .abbreviated, time: .omitted))."
                     : "Access continues until \(expiration.formatted(date: .abbreviated, time: .omitted)) and will not renew.")
                    .font(Typography.body(14))
                    .foregroundStyle(Theme.Color.secondary)
            }

            Button("Manage Subscription") {
                Task { await entitlements.showManageSubscriptions() }
            }
            .buttonStyle(.prompterPrimary)

            restoreButton
        }
    }

    // MARK: Not subscribed

    private var offerBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Unlimited reading time", systemImage: "infinity")
                Label("Unlimited scripts — always free", systemImage: "doc.on.doc")
                Label("Everything stays on your iPhone", systemImage: "lock")
            }
            .font(Typography.body(16))
            .foregroundStyle(Theme.Color.ink)

            Text("Free includes \(UsageMeter.freeSecondsPerDay / 60) minutes of reading each day, plus the demo any time.")
                .font(Typography.body(14))
                .foregroundStyle(Theme.Color.secondary)

            switch entitlements.status {
            case .unconfigured:
                unavailableNotice("Subscriptions aren\u{2019}t available in this build yet.")
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            default:
                purchaseButton
            }

            restoreButton
        }
    }

    private var purchaseButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task {
                    message = nil
                    switch await entitlements.purchase() {
                    case .purchased: message = nil
                    case .cancelled: break                       // silent: the reader chose to stop
                    case .pending:
                        message = "Your purchase needs approval before Premium unlocks. You can keep using Prompter meanwhile."
                    case .failed(let text): message = text
                    case .notConfigured: message = "Subscriptions aren\u{2019}t available in this build yet."
                    }
                }
            } label: {
                // **Price comes from store product data, never hardcoded.**
                Text(entitlements.localizedPrice.map { price in
                    entitlements.localizedPeriod.map { "\(price) / \($0)" } ?? price
                } ?? "Subscribe")
            }
            .buttonStyle(.prompterPrimary)
            .disabled(entitlements.isPurchasing || entitlements.localizedPrice == nil)

            if entitlements.localizedPrice == nil {
                Text("Loading price\u{2026}")
                    .font(Typography.body(13))
                    .foregroundStyle(Theme.Color.secondary)
            }
        }
    }

    private var restoreButton: some View {
        Button("Restore Purchases") {
            Task {
                isRestoring = true
                defer { isRestoring = false }
                switch await entitlements.restore() {
                case .purchased: message = nil
                case .failed(let text): message = text
                case .notConfigured: message = "Subscriptions aren\u{2019}t available in this build yet."
                default: break
                }
            }
        }
        .buttonStyle(.prompterSecondary)
        .disabled(isRestoring)
    }

    private func unavailableNotice(_ text: String) -> some View {
        Text(text)
            .font(Typography.body(14))
            .foregroundStyle(Theme.Color.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Renewal terms and the links Apple requires alongside a subscription.
    private var legalFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subscriptions renew automatically until cancelled. Cancel any time in your Apple Account settings; cancellation takes effect at the end of the current period.")
            HStack(spacing: 16) {
                Button("Terms") { openURL(URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!) }
                Button("Privacy Policy") { openURL(URL(string: "https://prompter.app/privacy")!) }
            }
            .font(Typography.body(13, weight: .medium))
        }
        .font(Typography.body(12))
        .foregroundStyle(Theme.Color.secondary)
        .padding(.top, 8)
    }
}
