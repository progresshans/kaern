import Foundation

/// Parses `--numstat -z` and `--name-status -z` output.
public enum ChangeListParser {
    /// `git diff --numstat -z`: "<added>\t<deleted>\t<path>" NUL, or for renames
    /// "<added>\t<deleted>\t" NUL "<old>" NUL "<new>" NUL. Binary files report "-".
    /// Returns stats keyed by the (new) path.
    public static func parseNumstat(_ data: Data) -> [String: LineStat] {
        let records = Records.splitNUL(data)
        var result: [String: LineStat] = [:]
        var index = 0
        while index < records.count {
            let record = records[index].drop(while: { $0 == "\n" })
            index += 1
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let stat = LineStat(additions: Int(parts[0]), deletions: Int(parts[1]))
            var path = String(parts[2])
            if path.isEmpty {
                // Rename: old and new path follow as separate records.
                guard index + 1 < records.count else { break }
                path = records[index + 1]
                index += 2
            }
            result[path] = (result[path].map { $0 + stat }) ?? stat
        }
        return result
    }

    /// `git diff --raw -z --no-abbrev`: ":<old mode> <new mode> <old object> <new object> <status>"
    /// NUL "<path>" NUL, with "<old>" NUL "<new>" NUL for renames and copies. Like
    /// ``parseNameStatus(_:)``, plus the commits of submodules (mode 160000).
    public static func parseRaw(_ data: Data) -> [FileChange] {
        let records = Records.splitNUL(data)
        var result: [FileChange] = []
        var index = 0
        while index < records.count {
            let header = records[index].trimmingCharacters(in: .whitespacesAndNewlines)
            index += 1
            let fields = header.split(separator: " ")
            guard header.hasPrefix(":"), fields.count == 5, let letter = fields[4].first, index < records.count else { continue }
            let kind = ChangeKind(statusLetter: letter) ?? .modified
            var change: FileChange
            if kind == .renamed || kind == .copied {
                guard index + 1 < records.count else { break }
                change = FileChange(path: records[index + 1], oldPath: records[index], kind: kind)
                index += 2
            } else {
                change = FileChange(path: records[index], kind: kind)
                index += 1
            }
            let oldMode = fields[0].dropFirst(), newMode = fields[1]
            if oldMode == "160000" || newMode == "160000" {
                func commit(_ mode: Substring, _ object: Substring) -> String? {
                    mode == "160000" && object.contains(where: { $0 != "0" }) ? String(object) : nil
                }
                change.submodule = SubmoduleMove(old: commit(oldMode, fields[2]), new: commit(newMode, fields[3]))
            }
            result.append(change)
        }
        return result
    }

    /// `git diff --name-status -z`: "M" NUL "<path>" NUL, "R100" NUL "<old>" NUL "<new>" NUL.
    public static func parseNameStatus(_ data: Data) -> [FileChange] {
        let records = Records.splitNUL(data)
        var result: [FileChange] = []
        var index = 0
        while index < records.count {
            let code = records[index].trimmingCharacters(in: .whitespacesAndNewlines)
            index += 1
            guard let letter = code.first, index < records.count else { continue }
            let kind = ChangeKind(statusLetter: letter) ?? .modified
            if kind == .renamed || kind == .copied {
                guard index + 1 < records.count else { break }
                result.append(FileChange(path: records[index + 1], oldPath: records[index], kind: kind))
                index += 2
            } else {
                result.append(FileChange(path: records[index], kind: kind))
                index += 1
            }
        }
        return result
    }
}
