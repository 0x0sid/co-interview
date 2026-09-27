import SwiftUI

/// Settings › Subscription. **Always shown**, whatever the build or connection state, so the plans
/// are never out of reach: a free user sees the preview's state and "View plans"; a subscriber sees
/// their plan, when it renews or ends, and "Manage subscription".
///
/// Opening the paywall from here never generates anything: `onViewPlans` presents it with the
/// `.settings` trigger, and a purchase made there resumes no request.
struct SubscriptionSettingsView: View {
    let entitlements: EntitlementService
    let access: AccessController?
    /// True when this build's Live sessions use the free preview (installation access).
    let previewApplies: Bool
    let onViewPlans: () -> Void
    @State private var isVerifying = false
    /// Seeing this section is what clears the home screen's Settings badge, for this state only.
    @AppStorage(SettingsBadge.storageKey) private var settingsBadgeSeen = ""

    /// True for this visit when the section had not been seen in this state: the card shows its own
    /// small "1" while the gear's badge clears for good.
    @State private var wasUnseenOnOpen = false

    private var cardState: SubscriptionCardState {
        SubscriptionCardState.make(status: entitlements.status, needsVerification: access?.needsVerification ?? false,
                                   expiredAt: entitlements.expiredAt, plan: entitlements.activePlanName)
    }

