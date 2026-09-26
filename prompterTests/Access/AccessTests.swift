import Foundation
import Testing
@testable import prompter

// MARK: - Free preview meter

struct FreePreviewMeterTests {
    @Test
    func onlyListeningTimeIsCharged() {
        var meter = FreePreviewMeter()
        #expect(meter.remaining(at: 100) == 30)
        meter.start(at: 100)
        meter.stop(at: 110)            // 10 s listening
        #expect(meter.used(at: 500) == 10, "time between stretches (setup, paywall, background) is not charged")
        meter.start(at: 500)
        #expect(meter.remaining(at: 505) == 15)
        meter.stop(at: 505)
        #expect(meter.usedSeconds == 15)
    }

    @Test
    func exhaustionIsExactAndFinal() {
        var meter = FreePreviewMeter(usedSeconds: 25)
        meter.start(at: 0)
        #expect(!meter.isExhausted(at: 4.9))
        #expect(meter.isExhausted(at: 5))
        #expect(meter.used(at: 999) == 30, "never charged beyond the allowance")
        meter.stop(at: 999)
        let restarted = meter.start(at: 1000)
        #expect(!restarted, "an exhausted preview cannot start again")
    }

    @Test
    func restoredUsageIsClamped() {
        #expect(FreePreviewMeter(usedSeconds: -4).usedSeconds == 0)
        #expect(FreePreviewMeter(usedSeconds: 400).usedSeconds == 30)
    }
}

// MARK: - Savings

struct PlanSavingsTests {
    @Test
    func monthlySavingComesFromTheStorePrices() {
        // 5.99 × 52/12 = 25.957; 12.99 is 49.95% less → shown as 49%, never rounded up.
        #expect(PlanSavings.monthlySavingPercent(weekly: Decimal(string: "5.99")!, monthly: Decimal(string: "12.99")!,
                                                 weeklyCurrency: "USD", monthlyCurrency: "USD") == 49)
        // Another storefront's prices give another figure — nothing is hard-coded.
        #expect(PlanSavings.monthlySavingPercent(weekly: 7, monthly: 21, weeklyCurrency: "EUR", monthlyCurrency: "EUR") == 30)
    }

    @Test
    func noSavingIsClaimedWhenThePricesDoNotSupportIt() {
        #expect(PlanSavings.monthlySavingPercent(weekly: 3, monthly: 13, weeklyCurrency: "USD", monthlyCurrency: "USD") == nil,
                "monthly dearer than a month of weekly")
        #expect(PlanSavings.monthlySavingPercent(weekly: 5.99, monthly: 12.99, weeklyCurrency: "USD", monthlyCurrency: "EUR") == nil,
                "different currencies cannot be compared")
        #expect(PlanSavings.monthlySavingPercent(weekly: 5.99, monthly: 12.99, weeklyCurrency: nil, monthlyCurrency: nil) == nil)
        #expect(PlanSavings.monthlySavingPercent(weekly: 0, monthly: 12.99, weeklyCurrency: "USD", monthlyCurrency: "USD") == nil)
    }
}

// MARK: - Four plans

