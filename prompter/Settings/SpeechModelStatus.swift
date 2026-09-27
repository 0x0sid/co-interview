import Foundation
import Observation

/// The selected interview language's on-device speech model, as Settings shows it: ready, a one-time
/// download (with progress), unsupported, or a failed download to retry.
///
/// Backed by `SpeechLocaleAssets` — the app's one owner of speech-model reservations — so a download
/// here reserves and installs exactly as a session would, and reservation limits are handled there,
/// never shown to the user.
@MainActor
@Observable
final class SpeechModelStatus {
    enum State: Equatable {
        case checking
        case ready
        case needsDownload
        case downloading(Double)
        case unsupported
        /// The download did not finish; Retry is offered.
        case failed
    }

    /// The app's one status: a download started in Settings keeps running after Settings closes, and
    /// reopening Settings shows its real progress.
    static let shared = SpeechModelStatus()

    private(set) var state: State = .checking
    private(set) var language: InterviewLanguage?
    private var downloadTask: Task<Void, Never>?

    private let availability: (Locale) async -> SpeechModelAvailability
    private let install: (Locale, @escaping @Sendable (Double) -> Void) async throws -> Void

    init(
        availability: @escaping (Locale) async -> SpeechModelAvailability = LiveReadiness.systemSpeechModel,
        install: @escaping (Locale, @escaping @Sendable (Double) -> Void) async throws -> Void = SpeechModelStatus.systemInstall
    ) {
        self.availability = availability
        self.install = install
    }

    /// The device's real download: reserved and installed by `SpeechLocaleAssets.shared`.
    nonisolated static func systemInstall(_ locale: Locale, _ progress: @escaping @Sendable (Double) -> Void) async throws {
        try await SpeechLocaleAssets.shared.prepare(locale, allowDownload: true, onProgress: progress)
    }

    /// Backed by one `SpeechLocaleAssets` instance for both checking and downloading.
    convenience init(assets: SpeechLocaleAssets) {
        self.init(availability: { await assets.availability(for: $0) },
                  install: { locale, progress in try await assets.prepare(locale, allowDownload: true, onProgress: progress) })
    }

    var isReady: Bool { state == .ready }
    var isDownloading: Bool { if case .downloading = state { true } else { false } }
    /// The selected language cannot be used until something is done: download, retry, or choose another.
    var needsAction: Bool { [.needsDownload, .failed, .unsupported].contains(state) }

    /// Starts the download unless one is already running — repeated taps do nothing.
    func startDownload() {
        guard !isDownloading, downloadTask == nil else { return }
        downloadTask = Task { [weak self] in
            await self?.download()
            self?.downloadTask = nil
        }
    }

    /// Stops waiting for the download. The system may still complete one it has already begun; the
    /// next check reports whatever is really on the device.
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if isDownloading { state = .needsDownload }
    }

    /// Re-reads the model's state for `language` (the selected interview language).
    func refresh(for language: InterviewLanguage) async {
        self.language = language
        if case .downloading = state { return }
        state = .checking
        let result = await availability(language.transcriberLocale)
        guard self.language == language else { return }         // the selection moved on meanwhile
        #if DEBUG
        // UI screenshots of the download states: `-UITestsSpeechModel failed|downloading`.
        switch UITestOverrides.speechModel {
        case "failed": state = .failed; return
        case "downloading": state = .downloading(0.42); return
        default: break
        }
        #endif
        switch result {
        case .installed: state = .ready
        case .needsDownload: state = .needsDownload
        case .downloading: state = .downloading(0)
        case .unsupported: state = .unsupported
        }
    }

    /// The one-time download. Ends ready, or failed with Retry — never silently in another language.
    func download() async {
        guard let language else { return }
        state = .downloading(0)
        defer { if Task.isCancelled, isDownloading { state = .needsDownload } }
        do {
            try await install(language.transcriberLocale) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(fraction)
                }
            }
            guard !Task.isCancelled else { return }
            state = .checking                                        // re-read, rather than assume
            await refresh(for: language)
        } catch is CancellationError {
            state = .needsDownload
        } catch SpeechLocaleAssetError.unsupported {
            state = .unsupported
        } catch {
            state = .failed
        }
    }
}
