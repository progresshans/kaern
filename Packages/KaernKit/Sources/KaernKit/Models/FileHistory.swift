import Foundation

/// A commit that changed a file (File History), with the file's path in that commit: history
/// follows renames, so older commits can name the file differently.
public struct FileHistoryEntry: Sendable, Hashable, Identifiable {
    public var commit: Commit
    /// The file's path in this commit.
    public var path: String
    /// The path before this commit, when this commit renamed the file.
    public var oldPath: String?
    public var stat: LineStat?

    public var id: String { commit.id }

    public init(commit: Commit, path: String, oldPath: String? = nil, stat: LineStat? = nil) {
        self.commit = commit
        self.path = path
        self.oldPath = oldPath
        self.stat = stat
    }
}

/// Parses `git log --follow --format=%x1e<LogParser.format> --numstat -z -- <path>`.
public enum FileHistoryParser {
    public static let format = "%x1e" + LogParser.format

    /// `path` is the file's current name; entries without a numstat line keep the name the
    /// newer commits had.
    public static func parse(_ data: Data, path: String) -> [FileHistoryEntry] {
        var entries: [FileHistoryEntry] = []
        var currentPath = path
        for record in data.split(separator: 0x1E, omittingEmptySubsequences: true) {
            // Header, NUL, then "\n" and the numstat records.
            guard let headerEnd = record.firstIndex(of: Records.nul) else { continue }
            let header = String(decoding: record[record.startIndex ..< headerEnd], as: UTF8.self)
            guard let commit = LogParser.parseRecord(header) else { continue }
            let tokens = Records.splitNUL(Data(record[record.index(after: headerEnd)...]))
                .map { $0.trimmingCharacters(in: .newlines) }
            var entry = FileHistoryEntry(commit: commit, path: currentPath)
            if let first = tokens.first(where: { !$0.isEmpty }), let firstIndex = tokens.firstIndex(of: first) {
                let parts = first.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                if parts.count >= 2 {
                    entry.stat = LineStat(additions: Int(parts[0]), deletions: Int(parts[1]))
                    if parts.count == 3, !parts[2].isEmpty {
                        entry.path = parts[2]
                    } else if firstIndex + 2 < tokens.count {
                        // A rename: "A\tD\t" NUL old NUL new.
                        entry.oldPath = tokens[firstIndex + 1]
                        entry.path = tokens[firstIndex + 2]
                    }
                }
            }
            entries.append(entry)
            // Older commits know the file by the name it had before a rename.
            currentPath = entry.oldPath ?? entry.path
        }
        return entries
    }
}

// MARK: - Blame

/// The commit that last changed some lines of a file (`git blame --porcelain`).
public struct BlameCommit: Sendable, Hashable, Identifiable {
    public var id: String
    public var author: String
    public var authorEmail: String
    public var date: Date
    public var summary: String
    /// The commit before this one and the file's path there, for Blame Before This Commit.
    public var previousID: String?
    public var previousPath: String?
    /// The file's path in this commit.
    public var path: String

    /// Lines changed in the working copy and not committed yet.
    public var isUncommitted: Bool { id.allSatisfy { $0 == "0" } }
    public var shortID: String { String(id.prefix(7)) }

    public init(id: String, author: String = "", authorEmail: String = "", date: Date = .distantPast, summary: String = "",
                previousID: String? = nil, previousPath: String? = nil, path: String = "") {
        self.id = id
        self.author = author
        self.authorEmail = authorEmail
        self.date = date
        self.summary = summary
        self.previousID = previousID
        self.previousPath = previousPath
        self.path = path
    }
}

/// Consecutive lines last changed by the same commit, shown as one block.
public struct BlameChunk: Sendable, Hashable, Identifiable {
    public var commitID: String
    /// Indexes into `Blame.lines`.
    public var lines: Range<Int>

    public var id: Int { lines.lowerBound }
}

public struct Blame: Sendable, Hashable {
    public struct Line: Sendable, Hashable {
        public var commitID: String
        /// 1-based line number in the blamed file.
        public var number: Int
        /// The line without its newline (may end with `\r` in CRLF files).
        public var text: String
    }

    public var lines: [Line]
    public var commits: [String: BlameCommit]
    public var chunks: [BlameChunk]
    /// 0 (oldest) … 3 (newest) per committed commit, spread by rank so every shade gets used
    /// and the newest change is always the darkest.
    public var ageLevels: [String: Int]

    public init(lines: [Line], commits: [String: BlameCommit]) {
        self.lines = lines
        self.commits = commits
        var chunks: [BlameChunk] = []
        for (index, line) in lines.enumerated() {
            if let last = chunks.last, last.commitID == line.commitID, last.lines.upperBound == index {
                chunks[chunks.count - 1].lines = last.lines.lowerBound ..< index + 1
            } else {
                chunks.append(BlameChunk(commitID: line.commitID, lines: index ..< index + 1))
            }
        }
        self.chunks = chunks
        let committed = commits.values.filter { !$0.isUncommitted }.sorted { $0.date < $1.date }
        var levels: [String: Int] = [:]
        for (rank, commit) in committed.enumerated() {
            levels[commit.id] = committed.count == 1 ? 3 : Int((Double(rank) * 3 / Double(committed.count - 1)).rounded())
        }
        ageLevels = levels
    }

    /// Text with NUL bytes isn't worth showing line by line.
    public var isBinary: Bool { lines.contains { $0.text.contains("\0") } }
}

/// Parses `git blame --porcelain`.
public enum BlameParser {
    public static func parse(_ data: Data) -> Blame {
        var lines: [Blame.Line] = []
        var commits: [String: BlameCommit] = [:]
        let rows = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0
        while index < rows.count {
            let header = rows[index].split(separator: " ")
            index += 1
            guard header.count >= 3, header[0].count >= 40, let final = Int(header[2]) else { continue }
            let id = String(header[0])
            var commit = commits[id] ?? BlameCommit(id: id)
            let isNew = commits[id] == nil
            // Metadata comes the first time a commit shows up; then the line itself after a tab.
            while index < rows.count, !rows[index].hasPrefix("\t") {
                let row = rows[index]
                index += 1
                guard isNew || row.hasPrefix("filename ") else { continue }
                let (key, value) = split(row)
                switch key {
                case "author": commit.author = value
                case "author-mail": commit.authorEmail = value.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                case "author-time": commit.date = Records.date(fromUnix: value)
                case "summary": commit.summary = value
                case "previous":
                    let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
                    commit.previousID = parts.first
                    commit.previousPath = parts.count > 1 ? parts[1] : nil
                case "filename": commit.path = value
                default: break
                }
            }
            commits[id] = commit
            guard index < rows.count else { break }
            lines.append(Blame.Line(commitID: id, number: final, text: String(rows[index].dropFirst())))
            index += 1
        }
        return Blame(lines: lines, commits: commits)
    }

    private static func split(_ row: Substring) -> (String, String) {
        guard let space = row.firstIndex(of: " ") else { return (String(row), "") }
        return (String(row[..<space]), String(row[row.index(after: space)...]))
    }
}