struct PlanLineupTests {
    @Test
    func plansAreRecognisedFromTheProductNotThePackageSlot() {
        #expect(PlanKind.classify(isSubscription: false, periodUnit: nil, periodValue: 0) == .lifetime,
                "a one-time product is lifetime even when it sits in the $rc_annual slot")
        #expect(PlanKind.classify(isSubscription: true, periodUnit: "week", periodValue: 1) == .weekly)
        #expect(PlanKind.classify(isSubscription: true, periodUnit: "day", periodValue: 7) == .weekly)
        #expect(PlanKind.classify(isSubscription: true, periodUnit: "month", periodValue: 1) == .monthly)
        #expect(PlanKind.classify(isSubscription: true, periodUnit: "year", periodValue: 1) == .yearly)
        #expect(PlanKind.classify(isSubscription: true, periodUnit: "month", periodValue: 3) == nil,
                "a plan this app does not sell is not shown as one it does")
    }

    @Test
    func purchasedPlansAreNamedFromTheirIdentifier() {
        #expect(EntitlementService.planName(forProductIdentifier: "monthly") == "Monthly")
        #expect(EntitlementService.planName(forProductIdentifier: "talk.cointerview.pro.weekly") == "Weekly")
        #expect(EntitlementService.planName(forProductIdentifier: "lifetime") == "Lifetime")
        #expect(EntitlementService.planName(forProductIdentifier: "yearly") == "Yearly")
    }

    @Test
    func misconfiguredProductsAreNotOffered() {
        // The Test Store as found on 2026-09-26.
        #expect(PlanKind.monthly.agrees(withProductIdentifier: "monthly"))
        #expect(!PlanKind.monthly.agrees(withProductIdentifier: "yearly"), "`yearly` defined as 1 month")
        #expect(!PlanKind.yearly.agrees(withProductIdentifier: "lifetime"), "`lifetime` defined as a 1-year subscription")
        // Correct definitions, including the App Store ids.
        #expect(PlanKind.yearly.agrees(withProductIdentifier: "yearly"))
        #expect(PlanKind.lifetime.agrees(withProductIdentifier: "lifetime"))
        #expect(PlanKind.weekly.agrees(withProductIdentifier: "talk.cointerview.pro.weekly"))
        #expect(PlanKind.monthly.agrees(withProductIdentifier: "talk.cointerview.pro.monthly"))
        #expect(PlanKind.yearly.agrees(withProductIdentifier: "talk.cointerview.pro.yearly"))
    }

    private func price(_ kind: PlanKind, _ amount: String, _ currency: String = "USD") -> PlanSavings.Price {
        .init(kind: kind, amount: Decimal(string: amount)!, currency: currency)
    }

    @Test
    func savingsAreMeasuredPerWeekAgainstThePriciestPlan() {
        let prices = [price(.weekly, "5.99"), price(.monthly, "12.99"), price(.yearly, "79.99"), price(.lifetime, "149.99")]
        let baseline = PlanSavings.baseline(prices)
        #expect(baseline?.kind == .weekly)
        #expect(PlanSavings.savingPercent(prices[1], comparedWith: baseline!) == 49)
        // 79.99 / 52 = 1.538 per week against 5.99 → 74.3% → 74.
        #expect(PlanSavings.savingPercent(prices[2], comparedWith: baseline!) == 74)
        #expect(PlanSavings.savingPercent(prices[3], comparedWith: baseline!) == nil, "lifetime is never given a percentage")
        #expect(PlanSavings.bestValue(prices) == .yearly)
    }

    @Test
    func noBestValueWhenNothingSaves() {
        // The same price per week (5 × 52/12 ≈ 21.67): nothing is cheaper, so nothing is "best".
        #expect(PlanSavings.bestValue([price(.weekly, "5"), price(.monthly, "21.67")]) == nil)
        // A dear monthly makes weekly the real saving — the badge follows the arithmetic, not the name.
        #expect(PlanSavings.bestValue([price(.weekly, "5"), price(.monthly, "40")]) == .weekly)
        #expect(PlanSavings.bestValue([price(.lifetime, "99")]) == nil)
        #expect(PlanSavings.bestValue([price(.weekly, "5.99", "USD"), price(.yearly, "79.99", "EUR")]) == nil,
                "different currencies are never compared")
    }
}

// MARK: - Configuration

struct AccessConfigurationTests {
    private func bundle(url: String?) throws -> Bundle {
        let dir = FileManager.default.temporaryDirectory.appending(path: "access-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "test.access.\(UUID().uuidString)"]
        if let url { info[ProviderConfiguration.backendURLPlistKey] = url }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: dir.appending(path: "Info.plist"))
        return try #require(Bundle(url: dir))
    }

    private let credential = InstallationCredential(installationID: "i1", secret: "s1", appUserID: "nb_i1")

    @Test
    func releaseAuthenticatesAsTheInstallationAndIgnoresDeveloperOverrides() throws {
        let defaults = try #require(UserDefaults(suiteName: "access-\(UUID().uuidString)"))
        defaults.set("https://attacker.example", forKey: ProviderConfiguration.backendURLDefaultsKey)
        defaults.set("leaked-token", forKey: ProviderConfiguration.backendTokenDefaultsKey)
        let config = ProviderConfiguration.resolve(bundle: try bundle(url: "https://backend.example"), defaults: defaults,
                                                   isDebugBuild: false, installation: credential)
        #expect(config.availability == .backend(url: URL(string: "https://backend.example")!))
        #expect(config.authorizationHeader == "Installation i1.s1", "no bearer token in a Release build")
        #expect(!config.authorizationHeader.contains("leaked-token"))
    }

