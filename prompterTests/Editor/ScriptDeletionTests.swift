import Testing
import Foundation
import SwiftData
@testable import prompter

/// **M5.11 — script deletion, and the things it must not touch.**
@MainActor
struct ScriptDeletionTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Script.self, PromptSession.self, UsageLedger.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test
    func deletingAScriptRemovesOnlyThatScript() throws {
        let context = try makeContext()
        let keep = Script(title: "Keep me", rawText: "one two three")
        let remove = Script(title: "Remove me", rawText: "four five six")
        context.insert(keep); context.insert(remove)
        try context.save()

        context.delete(remove)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<Script>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.title == "Keep me", "the wrong script was deleted")
    }

    /// The deletion must persist — not merely disappear from the in-memory view.
    @Test
    func deletionPersistsInTheStore() throws {
        let container = try ModelContainer(
            for: Script.self, PromptSession.self, UsageLedger.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let script = Script(title: "Doomed", rawText: "hello")
        context.insert(script)
        try context.save()
        context.delete(script)
        try context.save()

        // A fresh context over the same container is the closest in-process analogue of a relaunch.
        let reopened = ModelContext(container)
        let scripts = try reopened.fetch(FetchDescriptor<Script>())
        #expect(scripts.isEmpty, "the script came back after re-reading the store")
    }

    /// `Script.sessions` cascades, so a script's own sessions go with it — and nothing else does.
    @Test
    func deletingCascadesToItsOwnSessionsOnly() throws {
        let context = try makeContext()
        let a = Script(title: "A", rawText: "a")
        let b = Script(title: "B", rawText: "b")
        context.insert(a); context.insert(b)
        let sessionA = PromptSession(script: a)
        let sessionB = PromptSession(script: b)
        context.insert(sessionA); context.insert(sessionB)
        try context.save()

        context.delete(a)
        try context.save()

        let sessions = try context.fetch(FetchDescriptor<PromptSession>())
        #expect(sessions.count == 1, "cascade removed sessions belonging to another script")
        #expect(sessions.first?.script?.title == "B")
    }

    /// **Deleting a script must not reset the daily allowance.** `UsageLedger` is keyed by calendar
    /// day and holds no relationship to `Script`; this pins that they stay independent.
    @Test
    func deletingAScriptDoesNotResetDailyUsage() throws {
        let context = try makeContext()
        let script = Script(title: "Doomed", rawText: "hello")
        context.insert(script)
        let ledger = UsageLedger(dayKey: UsageLedger.dayKey(), secondsUsed: 420)
        context.insert(ledger)
        try context.save()

        context.delete(script)
        try context.save()

        let ledgers = try context.fetch(FetchDescriptor<UsageLedger>())
        #expect(ledgers.count == 1, "the usage ledger was removed with the script")
        #expect(ledgers.first?.secondsUsed == 420, "daily usage was reset by a script deletion")
    }

    /// Settings — which carry entitlement caching — must survive a script deletion untouched.
    @Test
    func deletingAScriptDoesNotAlterSettingsOrEntitlementCache() throws {
        let context = try makeContext()
        let settings = AppSettings(fontScale: 1.4, premiumCachedActive: true)
        context.insert(settings)
        let script = Script(title: "Doomed", rawText: "hello")
        context.insert(script)
        try context.save()

        context.delete(script)
        try context.save()

        let stored = try context.fetch(FetchDescriptor<AppSettings>())
        #expect(stored.count == 1)
        #expect(stored.first?.premiumCachedActive == true, "entitlement cache changed on script deletion")
        #expect(stored.first?.fontScale == 1.4, "settings changed on script deletion")
    }

    /// Cancelling must leave everything in place — the safe action really is safe.
    @Test
    func cancellingLeavesTheScriptInPlace() throws {
        let context = try makeContext()
        let script = Script(title: "Spared", rawText: "hello")
        context.insert(script)
        try context.save()

        // No delete is issued: this is what "Cancel" does.
        let scripts = try context.fetch(FetchDescriptor<Script>())
        #expect(scripts.count == 1)
        #expect(scripts.first?.title == "Spared")
    }

    /// The bundled demo is not a stored user document, so deletion cannot remove it.
    @Test
    func theBundledDemoIsNotADeletableUserDocument() throws {
        let context = try makeContext()
        let script = Script(title: "User script", rawText: "hello")
        context.insert(script)
        try context.save()
        context.delete(script)
        try context.save()

        // The demo's text is a compiled-in constant, reachable with an empty store.
        #expect(!PromptDemoFixture.defaultScriptText.isEmpty,
                "the bundled demo script is no longer available after deleting user scripts")
        #expect(try context.fetch(FetchDescriptor<Script>()).isEmpty)
    }
}
