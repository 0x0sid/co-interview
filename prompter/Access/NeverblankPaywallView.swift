import SwiftUI

/// Neverblank Pro. Sells the moment of use — real-time help while the questions are being asked —
/// with two plans at the store's own localized prices.
///
/// **Honest by construction:** no urgency, no invented discount or crossed-out price, no counts or
/// ratings. "Best value" and the saving appear only when the store's real prices support them
/// (`PlanSavings`). Auto-renewal terms, Restore Purchases and the legal links are always on the page.
///
/// A purchase counts only once the **backend** confirms Pro (`AccessController.verifyProAfterPurchase`);
/// `onFinish(true)` means verified access, and only then does a held Generate request go out.
struct NeverblankPaywallView: View {
    let trigger: PaywallTrigger
    let entitlements: EntitlementService
    let access: AccessController
    /// True: access verified. False: closed without it.
    let onFinish: (Bool) -> Void

    @State private var selected: PlanKind = .monthly
    /// Set once the reader picks a plan; nothing chooses for them after that.
    @State private var userChose = false
    @State private var phase: Phase = .choosing
    @State private var message: String?
    @State private var finished = false

    enum Phase: Equatable { case choosing, purchasing, confirming, restoring }

    /// The store took the payment but the backend has not confirmed Pro: offer Retry verification,
    /// never a second purchase.
    private var isVerificationPending: Bool { access.needsVerification }

    private var plans: [EntitlementService.PlanOffer] { entitlements.plans }
    private func plan(_ kind: PlanKind) -> EntitlementService.PlanOffer? { plans.first { $0.kind == kind } }

    private var prices: [PlanSavings.Price] {
        plans.map { PlanSavings.Price(kind: $0.kind, amount: $0.price, currency: $0.currencyCode) }
    }
    /// What savings are measured against: the subscription that costs most per week.
    private var baseline: PlanSavings.Price? { PlanSavings.baseline(prices) }
    /// "Best value" goes only to the plan the store's prices make cheapest per week — if any saves.
    private var bestValue: PlanKind? { PlanSavings.bestValue(prices) }

    private func saving(_ offer: EntitlementService.PlanOffer) -> Int? {
        guard let baseline, baseline.kind != offer.kind else { return nil }
        return PlanSavings.savingPercent(.init(kind: offer.kind, amount: offer.price, currency: offer.currencyCode), comparedWith: baseline)
    }