    @Test
    func releaseWithoutACredentialIsHonestlyConnecting() throws {
        let config = ProviderConfiguration.resolve(bundle: try bundle(url: "https://backend.example"), defaults: .standard,
                                                   isDebugBuild: false, installation: nil)
        #expect(config.availability == .unavailable(reason: "Connecting to Neverblank…"))
    }

    @Test
    func releaseRefusesAPlainHTTPBackend() throws {
        let config = ProviderConfiguration.resolve(bundle: try bundle(url: "http://backend.example"), defaults: .standard,
                                                   isDebugBuild: false, installation: credential)
        #expect(config.isUnavailable)
    }

    @Test
    func releaseNeverUsesATestStoreKey() {
        #expect(BillingConfiguration.acceptedKey("test_abc", isDebugBuild: false) == nil)
        #expect(BillingConfiguration.acceptedKey("appl_abc", isDebugBuild: false) == "appl_abc")
        #expect(BillingConfiguration.acceptedKey("test_abc", isDebugBuild: true) == "test_abc")
    }

    @Test
    func aBillingTestBuildUsesInstallationAccessFromItsPlist() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "billing-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.billing.\(UUID().uuidString)",
                                   ProviderConfiguration.installationAccessPlistKey: "YES"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: dir.appending(path: "Info.plist"))
        let bundle = try #require(Bundle(url: dir))
        let defaults = try #require(UserDefaults(suiteName: "billing-\(UUID().uuidString)"))
        defaults.set("https://dev.example", forKey: ProviderConfiguration.backendURLDefaultsKey)
        #expect(ProviderConfiguration.installationBackendURL(bundle: bundle, defaults: defaults, isDebugBuild: true, arguments: [])
                == URL(string: "https://dev.example"), "no launch argument needed: an ordinary home-screen launch")
    }

    @Test
    func debugRegistersOnlyWhenAskedTo() throws {
        let defaults = try #require(UserDefaults(suiteName: "access-\(UUID().uuidString)"))
        defaults.set("https://dev.example", forKey: ProviderConfiguration.backendURLDefaultsKey)
        defaults.set("dev-token", forKey: ProviderConfiguration.backendTokenDefaultsKey)
        let plain = try bundle(url: nil)
        #expect(ProviderConfiguration.installationBackendURL(bundle: plain, defaults: defaults, isDebugBuild: true, arguments: []) == nil,
                "an ordinary Debug run (and the test host) never registers an installation")
        #expect(ProviderConfiguration.installationBackendURL(bundle: plain, defaults: defaults, isDebugBuild: true,
                                                             arguments: ["-CopilotInstallationAuth"]) == URL(string: "https://dev.example"))
    }
}

// MARK: - Access controller

/// A scripted backend. Records what it was asked; never touches the network.
final class FakeAccessBackend: BackendAccessProviding, @unchecked Sendable {
    var registrations = 0
    var failRegistration = false
    var snapshots: [Result<AccessSnapshot, Error>] = []
    var accessCalls: [Bool] = []
    var endPreviewCalls = 0
    var events: [ProductEvent] = []

    func register() async throws -> InstallationCredential {
        registrations += 1
        if failRegistration { throw BackendAccessError.http(503) }
        return InstallationCredential(installationID: "inst-\(registrations)", secret: "secret", appUserID: "nb_inst-\(registrations)")
    }

    func access(_ credential: InstallationCredential, refresh: Bool) async throws -> AccessSnapshot {
        accessCalls.append(refresh)
        guard !snapshots.isEmpty else { return .make() }
        return try snapshots.removeFirst().get()
    }

    func endPreview(_ credential: InstallationCredential) async throws { endPreviewCalls += 1 }
    func send(event: ProductEvent, credential: InstallationCredential) async { events.append(event) }
}

extension AccessSnapshot {
    static func make(pro: Bool = false, verified: Bool = true, preview: String = "available") -> AccessSnapshot {
        AccessSnapshot(entitlement: "neverblank_pro", app_user_id: "nb_x",
                       pro: .init(active: pro, expires_at: nil, verified: verified),
                       preview: .init(state: preview, answers_left: preview == "ended" ? 0 : 5))
    }
}

