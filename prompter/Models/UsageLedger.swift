import Foundation
import SwiftData

@Model
final class UsageLedger {
    @Attribute(.unique) var dayKey: String
    var secondsUsed: Int
    var updatedAt: Date

    init(dayKey: String, secondsUsed: Int = 0, updatedAt: Date = .now) {
        self.dayKey = dayKey
        self.secondsUsed = secondsUsed
        self.updatedAt = updatedAt
    }

    static func dayKey(for date: Date = .now, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
