import Foundation

/// What the home screen says about the interview language's on-device speech model, before an
/// interview can start. It explains *why* a model is needed rather than reporting an error.
///
/// The selected language stays authoritative: it is chosen in Settings (the only language selector),
/// never changed here, and the model is Apple's on-device speech model, downloaded through the same
/// `SpeechModelStatus` Settings uses. Nothing here pretends a model is installed.
enum SpeechSetupState: Equatable {
    /// No language chosen yet (the app follows the iPhone's language): pick one first.
    case chooseLanguage
    /// A language is chosen and its model is missing.
    case download(languageName: String)
    case downloading(fraction: Double, languageName: String)
    case failed(languageName: String)
    /// This iPhone cannot run the model for that language.
    case unsupported(languageName: String)
    case checking
    /// Installed: Start Interview is available.
    case ready

    /// - Parameters:
    ///   - hasChosenLanguage: the user picked a language in Settings (not "System language").
    ///   - needsModel: the readiness check found the selected language's model missing.
    ///   - model: the live download state for that language.
    static func make(hasChosenLanguage: Bool, needsModel: Bool, model: SpeechModelStatus.State,
                     languageName: String) -> SpeechSetupState {
        switch model {
        case .downloading(let fraction): return .downloading(fraction: fraction, languageName: languageName)
        case .failed: return .failed(languageName: languageName)
        case .unsupported: return .unsupported(languageName: languageName)
        case .ready: return .ready
        case .checking: return needsModel ? .checking : .ready
        case .needsDownload:
            return hasChosenLanguage ? .download(languageName: languageName) : .chooseLanguage
        }
    }

    var headline: String {
        switch self {
        case .chooseLanguage: "Choose your interview language"
        case .download, .failed: "Download the speech model"
        case .downloading: "Downloading the speech model"
        case .unsupported: "Choose another language"
        case .checking: "Checking the speech model"
        case .ready: "Ready when you are."
        }
    }

    var body: String {
        switch self {
        case .chooseLanguage:
            "Neverblank uses an on-device speech model to understand the conversation during your interview. Choose the language you'll use and download its speech model once to get started."
        case .download(let name):
            "Neverblank needs the \(name) speech model before it can listen during a live interview."
        case .downloading(_, let name):
            "The \(name) speech model is downloading to your iPhone. You can start once it finishes."
        case .failed(let name):
            "The \(name) speech model couldn't be downloaded. Check your connection and try again."
        case .unsupported(let name):
            "This iPhone can't run the \(name) speech model. Choose another interview language."
        case .checking: "One moment…"
        case .ready: ""
        }
    }

    /// Shown under the explanation where it helps.
    var helper: String? {
        switch self {
        case .chooseLanguage, .download:
            "The speech model runs on your iPhone. You only need to download each language once."
        default: nil
        }
    }
}
