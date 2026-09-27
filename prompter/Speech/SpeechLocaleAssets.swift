import Foundation
import Speech

/// Whether the on-device speech model for one language can be used now.
enum SpeechModelAvailability: Equatable, Sendable {
    /// Installed: a session can start at once. Carries the locale the transcriber will use.
    case installed(Locale)
    /// Supported on this iPhone, not installed yet: a one-time download is needed.
    case needsDownload(Locale)
    /// The system is downloading it right now.
    case downloading(Locale)
    /// Not supported on this iPhone. Never substituted by another language.
    case unsupported
}

enum SpeechLocaleAssetError: Error, Equatable, Sendable {
    /// The on-device transcriber has no model for this language on this iPhone.
    case unsupported(Locale)
    /// The model is not installed and the caller did not allow a download.
    case needsDownload(Locale)
    /// Every reservation the system allows is held by a session that is running right now.
    case reservationsInUse
}

/// What the app needs from Apple's `AssetInventory` and `SpeechTranscriber`. Injectable so the
/// reservation policy is tested without touching the device's real reservations.
protocol SpeechAssetSystem: Sendable {
    var maximumReservedLocales: Int { get }
    func reservedLocales() async -> [Locale]
    func reserve(_ locale: Locale) async throws -> Bool
    func release(_ locale: Locale) async -> Bool
    func supportedLocale(equivalentTo locale: Locale) async -> Locale?
    func installedLocales() async -> [Locale]
    func status(of locale: Locale) async -> AssetInventory.Status
    func install(_ locale: Locale, onProgress: @escaping @Sendable (Double) -> Void) async throws
}