@MainActor
struct AccessControllerTests {
    final class Clock: @unchecked Sendable { var now: TimeInterval = 1_000 }

    struct Harness {
        let controller: AccessController
        let backend: FakeAccessBackend
        let clock: Clock
        let ledger: FreePreviewLedger
        let credentials: InstallationCredentialStore
        let pro: LockedBox<Bool>
        let identified: LockedBox<[String]>
    }

    static func make(backend: FakeAccessBackend = FakeAccessBackend(),
                     ledger: FreePreviewLedger = .inMemory(),
                     credentials: InstallationCredentialStore = .inMemory(),
                     pro: LockedBox<Bool> = LockedBox(false)) -> Harness {
        let clock = Clock()
        let identified = LockedBox<[String]>([])
        let controller = AccessController(
            credentials: credentials, ledger: ledger,
            makeClient: { _ in backend },
            entitlementActive: { pro.value },
            identify: { identified.value.append($0) },
            monotonicNow: { clock.now },
            // Countdown ticks never fire on their own here — each test ends the preview explicitly —
            // while the retry pauses in `verifyProAfterPurchase` pass instantly.
            sleep: { duration in
                if duration == AccessController.tickInterval { try await Task.sleep(for: .seconds(3600)) } else { await Task.yield() }
            }
        )
        return Harness(controller: controller, backend: backend, clock: clock, ledger: ledger,
                       credentials: credentials, pro: pro, identified: identified)
    }

    static let url = URL(string: "https://backend.example")!

