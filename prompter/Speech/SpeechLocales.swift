import Foundation
import Speech

/// The languages the on-device transcriber actually supports, and which are already installed.
///
/// Read from `SpeechTranscriber.supportedLocales` / `.installedLocales` (both async) once at launch and
/// cached. Until then — or if the query fails — English (US) and French (France), the languages the app
/// always shipped with, stand in. A language not in `supported` is never offered and never substituted.
enum SpeechLocales {
    private static let cache = LockedBox<(supported: [String], installed: Set<String>)>(
        (["en-US", "fr-FR"], [])
    )

    /// Supported transcriber locale identifiers, BCP-47 ("en-US").
    static var supported: [String] { cache.value.supported }
    static var installed: Set<String> { cache.value.installed }

    static func isSupported(_ identifier: String) -> Bool { supported.contains(identifier) }
    static func isInstalled(_ identifier: String) -> Bool { installed.contains(identifier) }

    /// Loads both lists from the transcriber. Safe to call more than once.
    static func load() async {
        let supported = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        guard !supported.isEmpty else { return }
        cache.value = (Array(Set(supported)).sorted(), Set(installed))
    }

    /// Test seam.
    static func setForTesting(supported: [String], installed: Set<String> = []) {
        cache.value = (supported, installed)
    }

    /// The supported locale that best matches a device language: same language and region, else the
    /// same language (and script, when given) in its most common supported region. Nil when the
    /// language is not supported at all.
    static func bestMatch(for identifier: String, in supported: [String] = SpeechLocales.supported) -> String? {
        let wanted = Locale(identifier: identifier).language
        guard let code = wanted.languageCode?.identifier else { return nil }
        let candidates = supported.filter { Locale(identifier: $0).language.languageCode?.identifier == code }
        guard !candidates.isEmpty else { return nil }
        if let region = wanted.region?.identifier,
           let exact = candidates.first(where: { Locale(identifier: $0).language.region?.identifier == region }) {
            return exact
        }
        // A script only when the device language names one ("zh-Hant"); Foundation infers one for
        // a bare "de", which must not decide the region.
        if let script = identifier.split(separator: "-").first(where: { $0.count == 4 }).map(String.init),
           let sameScript = candidates.first(where: { Locale(identifier: $0).language.maximalIdentifier.contains(script) }) {
            return sameScript
        }
        // The language's default region ("de" → "de-DE"), else the first supported variant.
        let maximal = Locale.Language(identifier: code).maximalIdentifier
        if let region = Locale.Language(identifier: maximal).region?.identifier,
           let usual = candidates.first(where: { Locale(identifier: $0).language.region?.identifier == region }) {
            return usual
        }
        return candidates.first
    }
}
