import Foundation
import SwiftData

enum AppEnvironment {
    /// **Co-Interview's local store is deliberately separate from Prompter's.**
    ///
    /// Two things keep them apart, and either alone would be sufficient:
    ///
    /// 1. the app's bundle identifier differs (`talk.cointerview` vs `talk.prompter`), so iOS gives
    ///    the two apps entirely different sandboxed containers; and
    /// 2. the store file is named explicitly below rather than taking SwiftData's default.
    ///
    /// The explicit name exists so the separation is visible in source and survives any future
    /// bundle-identifier change. Running Co-Interview cannot read, migrate or damage Prompter's
    /// scripts, settings or usage ledger.
    static let storeFileName = "CoInterview.store"

    static func makeModelContainer() -> ModelContainer {
        // NOTE (inherited): this schema is Prompter's. It is carried over as scaffolding so the app
        // builds and runs; it is **not** an approved Co-Interview data model. See
        // docs/CO_INTERVIEW_ARCHITECTURE.md.
        let schema = Schema([
            Script.self,
            PromptSession.self,
            UsageLedger.self,
            AppSettings.self,
        ])
        let url = URL.applicationSupportDirectory.appending(path: storeFileName)
        let configuration = ModelConfiguration(schema: schema, url: url)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }
}