    @Test
    func registersOnceAndBindsRevenueCatToTheIssuedIdentity() async {
        let h = Self.make()
        await h.controller.bootstrap(backendURL: Self.url)
        await h.controller.bootstrap(backendURL: Self.url)
        #expect(h.backend.registrations == 1)
        #expect(h.credentials.load()?.appUserID == "nb_inst-1")
        #expect(h.identified.value.allSatisfy { $0 == "nb_inst-1" } && !h.identified.value.isEmpty,
                "RevenueCat is told the server's id, never one the app made up")
        #expect(h.controller.connection == .ready)
        #expect(h.controller.allowsPaidRequests)
    }

    @Test
    func failedRegistrationAllowsNothingPaid() async {
        let backend = FakeAccessBackend()
        backend.failRegistration = true
        let h = Self.make(backend: backend)
        await h.controller.bootstrap(backendURL: Self.url)
        #expect(h.controller.connection != .ready)
        #expect(!h.controller.allowsPaidRequests, "no installation, no paid requests")
    }

    @Test
    func thePreviewEndsAfterThirtyListeningSecondsAndShowsThePaywallOnce() async {
        let h = Self.make()
        await h.controller.bootstrap(backendURL: Self.url)
        h.controller.setPreviewConditions(true)
        h.clock.now += 20
        h.controller.setPreviewConditions(false)     // backgrounded, or a permission prompt
        h.clock.now += 600                           // not charged
        #expect(h.controller.previewRemainingSeconds == 10)
        h.controller.setPreviewConditions(true)
        h.clock.now += 10
        #expect(h.controller.isPreviewExhausted)
        await h.controller.previewDidEnd()
        #expect(h.controller.paywall?.trigger == .previewEnd)
        #expect(h.backend.endPreviewCalls == 1)
        #expect(!h.controller.allowsPaidRequests)

        // Closing it and ending again never reopens it.
        h.controller.paywall = nil
        await h.controller.previewDidEnd()
        #expect(h.controller.paywall == nil)
        #expect(h.backend.endPreviewCalls == 1, "reported once")

        // A relaunch remembers: exhausted, and still no second automatic paywall.
        let relaunched = Self.make(backend: h.backend, ledger: h.ledger, credentials: h.credentials)
        await relaunched.controller.bootstrap(backendURL: Self.url)
        #expect(relaunched.controller.isPreviewExhausted)
        relaunched.controller.setPreviewConditions(true)
        await relaunched.controller.previewDidEnd()
        #expect(relaunched.controller.paywall == nil)
    }

    @Test
    func thePaywallStopsTheClock() async {
        let h = Self.make()
        await h.controller.bootstrap(backendURL: Self.url)
        h.controller.setPreviewConditions(true)
        h.clock.now += 5
        h.controller.requestPaywall(.generate)
        h.clock.now += 300
        #expect(h.controller.previewRemainingSeconds == 25)
        h.controller.setPreviewConditions(true)
        #expect(!h.controller.meter.isCounting, "no charging while the paywall is up")
    }

    @Test
    func proIsNeverLimitedByThePreview() async {
        let pro = LockedBox(false)
        let h = Self.make(ledger: .inMemory(FreePreviewRecord(usedSeconds: 30, endReported: true, endPaywallShown: true)), pro: pro)
        await h.controller.bootstrap(backendURL: Self.url)
        #expect(!h.controller.allowsPaidRequests)
        pro.value = true
        #expect(h.controller.allowsPaidRequests)
        h.controller.setPreviewConditions(true)
        #expect(!h.controller.meter.isCounting, "Pro listening never touches the preview")
    }

    @Test
    func theBackendsEndedPreviewWins() async {
        let backend = FakeAccessBackend()
        backend.snapshots = [.success(.make(preview: "ended"))]
        let h = Self.make(backend: backend)
        await h.controller.bootstrap(backendURL: Self.url)
        #expect(h.controller.isPreviewExhausted)
    }

    @Test
    func onlyAVerifiedServerEntitlementCountsAfterPurchase() async {
        let backend = FakeAccessBackend()
        let h = Self.make(backend: backend)
        await h.controller.bootstrap(backendURL: Self.url)

        backend.snapshots = [.success(.make(pro: false)), .success(.make(pro: true))]
        #expect(await h.controller.verifyProAfterPurchase(), "a receipt that reaches RevenueCat a moment later still verifies")

        backend.snapshots = Array(repeating: .failure(BackendAccessError.http(503)), count: 4)
        #expect(!(await h.controller.verifyProAfterPurchase()), "a failed check is never Pro")

        backend.snapshots = Array(repeating: .success(.make(pro: true, verified: false)), count: 4)
        #expect(!(await h.controller.verifyProAfterPurchase()), "an unverified cached state does not resume a request")
        #expect(backend.accessCalls.suffix(4).allSatisfy { $0 }, "purchase checks always bypass the server cache")
    }

    @Test
    func noPurchaseUntilRevenueCatIsOnTheIssuedIdentity() async {
        let backend = FakeAccessBackend()
        let rcUser = LockedBox<String?>("$RCAnonymousID:abc")
        let controller = AccessController(
            credentials: .inMemory(), ledger: .inMemory(), makeClient: { _ in backend },
            entitlementActive: { false },
            identify: { _ in },                                   // a login that did not happen
            currentAppUserID: { rcUser.value },
            monotonicNow: { 0 }, sleep: { _ in await Task.yield() })
        #expect(!(await controller.prepareForPurchase()), "no server access: no purchase")
        await controller.bootstrap(backendURL: Self.url)
        #expect(!(await controller.prepareForPurchase()), "still anonymous: a purchase would not reach the checked customer")
        rcUser.value = "nb_inst-1"
        #expect(await controller.prepareForPurchase())
    }

    @Test
    func aRecognisedSubscriptionIsNotProUntilTheServerVerifiesIt() async {
        let backend = FakeAccessBackend()
        let storeSaysActive = LockedBox(true)
        let h = Self.make(backend: backend, pro: storeSaysActive)
        await h.controller.bootstrap(backendURL: Self.url)
        #expect(h.controller.needsVerification, "store-active but unverified is its own state")
        backend.snapshots = [.success(.make(pro: true))]
        #expect(await h.controller.verifyProAfterPurchase(attempts: 1))
        #expect(h.controller.purchaseVerification == .verified)
        #expect(!h.controller.needsVerification)
    }

    @Test
    func eventsCarryOnlyEnumeratedValues() throws {
        let data = try JSONEncoder().encode(ProductEvent(name: .purchaseFailed, plan: .monthly, trigger: .generate, reason: .cancelled))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["name": "purchase_failed", "plan": "monthly", "trigger": "generate", "reason": "cancelled"])
    }
}

// MARK: - The interview under access

@MainActor
final class FakeGate: InterviewAccessGate {
    var allowsPaidRequests: Bool
    private(set) var paywalls: [PaywallTrigger] = []
    init(allows: Bool) { allowsPaidRequests = allows }
    func requestPaywall(_ trigger: PaywallTrigger) { paywalls.append(trigger) }
}

@MainActor
struct InterviewAccessTests {
    typealias Support = ManualGenerationTests

