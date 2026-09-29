import Testing
import Foundation

/// Guards the one Info.plist difference that is allowed to exist.
///
/// Live mode needs to reach a development backend over plain HTTP on the LAN, which App Transport
/// Security forbids unless the app asks for an exception. That exception belongs in **development
/// builds only** — a shipped app has no business relaxing transport security for a server that only
/// exists on a developer's desk.
///
/// Xcode cannot express a nested ATS dictionary as a per-configuration build setting, so there are
/// two plists: `Info.plist` for Release and `Info-Debug.plist` for Debug. Two files invite drift,
/// which is exactly what these tests exist to catch: the debug plist may differ **only** by the
/// local-networking keys, and the release plist must not carry them at all.
struct InfoPlistConfigurationTests {
    /// The keys development is allowed to add, and nothing else.
    static let developmentOnlyKeys: Set<String> = [
        "NSAppTransportSecurity",
        "NSLocalNetworkUsageDescription",
        // Backend host (not a secret) injected from the git-ignored Local-Debug.xcconfig.
        "CopilotDevBackendHost",
        // Billing-test builds only (set on the xcodebuild command line); Release always uses it.
        "NeverblankInstallationAccess",
    ]

    /// The production backend. Release-only on purpose: in Debug a plist URL would outrank the
    /// developer's own backend (`ProviderConfiguration.resolve`).
    static let releaseOnlyKeys: Set<String> = ["CopilotBackendURL"]

    static func plist(named name: String) throws -> [String: Any] {
        // Walk up from this file to the repository root, so the test reads the checked-in sources
        // rather than whatever was copied into a build product.
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // DesignSystem
            .deletingLastPathComponent()      // prompterTests
            .deletingLastPathComponent()      // repository root
        directory.append(path: "prompter/Resources/\(name)")
        let data = try Data(contentsOf: directory)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(parsed as? [String: Any])
    }