    /// Shown order: the longest commitment first, lifetime last.
    private static let order: [PlanKind] = [.yearly, .monthly, .weekly, .lifetime]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                closeRow
                header
                if let context = contextLine {
                    Text(context)
                        .font(Typography.body(14))
                        .foregroundStyle(Theme.Color.ink)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: 12))
                }
                benefits
                if entitlements.isTestStore { testStoreNotice }
                if isVerificationPending {
                    verificationPendingBlock
                } else {
                    planPicker
                    // No plans, no purchase button: a control that cannot work is not offered.
                    if !plans.isEmpty { continueButton }
                }
                if let message {
                    Text(message)
                        .font(Typography.body(13))
                        .foregroundStyle(Theme.Color.error)
                        .accessibilityIdentifier("paywall-message")
                }
                footer
            }
            .padding(20)
        }
        .background(Theme.Color.paper)
        .interactiveDismissDisabled(phase != .choosing)
        .task {
            access.log(.init(name: .paywallViewed, trigger: trigger))
            if plans.isEmpty { await entitlements.loadOffering() }
            preselect()
        }
        .onChange(of: plans) { _, _ in preselect() }
        .onDisappear {
            if !finished { finish(false) }
        }
    }

    // MARK: Sections

    private var closeRow: some View {
        HStack {
            Spacer()
            Button { finish(false) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Color.secondary)
                    .frame(width: 36, height: 36)
                    .background(Theme.Color.card, in: Circle())
            }
            .disabled(phase != .choosing)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("paywall-close")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Never interview alone again.")
                .font(Typography.display(30))
                .foregroundStyle(Theme.Color.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Real-time answers when the questions start.")
                .font(Typography.body(17))
                .foregroundStyle(Theme.Color.secondary)
        }
    }

    /// Why the paywall is here, in the reader's terms. The session is never at risk and says so.
    private var contextLine: String? {
        switch trigger {
        case .previewEnd: "Your free preview has ended. Everything from this interview is saved, and listening continues."
        case .generate, .retry: "Your answer is kept. It will be written as soon as you unlock Pro."
        case .settings: nil
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.benefitLines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.Color.action)
                    Text(line)
                        .font(Typography.body(15))
                        .foregroundStyle(Theme.Color.ink)
                }
            }
        }
    }

    static let benefitLines = [
        "A real-time interview copilot",
        "Answers built from the conversation",
        "Uses your CV and interview context",
        "Questions detected while they are asked",
        "Your interview history, kept on your iPhone",
        "Full Live sessions with Pro",
    ]

    /// Why no plans are shown. Never a price that did not come from the store.
    private var unavailableMessage: String {
        if entitlements.isLoadingOffering { return "Loading plans…" }
        if entitlements.status == .unconfigured {
            return "Plans can't be shown yet: subscriptions aren't set up in this build. Nothing has been charged."
        }
        return entitlements.offeringsError ?? "Plans could not be loaded. Check your connection and try again."
    }

    @ViewBuilder
    private var planPicker: some View {
        if plans.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(unavailableMessage)
                    .font(Typography.body(14))
                    .foregroundStyle(Theme.Color.ink)
                    .accessibilityIdentifier("paywall-plans-unavailable")
                if !entitlements.isLoadingOffering {
                    Button("Retry") { Task { await entitlements.loadOffering() } }
                        .font(Typography.body(14, weight: .semibold))
                        .accessibilityIdentifier("paywall-retry")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.Color.hairline, lineWidth: 0.5))
        } else {
            VStack(spacing: 10) {
                ForEach(Self.order, id: \.self) { kind in
                    if let offer = plan(kind) { planRow(offer) }
                }
            }
        }
    }

    private func planRow(_ offer: EntitlementService.PlanOffer) -> some View {
        let isSelected = selected == offer.kind
        let isRecommended = offer.kind == bestValue
        return Button {
            userChose = true
            guard selected != offer.kind else { return }
            selected = offer.kind
            // The funnel's events name the two original plans; the plan field carries the rest.
            access.log(.init(name: offer.kind == .weekly ? .weeklySelected : .monthlySelected, plan: offer.kind, trigger: trigger))
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Theme.Color.action : Theme.Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(offer.kind.title)
                            .font(Typography.body(16, weight: .semibold))
                            .foregroundStyle(Theme.Color.ink)
                        if isRecommended {
                            Text("BEST VALUE")
                                .font(Typography.mono(10, weight: .medium))
                                .foregroundStyle(Theme.Color.onDark)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Theme.Color.action, in: Capsule())
                        }
                    }
                    if let subtitle = subtitle(for: offer) {
                        Text(subtitle)
                            .font(Typography.body(12))
                            .foregroundStyle(Theme.Color.secondary)
                    }
                }
                Spacer()
                Text(offer.kind.periodNoun.map { "\(offer.localizedPrice) / \($0)" } ?? offer.localizedPrice)
                    .font(Typography.body(15, weight: .semibold))
                    .foregroundStyle(Theme.Color.ink)
            }
            .padding(isRecommended ? 16 : 14)
            .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? Theme.Color.action : Theme.Color.hairline, lineWidth: isSelected ? 2 : 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("plan-\(offer.kind.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var continueButton: some View {
        VStack(spacing: 8) {
            Button {
                Task { await purchase() }
            } label: {
                HStack(spacing: 8) {
                    if phase == .purchasing || phase == .confirming { ProgressView().tint(Theme.Color.onDark) }
                    Text(phase == .confirming ? "Confirming your subscription…" : "Continue")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.prompterPrimary)
            .disabled(plan(selected) == nil || phase != .choosing)
            .accessibilityIdentifier("paywall-continue")
            Text(selected == .lifetime ? "One-time purchase." : "Cancel anytime.")
                .font(Typography.body(13, weight: .medium))
                .foregroundStyle(Theme.Color.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let offer = plan(selected) {
                Text(termsLine(for: offer))
                    .font(Typography.body(11))
                    .foregroundStyle(Theme.Color.secondary)
            }
            HStack(spacing: 16) {
                Button(phase == .restoring ? "Restoring…" : "Restore Purchases") { Task { await restore() } }
                    .disabled(phase != .choosing)
                    .accessibilityIdentifier("paywall-restore")
                if let terms = LegalLinks.terms { Link("Terms of Use", destination: terms) }
                if let privacy = LegalLinks.privacy { Link("Privacy Policy", destination: privacy) }
            }
            .font(Typography.body(12, weight: .medium))
        }
    }

    private func subtitle(for offer: EntitlementService.PlanOffer) -> String? {
        if offer.kind == .lifetime { return "One-time purchase · never renews" }
        if let saving = saving(offer), let baseline {
            return "Save \(saving)% compared with paying \(baseline.kind.title.lowercased())"
        }
        return offer.kind == .weekly ? "Low commitment" : nil
    }

    private func termsLine(for offer: EntitlementService.PlanOffer) -> String {
        guard let noun = offer.kind.periodNoun else {
            return "Neverblank Pro Lifetime is a one-time purchase of \(offer.localizedPrice), charged to your Apple Account. It does not renew."
        }
        return "Neverblank Pro \(offer.kind.title) renews automatically at \(offer.localizedPrice) per \(noun) until you cancel. Payment is charged to your Apple Account. Cancel at least 24 hours before renewal in Settings › Apple Account › Subscriptions."
    }

    /// Starts on the best value when the prices show one, otherwise Monthly, otherwise the first plan.
    private func preselect() {
        guard phase == .choosing, !(userChose && plan(selected) != nil) else { return }
        selected = bestValue ?? (plan(.monthly) != nil ? .monthly : Self.order.first { plan($0) != nil } ?? .monthly)
    }

    private var testStoreNotice: some View {
        Text("RevenueCat Test Store — purchases here are simulated and never billed or managed by Apple.")
            .font(Typography.body(12, weight: .medium))
            .foregroundStyle(Theme.Color.warm)
            .accessibilityIdentifier("paywall-test-store")
    }

    /// Purchase succeeded, access not yet confirmed. Nothing here can buy again.
    private var verificationPendingBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Purchase complete — confirming access")
                .font(Typography.body(15, weight: .semibold))
                .foregroundStyle(Theme.Color.ink)
            Text("Your purchase went through. Neverblank has not confirmed Pro for this device yet, so answers stay locked until it does. You won't be charged again.")
                .font(Typography.body(13))
                .foregroundStyle(Theme.Color.secondary)
            Button {
                Task { await confirm(event: .purchaseCompleted) }
            } label: {
                HStack(spacing: 8) {
                    if phase == .confirming { ProgressView().tint(Theme.Color.onDark) }
                    Text(phase == .confirming ? "Confirming…" : "Retry verification")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.prompterPrimary)
            .disabled(phase != .choosing)
            .accessibilityIdentifier("paywall-retry-verification")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Actions

    private func purchase() async {
        guard phase == .choosing else { return }
        message = nil
        // A purchase must land on the customer the backend checks. Not registered, or RevenueCat not
        // yet on the server-issued id: do not take the payment.
        guard access.usesServerAccess else {
            message = "Purchases are off in this development build: it is not registered with the Neverblank server, so a purchase could not be linked to your access."
            return
        }
        phase = .purchasing
        guard await access.prepareForPurchase() else {
            message = "Neverblank is still setting up this device. Check your connection and try again in a moment."
            phase = .choosing
            return
        }
        access.log(.init(name: .purchaseStarted, plan: selected, trigger: trigger))
        let outcome = await entitlements.purchase(plan: selected)
        switch outcome {
        case .purchased, .pending where entitlements.hasActivePro:
            await confirm(event: .purchaseCompleted)
        case .cancelled:
            access.log(.init(name: .purchaseFailed, plan: selected, trigger: trigger, reason: .cancelled))
            phase = .choosing
        case .pending:
            access.log(.init(name: .purchaseFailed, plan: selected, trigger: trigger, reason: .pending))
            message = "Your purchase is waiting for approval. Pro unlocks as soon as it is approved."
            phase = .choosing
        case .failed(let detail):
            access.log(.init(name: .purchaseFailed, plan: selected, trigger: trigger, reason: .storeError))
            message = detail
            phase = .choosing
        case .notConfigured:
            access.log(.init(name: .purchaseFailed, plan: selected, trigger: trigger, reason: .unavailable))
            message = "Subscriptions are not available in this build."
            phase = .choosing
        }
    }

    private func restore() async {
        guard phase == .choosing else { return }
        message = nil
        phase = .restoring
        switch await entitlements.restore() {
        case .purchased:
            if entitlements.isTestStore {
                message = "Test Store restore: this reflects RevenueCat's simulated purchases, not an Apple restore."
            }
            await confirm(event: .purchaseRestored)
        case .failed(let detail):
            access.log(.init(name: .purchaseFailed, trigger: trigger, reason: .notEntitled))
            message = detail
            phase = .choosing
        case .notConfigured:
            message = "Restore isn't available yet: subscriptions aren't set up in this build."
            phase = .choosing
        default:
            message = "Nothing to restore."
            phase = .choosing
        }
    }

    /// The store says yes; the backend must agree before anything is unlocked or resumed.
    private func confirm(event: ProductEvent.Name) async {
        phase = .confirming
        if await access.verifyProAfterPurchase() {
            access.log(.init(name: event, plan: event == .purchaseCompleted ? selected : nil, trigger: trigger))
            finish(true)
        } else {
            // Not a failure of the purchase: the pending block offers Retry verification.
            access.log(.init(name: .purchaseFailed, plan: selected, trigger: trigger, reason: .network))
            phase = .choosing
        }
    }

    private func finish(_ unlocked: Bool) {
        guard !finished else { return }
        finished = true
        if !unlocked { access.log(.init(name: .paywallDismissed, trigger: trigger)) }
        onFinish(unlocked)
    }
}

/// The Terms of Use and Privacy Policy pages, from the build's Info.plist (`NeverblankTermsURL`,
/// `NeverblankPrivacyURL`). Required on the paywall by App Review; nil until configured.
enum LegalLinks {
    static var terms: URL? { url("NeverblankTermsURL") }
    static var privacy: URL? { url("NeverblankPrivacyURL") }

    private static func url(_ key: String) -> URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !raw.isEmpty, !raw.hasPrefix("$("), let url = URL(string: raw), url.scheme == "https" else { return nil }
        return url
    }
}
