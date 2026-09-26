import Foundation
import Observation

/// Who may use Neverblank's paid features right now, and when the paywall appears.
///
/// **The rule:** an authenticated installation AND (an active `pro` entitlement OR free preview left).
/// The backend applies the same rule to every paid request and is the authority; this type decides
/// what to *offer*, and it never unlocks anything on its own say-so:
/// - a paywall opened by Generate resumes that request only after the **backend** confirms Pro
///   (`verifyProAfterPurchase`), not merely because the store said the purchase went through;
/// - a failed check never becomes Pro — offline, only RevenueCat's own last verified state counts,
///   and the backend still refuses anything it cannot verify.
@MainActor
@Observable
final class AccessController {
    enum Connection: Equatable {
        /// This build has no backend URL.
        case unconfigured
        case connecting
        case ready
        case failed(String)
    }

    struct PaywallRequest: Identifiable, Equatable {
        let id = UUID()
        let trigger: PaywallTrigger
    }

    private(set) var credential: InstallationCredential?
    private(set) var connection: Connection = .connecting
    /// The backend's last answer about this installation.
    private(set) var server: AccessSnapshot?
    private(set) var meter: FreePreviewMeter
    /// Whole seconds of preview left, for the on-screen countdown.
    private(set) var previewRemainingSeconds: Int
    /// The paywall a Live session should present. Set by `requestPaywall`; cleared by the paywall.
    var paywall: PaywallRequest?

    /// After a store purchase: has the **backend** confirmed Pro for this installation yet?
    enum PurchaseVerification: Equatable {
        case none
        /// The store accepted the purchase; the backend has not confirmed access. Retry, not re-buy.
        case pending
        case verified
    }
    private(set) var purchaseVerification: PurchaseVerification = .none

    private var record: FreePreviewRecord
    private let credentials: InstallationCredentialStore
    private let ledger: FreePreviewLedger
    private let makeClient: (URL) -> any BackendAccessProviding
    private var client: (any BackendAccessProviding)?
    private let entitlementActive: @MainActor () -> Bool
    private let identify: @MainActor (String) async -> Void
    /// RevenueCat's current App User ID, so a purchase is allowed only once it is this installation's.
    private let currentAppUserID: @MainActor () -> String?
    private let monotonicNow: () -> TimeInterval
    private let sleep: (Duration) async throws -> Void
    private var ticker: Task<Void, Never>?
    private var isReportingEnd = false
    /// How often the countdown refreshes while the preview is being charged.
    static let tickInterval: Duration = .milliseconds(500)

    init(
        credentials: InstallationCredentialStore = .keychain,
        ledger: FreePreviewLedger = .keychain,
        makeClient: @escaping (URL) -> any BackendAccessProviding = { BackendAccessClient(baseURL: $0) },
        entitlementActive: @escaping @MainActor () -> Bool,
        identify: @escaping @MainActor (String) async -> Void = { _ in },
        currentAppUserID: @escaping @MainActor () -> String? = { nil },
        monotonicNow: @escaping () -> TimeInterval = AccessController.processClock,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.credentials = credentials
        self.ledger = ledger
        self.makeClient = makeClient
        self.entitlementActive = entitlementActive
        self.identify = identify
        self.currentAppUserID = currentAppUserID
        self.monotonicNow = monotonicNow
        self.sleep = sleep
        let record = ledger.load()
        self.record = record
        self.meter = FreePreviewMeter(usedSeconds: record.usedSeconds)
        self.previewRemainingSeconds = Int(FreePreviewMeter(usedSeconds: record.usedSeconds).remaining(at: 0).rounded(.up))
        self.credential = credentials.load()
    }

