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
    @Environment(\.scenePhase) private var scenePhase

    /// What each plan is for this customer right now — from RevenueCat CustomerInfo.
    private var availability: [PlanKind: EntitlementService.PlanAvailability] {
        EntitlementService.planAvailability(for: plans, subscription: entitlements.presentation())
    }
    private func isPurchasable(_ kind: PlanKind) -> Bool { availability[kind] == .purchasable }
    /// A plan is active: any plan still buyable here is an upgrade from it.
    private var hasCurrentPlan: Bool { availability.values.contains(.current) }

    /// What the main button does for a plan: Become Pro, Upgrade, or Manage subscription.
    private func action(for kind: PlanKind) -> EntitlementService.PaywallAction {
        EntitlementService.paywallAction(selected: kind, availability: availability, subscription: entitlements.presentation())
    }
    /// A plan card can be chosen only when choosing it leads to a purchase.
    private func isSelectable(_ kind: PlanKind) -> Bool {
        isPurchasable(kind) && action(for: kind) != .manageSubscription
    }
    /// When the active entitlement ends, if the paywall is still open: CustomerInfo is fetched again so
    /// the page leaves subscriber mode on RevenueCat's word, not on a local clock.
    private var activeUntil: Date? {
        let subscription = entitlements.presentation()
        return subscription.entitlementActive ? subscription.expirationDate : nil
    }

    private var plans: [EntitlementService.PlanOffer] { entitlements.plans }
    private func plan(_ kind: PlanKind) -> EntitlementService.PlanOffer? { plans.first { $0.kind == kind } }

    private var prices: [PlanSavings.Price] {
        plans.map { PlanSavings.Price(kind: $0.kind, amount: $0.price, currency: $0.currencyCode) }
    }
    /// The plan the store's prices make cheapest per week, if any saves — only to preselect it.
    private var bestValue: PlanKind? { PlanSavings.bestValue(prices) }

    /// Shown order: shortest period first, so Monthly and Yearly read as a pair.
    private static let order: [PlanKind] = [.weekly, .monthly, .yearly]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                closeRow
                header
                if let context = contextLine {
                    Text(context)
                        .font(Typography.body(14))
                        .foregroundStyle(Theme.Color.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                benefits
                if let notice = BillingEnvironment.testStoreNotice(.paywall) { testStoreNotice(notice) }
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
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .background(Theme.Color.paper)
        .interactiveDismissDisabled(phase != .choosing)
        .task {
            access.log(.init(name: .paywallViewed, trigger: trigger))
            // Fresh CustomerInfo and offering: the current plan is never judged from stale state.
            await entitlements.refresh()
            if plans.isEmpty { await entitlements.loadOffering() }
            preselect()
        }
        .onChange(of: plans) { _, _ in preselect() }
        .onChange(of: availability) { _, _ in preselect() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await entitlements.refresh() }
        }
        .task(id: activeUntil) {
            guard let end = activeUntil, end > .now else { return }
            try? await Task.sleep(for: .seconds(end.timeIntervalSinceNow + 2))
            guard !Task.isCancelled else { return }
            await entitlements.refresh()
        }
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Never interview alone again.")
                .font(Typography.display(28))
                .foregroundStyle(Theme.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Real-time answers when the questions start.")
                .font(Typography.body(16))
                .foregroundStyle(Theme.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Why the paywall is here, in the reader's terms. The session is never at risk and says so.
    private var contextLine: String? {
        switch trigger {
        case .freeAnswersExhausted: "You've used your \(FreeAnswersRecord.limit) free interview answers. Everything from this interview is saved, and listening continues."
        case .generate, .retry: "Your answer is kept. It will be written as soon as you unlock Pro."
        case .settings: nil
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.benefitLines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.Color.action)
                    Text(line)
                        .font(Typography.body(15))
                        .foregroundStyle(Theme.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
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
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            // One complete card per real plan in the offering, each with its own full frame.
            VStack(spacing: 10) {
                ForEach(Self.order.compactMap(plan), id: \.kind) { offer in
                    planCard(offer)
                }
            }
        }
    }

    private func planCard(_ offer: EntitlementService.PlanOffer) -> some View {
        let state = availability[offer.kind] ?? .purchasable
        let selectable = isSelectable(offer.kind)
        let isSelected = selected == offer.kind && selectable
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button {
            guard selectable else { return }
            userChose = true
            guard selected != offer.kind else { return }
            withAnimation(.snappy(duration: 0.2)) { selected = offer.kind }
            // The funnel's events name the two original plans; the plan field carries the rest.
            access.log(.init(name: offer.kind == .weekly ? .weeklySelected : .monthlySelected, plan: offer.kind, trigger: trigger))
        } label: {
            HStack(alignment: .center, spacing: 12) {
                selectionMark(selected: isSelected, selectable: selectable)
                VStack(alignment: .leading, spacing: 3) {
                    // Title and pill side by side; the pill drops under the title when space is short.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { planTitle(offer, emphasized: isSelected); planBadge(offer.kind, state: state) }
                        VStack(alignment: .leading, spacing: 4) { planTitle(offer, emphasized: isSelected); planBadge(offer.kind, state: state) }
                    }
                    if let subtitle = subtitle(for: offer) {
                        Text(subtitle)
                            .font(Typography.body(12.5))
                            .foregroundStyle(Theme.Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if state == .managedByApple {
                        Text("Change in Apple subscriptions")
                            .font(Typography.body(11.5))
                            .foregroundStyle(Theme.Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                Text(offer.pricePerPeriod)
                    .font(Typography.body(15, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(state == .current ? Theme.Color.secondary : Theme.Color.ink)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            // A solid card on the page, a hairline frame all round; the selected card is tinted and
            // framed in the accent. Nothing translucent, so no edge fades into the background.
            .background {
                shape.fill(Theme.Color.card)
                if isSelected { shape.fill(Theme.Color.action.opacity(0.10)) }
            }
            .overlay {
                shape.strokeBorder(isSelected ? Theme.Color.action : Theme.Color.hairline, lineWidth: isSelected ? 1.5 : 1)
            }
            .opacity(state == .managedByApple ? 0.55 : 1)
            .contentShape(shape)
        }
        .buttonStyle(PlanRowPressStyle())
        .disabled(!selectable)
        .accessibilityIdentifier("plan-\(offer.kind.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(state == .current ? "Your current plan" : state == .managedByApple ? "Change plans in Apple subscription settings" : "")
    }

    private func planTitle(_ offer: EntitlementService.PlanOffer, emphasized: Bool) -> some View {
        Text(offer.kind.title)
            .font(Typography.body(16, weight: emphasized ? .semibold : .medium))
            .foregroundStyle(Theme.Color.ink)
            .lineLimit(1)
            .fixedSize()
    }

    /// A radio mark: filled accent check when selected, an open ring when it can be chosen, a faint
    /// ring on a plan that cannot (the current plan, or one Apple's settings change).
    private func selectionMark(selected: Bool, selectable: Bool) -> some View {
        ZStack {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.Color.action)
            } else {
                Circle()
                    .strokeBorder(selectable ? Theme.Color.secondary.opacity(0.6) : Theme.Color.hairline, lineWidth: 1.5)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }

    /// "Current plan": a soft accent pill. "Upgrade": solid accent, only while another plan is active.
    @ViewBuilder
    private func planBadge(_ kind: PlanKind, state: EntitlementService.PlanAvailability) -> some View {
        switch state {
        case .current:
            Text("Current plan")
                .font(Typography.body(11.5, weight: .semibold))
                .foregroundStyle(Theme.Color.action)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.Color.action.opacity(0.14), in: Capsule())
                .fixedSize()
                .accessibilityIdentifier("plan-current-\(kind.rawValue)")
        case .purchasable where hasCurrentPlan:
            Text("Upgrade")
                .font(Typography.body(11.5, weight: .semibold))
                .foregroundStyle(Theme.Color.onDark)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.Color.action, in: Capsule())
                .fixedSize()
                .accessibilityIdentifier("plan-upgrade-\(kind.rawValue)")
        default:
            EmptyView()
        }
    }

    /// Not subscribed: "Become Pro". Subscribed: "Upgrade to Yearly" with Manage subscription beside
    /// it, or Manage subscription alone when there is nothing to buy (`EntitlementService.PaywallAction`).
    @ViewBuilder
    private var continueButton: some View {
        switch action(for: selected) {
        case .becomePro:
            purchaseButton(title: "Become Pro", caption: selected == .lifetime ? "One-time purchase." : "Cancel anytime.")
        case .upgrade(let kind):
            VStack(spacing: 4) {
                purchaseButton(title: "Upgrade to \(kind.title)", caption: nil)
                manageLink
            }
        case .manageSubscription:
            VStack(spacing: 8) {
                Button {
                    Task { await entitlements.showManageSubscriptions() }
                } label: {
                    Text("Manage subscription").frame(maxWidth: .infinity)
                }
                .buttonStyle(.prompterPrimary)
                .accessibilityIdentifier("paywall-manage-subscription")
                Text("You're subscribed to Neverblank Pro.")
                    .font(Typography.body(12.5, weight: .medium))
                    .foregroundStyle(Theme.Color.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// A subscriber can always reach Apple's own subscription page, upgrade or not.
    private var manageLink: some View {
        Button("Manage subscription") { Task { await entitlements.showManageSubscriptions() } }
            .font(Typography.body(13, weight: .medium))
            .tint(Theme.Color.action)
            .frame(maxWidth: .infinity, minHeight: 36)
            .disabled(phase != .choosing)
            .accessibilityIdentifier("paywall-manage-subscription")
    }

    private func purchaseButton(title: String, caption: String?) -> some View {
        VStack(spacing: 8) {
            Button {
                Task { await purchase() }
            } label: {
                HStack(spacing: 8) {
                    if phase == .purchasing || phase == .confirming { ProgressView().tint(Theme.Color.onDark) }
                    Text(phase == .confirming ? "Confirming your subscription…" : title)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.prompterPrimary)
            .disabled(plan(selected) == nil || !isSelectable(selected) || phase != .choosing)
            .accessibilityIdentifier("paywall-continue")
            if let caption {
                Text(caption)
                    .font(Typography.body(12.5, weight: .medium))
                    .foregroundStyle(Theme.Color.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let offer = plan(selected) {
                Text(termsLine(for: offer))
                    .font(Typography.body(11))
                    .foregroundStyle(Theme.Color.secondary)
            }
            // One line when it fits; two on a small iPhone rather than a clipped link.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { restoreButton; legalLinks }
                VStack(alignment: .leading, spacing: 8) {
                    restoreButton
                    HStack(spacing: 16) { legalLinks }
                }
            }
            .font(Typography.body(12, weight: .medium))
        }
    }

    private var restoreButton: some View {
        Button(phase == .restoring ? "Restoring…" : "Restore Purchases") { Task { await restore() } }
            .disabled(phase != .choosing)
            .accessibilityIdentifier("paywall-restore")
    }

    @ViewBuilder
    private var legalLinks: some View {
        if let terms = LegalLinks.terms { Link("Terms of Use", destination: terms) }
        if let privacy = LegalLinks.privacy { Link("Privacy Policy", destination: privacy) }
        if let support = LegalLinks.support { Link("Support", destination: support) }
    }

    /// Only what the price itself says: a yearly plan's per-month equivalent, from its own store price.
    /// No badges, no savings claims.
    private func subtitle(for offer: EntitlementService.PlanOffer) -> String? {
        offer.monthlyEquivalent.map { "\($0) / month" }
    }

    private func termsLine(for offer: EntitlementService.PlanOffer) -> String {
        guard let noun = offer.kind.periodNoun else {
            return "Neverblank Pro Lifetime is a one-time purchase of \(offer.localizedPrice), charged to your Apple Account. It does not renew."
        }
        return "Neverblank Pro \(offer.kind.title) renews automatically at \(offer.localizedPrice) per \(noun) until you cancel. Payment is charged to your Apple Account. Cancel at least 24 hours before renewal in Settings › Apple Account › Subscriptions."
    }

    /// Starts on the best value when the prices show one, otherwise Monthly, otherwise the first plan.
    private func preselect() {
        guard phase == .choosing, !(userChose && plan(selected) != nil && isSelectable(selected)) else { return }
        // Only a plan that can be bought is preselected; the current plan never is. With nothing to
        // buy (the longest plan is active), the current plan stays shown and Continue becomes Manage.
        let buyable = Self.order.filter { plan($0) != nil && isSelectable($0) }
        if let best = bestValue, buyable.contains(best) {
            selected = best
        } else if buyable.contains(.monthly) {
            selected = .monthly
        } else if let first = buyable.first {
            selected = first
        } else if let current = availability.first(where: { $0.value == .current })?.key {
            selected = current
        }
    }

    private func testStoreNotice(_ notice: String) -> some View {
        Text(notice)
            .font(Typography.body(11.5))
            .foregroundStyle(Theme.Color.secondary)
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
        // The current plan (or a downgrade) is never sent to StoreKit from here.
        guard phase == .choosing, isSelectable(selected) else { return }
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
            if let notice = BillingEnvironment.testStoreNotice(.restore) { message = notice }
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
    static var support: URL? { url("NeverblankSupportURL") }

    private static func url(_ key: String) -> URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !raw.isEmpty, !raw.hasPrefix("$("), let url = URL(string: raw), url.scheme == "https" else { return nil }
        return url
    }
}

/// A plan row's press: a slight give and dim, springing back — fluid, no border flash.
private struct PlanRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}
