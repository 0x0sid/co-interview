import SwiftUI

/// Trial or Pro, in one line — the start screen's status and the Live screen's header line.
///
/// - Free, answers left: an orange **Trial period** badge beside the real count ("2 free answers
///   remaining"), so it never reads as a timed trial. Tapping it opens the plans.
/// - Free, both used: **Trial used · Subscribe**, which opens the plans.
/// - Store-recognised but not yet verified by the backend: its own state, never shown as Pro.
/// - Verified: **Neverblank Pro** and the actual plan.
struct AccessStatusBadge: View {
    let entitlements: EntitlementService
    let access: AccessController
    /// False on the home screen: an active subscription is shown in Settings instead.
    var showsActivePro = true
    let onOpenPlans: () -> Void

    @ViewBuilder
    var body: some View {
        if access.needsVerification {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                Text("Subscription recognised · verifying access")
            }
            .font(Typography.body(13, weight: .semibold))
            .foregroundStyle(Theme.Color.secondary)
            .accessibilityIdentifier("status-verifying")
        } else if access.isPro {
            if showsActivePro { activePro }
        } else if access.usesServerAccess {
            trial
        }
    }

    private var activePro: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
            Text(entitlements.activePlanName.map { "Neverblank Pro · \($0)" } ?? "Neverblank Pro")
        }
        .font(Typography.body(13, weight: .semibold))
        .foregroundStyle(Theme.Color.action)
        .accessibilityIdentifier("status-pro")
    }

    private var trial: some View {
        HStack(spacing: 10) {
            Button(action: onOpenPlans) {
                Text(access.areFreeAnswersUsed ? "Trial used · Subscribe" : "Trial period")
                    .font(Typography.body(12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Self.orange, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("trial-badge")
            if !access.areFreeAnswersUsed {
                Text(AccessCopy.freeAnswersRemaining(access.freeAnswersRemaining))
                    .font(Typography.body(13))
                    .foregroundStyle(Theme.Color.secondary)
                    .accessibilityIdentifier("trial-remaining")
            }
        }
    }

    /// The trial badge's orange, fixed so it reads the same in light and dark appearance.
    static let orange = Color(red: 0.93, green: 0.45, blue: 0.13)
}