    @Test
    func generateWithoutAccessHoldsTheExactSnapshotAndSendsItOnceAfterAccess() {
        let (model, feed) = Support.make()
        let gate = FakeGate(allows: false)
        model.accessGate = gate
        Support.speak("How would you shard a payments table?", in: model)
        Support.tap(model, at: 0)
        #expect(feed.discussionRequests.isEmpty, "nothing is sent without access")
        #expect(gate.paywalls == [.generate])
        let entry = try! #require(model.questions.last)
        #expect(model.isWaitingForAccess(questionID: entry.id))

        // Speech keeps arriving while the paywall is up; it must not leak into the held request.
        Support.speak("And what about hot partitions?", in: model)

        gate.allowsPaidRequests = true
        model.releaseHeldRequests()
        model.releaseHeldRequests()
        #expect(feed.discussionRequests.count == 1, "sent exactly once")
        let sent = feed.discussionRequests[0].discussion
        #expect(sent.newInput == ["How would you shard a payments table?"])
        #expect(!sent.allLines.contains("And what about hot partitions?"), "later speech is not substituted")
        #expect(!model.isWaitingForAccess(questionID: entry.id))
    }

    @Test
    func closingThePaywallKeepsTheEntryForRetryAndSendsNothing() throws {
        let (model, feed) = Support.make()
        let gate = FakeGate(allows: false)
        model.accessGate = gate
        Support.speak("Tell me about a failure.", in: model)
        Support.tap(model, at: 0)
        model.abandonHeldRequests()
        #expect(feed.discussionRequests.isEmpty)
        let entry = try #require(model.questions.last)
        #expect(entry.selectedAnswer?.failureMessage == CopilotProviderError.proRequiredMessage)
        #expect(model.canRetry(questionID: entry.id), "the snapshot is kept")
        #expect(gate.paywalls == [.generate], "closing does not reopen it")

        // Retry after unlocking re-sends the original snapshot.
        gate.allowsPaidRequests = true
        model.retry(questionID: entry.id)
        #expect(feed.discussionRequests.count == 1)
        #expect(feed.discussionRequests[0].discussion.newInput == ["Tell me about a failure."])
    }

    @Test
    func anAnswerAcceptedDuringThePreviewFinishesAfterItEnds() {
        let (model, feed) = Support.make()
        let gate = FakeGate(allows: true)
        model.accessGate = gate
        Support.speak("First question?", in: model)
        Support.tap(model, at: 0)
        Support.speak("Second question?", in: model)
        Support.tap(model, at: 5)                  // queued behind the first, accepted with access
        gate.allowsPaidRequests = false            // the preview ends here
        Support.completeActiveRequest(model, feed)
        #expect(feed.discussionRequests.count == 2, "an accepted request is honoured")
        #expect(gate.paywalls.isEmpty)
    }

    @Test
    func noAccessMeansNoRegenerateAndThePaywallInstead() throws {
        let (model, feed) = Support.make()
        let gate = FakeGate(allows: true)
        model.accessGate = gate
        Support.speak("Why Kafka?", in: model)
        Support.tap(model, at: 0)
        Support.completeActiveRequest(model, feed)
        gate.allowsPaidRequests = false
        model.regenerate()
        #expect(feed.questionRequests.isEmpty)
        #expect(gate.paywalls == [.generate])
    }

    @Test
    func aBackendRefusalOffersThePaywallOnceAndKeepsTheAnswerRetryable() throws {
        let (model, feed) = Support.make()
        let gate = FakeGate(allows: true)
        model.accessGate = gate
        Support.speak("Describe CQRS.", in: model)
        Support.tap(model, at: 0)
        let request = try #require(feed.discussionRequests.last)
        model.handle(.answerStarted(requestID: request.requestID, questionID: request.questionID))
        model.handle(.answerFailed(requestID: request.requestID, message: CopilotProviderError.proRequiredMessage))
        #expect(gate.paywalls == [.generate])
        #expect(model.canRetry(questionID: request.questionID))
    }

    @Test
    func withoutAGateEverythingIsAllowed() {
        let (model, feed) = Support.make()
        Support.speak("Any question?", in: model)
        Support.tap(model, at: 0)
        #expect(feed.discussionRequests.count == 1, "Demo and tests are unaffected")
    }
}
