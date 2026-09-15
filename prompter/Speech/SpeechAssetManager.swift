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

    /// Downloads and installs the on-device model for `locale` if it isn't already present.
    /// `assetInstallationRequest` returns `nil` when nothing needs downloading, so this is safe
    /// to call unconditionally at the start of onboarding/demo pre-warm.
    static func ensureInstalled(locale: Locale) async throws {
        try await ensureInstalled(locale: locale, onProgress: { _ in })
    }

    /// Same as `ensureInstalled(locale:)`, but reports fractional progress (0...1) while
    /// downloading — used by the Demo explainer's "small progress hint" (§12.2, M5). Verified
    /// against the real SDK: `AssetInstallationRequest: ProgressReporting` exposes a `Progress`
    /// (`Foundation.ProgressReporting`, not invented), so this polls its real
    /// `fractionCompleted` rather than faking a hint. `onProgress` is called on the main actor —
    /// callers (SwiftUI) don't need their own hop.
    @MainActor
    static func ensureInstalled(locale: Locale, onProgress: @escaping @MainActor (Double) -> Void) async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            onProgress(1.0)
            return
        }

        let progress = request.progress
        let pollTask = Task { @MainActor in
            while !Task.isCancelled {
                onProgress(progress.fractionCompleted)
                if progress.isFinished { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        try await request.downloadAndInstall()
        pollTask.cancel()
        onProgress(1.0)
    }
}
