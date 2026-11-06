import Foundation

enum Formatters {
    private static let relativeFull: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let relativeShort: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let namedDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static let namedDayAndTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
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

    /// History table dates: "2 hours ago", "Yesterday", "Sep 27", "Sep 27, 2025".
    static func historyDate(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60, elapsed > -60 {
            return String(localized: "Just now")
        }
        if calendar.isDate(date, inSameDayAs: now) {
            return relativeFull.localizedString(for: date, relativeTo: now)
        }
        if calendar.isDateInYesterday(date) {
            return namedDay.string(from: date)
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return monthDay.string(from: date)
        }
        return monthDayYear.string(from: date)
    }

    /// Inspector dates: "Today at 9:14 AM".
    static func detailDate(_ date: Date) -> String {
        namedDayAndTime.string(from: date)
    }

    /// Status bar: "2 min ago".
    static func shortRelative(_ date: Date, now: Date = .now) -> String {
        if now.timeIntervalSince(date) < 60 {
            return String(localized: "just now")
        }
        return relativeShort.localizedString(for: date, relativeTo: now)
    }

    /// Blame's narrow column: "21 min ago" today, then "Yesterday", "Sep 27".
    static func compactDate(_ date: Date, now: Date = .now) -> String {
        now.timeIntervalSince(date) < 12 * 3600 ? shortRelative(date, now: now) : historyDate(date, now: now)
    }

    /// "~/Developer/powerlens"
    static func abbreviatedPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false).trimmingSuffix("/")
        // Canonical paths resolve /tmp and /var through /private; show them the way people type them.
        for prefix in ["/private/tmp/", "/private/var/"] where path.hasPrefix(prefix) {
            path.removeFirst("/private".count)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false).trimmingSuffix("/")
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) && count > suffix.count ? String(dropLast(suffix.count)) : self
    }
}

extension URL {
    /// Path without percent encoding or a trailing slash.
    var plainPath: String {
        path(percentEncoded: false).trimmingSuffix("/")
    }
}
