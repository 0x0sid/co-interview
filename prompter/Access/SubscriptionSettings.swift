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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if entitlements.isTestStore {
                Text("RevenueCat Test Store · simulated purchases, not billed or managed by Apple")
                    .font(Typography.body(12, weight: .medium))
                    .foregroundStyle(Theme.Color.warm)
            }
            if let access, access.needsVerification {
                // Recognised by the store, not yet authorised by the backend: two different things.
                Text(entitlements.activePlanName.map { "Subscription recognised · \($0)" } ?? "Subscription recognised")
                    .font(Typography.body(15, weight: .semibold))
                    .foregroundStyle(Theme.Color.ink)
                    .accessibilityIdentifier("subscription-plan")
                Text("Neverblank is still verifying access for this device. Answers unlock once it confirms.")
                    .font(Typography.body(13))
                    .foregroundStyle(Theme.Color.secondary)
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
            } else if case .premium(let expiration, let willRenew) = entitlements.status {
                Text(entitlements.activePlanName.map { "Neverblank Pro · \($0)" } ?? "Neverblank Pro")
                    .font(Typography.body(15, weight: .semibold))
                    .foregroundStyle(Theme.Color.ink)
                    .accessibilityIdentifier("subscription-plan")
                Text(Self.renewalLine(expiration: expiration, willRenew: willRenew))
                    .font(Typography.body(13))
                    .foregroundStyle(Theme.Color.secondary)
                if entitlements.isTestStore {
                    Text("Simulated in the Test Store: there is nothing to manage in Apple's Subscriptions.")
                        .font(Typography.body(12))
                        .foregroundStyle(Theme.Color.secondary)
                } else {
                    Button("Manage subscription") { Task { await entitlements.showManageSubscriptions() } }
                        .font(Typography.body(14, weight: .medium))
                        .accessibilityIdentifier("manage-subscription")
                }
            } else {
                Text("Free")
                    .font(Typography.body(15, weight: .semibold))
                    .foregroundStyle(Theme.Color.ink)
                Text(previewLine)
                    .font(Typography.body(13))
                    .foregroundStyle(Theme.Color.secondary)
                    .accessibilityIdentifier("preview-disclosure")
                Button("View plans", action: onViewPlans)
                    .font(Typography.body(14, weight: .semibold))
                    .accessibilityIdentifier("view-plans")
            }
            if let access, case .failed(let reason) = access.connection {
                Text(reason)
                    .font(Typography.body(12))
                    .foregroundStyle(Theme.Color.error)
                Button("Try again") { Task { await access.bootstrap(backendURL: ProviderConfiguration.installationBackendURL()) } }
                    .font(Typography.body(13, weight: .medium))
            }
        }
    }

    private var previewLine: String {
        guard previewApplies, let access else {
            return "This build is connected with a developer token, so the free preview and the Pro limit don't apply to Live here."
        }
        if access.isPreviewExhausted {
            return "Your free preview is used. Listening and the transcript stay free; questions and answers need Pro."
        }
        return AccessCopy.previewDisclosure
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
