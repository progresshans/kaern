import Foundation

/// Parses `git status --porcelain=v2 --branch --show-stash -z`.
public enum StatusParser {
    public static func parse(_ data: Data) -> WorkingTreeStatus {
        let records = Records.splitNUL(data)
        var status = WorkingTreeStatus()
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard let type = record.first else { continue }
            switch type {
            case "#":
                parseHeader(record, into: &status)
            case "1":
                // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
                let parts = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9, let xy = statusPair(parts[1]) else { continue }
                var entry = StatusEntry(path: String(parts[8]), indexStatus: xy.0, worktreeStatus: xy.1)
                entry.submodule = submoduleStatus(parts)
                status.entries.append(entry)
            case "2":
                // 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path> NUL <origPath>
                let parts = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                let original = index < records.count ? records[index] : nil
                index += 1
                guard parts.count == 10, let xy = statusPair(parts[1]) else { continue }
                var entry = StatusEntry(
                    path: String(parts[9]),
                    originalPath: original,
                    indexStatus: xy.0,
                    worktreeStatus: xy.1
                )
                entry.submodule = submoduleStatus(parts)
                status.entries.append(entry)
            case "u":
                // u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
                let parts = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11, let xy = statusPair(parts[1]) else { continue }
                status.entries.append(StatusEntry(
                    path: String(parts[10]),
                    indexStatus: xy.0,
                    worktreeStatus: xy.1,
                    isConflicted: true
                ))
            case "?":
                status.entries.append(StatusEntry(
                    path: String(record.dropFirst(2)),
                    indexStatus: ".",
                    worktreeStatus: "?",
                    isUntracked: true
                ))
            default:
                // "!" (ignored) and anything unknown.
                continue
            }
        }
        return status
    }

    private static func statusPair(_ field: Substring) -> (Character, Character)? {
        let characters = Array(field)
        guard characters.count == 2 else { return nil }
        return (characters[0], characters[1])
    }

    /// `<sub> <mH> <mI> <mW> <hH> <hI>` of a changed entry: "S<c><m><u>" marks a submodule.
    private static func submoduleStatus(_ parts: [Substring]) -> SubmoduleStatus? {
        let sub = Array(parts[2])
        guard sub.count == 4, sub[0] == "S" else { return nil }
        func commit(mode: Substring, object: Substring) -> String? {
            mode == "160000" && object.contains(where: { $0 != "0" }) ? String(object) : nil
        }
        return SubmoduleStatus(
            headCommit: commit(mode: parts[3], object: parts[6]),
            indexCommit: commit(mode: parts[4], object: parts[7]),
            commitChanged: sub[1] == "C",
            hasModifiedContent: sub[2] == "M",
            hasUntrackedContent: sub[3] == "U"
        )
    }

    private static func parseHeader(_ record: String, into status: inout WorkingTreeStatus) {
        let body = record.dropFirst(2)
        func value(after key: String) -> String? {
            body.hasPrefix(key) ? String(body.dropFirst(key.count)) : nil
        }
        if let oid = value(after: "branch.oid ") {
            status.headID = oid == "(initial)" ? nil : oid
        } else if let head = value(after: "branch.head ") {
            status.branch = head == "(detached)" ? nil : head
        } else if let upstream = value(after: "branch.upstream ") {
            status.upstream = upstream
        } else if let counts = value(after: "branch.ab ") {
            for token in counts.split(separator: " ") {
                if token.hasPrefix("+") {
                    status.ahead = Int(token.dropFirst()) ?? 0
                } else if token.hasPrefix("-") {
                    status.behind = Int(token.dropFirst()) ?? 0
                }
            }
        } else if let count = value(after: "stash ") {
            status.stashCount = Int(count) ?? 0
        }
    }
}
