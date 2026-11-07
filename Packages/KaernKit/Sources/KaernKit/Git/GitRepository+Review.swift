import Foundation

// MARK: - Whole diffs (Review, the Focus drawer)

extension GitRepository {
    /// Every file's diff between two commits in one git call (`base` `nil`: everything in
    /// `target`, as for a root commit). `ignoringWhitespace` is `git diff -w`; `contextLines`
    /// is how many unchanged lines surround each change (`-U`, git's default 3).
    public func diffs(from base: String?, to target: String, ignoringWhitespace: Bool = false, contextLines: Int = 3) async throws -> [FileDiff] {
        let whitespace = (ignoringWhitespace ? ["-w"] : []) + Self.contextArguments(contextLines)
        let arguments: [String]
        if let base {
            arguments = ["diff", "--no-ext-diff", "-M"] + whitespace + [base, target, "--"]
        } else {
            arguments = ["diff-tree", "-p", "-r", "-M", "--root", "--no-commit-id"] + whitespace + [target, "--"]
        }
        let output = try await git(arguments)
        return DiffParser.parse(output.stdout).map { diff in
            var diff = diff
            diff.ignoresWhitespace = ignoringWhitespace
            return diff
        }
    }

    /// Every file's diff of `commit` against its first parent.
    public func diffs(of commit: Commit, ignoringWhitespace: Bool = false, contextLines: Int = 3) async throws -> [FileDiff] {
        try await diffs(from: commit.parents.first, to: commit.id, ignoringWhitespace: ignoringWhitespace, contextLines: contextLines)
    }

    /// `-U<n>` when `lines` isn't git's default.
    static func contextArguments(_ lines: Int) -> [String] {
        lines == 3 || lines < 0 ? [] : ["-U\(lines)"]
    }

    /// Staged (`git diff --cached`: HEAD → index) or unstaged (`git diff`: index → work tree)
    /// changes of every tracked file, in one git call. Untracked files aren't in it; see
    /// ``untrackedFileDiff(path:limit:)``.
    public func workingDiffs(staged: Bool, ignoringWhitespace: Bool = false, contextLines: Int = 3) async throws -> [FileDiff] {
        var arguments = ["diff", "--no-ext-diff", "-M"]
        if staged { arguments.append("--cached") }
        if ignoringWhitespace { arguments.append("-w") }
        arguments += Self.contextArguments(contextLines)
        arguments.append("--")
        let output = try await git(arguments)
        return DiffParser.parse(output.stdout).map { diff in
            var diff = diff
            diff.ignoresWhitespace = ignoringWhitespace
            return diff
        }
    }

    /// An untracked file as an added file, read from disk without running git. A binary file
    /// (a NUL byte in its first 8,000 bytes), a file larger than `limit` bytes or one that can't
    /// be read comes back without hunks.
    public func untrackedFileDiff(path: String, limit: Int = 2_000_000) -> FileDiff {
        let url = root.appending(path: path)
        var diff = FileDiff(
            path: path,
            header: ["diff --git a/\(path) b/\(path)", "new file mode 100644", "--- /dev/null", "+++ b/\(path)"],
            isNewFile: true
        )
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let size = attributes[.size] as? Int, size <= limit,
              let data = try? Data(contentsOf: url) else {
            diff.isBinary = true
            return diff
        }
        if data.prefix(8000).contains(0) {
            diff.isBinary = true
            return diff
        }
        diff.isLossy = String(data: data, encoding: .utf8) == nil
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { return diff }
        var fileLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let endsWithNewline = fileLines.last == ""
        if endsWithNewline { fileLines.removeLast() }
        var lines = fileLines.enumerated().map { index, line in
            DiffLine(id: index, kind: .addition, text: line, oldNumber: nil, newNumber: index + 1)
        }
        if !endsWithNewline {
            lines.append(DiffLine(id: lines.count, kind: .noNewline, text: " No newline at end of file", oldNumber: nil, newNumber: nil))
        }
        diff.hunks = [DiffHunk(id: 0, oldStart: 0, oldCount: 0, newStart: 1, newCount: fileLines.count, section: "", lines: lines)]
        return diff
    }
}

// MARK: - Staging one hunk

extension FileDiff {
    /// A change that can only be staged or unstaged as a whole: a new, deleted, renamed or binary
    /// file, or a diff whose hunks can't be turned back into patches.
    public var stagesWholeFile: Bool {
        isNewFile || isDeletedFile || oldPath != nil || !supportsPartialPatches
    }
}

extension GitRepository {
    /// Stages one hunk of `diff`, a file's unstaged changes (index → work tree). A change that
    /// ``FileDiff/stagesWholeFile`` is staged whole.
    public func stage(hunk: Int, of diff: FileDiff) async throws {
        guard !diff.stagesWholeFile, let patch = diff.patch(hunk: hunk) else {
            try await stage([diff.oldPath, diff.path].compactMap { $0 })
            return
        }
        try await apply(patch: patch, cached: true, reverse: false)
    }

    /// Unstages one hunk of `diff`, a file's staged changes (HEAD → index). A change that
    /// ``FileDiff/stagesWholeFile`` is unstaged whole.
    public func unstage(hunk: Int, of diff: FileDiff, hasHead: Bool) async throws {
        guard !diff.stagesWholeFile, let patch = diff.patch(hunk: hunk, reverse: true) else {
            try await unstage([diff.oldPath, diff.path].compactMap { $0 }, hasHead: hasHead)
            return
        }
        try await apply(patch: patch, cached: true, reverse: true)
    }
}
