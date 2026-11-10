import Foundation

/// Everything the stash view shows about one stash entry.
public struct StashDetails: Sendable, Hashable {
    public var stash: Stash
    public var author: Signature
    /// The commit the changes were made on top of (the stash's first parent).
    public var baseID: String
    /// The branch it was stashed from, when the message says ("On develop: …").
    public var branch: String?
    public var includesUntracked: Bool
    /// Tracked changes first, then the untracked files it holds (as new files).
    public var files: [FileDiff]
    public var untrackedPaths: Set<String>

    public init(stash: Stash, author: Signature, baseID: String, branch: String?, includesUntracked: Bool,
                files: [FileDiff], untrackedPaths: Set<String>) {
        self.stash = stash
        self.author = author
        self.baseID = baseID
        self.branch = branch
        self.includesUntracked = includesUntracked
        self.files = files
        self.untrackedPaths = untrackedPaths
    }

    /// "On develop: release notes" or "WIP on develop: 1d77f5b chore: …" → "develop".
    public static func branch(fromMessage message: String) -> String? {
        for prefix in ["WIP on ", "On "] where message.hasPrefix(prefix) {
            let rest = message.dropFirst(prefix.count)
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            let name = rest[..<colon]
            return name.isEmpty || name == "(no branch)" ? nil : String(name)
        }
        return nil
    }
}

extension FileDiff {
    /// Added and removed lines counted from the hunks (`nil` counts for binary files).
    public var lineStat: LineStat {
        if isBinary { return LineStat(additions: nil, deletions: nil) }
        var additions = 0, deletions = 0
        for hunk in hunks {
            for line in hunk.lines {
                switch line.kind {
                case .addition: additions += 1
                case .deletion: deletions += 1
                default: break
                }
            }
        }
        return LineStat(additions: additions, deletions: deletions)
    }
}

// MARK: - Stashes

extension GitRepository {
    /// The stash's changes compared with the commit it was made on, and the untracked files it
    /// keeps (a stash made with `--include-untracked` has them in a third parent).
    public func stashDetails(_ stash: Stash) async throws -> StashDetails {
        let parents = try await git(["rev-list", "--parents", "-n", "1", stash.id]).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").map(String.init)
        guard parents.count >= 2 else {
            throw GitError(arguments: ["rev-list", stash.id], status: 0, message: "\(stash.reference) isn't a stash.")
        }
        let base = parents[1]
        let untrackedCommit = parents.count > 3 ? parents[3] : nil

        async let header = git(["log", "-1", "--format=%an%x1f%ae%x1f%at", stash.id, "--"])
        async let tracked = git(["diff", "--no-ext-diff", "-M", base, stash.id, "--"])
        var files = DiffParser.parse(try await tracked.stdout)
        var untrackedPaths = Set<String>()
        if let untrackedCommit {
            let output = try await git(["diff-tree", "-p", "-r", "--root", "--no-commit-id", "--no-ext-diff", untrackedCommit])
            for var diff in DiffParser.parse(output.stdout) {
                diff.isNewFile = true
                diff.oldPath = nil
                untrackedPaths.insert(diff.path)
                files.append(diff)
            }
        }
        let fields = Records.fields(try await header.text.trimmingCharacters(in: .whitespacesAndNewlines), maxSplits: 2)
        let author = Signature(
            name: fields.first ?? "",
            email: fields.count > 1 ? fields[1] : "",
            date: fields.count > 2 ? Records.date(fromUnix: fields[2]) : stash.date
        )
        return StashDetails(
            stash: stash, author: author, baseID: base, branch: StashDetails.branch(fromMessage: stash.message),
            includesUntracked: untrackedCommit != nil, files: files, untrackedPaths: untrackedPaths
        )
    }

    /// `git stash create`: the working tree's tracked changes (and the index) as a stash commit,
    /// without touching the stash list or the files. `nil` when there's nothing to keep.
    public func stashCreate() async -> String? {
        guard let output = try? await git(["stash", "create"]) else { return nil }
        let id = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// The tree object of a commit.
    public func treeID(of commit: String) async -> String? {
        await resolve("\(commit)^{tree}")
    }

    /// Untracked files that aren't ignored.
    public func untrackedFiles() async -> [String] {
        guard let output = try? await git(["ls-files", "--others", "--exclude-standard", "-z"]) else { return [] }
        return Records.splitNUL(output.stdout)
    }

    /// Applies a stash-like commit (from `git stash create`), restoring what was staged too.
    public func applyStash(object: String) async throws {
        try await git(["stash", "apply", "--index", object])
    }

    /// Create Branch from Stash: a new branch at the commit the stash was made on, checked out,
    /// with the stash applied and dropped (`git stash branch`).
    public func createBranch(_ name: String, from stash: Stash) async throws {
        let entry = try await entryNow(stash)
        try await git(["stash", "branch", name, entry.reference])
    }
}
