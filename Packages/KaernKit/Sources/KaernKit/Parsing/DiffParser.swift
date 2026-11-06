import Foundation

/// Parses unified diffs produced by `git diff` / `git show` (not combined `--cc` diffs).
public enum DiffParser {
    public static func parse(_ data: Data) -> [FileDiff] {
        var builder = Builder(isLossy: false)
        // Each file is checked for UTF-8 on its own, so one file in another encoding doesn't stop
        // partial staging in the others.
        for segment in fileSegments(data) {
            builder.isLossy = String(data: segment, encoding: .utf8) == nil
            let text = String(decoding: segment, as: UTF8.self)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                builder.consume(String(line))
            }
        }
        return builder.finish()
    }

    /// Splits multi-file output in front of each `diff --git ` line.
    static func fileSegments(_ data: Data) -> [Data] {
        let marker = Array("diff --git ".utf8)
        let bytes = [UInt8](data)
        var starts: [Int] = []
        var index = 0
        // Line by line: only a line that starts with the marker begins a file (hunk lines start
        // with a space, `+`, `-` or `\`).
        while index < bytes.count {
            if bytes.count - index >= marker.count, bytes[index ..< index + marker.count].elementsEqual(marker) {
                starts.append(index)
            }
            guard let newline = bytes[index...].firstIndex(of: 0x0A) else { break }
            index = newline + 1
        }
        guard !starts.isEmpty else { return [data] }
        var segments: [Data] = []
        if starts[0] > 0 { segments.append(Data(bytes[0 ..< starts[0]])) }
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1] : bytes.count
            // Drop the newline that ends the segment: the next one starts on its own line.
            let trimmedEnd = end > start && end < bytes.count && bytes[end - 1] == 0x0A ? end - 1 : end
            segments.append(Data(bytes[start ..< trimmedEnd]))
        }
        return segments
    }

    private struct Builder {
        var isLossy: Bool
        var files: [FileDiff] = []
        var file: FileDiff?
        var hunk: DiffHunk?
        var oldLine = 0
        var newLine = 0

        init(isLossy: Bool) {
            self.isLossy = isLossy
        }

        mutating func consume(_ line: String) {
            if line.hasPrefix("diff --git ") {
                finishFile()
                var diff = FileDiff(path: "", header: [line], isLossy: isLossy)
                if let paths = DiffParser.pathsFromGitHeader(line) {
                    diff.oldPath = paths.old
                    diff.path = paths.new
                }
                file = diff
                return
            }
            guard file != nil else { return }

            if line.hasPrefix("@@") {
                finishHunk()
                startHunk(line)
                return
            }

            if hunk != nil {
                guard let marker = line.first else { return }
                let text = String(line.dropFirst())
                switch marker {
                case " ":
                    appendLine(.context, text, old: oldLine, new: newLine)
                    oldLine += 1
                    newLine += 1
                case "+":
                    appendLine(.addition, text, old: nil, new: newLine)
                    newLine += 1
                case "-":
                    appendLine(.deletion, text, old: oldLine, new: nil)
                    oldLine += 1
                case "\\":
                    appendLine(.noNewline, text, old: nil, new: nil)
                default:
                    // Not part of a hunk any more (shouldn't happen for single-file output).
                    finishHunk()
                }
                return
            }

            // Extended header lines.
            file?.header.append(line)
            if line.hasPrefix("new file mode") {
                file?.isNewFile = true
            } else if line.hasPrefix("deleted file mode") {
                file?.isDeletedFile = true
            } else if line.hasPrefix("rename from ") {
                file?.oldPath = DiffParser.unquote(String(line.dropFirst("rename from ".count)))
            } else if line.hasPrefix("rename to ") {
                file?.path = DiffParser.unquote(String(line.dropFirst("rename to ".count)))
            } else if line.hasPrefix("--- ") {
                let path = String(line.dropFirst(4))
                if path == "/dev/null" {
                    file?.isNewFile = true
                } else {
                    file?.oldPath = DiffParser.stripPrefix(DiffParser.unquote(path))
                }
            } else if line.hasPrefix("+++ ") {
                let path = String(line.dropFirst(4))
                if path == "/dev/null" {
                    file?.isDeletedFile = true
                } else {
                    file?.path = DiffParser.stripPrefix(DiffParser.unquote(path))
                }
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                file?.isBinary = true
            }
        }

        mutating func startHunk(_ line: String) {
            guard let range = DiffParser.parseHunkHeader(line) else { return }
            hunk = DiffHunk(
                id: file?.hunks.count ?? 0,
                oldStart: range.oldStart,
                oldCount: range.oldCount,
                newStart: range.newStart,
                newCount: range.newCount,
                section: range.section,
                lines: []
            )
            oldLine = range.oldStart
            newLine = range.newStart
        }

        mutating func appendLine(_ kind: DiffLine.Kind, _ text: String, old: Int?, new: Int?) {
            guard hunk != nil else { return }
            // Mutate in place; copying the hunk per line would be quadratic for large diffs.
            let id = hunk!.lines.count
            hunk!.lines.append(DiffLine(id: id, kind: kind, text: text, oldNumber: old, newNumber: new))
        }

        mutating func finishHunk() {
            if let hunk {
                file?.hunks.append(hunk)
            }
            hunk = nil
        }

        mutating func finishFile() {
            finishHunk()
            if var file {
                if file.path.isEmpty, let old = file.oldPath { file.path = old }
                if file.oldPath == file.path { file.oldPath = nil }
                files.append(file)
            }
            file = nil
        }

        mutating func finish() -> [FileDiff] {
            finishFile()
            return files
        }
    }

    struct HunkRange {
        var oldStart: Int
        var oldCount: Int
        var newStart: Int
        var newCount: Int
        var section: String
    }

    /// `@@ -12,7 +12,9 @@ on:`
    static func parseHunkHeader(_ line: String) -> HunkRange? {
        let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0] == "@@", parts[3] == "@@" else { return nil }
        func range(_ token: Substring) -> (Int, Int)? {
            let numbers = token.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = Int(numbers[0]) else { return nil }
            let count = numbers.count > 1 ? Int(numbers[1]) ?? 1 : 1
            return (start, count)
        }
        guard let old = range(parts[1]), let new = range(parts[2]) else { return nil }
        let section = parts.count == 5 ? String(parts[4]) : ""
        return HunkRange(oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1, section: section)
    }

    /// Splits `diff --git a/<path> b/<path>` when both sides are the same path (binary and mode-only
    /// changes have no `---`/`+++` lines to read the path from).
    static func pathsFromGitHeader(_ line: String) -> (old: String, new: String)? {
        let rest = String(line.dropFirst("diff --git ".count))
        if rest.hasPrefix("\"") {
            // Quoted paths: fall back to splitting on the `" "` between them.
            let pieces = rest.components(separatedBy: "\" \"")
            guard pieces.count == 2 else { return nil }
            return (stripPrefix(unquote(pieces[0] + "\"")), stripPrefix(unquote("\"" + pieces[1])))
        }
        guard rest.hasPrefix("a/") else { return nil }
        var searchStart = rest.startIndex
        while let separator = rest.range(of: " b/", range: searchStart..<rest.endIndex) {
            let old = rest[rest.index(rest.startIndex, offsetBy: 2)..<separator.lowerBound]
            let new = rest[separator.upperBound...]
            if old == new {
                return (String(old), String(new))
            }
            searchStart = separator.upperBound
        }
        return nil
    }

    static func stripPrefix(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            return String(path.dropFirst(2))
        }
        return path
    }

    /// Undoes git's C-style quoting of unusual paths (`"tab\there"`).
    static func unquote(_ path: String) -> String {
        guard path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") else { return path }
        var bytes: [UInt8] = []
        var iterator = Array(path.dropFirst().dropLast().utf8).makeIterator()
        while let byte = iterator.next() {
            guard byte == UInt8(ascii: "\\"), let escaped = iterator.next() else {
                bytes.append(byte)
                continue
            }
            switch escaped {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "\""): bytes.append(0x22)
            case UInt8(ascii: "\\"): bytes.append(0x5C)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                // Three-digit octal escape.
                var value = Int(escaped - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let digit = iterator.next() else { break }
                    value = value * 8 + Int(digit - UInt8(ascii: "0"))
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default:
                bytes.append(escaped)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
