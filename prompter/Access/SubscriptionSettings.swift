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
    @Environment(\.layoutMetrics) private var metrics

    private var cardState: SubscriptionCardState {
        #if DEBUG
        // UI screenshots only: `-UITestsSubscriptionState pro|pro-weekly|pro-yearly|cancelled|grace|
        // expired|expired-unknown|free`. Fixed dates, so captures are comparable.
        if let fixture = Self.fixture(UITestOverrides.subscriptionState) { return fixture }
        #endif
        return SubscriptionCardState.make(status: entitlements.status, needsVerification: access?.needsVerification ?? false,
                                          expiredAt: entitlements.expiredAt, plan: entitlements.activePlanName,
                                          subscription: entitlements.subscription, expiredPlan: entitlements.expiredPlanName)
    }

    #if DEBUG
    static func fixture(_ name: String?) -> SubscriptionCardState? {
        let date = { (y: Int, m: Int, d: Int) in
            Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d, hour: 12)) ?? .now
        }
        func active(_ plan: String, _ end: Date, renews: Bool, billingIssue: Bool = false) -> SubscriptionCardState {
            SubscriptionCardState.make(status: .premium(expiration: end, willRenew: renews), needsVerification: false,
                                       expiredAt: nil, plan: plan,
                                       subscription: .init(productIdentifier: plan.lowercased(), period: nil, expiration: end,
                                                           willRenew: renews, billingIssueDetectedAt: billingIssue ? .now : nil,
                                                           gracePeriodExpiresDate: billingIssue ? end : nil))
        }
        switch name {
        case "pro": return active("Monthly", date(2026, 10, 29), renews: true)
        case "pro-weekly": return active("Weekly", date(2026, 10, 6), renews: true)
        case "pro-yearly": return active("Yearly", date(2027, 9, 29), renews: true)
        case "cancelled": return active("Monthly", date(2026, 10, 29), renews: false)
        case "grace": return active("Monthly", date(2026, 10, 12), renews: true, billingIssue: true)
        case "expired": return .expired(plan: "Monthly", date: date(2026, 9, 29))
        case "expired-unknown": return .expired(plan: nil, date: date(2026, 9, 29))
        case "free": return .free
        default: return nil
        }
    }
    #endif

    private var badgeState: SettingsBadge.State {
        SettingsBadge.state(isPro: access?.isPro ?? false, needsVerification: access?.needsVerification ?? false,
                            usesServerAccess: access?.usesServerAccess ?? false, expiredAt: entitlements.expiredAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.cardSpacing) {
            header
            details
            // Restore stays in reach in every state, inside the card rather than a row beneath it.
            Button("Restore Purchases", action: onViewPlans)
                .font(Typography.body(metrics.bodySize, weight: .medium))
                .tint(Theme.Color.action)
                .frame(minHeight: 30)
                .accessibilityIdentifier("settings-restore")
            if entitlements.isTestStore {
                Text("Test Store · simulated purchases, not billed by Apple")
                    .font(Typography.body(metrics.footnoteSize - 1, weight: .medium))
                    .foregroundStyle(Theme.Color.warm)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let access, case .failed(let reason) = access.connection {
                Text(reason)
                    .font(Typography.body(metrics.footnoteSize))
                    .foregroundStyle(Theme.Color.error)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await access.bootstrap(backendURL: ProviderConfiguration.installationBackendURL()) } }
                    .font(Typography.body(metrics.footnoteSize + 1, weight: .medium))
            }
        }
        .padding(metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A native glass card with a hairline edge; the PRO / Expired pill carries the state, not a
        // coloured frame.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: metrics.cardCornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: metrics.cardCornerRadius, style: .continuous)
            .strokeBorder(Theme.Color.hairline, lineWidth: 0.5))
        .onAppear {
            wasUnseenOnOpen = SettingsBadge.shows(for: badgeState, seen: settingsBadgeSeen)
            if let seen = SettingsBadge.seenValue(for: badgeState) { settingsBadgeSeen = seen }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Neverblank Pro")
                .font(Typography.body(metrics.cardTitleSize, weight: .semibold))
                .foregroundStyle(Theme.Color.ink)
                .lineLimit(1)
                .layoutPriority(1)
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
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 18, minHeight: 18)
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

    private func line(_ text: String, primary: Bool = false, color: Color? = nil) -> some View {
        Text(text)
            .font(Typography.body(primary ? metrics.bodySize + 1 : metrics.bodySize, weight: primary ? .medium : .regular))
            .foregroundStyle(color ?? (primary ? Theme.Color.ink : Theme.Color.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var details: some View {
        switch cardState {
        case .verifying(let plan):
            // Recognised by the store, not yet authorised by the backend: two different things.
            line(plan.map { "Subscription recognised · \($0)" } ?? "Subscription recognised", primary: true)
                .accessibilityIdentifier("subscription-plan")
            line("Verifying access for this device. Answers unlock once it confirms.")
            if let access {
                Button(isVerifying ? "Verifying…" : "Retry verification") {
                    Task {
                        isVerifying = true
                        _ = await access.verifyProAfterPurchase()
                        isVerifying = false
                    }
                }
                .disabled(isVerifying)
                .font(Typography.body(metrics.bodySize, weight: .semibold))
                .accessibilityIdentifier("retry-verification")
            }
        case .active(let plan, let renewal, let note):
            VStack(alignment: .leading, spacing: 2) {
                if let plan {
                    line(plan, primary: true)
                        .accessibilityIdentifier("subscription-plan")
                }
                line(renewal)
                    .accessibilityIdentifier("subscription-renewal")
                if let note {
                    line(note.text, color: note == .billingIssue ? Theme.Color.warm : nil)
                        .accessibilityIdentifier("subscription-note")
                }
            }
            if !entitlements.isTestStore {
                Button { Task { await entitlements.showManageSubscriptions() } } label: {
                    Label("Manage subscription", systemImage: "creditcard")
                        .font(Typography.body(metrics.bodySize, weight: .semibold))
                        .frame(minHeight: metrics.cardControlHeight - 8)
                }
                .buttonStyle(.bordered)
                .tint(Theme.Color.action)
                .accessibilityIdentifier("manage-subscription")
            }
        case .expired(let plan, let date):
            VStack(alignment: .leading, spacing: 2) {
                if let plan {
                    line("\(plan) plan", primary: true)
                        .accessibilityIdentifier("subscription-plan")
                }
                line("Expired \(SubscriptionCardState.dateText(date, nearTime: false))", primary: plan == nil)
                    .accessibilityIdentifier("subscription-renewal")
            }
            primaryButton("Renew Pro", systemImage: "arrow.clockwise")
        case .free:
            VStack(alignment: .leading, spacing: 2) {
                line("Unlimited AI answers and Pro features.", primary: true)
                line(previewLine)
                    .accessibilityIdentifier("free-answers-disclosure")
            }
            primaryButton("Upgrade to Pro", systemImage: "sparkles")
        }
    }

    private func primaryButton(_ title: String, systemImage: String) -> some View {
        Button(action: onViewPlans) { Label(title, systemImage: systemImage) }
            .buttonStyle(CardPrimaryButtonStyle())
            .accessibilityIdentifier("view-plans")
    }

    /// One short line about the free answers; the full disclosure is shown where they are first used.
    private var previewLine: String {
        guard previewApplies, let access else { return "Developer build: free-answer limits don't apply here." }
        return AccessCopy.freeAnswersStatus(remaining: access.freeAnswersRemaining, limit: access.freeAnswerLimit)
    }
}

/// A small capsule label ("PRO", "Expired") — always next to text that says the same thing.
private struct StatusPill: View {
    let text: String
    let foreground: Color
    let background: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
    }
}