    /// Seconds on a monotonic clock since this process started using it.
    nonisolated static func processClock() -> TimeInterval {
        let elapsed = ContinuousClock.now - processEpoch
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
    nonisolated private static let processEpoch = ContinuousClock.now

    // MARK: - The rule

    /// True when this build's access is decided by the backend (installation credentials): always in
    /// Release; in Debug only with installation access switched on.
    var usesServerAccess: Bool { client != nil }

    /// The backend has verified an active `neverblank_pro` for this installation.
    var isServerVerifiedPro: Bool { server?.pro.active == true && server?.pro.verified == true }

    /// The store recognises a subscription that the backend has not verified for this installation —
    /// retry verification, never sell again.
    var needsVerification: Bool {
        usesServerAccess && (purchaseVerification == .pending || entitlementActive()) && !isServerVerifiedPro
    }

    /// RevenueCat reports `pro` active, or the backend verified it.
    var isPro: Bool { entitlementActive() || server?.pro.active == true }
    var isPreviewExhausted: Bool { meter.isExhausted(at: monotonicNow()) }
    /// May this installation start paid work (detection, a new answer) now?
    var allowsPaidRequests: Bool { credential != nil && (isPro || !isPreviewExhausted) }

    // MARK: - Installation

    /// Registers this installation if it has no credential, binds RevenueCat to the issued identity,
    /// and reads the backend's view of access. Safe to call repeatedly.
    func bootstrap(backendURL: URL?) async {
        guard let backendURL else { connection = .unconfigured; return }
        let client = makeClient(backendURL)
        self.client = client
        if credential == nil {
            connection = .connecting
            do {
                let issued = try await client.register()
                credentials.save(issued)
                credential = issued
            } catch {
                connection = .failed("Neverblank could not connect. Check your connection and try again.")
                return
            }
        }
        guard let credential else { return }
        await identify(credential.appUserID)
        connection = .ready
        await refresh()
    }

    /// Re-reads access from the backend. A failure keeps what was known; it never grants anything.
    func refresh(force: Bool = false) async {
        guard let client, let credential else { return }
        guard let snapshot = try? await client.access(credential, refresh: force) else { return }
        server = snapshot
        // The backend's record wins over a local one that says otherwise — for example a Keychain
        // preview record lost while the credential survived.
        if snapshot.preview.state == "ended", !isPreviewExhausted {
            meter.stop(at: monotonicNow())
            meter = FreePreviewMeter(usedSeconds: FreePreviewMeter.allowance)
            record.usedSeconds = FreePreviewMeter.allowance
            record.endReported = true
            ledger.save(record)
            updateRemaining()
        }
    }

    // MARK: - Free preview

    /// Called whenever the Live screen's state changes, with true only while **every** condition for
    /// charging the preview holds: listening, foreground, consent given, answers configured, no paywall.
    func setPreviewConditions(_ allMet: Bool) {
        let now = monotonicNow()
        let shouldCount = allMet && !isPro && credential != nil && paywall == nil
        if shouldCount, !meter.isCounting {
            let isFirst = !meter.hasStarted
            if meter.start(at: now) {
                if isFirst { log(.init(name: .trialStarted)) }
                startTicker()
            }
        } else if !shouldCount, meter.isCounting {
            meter.stop(at: now)
            persist()
            ticker?.cancel()
            ticker = nil
        }
        updateRemaining()
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await self?.sleep(Self.tickInterval)
                guard let self, !Task.isCancelled, self.meter.isCounting else { return }
                self.updateRemaining()
                tick += 1
                if tick % 10 == 0 { self.persistRunning() }
                if self.isPreviewExhausted {
                    await self.previewDidEnd()
                    return
                }
            }
        }
    }

    /// The 30 seconds are used: bank them, tell the backend once, and show the paywall **once**.
    func previewDidEnd() async {
        meter.stop(at: monotonicNow())
        ticker = nil
        persist()
        updateRemaining()
        guard !isPro else { return }
        if !record.endPaywallShown {
            record.endPaywallShown = true
            ledger.save(record)
            log(.init(name: .trial30sConsumed))
            requestPaywall(.previewEnd)
        }
        if !record.endReported, !isReportingEnd, let client, let credential {
            isReportingEnd = true
            defer { isReportingEnd = false }
            if (try? await client.endPreview(credential)) != nil {
                record.endReported = true
                ledger.save(record)
            }
        }
    }

    private func persist() {
        record.usedSeconds = meter.usedSeconds
        ledger.save(record)
    }

    /// Saves progress mid-stretch, so a crash or a kill loses at most a few seconds of charging.
    private func persistRunning() {
        record.usedSeconds = meter.used(at: monotonicNow())
        ledger.save(record)
    }

    private func updateRemaining() {
        previewRemainingSeconds = max(0, Int(meter.remaining(at: monotonicNow()).rounded(.up)))
    }

    // MARK: - Paywall and purchase

    func requestPaywall(_ trigger: PaywallTrigger) {
        // Charging stops while the paywall is up.
        if meter.isCounting { setPreviewConditions(false) }
        paywall = PaywallRequest(trigger: trigger)
    }

    /// Makes sure a purchase will belong to the customer the backend checks: the installation is
    /// registered and RevenueCat is on the App User ID the server issued. Returns false — and the
    /// purchase must not start — when either is not so.
    func prepareForPurchase() async -> Bool {
        guard usesServerAccess else { return false }
        if credential == nil { await bootstrap(backendURL: ProviderConfiguration.installationBackendURL()) }
        guard let credential else { return false }
        if currentAppUserID() != credential.appUserID { await identify(credential.appUserID) }
        return currentAppUserID() == credential.appUserID
    }

    /// Asks the backend, which asks RevenueCat, whether this installation is now Pro. A few quick
    /// attempts, because the store's receipt can take a moment to reach RevenueCat. Returns true only
    /// on a verified active entitlement.
    func verifyProAfterPurchase(attempts: Int = 4) async -> Bool {
        guard let client, let credential else { purchaseVerification = .pending; return false }
        for attempt in 0..<attempts {
            if attempt > 0 { try? await sleep(.seconds(Double(attempt) * 1.5)) }
            if let snapshot = try? await client.access(credential, refresh: true) {
                server = snapshot
                if snapshot.pro.active && snapshot.pro.verified {
                    purchaseVerification = .verified
                    return true
                }
            }
        }
        purchaseVerification = .pending
        return false
    }

    func log(_ event: ProductEvent) {
        guard let client, let credential else { return }
        Task.detached { await client.send(event: event, credential: credential) }
    }
}