/// The real system. Verified against the iOS 26.5 SDK's Speech.swiftinterface:
/// `AssetInventory.maximumReservedLocales`, `.reservedLocales`, `.reserve(locale:)`,
/// `.release(reservedLocale:)`, `.status(forModules:)`, `.assetInstallationRequest(supporting:)`,
/// `SpeechTranscriber.supportedLocale(equivalentTo:)`, `.installedLocales`.
struct AppleSpeechAssetSystem: SpeechAssetSystem {
    var maximumReservedLocales: Int { AssetInventory.maximumReservedLocales }
    func reservedLocales() async -> [Locale] { await AssetInventory.reservedLocales }
    func reserve(_ locale: Locale) async throws -> Bool { try await AssetInventory.reserve(locale: locale) }
    func release(_ locale: Locale) async -> Bool { await AssetInventory.release(reservedLocale: locale) }
    func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }
    func installedLocales() async -> [Locale] { await SpeechTranscriber.installedLocales }
    func status(of locale: Locale) async -> AssetInventory.Status {
        await AssetInventory.status(forModules: [SpeechTranscriber(locale: locale, preset: .transcription)])
    }

    func install(_ locale: Locale, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            onProgress(1)
            return
        }
        let progress = request.progress
        let poll = Task {
            while !Task.isCancelled {
                onProgress(progress.fractionCompleted)
                if progress.isFinished { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { poll.cancel() }
        try await request.downloadAndInstall()
        onProgress(1)
    }
}

/// Which inactive reservations to give up so another locale can be reserved.
///
/// Apple lets an app hold at most `maximumReservedLocales` speech locales, and
/// `assetInstallationRequest` reserves implicitly. Without releasing, every language ever tried stays
/// reserved and the next new one fails ("Too many allocated locales"). The plan keeps, in order: every
/// locale a running session uses (never released), the locale being prepared, English, and the most
/// recently used others; it releases the least recently used of the rest.
enum SpeechReservationPlan {
    /// One key per language/script/region, so "zh-TW", "zh_TW" and "zh-Hant-TW" are the same locale.
    static func key(_ locale: Locale) -> String {
        var key = locale.language.maximalIdentifier
        if let region = locale.region?.identifier, !key.hasSuffix("-\(region)") { key += "-\(region)" }
        return key.lowercased()
    }

    /// Reservations to release before reserving `desired` — empty when it is already reserved or there
    /// is room. Nil when there is no room and nothing may be released.
    static func releases(
        reserved: [Locale],
        maximum: Int,
        desired: Locale,
        inUse: Set<String>,
        recentlyUsed: [String]
    ) -> [Locale]? {
        let desiredKey = key(desired)
        if reserved.contains(where: { key($0) == desiredKey }) { return [] }
        let needed = reserved.count - max(maximum, 1) + 1
        guard needed > 0 else { return [] }
        let candidates = reserved.filter { !inUse.contains(key($0)) && key($0) != desiredKey }
        guard candidates.count >= needed else { return nil }
        // Lowest first: never used by this app, then the least recently used; English last.
        func keepScore(_ locale: Locale) -> Int {
            let localeKey = key(locale)
            if locale.language.languageCode?.identifier == "en" { return Int.max }
            guard let index = recentlyUsed.firstIndex(of: localeKey) else { return 0 }
            return recentlyUsed.count - index
        }
        let ordered = candidates.enumerated()
            .sorted { (keepScore($0.element), $0.offset) < (keepScore($1.element), $1.offset) }
            .map(\.element)
        return Array(ordered.prefix(needed))
    }
}

/// The app's one owner of on-device speech models: resolves a language to the locale the transcriber
/// supports, reserves it (releasing inactive reservations when the system limit is reached), installs
/// it when allowed, and knows which locales running sessions hold so those are never released.
///
/// Both the live interview and script reading go through here; there is no second speech stack.
actor SpeechLocaleAssets {
    static let shared = SpeechLocaleAssets(system: AppleSpeechAssetSystem())

    /// A running session's hold on its locale. Its locale is never released while held.
    struct Lease: Sendable, Hashable {
        let id = UUID()
        let locale: Locale
        let key: String
    }

    private let system: SpeechAssetSystem
    private let defaults: UserDefaults
    private var holds: [String: Int] = [:]
    private var downloading: Set<String> = []
    private static let recencyKey = "speechLocaleRecency"

    init(system: SpeechAssetSystem, defaults: UserDefaults = .standard) {
        self.system = system
        self.defaults = defaults
    }

    /// Locales held by running sessions (keys).
    var locked: Set<String> { Set(holds.filter { $0.value > 0 }.keys) }

    /// What a session in `requested` needs now. Changes nothing.
    func availability(for requested: Locale) async -> SpeechModelAvailability {
        guard let resolved = await system.supportedLocale(equivalentTo: requested) else { return .unsupported }
        if downloading.contains(SpeechReservationPlan.key(resolved)) { return .downloading(resolved) }
        let status = await system.status(of: resolved)
        log("availability requested=\(requested.identifier(.bcp47)) resolved=\(resolved.identifier(.bcp47)) status=\(status)")
        switch status {
        case .installed: return .installed(resolved)
        case .downloading: return .downloading(resolved)
        case .supported: return .needsDownload(resolved)
        case .unsupported: return .unsupported
        @unknown default: return .needsDownload(resolved)
        }
    }

    /// Makes `requested` ready and holds it for a session: resolved, reserved and installed. The
    /// returned lease must be ended when the session stops.
    func acquire(
        _ requested: Locale,
        allowDownload: Bool,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Lease {
        let resolved = try await prepare(requested, allowDownload: allowDownload, onProgress: onProgress)
        let lease = Lease(locale: resolved, key: SpeechReservationPlan.key(resolved))
        // Held from here on. `prepare` protected it while it ran; this keeps it protected for the session.
        holds[lease.key, default: 0] += 1
        return lease
    }

    func end(_ lease: Lease) {
        guard let count = holds[lease.key], count > 0 else { return }
        holds[lease.key] = count == 1 ? nil : count - 1
    }

    /// Resolved, reserved and — if allowed — installed. The locale is protected while this runs.
    @discardableResult
    func prepare(
        _ requested: Locale,
        allowDownload: Bool,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Locale {
        guard let resolved = await system.supportedLocale(equivalentTo: requested) else {
            log("requested=\(requested.identifier(.bcp47)) unsupported")
            throw SpeechLocaleAssetError.unsupported(requested)
        }
        let key = SpeechReservationPlan.key(resolved)
        holds[key, default: 0] += 1
        defer { end(Lease(locale: resolved, key: key)) }

        let installed = await system.installedLocales().contains { SpeechReservationPlan.key($0) == key }
        let status = await system.status(of: resolved)
        log("requested=\(requested.identifier(.bcp47)) resolved=\(resolved.identifier(.bcp47)) installed=\(installed ? "yes" : "no") status=\(status)")
        if status == .unsupported { throw SpeechLocaleAssetError.unsupported(requested) }

        try await ensureReserved(resolved)
        remember(key)

        if status != .installed {
            guard allowDownload else { throw SpeechLocaleAssetError.needsDownload(resolved) }
            log("install needed=yes locale=\(resolved.identifier(.bcp47))")
            downloading.insert(key)
            defer { downloading.remove(key) }
            try await system.install(resolved, onProgress: onProgress)
        } else {
            log("install needed=no locale=\(resolved.identifier(.bcp47))")
        }
        return resolved
    }

    /// Reserves `locale`, first releasing inactive reservations if the system limit is reached. One
    /// deterministic retry: if the reservation still fails, the list is re-read and planned again.
    private func ensureReserved(_ locale: Locale) async throws {
        for attempt in 1...2 {
            let reserved = await system.reservedLocales()
            let maximum = system.maximumReservedLocales
            log("reserved=[\(reserved.map { $0.identifier(.bcp47) }.joined(separator: ","))] maximum=\(maximum) attempt=\(attempt)")
            guard let releases = SpeechReservationPlan.releases(
                reserved: reserved, maximum: maximum, desired: locale,
                inUse: locked, recentlyUsed: recentlyUsed
            ) else {
                log("reservation blocked: every reserved locale is in use")
                throw SpeechLocaleAssetError.reservationsInUse
            }
            if reserved.contains(where: { SpeechReservationPlan.key($0) == SpeechReservationPlan.key(locale) }) {
                log("reservation reused locale=\(locale.identifier(.bcp47))")
                return
            }
            for old in releases {
                let released = await system.release(old)
                log("release locale=\(old.identifier(.bcp47)) ok=\(released)")
            }
            do {
                let created = try await system.reserve(locale)
                log("reserve locale=\(locale.identifier(.bcp47)) created=\(created)")
                return
            } catch {
                log("reserve locale=\(locale.identifier(.bcp47)) failed attempt=\(attempt): \(error.localizedDescription)")
                if attempt == 2 { throw error }
            }
        }
    }

    // MARK: Recency

    private var recentlyUsed: [String] { defaults.stringArray(forKey: Self.recencyKey) ?? [] }

    private func remember(_ key: String) {
        var list = recentlyUsed.filter { $0 != key }
        list.insert(key, at: 0)
        defaults.set(Array(list.prefix(8)), forKey: Self.recencyKey)
    }

    // MARK: Diagnostics

    /// Debug only: locale identifiers and asset states — never transcript text.
    private func log(_ message: String) {
        #if DEBUG
        let line = "[SpeechAssets] \(message)"
        LiveLifecycle.note(line)
        #endif
    }
}
