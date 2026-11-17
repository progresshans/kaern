import Foundation

public struct DiffLine: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case context
        case addition
        case deletion
        /// `\ No newline at end of file`
        case noNewline
    }

    /// Position inside the hunk; stable for selection.
    public var id: Int
    public var kind: Kind
    /// The line without its leading marker (may end with `\r` for CRLF files).
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?

    public init(id: Int, kind: Kind, text: String, oldNumber: Int?, newNumber: Int?) {
        self.id = id
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }

    public var isChange: Bool { kind == .addition || kind == .deletion }

    var marker: String {
        switch kind {
        case .context: " "
        case .addition: "+"
        case .deletion: "-"
        case .noNewline: "\\"
        }
    }
}

public struct DiffHunk: Sendable, Hashable, Identifiable {
    public var id: Int
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// Text after the second `@@` (usually the enclosing function or section).
    public var section: String
    public var lines: [DiffLine]

    public init(id: Int, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String, lines: [DiffLine]) {
        self.id = id
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
    }

    /// `@@ -12,7 +12,9 @@`
    public var rangeDescription: String {
        "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
    }

    public var additions: Int { lines.count { $0.kind == .addition } }
    public var deletions: Int { lines.count { $0.kind == .deletion } }
}

/// The diff of one file.
public struct FileDiff: Sendable, Hashable {
    public var path: String
    public var oldPath: String?
    /// `diff --git`, `index`, mode, `---` and `+++` lines, needed to rebuild partial patches.
    public var header: [String]
    public var hunks: [DiffHunk]
    public var isBinary: Bool
    public var isNewFile: Bool
    public var isDeletedFile: Bool
    /// The file isn't valid UTF-8, so partial patches can't be rebuilt byte-for-byte.
    public var isLossy: Bool
    /// Loaded with `git diff -w`: the hunks leave out white-space changes, so they don't match
    /// the file exactly and can't be applied one at a time.
    public var ignoresWhitespace = false

    public init(
        path: String,
        oldPath: String? = nil,
        header: [String] = [],
        hunks: [DiffHunk] = [],
        isBinary: Bool = false,
        isNewFile: Bool = false,
        isDeletedFile: Bool = false,
        isLossy: Bool = false
    ) {
        self.path = path
        self.oldPath = oldPath
        self.header = header
        self.hunks = hunks
        self.isBinary = isBinary
        self.isNewFile = isNewFile
        self.isDeletedFile = isDeletedFile
        self.isLossy = isLossy
    }

    public var additions: Int { hunks.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.deletions } }

    /// Whether hunks and lines of this diff can be staged, unstaged or discarded one at a time.
    public var supportsPartialPatches: Bool {
        !isBinary && !isLossy && !ignoresWhitespace && !hunks.isEmpty && !header.isEmpty
    }

    /// Builds a patch for `git apply` containing one hunk, optionally only some of its lines.
    ///
    /// - Parameters:
    ///   - selectedLines: IDs of the addition/deletion lines to keep. `nil` keeps the whole hunk.
    ///   - reverse: Pass `true` when the patch will be applied with `--reverse` (unstaging from
    ///     the index, or discarding from the work tree). Unselected lines are then treated so the
    ///     reverse application leaves them alone.
    /// - Returns: `nil` when the selection contains no change.
    public func patch(hunk hunkID: Int, selectedLines: Set<Int>? = nil, reverse: Bool = false) -> String? {
        guard let hunk = hunks.first(where: { $0.id == hunkID }) else { return nil }
        var body: [String] = []
        var oldCount = 0
        var newCount = 0
        var changes = 0
        var lastLineKept = false

        for line in hunk.lines {
            let selected = selectedLines?.contains(line.id) ?? true
            switch line.kind {
            case .context:
                body.append(" " + line.text)
                oldCount += 1
                newCount += 1
                lastLineKept = true
            case .addition:
                if selected {
                    body.append("+" + line.text)
                    newCount += 1
                    changes += 1
                    lastLineKept = true
                } else if reverse {
                    // Stays in the target, so it becomes context for the reverse application.
                    body.append(" " + line.text)
                    oldCount += 1
                    newCount += 1
                    lastLineKept = true
                } else {
                    lastLineKept = false
                }
            case .deletion:
                if selected {
                    body.append("-" + line.text)
                    oldCount += 1
                    changes += 1
                    lastLineKept = true
                } else if reverse {
                    lastLineKept = false
                } else {
                    // The line is still there after applying, so it becomes context.
                    body.append(" " + line.text)
                    oldCount += 1
                    newCount += 1
                    lastLineKept = true
                }
            case .noNewline:
                if lastLineKept {
                    body.append("\\" + line.text)
                }
            }
        }

        guard changes > 0 else { return nil }
        let oldStart = oldCount == 0 ? max(hunk.oldStart - 1, 0) : hunk.oldStart
        let newStart = newCount == 0 ? max(hunk.newStart - 1, 0) : hunk.newStart
        let headerLine = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        return (header + [headerLine] + body).joined(separator: "\n") + "\n"
    }
}
