import Foundation

enum Formatters {
    private static let relativeFull: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private static let monthDayYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdyyyy")
        return formatter
    }()

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// "10:42 AM".
    static func time(_ date: Date) -> String {
        Self.time.string(from: date)
    }

    /// History dates: "2 hours ago", "Yesterday", "Sep 27", "Sep 27, 2025".
    static func historyDate(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60, elapsed > -60 { return String(localized: "Just now") }
        if calendar.isDate(date, inSameDayAs: now) {
            return relativeFull.localizedString(for: date, relativeTo: now)
        }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return monthDay.string(from: date)
        }
        return monthDayYear.string(from: date)
    }

    /// Short dates for sidebar rows: "Sep 26", "Sep 26, 2025".
    static func shortDate(_ date: Date, now: Date = .now) -> String {
        if Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now) {
            return monthDay.string(from: date)
        }
        return monthDayYear.string(from: date)
    }

    /// Status bar: "just now", "2 min ago", "3 hours ago", "yesterday", "4 days ago".
    static func shortRelative(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return String(localized: "just now") }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return String(localized: "\(minutes) min ago") }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? String(localized: "1 hour ago") : String(localized: "\(hours) hours ago") }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "yesterday") }
        let days = max(1, hours / 24)
        if days < 30 { return days == 1 ? String(localized: "1 day ago") : String(localized: "\(days) days ago") }
        return String(localized: "on \(shortDate(date, now: now))")
    }

    /// "today at 6:12 PM", "Yesterday at 9:02 AM", "Sep 26 at 4:10 PM".
    static func closedAt(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let clock = time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "today at \(clock)") }
        if calendar.isDateInYesterday(date) { return String(localized: "yesterday at \(clock)") }
        return String(localized: "\(shortDate(date, now: now)) at \(clock)")
    }

    /// Commit details: "today at 2:05 PM", "yesterday at 6:40 PM", "on Sep 27, 2026".
    static func authoredAt(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let clock = time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "today at \(clock)") }
        if calendar.isDateInYesterday(date) { return String(localized: "yesterday at \(clock)") }
        return String(localized: "on \(monthDayYear.string(from: date))")
    }

    /// "~/Developer/powerlens"
    static func abbreviatedPath(_ path: String) -> String {
        var path = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        // Canonical paths resolve /tmp and /var through /private; show them the way people type them.
        for prefix in ["/private/tmp/", "/private/var/"] where path.hasPrefix(prefix) {
            path.removeFirst("/private".count)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == trimmedHome { return "~" }
        if path.hasPrefix(trimmedHome + "/") { return "~" + path.dropFirst(trimmedHome.count) }
        return path
    }

    static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value.formatted()) \(value == 1 ? singular : plural)"
    }
}
