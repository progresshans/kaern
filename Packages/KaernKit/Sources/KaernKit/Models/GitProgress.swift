import Foundation

/// One progress line git prints on standard error while it talks to a remote or checks out files
/// ("Receiving objects:  62% (1284/2071), 18.40 MiB | 3.20 MiB/s").
public struct GitProgress: Sendable, Hashable {
    /// What git is doing: "Receiving objects", "Resolving deltas", "Updating files"…
    public var phase: String
    /// 0…100, when the line has a percentage.
    public var percent: Int?
    public var done: Int?
    public var total: Int?
    /// "18.40 MiB" while receiving.
    public var transferred: String?
    /// "3.20 MiB/s" while receiving.
    public var speed: String?
    /// The line ends with ", done.".
    public var isFinished: Bool

    public init(phase: String, percent: Int? = nil, done: Int? = nil, total: Int? = nil,
                transferred: String? = nil, speed: String? = nil, isFinished: Bool = false) {
        self.phase = phase
        self.percent = percent
        self.done = done
        self.total = total
        self.transferred = transferred
        self.speed = speed
        self.isFinished = isFinished
    }

    /// Reads one progress line; `nil` for anything else ("Cloning into…", hints, warnings).
    public static func parse(_ line: String) -> GitProgress? {
        var text = line.trimmingCharacters(in: .whitespaces)
        // Lines from the server carry "remote: ".
        if text.hasPrefix("remote: ") { text.removeFirst("remote: ".count) }
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let phase = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
        guard Self.phases.contains(where: { phase.hasPrefix($0) }) else { return nil }
        let rest = text[text.index(after: colon)...]
        var progress = GitProgress(phase: phase)
        progress.isFinished = rest.hasSuffix(", done.") || rest.hasSuffix("done.")
        // "  62% (1284/2071), 18.40 MiB | 3.20 MiB/s"
        if let percentEnd = rest.firstIndex(of: "%") {
            let number = rest[..<percentEnd].trimmingCharacters(in: .whitespaces)
            progress.percent = Int(number)
        }
        if let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let pair = rest[rest.index(after: open)..<close].split(separator: "/")
            if pair.count == 2 {
                progress.done = Int(pair[0])
                progress.total = Int(pair[1])
            }
        } else if progress.percent == nil {
            // "Counting objects: 2071, done." / "Enumerating objects: 5"
            let number = rest.split(separator: ",").first?.trimmingCharacters(in: .whitespaces)
            progress.done = number.flatMap { Int($0) }
        }
        if let comma = rest.range(of: "), ") {
            let tail = rest[comma.upperBound...].replacingOccurrences(of: ", done.", with: "")
            let parts = tail.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if let first = parts.first, first.contains("B") { progress.transferred = first }
            if parts.count > 1, parts[1].hasSuffix("/s") { progress.speed = parts[1] }
        }
        return progress
    }

    /// What git reports progress for, in the order a clone goes through them.
    static let phases = [
        "Enumerating objects", "Counting objects", "Compressing objects", "Receiving objects", "Resolving deltas",
        "Writing objects", "Updating files", "Checking out files", "Unpacking objects", "Filtering content",
    ]

    /// How far a whole clone or fetch is (0…1), counting receiving as most of it.
    public var overallFraction: Double? {
        guard let percent else { return nil }
        let value = Double(percent) / 100
        switch phase {
        case "Enumerating objects", "Counting objects", "Compressing objects": return value * 0.05
        case "Receiving objects", "Unpacking objects", "Writing objects": return 0.05 + value * 0.75
        case "Resolving deltas": return 0.8 + value * 0.12
        case "Updating files", "Checking out files", "Filtering content": return 0.92 + value * 0.08
        default: return value
        }
    }

    /// "1,284 of 2,071 objects · 18.4 MB · 3.2 MB/s" (what the clone sheet shows under the bar).
    public var detail: String? {
        var parts: [String] = []
        if let done, let total {
            let noun = phase.hasSuffix("deltas") ? "deltas" : phase.hasSuffix("files") ? "files" : "objects"
            parts.append("\(Self.grouped(done)) of \(Self.grouped(total)) \(noun)")
        }
        if let transferred { parts.append(Self.decimalUnits(transferred)) }
        if let speed { parts.append(Self.decimalUnits(speed)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func grouped(_ number: Int) -> String {
        number.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// git prints binary units ("18.40 MiB"); the Mac shows sizes in decimal ones ("19.3 MB").
    static func decimalUnits(_ text: String) -> String {
        let units: [(String, Double)] = [("GiB", 1_073_741_824), ("MiB", 1_048_576), ("KiB", 1024), ("bytes", 1)]
        let perSecond = text.hasSuffix("/s")
        let body = perSecond ? String(text.dropLast(2)) : text
        let parts = body.split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0]), let unit = units.first(where: { $0.0 == parts[1] }) else { return text }
        let bytes = Int64(value * unit.1)
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return perSecond ? formatted + "/s" : formatted
    }
}

/// Who wants to hear about the progress of the git commands a task runs (Activity's bars). Set
/// with `GitProgressReporter.$current.withValue(…)` around the work: network commands and
/// checkouts then report their progress lines to it.
public enum GitProgressReporter {
    @TaskLocal public static var current: (@Sendable (GitProgress) -> Void)?
}
