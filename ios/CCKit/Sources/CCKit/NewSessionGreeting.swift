import Foundation

public enum NewSessionGreeting {
    public static func text(date: Date, name: String?, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .weekday], from: date)
        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = cleanName.flatMap { $0.isEmpty ? nil : ", \($0)" } ?? ""

        if weekdayVariant(components) {
            let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            if let weekday = components.weekday,
               weekdayNames.indices.contains(weekday - 1) {
                return "Happy \(weekdayNames[weekday - 1])\(suffix)"
            }
        }

        switch components.hour ?? 0 {
        case 5..<12:
            return "Good morning\(suffix)"
        case 12..<17:
            return "Good afternoon\(suffix)"
        case 17..<22:
            return "Good evening\(suffix)"
        default:
            return "Hello, night owl"
        }
    }

    private static func weekdayVariant(_ components: DateComponents) -> Bool {
        guard let year = components.year, let month = components.month, let day = components.day, let hour = components.hour else {
            return false
        }
        var hash = UInt64(year)
        hash = hash &* 31 &+ UInt64(month)
        hash = hash &* 31 &+ UInt64(day)
        hash = hash &* 31 &+ UInt64(hour)
        return hash % 5 == 0
    }
}
