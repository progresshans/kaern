import Foundation

// MARK: - File history and blame

extension GitRepository {
    /// Commits that changed `path`, newest first, following renames (`git log --follow`), from
    /// `revision` back.
    public func fileHistory(_ path: String, from revision: String = "HEAD", limit: Int = 1000) async throws -> [FileHistoryEntry] {
        let output = try await git([
            "log", "--follow", "-M", "--format=\(FileHistoryParser.format)", "--numstat", "-z",
            "--max-count=\(limit)", revision, "--", path,
        ])
        return FileHistoryParser.parse(output.stdout, path: path)
    }

    /// Who last changed each line of `path`: in the working copy when `revision` is `nil`
    /// (uncommitted lines included), otherwise as of that commit.
    public func blame(_ path: String, at revision: String?, ignoreWhitespace: Bool, detectMoves: Bool) async throws -> Blame {
        var arguments = ["blame", "--porcelain"]
        if ignoreWhitespace { arguments.append("-w") }
        // Lines moved within the file (-M) or from other files changed in the same commit (-C).
        if detectMoves { arguments += ["-M", "-C"] }
        if let revision { arguments.append(revision) }
        arguments += ["--", path]
        let output = try await git(arguments)
        return BlameParser.parse(output.stdout)
    }

    /// One commit by its object name (for commits outside the loaded history).
    public func commit(_ id: String) async throws -> Commit {
        let output = try await git(["log", "-1", "-z", "--format=\(LogParser.format)", id, "--"])
        guard let commit = LogParser.parse(output.stdout).first else {
            throw GitError(arguments: ["log", id], status: 0, message: "Couldn't read commit \(id.prefix(7)).")
        }
        return commit
    }

    /// The commit object as git stores it (`git cat-file commit`): headers, signature, message.
    public func commitObject(_ id: String) async throws -> Data {
        try await git(["cat-file", "commit", id]).stdout
    }

    /// The full message of a commit.
    public func message(of id: String) async throws -> String {
        try await git(["log", "-1", "--format=%B", id, "--"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
