import Foundation
import SwiftData

@Model
final class PromptSession {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var activeSeconds: Int
    var completed: Bool
    var wasDemo: Bool
    var script: Script?

    init(
        id: UUID = UUID(),
        startedAt: Date = .now,
        activeSeconds: Int = 0,
        completed: Bool = false,
        wasDemo: Bool = false,
        script: Script? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.activeSeconds = activeSeconds
        self.completed = completed
        self.wasDemo = wasDemo
        self.script = script
    }
}