    private var badgeState: SettingsBadge.State {
        SettingsBadge.state(isPro: access?.isPro ?? false, needsVerification: access?.needsVerification ?? false,
                            usesServerAccess: access?.usesServerAccess ?? false, expiredAt: entitlements.expiredAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            details
            // Restore stays in reach in every state, inside the card rather than a row beneath it.
            Button("Restore Purchases", action: onViewPlans)
                .font(Typography.body(14, weight: .medium))
                .tint(Theme.Color.action)
                .accessibilityIdentifier("settings-restore")
            if entitlements.isTestStore {
                Text("RevenueCat Test Store · simulated purchases, not billed or managed by Apple")
                    .font(Typography.body(12, weight: .medium))
                    .foregroundStyle(Theme.Color.warm)
            }
            if let access, case .failed(let reason) = access.connection {
                Text(reason)
                    .font(Typography.body(12))
                    .foregroundStyle(Theme.Color.error)
                Button("Try again") { Task { await access.bootstrap(backendURL: ProviderConfiguration.installationBackendURL()) } }
                    .font(Typography.body(13, weight: .medium))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(cardBorder, lineWidth: 1))
        .onAppear {
            wasUnseenOnOpen = SettingsBadge.shows(for: badgeState, seen: settingsBadgeSeen)
            if let seen = SettingsBadge.seenValue(for: badgeState) { settingsBadgeSeen = seen }
        }
    }

    /// Active reads as the app's action colour; expired as warm; free and verifying stay neutral.
    private var cardBorder: Color {
        switch cardState {
        case .active: Theme.Color.action.opacity(0.55)
        case .expired: Theme.Color.warm.opacity(0.6)
        case .free, .verifying: Theme.Color.hairline
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Neverblank Pro")
                .font(Typography.body(18, weight: .semibold))
                .foregroundStyle(Theme.Color.ink)
            Spacer(minLength: 8)
            switch cardState {
            case .active:
                StatusPill(text: "PRO", foreground: Theme.Color.onDark, background: Theme.Color.action)
                    .accessibilityIdentifier("pro-badge")
            case .expired:
                StatusPill(text: "Expired", foreground: Theme.Color.onDark, background: Theme.Color.warm)
                    .accessibilityIdentifier("expired-badge")
            case .free, .verifying:
                if wasUnseenOnOpen {
                    Text("1")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Color.red, in: Circle())
                        .accessibilityLabel("New")
                        .accessibilityIdentifier("subscription-new-badge")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cardState.accessibilitySummary)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("subscription-title")
    }

    @ViewBuilder
    private var details: some View {
        switch cardState {
        case .verifying(let plan):
            // Recognised by the store, not yet authorised by the backend: two different things.
            Text(plan.map { "Subscription recognised · \($0)" } ?? "Subscription recognised")
                .font(Typography.body(15, weight: .semibold))
                .foregroundStyle(Theme.Color.ink)
                .accessibilityIdentifier("subscription-plan")
            Text("Neverblank is still verifying access for this device. Answers unlock once it confirms.")
                .font(Typography.body(13))
                .foregroundStyle(Theme.Color.secondary)
            if let access {
                Button(isVerifying ? "Verifying…" : "Retry verification") {
                    Task {
                        isVerifying = true
                        _ = await access.verifyProAfterPurchase()
                        isVerifying = false
                    }
                }
                .disabled(isVerifying)
                .font(Typography.body(14, weight: .semibold))
                .accessibilityIdentifier("retry-verification")
            }
        case .active(let plan, let renewal):
            VStack(alignment: .leading, spacing: 2) {
                if let plan {
                    Text("\(plan) plan")
                        .font(Typography.body(15, weight: .medium))
                        .foregroundStyle(Theme.Color.ink)
                        .accessibilityIdentifier("subscription-plan")
                }
                Text(renewal)
                    .font(Typography.body(13))
                    .foregroundStyle(Theme.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if entitlements.isTestStore {
                Text("Simulated in the Test Store: there is nothing to manage in Apple's Subscriptions.")
                    .font(Typography.body(12))
                    .foregroundStyle(Theme.Color.secondary)
            } else {
                Button { Task { await entitlements.showManageSubscriptions() } } label: {
                    Label("Manage subscription", systemImage: "creditcard")
                        .font(Typography.body(15, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(Theme.Color.action)
                .accessibilityIdentifier("manage-subscription")
            }
        case .expired(let date):
            Text("Expired on \(date.formatted(date: .abbreviated, time: .omitted))")
                .font(Typography.body(15, weight: .medium))
                .foregroundStyle(Theme.Color.ink)
                .accessibilityIdentifier("subscription-plan")
            Text(previewLine)
                .font(Typography.body(13))
                .foregroundStyle(Theme.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("free-answers-disclosure")
            primaryButton("Renew", systemImage: "arrow.clockwise")
        case .free:
            Text("Unlock unlimited interview assistance and Pro features.")
                .font(Typography.body(15))
                .foregroundStyle(Theme.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(previewLine)
                .font(Typography.body(13))
                .foregroundStyle(Theme.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("free-answers-disclosure")
            primaryButton("Upgrade to Pro", systemImage: "sparkles")
        }
    }

    private func primaryButton(_ title: String, systemImage: String) -> some View {
        Button(action: onViewPlans) {
            Label(title, systemImage: systemImage)
                .font(Typography.body(16, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.Color.action)
        .foregroundStyle(Theme.Color.onDark)
        .accessibilityIdentifier("view-plans")
    }

    private var previewLine: String {
        guard previewApplies, let access else {
            return "This build is connected with a developer token, so the free answers and the Pro limit don't apply to Live here."
        }
        if access.areFreeAnswersUsed {
            return "Your 2 free AI answers are used. Listening, the transcript, history and files stay free; more AI answers need Pro."
        }
        return AccessCopy.freeAnswersRemaining(access.freeAnswersRemaining) + ". " + AccessCopy.freeAnswersDisclosure
    }

    /// A cancelled plan keeps access until it actually ends, and says so.
    static func renewalLine(expiration: Date?, willRenew: Bool) -> String {
        guard let expiration else { return "Active." }
        // Within a day (Test Store periods are minutes to hours), the time matters as much as the date.
        let date = expiration.timeIntervalSinceNow < 86_400
            ? expiration.formatted(date: .abbreviated, time: .shortened)
            : expiration.formatted(date: .abbreviated, time: .omitted)
        return willRenew ? "Renews on \(date)." : "Active until \(date). It will not renew."
    }
}

/// A small capsule label ("PRO", "Expired") — always next to text that says the same thing.
private struct StatusPill: View {
    let text: String
    let foreground: Color
    let background: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
    }
}

