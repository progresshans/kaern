import Foundation

// MARK: - Picked lines

extension FileDiff {
    /// One patch for `git apply` with the picked lines of several hunks (hunk id → line ids),
    /// in file order. Hunks with nothing picked are left out.
    ///
    /// - Parameter reverse: `true` when the patch is applied with `--reverse` (unstaging from
    ///   the index, discarding from the working tree); see ``patch(hunk:selectedLines:reverse:)``.
    /// - Returns: `nil` when no picked line is a change.
    public func patch(picking selection: [Int: Set<Int>], reverse: Bool = false) -> String? {
        var body: [String] = []
        // The side git matches the patch against keeps the diff's numbers; the other side moves
        // by what the hunks before it add or remove.
        var shift = 0
        for hunk in hunks where selection[hunk.id]?.isEmpty == false {
            guard let built = Self.build(hunk, picked: selection[hunk.id], reverse: reverse) else { continue }
            var oldStart: Int
            var newStart: Int
            if reverse {
                newStart = hunk.newStart
                oldStart = hunk.newStart - shift
            } else {
                oldStart = hunk.oldStart
                newStart = hunk.oldStart + shift
            }
            if built.oldCount == 0 { oldStart = max(oldStart - 1, 0) }
            if built.newCount == 0 { newStart = max(newStart - 1, 0) }
            // An empty side is numbered one line up (`@@ -0,0 +1,3 @@`), so it doesn't shift the rest.
            shift += built.newCount - built.oldCount
            body.append("@@ -\(oldStart),\(built.oldCount) +\(newStart),\(built.newCount) @@")
            body += built.lines
        }
        guard !body.isEmpty else { return nil }
        return (header + body).joined(separator: "\n") + "\n"
    }

    /// The body of one hunk keeping only the picked changes (see `patch(hunk:selectedLines:reverse:)`).
    ///
    /// A block of deletions followed by additions is built row by row, pairing the n-th deleted
    /// line with the n-th added one as Split shows them. Picking the first pair of a two-line
    /// edit then gives "new 1, old 2", not "old 2, new 1" as keeping lines in place would.
    private static func build(_ hunk: DiffHunk, picked: Set<Int>?, reverse: Bool) -> (lines: [String], oldCount: Int, newCount: Int)? {
        var lines: [String] = []
        var oldCount = 0
        var newCount = 0
        var changes = 0
        var lastLineKept = false

        func emit(_ line: DiffLine) {
            let selected = picked?.contains(line.id) ?? true
            switch line.kind {
            case .context:
                lines.append(" " + line.text)
                oldCount += 1
                newCount += 1
                lastLineKept = true
            case .addition:
                if selected {
                    lines.append("+" + line.text)
                    newCount += 1
                    changes += 1
                    lastLineKept = true
                } else if reverse {
                    // Stays in the target, so it becomes context for the reverse application.
                    lines.append(" " + line.text)
                    oldCount += 1
                    newCount += 1
                    lastLineKept = true
                } else {
                    lastLineKept = false
                }
            case .deletion:
                if selected {
                    lines.append("-" + line.text)
                    oldCount += 1
                    changes += 1
                    lastLineKept = true
                } else if reverse {
                    lastLineKept = false
                } else {
                    // The line is still there after applying, so it becomes context.
                    lines.append(" " + line.text)
                    oldCount += 1
                    newCount += 1
                    lastLineKept = true
                }
            case .noNewline:
                if lastLineKept { lines.append("\\" + line.text) }
            }
        }

        let all = hunk.lines
        var index = 0
        while index < all.count {
            guard all[index].isChange else {
                emit(all[index])
                index += 1
                continue
            }
            var end = index
            while end < all.count, all[end].isChange || all[end].kind == .noNewline { end += 1 }
            let block = all[index..<end]
            let deletions = block.filter { $0.kind == .deletion }
            let additions = block.filter { $0.kind == .addition }
            let ordered = block.allSatisfy { $0.kind != .noNewline }
                && Array(block) == deletions + additions
            if ordered, !deletions.isEmpty, !additions.isEmpty {
                for row in 0..<max(deletions.count, additions.count) {
                    if row < deletions.count { emit(deletions[row]) }
                    if row < additions.count { emit(additions[row]) }
                }
            } else {
                // End-of-file markers belong right after their line: keep the order git gave.
                block.forEach(emit)
            }
            index = end
        }
        return changes > 0 ? (lines, oldCount, newCount) : nil
    }

    /// The changed lines of `selection` that exist in this diff (ids of additions and deletions).
    public func changedLines(in selection: [Int: Set<Int>]) -> Int {
        hunks.reduce(0) { total, hunk in
            guard let picked = selection[hunk.id] else { return total }
            return total + hunk.lines.count { $0.isChange && picked.contains($0.id) }
        }
    }
}

extension GitRepository {
    /// Stages the picked lines of `diff`, a file's unstaged changes (index → working tree).
    public func stage(lines selection: [Int: Set<Int>], of diff: FileDiff) async throws {
        guard diff.supportsPartialPatches, !diff.stagesWholeFile else {
            throw GitError(arguments: ["apply"], status: -1, message: "\(diff.path) can only be staged as a whole file.")
        }
        guard let patch = diff.patch(picking: selection) else { return }
        try await apply(patch: patch, cached: true, reverse: false)
    }

    /// Unstages the picked lines of `diff`, a file's staged changes (HEAD → index).
    public func unstage(lines selection: [Int: Set<Int>], of diff: FileDiff) async throws {
        guard diff.supportsPartialPatches, !diff.stagesWholeFile else {
            throw GitError(arguments: ["apply"], status: -1, message: "\(diff.path) can only be unstaged as a whole file.")
        }
        guard let patch = diff.patch(picking: selection, reverse: true) else { return }
        try await apply(patch: patch, cached: true, reverse: true)
    }

    /// Throws away the picked lines of `diff`, a file's unstaged changes, from the working tree.
    /// Returns the patch that puts them back (`applyToWorkingTree(_:)`), `nil` when nothing changed.
    @discardableResult
    public func discard(lines selection: [Int: Set<Int>], of diff: FileDiff) async throws -> String? {
        guard diff.supportsPartialPatches, !diff.stagesWholeFile else {
            throw GitError(arguments: ["apply"], status: -1, message: "Lines of \(diff.path) can't be discarded one at a time.")
        }
        guard let patch = diff.patch(picking: selection, reverse: true) else { return nil }
        try await apply(patch: patch, cached: false, reverse: true)
        return patch
    }

    /// Applies a patch from ``discard(lines:of:)`` forward, putting the lines back.
    public func restoreDiscardedLines(_ patch: String) async throws {
        try await apply(patch: patch, cached: false, reverse: false)
    }
}
