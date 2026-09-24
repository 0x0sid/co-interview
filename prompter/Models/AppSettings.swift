import Foundation
import SwiftData

@Model
final class AppSettings {
    var fontScale: Double
    /// Reader appearance: "system" (default), "light" or "dark" (M5.10).
    var appearanceRaw: String = AppearancePreference.system.rawValue
    /// Whether the reader has opened the Premium entry at least once (M5.12). Drives the single
    /// unread badge; once cleared it stays cleared — the badge is not re-added merely because the
    /// reader has not subscribed.
    var hasSeenPremiumAnnouncement: Bool = false
    /// Interface language override. Empty means "follow the system", and English is the default
    /// the app ships with. An explicit existing choice is preserved.
    var interfaceLanguageRaw: String = ""
    /// Interview language preference ("system", "english", "french"). System by default; each
    /// session stores the language it actually used, so changing this never changes an old session.
    var interviewLanguageRaw: String = InterviewLanguagePreference.system.rawValue
    var mirrorDefault: Bool
    var outdoorMode: Bool
    var hasCompletedDemo: Bool
    var aiRewriteEnabled: Bool
    var premiumCachedActive: Bool
    var premiumCachedAt: Date?

    init(
        fontScale: Double = 1.0,
        appearanceRaw: String = AppearancePreference.system.rawValue,
        mirrorDefault: Bool = false,
        outdoorMode: Bool = false,
        hasCompletedDemo: Bool = false,
        aiRewriteEnabled: Bool = false,
        premiumCachedActive: Bool = false,
        premiumCachedAt: Date? = nil
    ) {
        self.fontScale = fontScale
        self.appearanceRaw = appearanceRaw
        self.mirrorDefault = mirrorDefault
        self.outdoorMode = outdoorMode
        self.hasCompletedDemo = hasCompletedDemo
        self.aiRewriteEnabled = aiRewriteEnabled
        self.premiumCachedActive = premiumCachedActive
        self.premiumCachedAt = premiumCachedAt
    }

    /// `AppSettings` is a singleton row — there's no natural unique key to `@Attribute(.unique)`
    /// since every field is a plain user preference, so callers fetch-or-create through here
    /// instead of constructing their own and risking a second row.
    @MainActor
    static func fetchOrCreate(in context: ModelContext) -> AppSettings {
        if let existing = try? context.fetch(FetchDescriptor<AppSettings>()).first {
            return existing
        }
        let created = AppSettings()
        context.insert(created)
        return created
    }
}

extension AppSettings {
    /// Typed accessor for `appearanceRaw`, falling back to `.system` for unknown values so a
    /// future addition can never strand an existing store.
    var appearance: AppearancePreference {
        get { AppearancePreference(rawValue: appearanceRaw) ?? .system }
        set { appearanceRaw = newValue.rawValue }
    }
}