    @Test
    func theReleasePlistCarriesNoTransportSecurityException() throws {
        let release = try Self.plist(named: "Info.plist")
        #expect(release["NSAppTransportSecurity"] == nil,
                "a Release build would ship an ATS exception for a development backend")
        #expect(release["NSLocalNetworkUsageDescription"] == nil)
    }

    /// A Release build must carry no development backend and no access token of any kind.
    @Test
    func theReleasePlistCarriesNoDevelopmentBackend() throws {
        let release = try Self.plist(named: "Info.plist")
        #expect(release["CopilotDevBackendHost"] == nil)
        #expect(release["CopilotDevBackendToken"] == nil,
                "a Release build would ship a client access token")
    }

    /// **No provider credential may exist in either plist, under any name.**
    ///
    /// The phone is only ever entitled to a *client* token for the backend. The provider key is what
    /// costs money and what an attacker wants, and it belongs in the backend's environment. This
    /// asserts the absence by shape rather than by listing the keys we happen to use today, so a new
    /// key added carelessly in future fails here.
    /// **No backend token in any build.** An operator token baked into the Debug plist reached every
    /// Debug build on a device and was accepted by production. Neither plist may carry a token key.
    @Test
    func neitherPlistCarriesABackendToken() throws {
        for name in ["Info.plist", "Info-Debug.plist"] {
            let plist = try Self.plist(named: name)
            for (key, value) in plist {
                #expect(!key.lowercased().contains("token"), "\(name) has a token key: \(key)")
                if let text = value as? String {
                    #expect(!text.contains("TOKEN"), "\(name) substitutes a token setting at \(key)")
                }
            }
        }
    }

    @Test
    func neitherPlistCarriesAProviderCredential() throws {
        for name in ["Info.plist", "Info-Debug.plist"] {
            let plist = try Self.plist(named: name)
            for (key, value) in plist {
                let lowered = key.lowercased()
                #expect(!lowered.contains("openrouter"), "\(name) has a key named \(key)")
                #expect(!lowered.contains("openai"), "\(name) has a key named \(key)")
                #expect(!lowered.contains("apikey") && !lowered.contains("api_key"),
                        "\(name) has a key named \(key)")
                if let text = value as? String {
                    #expect(!text.hasPrefix("sk-"), "\(name) carries a provider-key-shaped value at \(key)")
                }
            }
        }
    }

    /// The committed Debug plist must reference build settings, never literal values — the real
    /// host and token live in the git-ignored xcconfig and must never be committed here.
    @Test
    func theDebugPlistHoldsSubstitutionsRatherThanRealValues() throws {
        let debug = try Self.plist(named: "Info-Debug.plist")
        #expect(debug["CopilotDevBackendHost"] as? String == "$(COPILOT_DEV_BACKEND_HOST)")
        #expect(debug["CopilotDevBackendToken"] == nil, "no token is ever built into the app")
    }

    @Test
    func theDebugPlistCarriesTheNarrowestExceptionThatWorks() throws {
        let debug = try Self.plist(named: "Info-Debug.plist")
        let ats = try #require(debug["NSAppTransportSecurity"] as? [String: Any])
        #expect(ats["NSAllowsLocalNetworking"] as? Bool == true)
        // The blanket escape hatch must never appear: local networking permits plain HTTP to LAN
        // and .local addresses only, while arbitrary loads would relax every public connection too.
        #expect(ats["NSAllowsArbitraryLoads"] == nil,
                "NSAllowsArbitraryLoads would weaken transport security for internet hosts")
        #expect(debug["NSLocalNetworkUsageDescription"] is String)
    }

    /// The two files must stay identical apart from those keys — otherwise a permission string or a
    /// font list fixed in one configuration quietly stays broken in the other.
    @Test
    func theTwoPlistsDifferOnlyByTheDevelopmentKeys() throws {
        let release = try Self.plist(named: "Info.plist")
        let debug = try Self.plist(named: "Info-Debug.plist")

        let extraInDebug = Set(debug.keys).subtracting(release.keys)
        #expect(extraInDebug == Self.developmentOnlyKeys,
                "unexpected difference: \(extraInDebug.symmetricDifference(Self.developmentOnlyKeys))")
        #expect(Set(release.keys).subtracting(debug.keys) == Self.releaseOnlyKeys,
                "the debug plist is missing keys the release plist has")

        for key in release.keys where !Self.releaseOnlyKeys.contains(key) {
            // Deep equality, not string description: a dictionary or array prints in whatever order
            // it happens to enumerate, which made this compare unequal values that were identical.
            let releaseValue = release[key] as? NSObject
            let debugValue = debug[key] as? NSObject
            #expect(releaseValue == debugValue, "\(key) differs between the Debug and Release plists")
        }
    }

    // MARK: Billing environment

    static func repositoryFile(_ path: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        url.append(path: path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Both plists take the store and the key from build settings — never a literal key.
    @Test
    func bothPlistsTakeTheBillingStoreAndKeyFromBuildSettings() throws {
        for name in ["Info.plist", "Info-Debug.plist"] {
            let plist = try Self.plist(named: name)
            #expect(plist["BillingStoreMode"] as? String == "$(BILLING_STORE_MODE)", "\(name)")
            #expect(plist["RevenueCatPublicKey"] as? String == "$(REVENUECAT_API_KEY)", "\(name)")
        }
    }

    /// Debug sells through the Test Store, Release through the App Store — declared in the committed
    /// xcconfigs, with no key committed in either.
    @Test
    func theCommittedXcconfigsDeclareTheStorePerConfiguration() throws {
        let debug = try Self.repositoryFile("prompter/Config/Debug.xcconfig")
        let release = try Self.repositoryFile("prompter/Config/Release.xcconfig")
        #expect(debug.contains("BILLING_STORE_MODE = test-store"))
        #expect(release.contains("BILLING_STORE_MODE = app-store"))
        for text in [debug, release] {
            let settings = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            #expect(!settings.contains { $0.contains("test_") || $0.contains("appl_") }, "no key literal committed")
            #expect(!settings.contains { $0.uppercased().contains("TOKEN") }, "no token setting")
        }
        #expect(!release.contains("Local-Debug"), "Release never reads the development file")
    }

    /// The production backend comes from the Release configuration, not a literal in the plist.
    @Test
    func theReleaseBackendURLComesFromTheReleaseConfiguration() throws {
        let plist = try Self.plist(named: "Info.plist")
        #expect(plist["CopilotBackendURL"] as? String == "https://$(NEVERBLANK_BACKEND_HOST)")
        let release = try Self.repositoryFile("prompter/Config/Release.xcconfig")
        let host = release.split(separator: "\n").first { $0.hasPrefix("NEVERBLANK_BACKEND_HOST") }
            .map { $0.split(separator: "=", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "" }
        #expect(host == "backend--d7y3w.fly.dev")
        #expect(!(host ?? "").contains("/"), "a host only: xcconfig would cut an https:// value at //")
    }

    /// "Stamp Build Info" writes the checkout path, commit and date into Debug builds only.
    @Test
    func buildInfoIsStampedIntoDebugOnly() throws {
        let project = try Self.repositoryFile("co-interview.xcodeproj/project.pbxproj")
        let stamp = try #require(project.range(of: "/* Stamp Build Info */ = {"))
        let script = project[stamp.upperBound...].prefix(1_600)
        #expect(script.contains("[ \\\"${CONFIGURATION}\\\" = \\\"Debug\\\" ] || exit 0"),
                "the stamp must exit before writing anything outside Debug")
    }

    /// The Release build runs the safety check, and it enforces what it says.
    @Test
    func theReleaseBuildRunsTheSafetyCheck() throws {
        let project = try Self.repositoryFile("co-interview.xcodeproj/project.pbxproj")
        #expect(project.contains("/* Release safety check */ = {"))
        #expect(project.contains("scripts/release-guard.sh"))
        #expect(!project.contains("REVENUECAT_PUBLIC_KEY"), "a target-level key setting would override the xcconfig")
        let guardScript = try Self.repositoryFile("scripts/release-guard.sh")
        for rule in ["test_*)", "app-store", "CopilotBackendURL", "ngrok", "COPILOT_DEV_BACKEND_TOKEN", "sk-or-v1-", "backend/.env"] {
            #expect(guardScript.contains(rule), "the guard no longer checks \(rule)")
        }
    }
}
