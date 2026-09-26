import Foundation
import Observation

/// Who may use Neverblank's paid features right now, and when the paywall appears.
///
/// **The rule:** an authenticated installation AND (an active `neverblank_pro` OR free answers left).
///
/// A free installation gets **2 free AI answers** in total (`backend/access.mjs`, "Free answers"). The
/// backend's ledger is the authority; this type mirrors it so the app can say how many are left and
/// open the paywall on the third Generate **before** any request is sent.
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

    private var record: FreeAnswersRecord
    private let credentials: InstallationCredentialStore
    private let ledger: FreeAnswersLedger
    private let makeClient: (URL) -> any BackendAccessProviding
    private var client: (any BackendAccessProviding)?
    private let entitlementActive: @MainActor () -> Bool
    private let identify: @MainActor (String) async -> Void
    /// RevenueCat's current App User ID, so a purchase is allowed only once it is this installation's.
    private let currentAppUserID: @MainActor () -> String?
    private let sleep: (Duration) async throws -> Void

    init(
        credentials: InstallationCredentialStore = .keychain,
        ledger: FreeAnswersLedger = .keychain,
        makeClient: @escaping (URL) -> any BackendAccessProviding = { BackendAccessClient(baseURL: $0) },
        entitlementActive: @escaping @MainActor () -> Bool,
        identify: @escaping @MainActor (String) async -> Void = { _ in },
        currentAppUserID: @escaping @MainActor () -> String? = { nil },
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.credentials = credentials
        self.ledger = ledger
        self.makeClient = makeClient
        self.entitlementActive = entitlementActive
        self.identify = identify
        self.currentAppUserID = currentAppUserID
        self.sleep = sleep
        self.record = ledger.load()
        self.credential = credentials.load()
    }

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
    /// Free answers per installation. The backend's figure wins once known.
    var freeAnswerLimit: Int { server?.free_answers?.limit ?? FreeAnswersRecord.limit }
    /// Free answers used: the larger of the backend's count and what this device has seen complete,
    /// so a slow refresh can never offer an answer that was already used.
    var freeAnswersUsed: Int { max(server?.free_answers?.used ?? 0, record.used) }
    var freeAnswersRemaining: Int {
        if let serverRemaining = server?.free_answers?.remaining, serverRemaining == 0 { return 0 }
        return max(0, freeAnswerLimit - freeAnswersUsed)
    }
    var areFreeAnswersUsed: Bool { freeAnswersRemaining == 0 }
    /// May this installation start paid work (detection, a new answer) now?
    var allowsPaidRequests: Bool { credential != nil && (isPro || !areFreeAnswersUsed) }

    /// May one more answer be accepted, with `pending` free answers already queued or running?
    /// Prevents a quick second tap from queueing more free answers than are left.
    func allowsNewAnswer(pending: Int) -> Bool {
        credential != nil && (isPro || freeAnswersRemaining - pending > 0)
    }

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
        noteExhaustionIfNeeded()
    }

    // MARK: - Free answers

    /// An answer finished on screen. `counted` is true for a non-empty answer that was not only a
    /// request for clarification or context — the same rule the backend settles by. The local count
    /// moves at once; the backend's is read again straight after.
    func noteAnswerCompleted(counted: Bool) {
        guard counted, !isPro, usesServerAccess else { return }
        record.used = min(freeAnswerLimit, freeAnswersUsed + 1)
        if record.used == 1 { log(.init(name: .trialStarted)) }
        ledger.save(record)
        noteExhaustionIfNeeded()
        Task { await refresh() }
    }

    /// Recorded once, when the second free answer has been used.
    private func noteExhaustionIfNeeded() {
        guard areFreeAnswersUsed, !isPro, !record.exhaustionLogged, credential != nil else { return }
        record.exhaustionLogged = true
        ledger.save(record)
        log(.init(name: .freeAnswersExhausted))
    }

    // MARK: - Paywall and purchase

    func requestPaywall(_ trigger: PaywallTrigger) {
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
