import Foundation
import Speech

/// Ensures the on-device speech model for a locale is installed before a prompting session
/// starts (§11.2). Pre-warmed during onboarding/the demo screen (M5) so the first real session
/// has no download delay.
///
/// Verified against the installed iOS 26.5 SDK's Speech.swiftinterface (public docs page did not
/// return renderable content at verification time — see AGENT_PROGRESS.md):
/// `SpeechTranscriber.supportedLocale(equivalentTo:)`,
/// `AssetInventory.assetInstallationRequest(supporting:)`,
/// `AssetInstallationRequest.downloadAndInstall()`.
enum SpeechAssetManager {
    enum AssetError: Error, Sendable {
        case localeNotSupported(Locale)
    }

    /// Resolves `locale` to one `SpeechTranscriber` actually supports, or throws if none is
    /// close enough (§24.3: no phantom fallback — the fuzzy matcher absorbs recognition
    /// variance, but an unsupported locale is a real, surfaced error, not silently substituted).
    static func supportedLocale(for locale: Locale) async throws -> Locale {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AssetError.localeNotSupported(locale)
        }
        return supported
    }

    /// Downloads and installs the on-device model for `locale` if it isn't already present, through
    /// the app's one reservation owner (`SpeechLocaleAssets`), so reservations never accumulate.
    static func ensureInstalled(locale: Locale) async throws {
        try await SpeechLocaleAssets.shared.prepare(locale, allowDownload: true)
    }

    /// Same, reporting fractional progress (0...1) on the main actor.
    @MainActor
    static func ensureInstalled(locale: Locale, onProgress: @escaping @MainActor (Double) -> Void) async throws {
        try await SpeechLocaleAssets.shared.prepare(locale, allowDownload: true) { fraction in
            Task { @MainActor in onProgress(fraction) }
        }
        onProgress(1.0)
    }
}
