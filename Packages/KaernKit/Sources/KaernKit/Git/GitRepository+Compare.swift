import Foundation

// MARK: - Comparing commits and branches

/// Two branches side by side (`git rev-list --left-right ours...theirs`).
public struct BranchComparison: Sendable, Hashable {
    /// Commits only on the first branch, newest first.
    public var ours: [String]
    /// Commits only on the second branch, newest first.
    public var theirs: [String]
    /// Where the two histories meet (`git merge-base`), `nil` when they don't.
    public var base: String?
}

/// A commit's id and subject, for lists in sheets and panels.
public struct CommitSummary: Sendable, Hashable, Identifiable {
    public var id: String
    public var subject: String
    public var shortID: String { String(id.prefix(7)) }

    public init(id: String, subject: String) {
        self.id = id
        self.subject = subject
    }
}

extension GitRepository {
    /// `git merge-base a b`, `nil` when the histories don't meet.
    public func mergeBase(_ a: String, _ b: String) async -> String? {
        guard let output = try? await git(["merge-base", a, b], accepted: [0, 1]), output.status == 0 else { return nil }
        let id = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// The commits `git log base..target` lists (reachable from `target`, not from `base`),
    /// newest first, at most `limit`.
    public func commitIDs(from base: String, to target: String, limit: Int = 500) async throws -> [String] {
        let output = try await git(["rev-list", "--max-count=\(limit)", "\(base)..\(target)", "--"])
        return output.text.split(separator: "\n").map(String.init)
    }

    /// Which commits each branch has that the other doesn't.
    public func compare(_ ours: String, with theirs: String, limit: Int = 500) async throws -> BranchComparison {
        let output = try await git(["rev-list", "--left-right", "--max-count=\(limit * 2)", "\(ours)...\(theirs)", "--"])
        var left: [String] = []
        var right: [String] = []
        for line in output.text.split(separator: "\n") {
            if line.hasPrefix("<") { left.append(String(line.dropFirst())) } else if line.hasPrefix(">") { right.append(String(line.dropFirst())) }
        }
        return BranchComparison(ours: Array(left.prefix(limit)), theirs: Array(right.prefix(limit)), base: await mergeBase(ours, theirs))
    }

    /// Ids and subjects of the commits in `revisions` (a range such as `HEAD..@{upstream}`).
    public func summaries(_ revisions: [String], limit: Int = 50) async throws -> [CommitSummary] {
        let output = try await git(["log", "-z", "--format=%H%x1f%s", "--max-count=\(limit)"] + revisions + ["--"])
        return Records.splitNUL(output.stdout).compactMap { record in
            let fields = Records.fields(record, maxSplits: 1)
            guard fields.count == 2 else { return nil }
            return CommitSummary(id: fields[0], subject: fields[1])
        }
    }

    /// Every file's diff between `commit` and the working tree (`git diff <commit>`). Untracked
    /// files aren't in it.
    public func diffsToWorkingTree(from commit: String, ignoringWhitespace: Bool = false, contextLines: Int = 3) async throws -> [FileDiff] {
        var arguments = ["diff", "--no-ext-diff", "-M"]
        if ignoringWhitespace { arguments.append("-w") }
        arguments += Self.contextArguments(contextLines)
        arguments += [commit, "--"]
        let output = try await git(arguments)
        return DiffParser.parse(output.stdout).map { diff in
            var diff = diff
            diff.ignoresWhitespace = ignoringWhitespace
            return diff
        }
    }

    /// Files that differ between `commit` and the working tree, with line counts.
    public func changedFilesToWorkingTree(from commit: String) async throws -> [FileChange] {
        async let names = git(["diff", "--raw", "--no-abbrev", "-z", "-M", "--no-ext-diff", commit, "--"])
        async let stats = git(["diff", "--numstat", "-z", "-M", "--no-ext-diff", commit, "--"])
        let changes = ChangeListParser.parseRaw(try await names.stdout)
        let lineStats = ChangeListParser.parseNumstat(try await stats.stdout)
        return changes.map { change in
            var change = change
            change.stat = lineStats[change.path]
            return change
        }
    }
}

// MARK: - Picking, reverting and moving commits

extension GitRepository {
    /// `git cherry-pick <commits>` in the given order (pass them oldest first). A merge commit is
    /// picked against its first parent. Conflicts stop the pick instead of throwing.
    public func cherryPick(_ commits: [Commit]) async throws -> OperationOutcome {
        guard !commits.isEmpty else { return .finished }
        var arguments = ["cherry-pick"]
        if commits.count == 1, commits[0].isMerge { arguments += ["-m", "1"] }
        arguments += commits.map(\.id)
        return try await runStoppable(arguments)
    }

    /// `git revert --no-edit <commits>` in the given order (pass them newest first), one new commit
    /// each. A lone merge commit is reverted against its first parent.
    public func revert(_ commits: [Commit]) async throws -> OperationOutcome {
        guard !commits.isEmpty else { return .finished }
        var arguments = ["revert", "--no-edit"]
        if commits.count == 1, commits[0].isMerge { arguments += ["-m", "1"] }
        arguments += commits.map(\.id)
        return try await runStoppable(arguments)
    }

    /// Runs `work` (a cherry-pick, revert, merge or rebase; git refuses the first two with staged
    /// changes) with the uncommitted changes of tracked files put aside in the stash list
    /// (`message`), then puts them back, staged parts staged. They stay in the stash list, and
    /// `kept` is that entry's object, when `work` stopped on conflicts or when its result touches
    /// files the changes touch (putting them back would leave conflict markers). When `work`
    /// throws they're put back first.
    public func withChangesStashed(message: String, _ work: @Sendable () async throws -> OperationOutcome) async throws
        -> (outcome: OperationOutcome, kept: String?) {
        let before = await resolve("HEAD")
        let stash = try await stashAll(message: message, includeUntracked: false)
        let outcome: OperationOutcome
        do {
            outcome = try await work()
        } catch {
            if let stash { try? await popStash(object: stash) }
            throw error
        }
        guard let stash else { return (outcome, nil) }
        guard outcome == .finished else { return (outcome, stash) }
        if let before, let after = await resolve("HEAD"), before != after {
            let touched = Set(Records.splitNUL(try await git(["diff", "--name-only", "-z", "--no-renames", before, after, "--"]).stdout))
            let stashed = Set(Records.splitNUL(try await git(["stash", "show", "--name-only", "-z", stash]).stdout))
            if !touched.isDisjoint(with: stashed) { return (outcome, stash) }
        }
        do {
            try await popStash(object: stash)
        } catch {
            throw GitError(arguments: ["stash", "pop"], status: -1,
                           message: "It worked, but your uncommitted changes clash with it. They’re kept in the stash list as “\(message)”.")
        }
        return (outcome, nil)
    }

    /// The branch HEAD is on, or `nil` when it's detached (`git symbolic-ref`).
    public func currentBranchName() async -> String? {
        guard let output = try? await git(["symbolic-ref", "--quiet", "--short", "HEAD"], accepted: [0, 1]),
              output.status == 0 else { return nil }
        let name = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

// MARK: - Pushing

extension GitRepository {
    /// Pushes HEAD to `remote` as `name` (`git push [--set-upstream] <remote> HEAD:refs/heads/<name>`).
    /// `track`: Pull and Push use it from now on.
    public func publish(to remote: String, as name: String, track: Bool, onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        var arguments = ["push", "--progress"]
        if track { arguments.append("--set-upstream") }
        arguments += [remote, "HEAD:refs/heads/\(name)"]
        try await git(arguments, onProgress: onProgress)
    }

    /// Replaces `remoteBranch` on `remote` with HEAD, only if it's still at `expected` (what the
    /// last fetch saw): `git push --force-with-lease=<branch>:<expected> <remote> HEAD:<branch>`.
    public func forcePush(to remote: String, branch remoteBranch: String, expected: String,
                          onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        try await git([
            "push", "--progress", "--force-with-lease=refs/heads/\(remoteBranch):\(expected)",
            remote, "HEAD:refs/heads/\(remoteBranch)",
        ], onProgress: onProgress)
    }

    /// Pushes a branch that isn't checked out: `git push <remote> refs/heads/<name>:refs/heads/<remoteBranch>`.
    public func push(branch name: String, to remote: String, as remoteBranch: String,
                     onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        try await git(["push", "--progress", remote, "refs/heads/\(name):refs/heads/\(remoteBranch)"], onProgress: onProgress)
    }

    /// Brings a branch that isn't checked out up to its remote branch, fast-forward only
    /// (`git fetch <remote> <remoteBranch>:refs/heads/<name>`).
    public func fastForward(branch name: String, from remote: String, remoteBranch: String,
                            onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        try await git(["fetch", "--progress", remote, "refs/heads/\(remoteBranch):refs/heads/\(name)"], onProgress: onProgress)
    }

    /// `git push <remote> --delete <branch>` and `git branch -D <branch>`: Delete Here and on origin.
    public func deleteBranchEverywhere(_ name: String, remote: String, remoteBranch: String,
                                       onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        try await deleteRemoteBranch(remoteBranch, on: remote, onProgress: onProgress)
        try await deleteBranch(name, force: true)
    }

    /// Commits on HEAD that no remote branch has (`git rev-list --count HEAD --not --remotes`):
    /// what Publish would push for a branch without an upstream. `nil` without remote branches.
    public func unpublishedCount() async -> Int? {
        guard let remotes = try? await git(["for-each-ref", "--count=1", "--format=%(refname)", "refs/remotes"]),
              !remotes.text.isEmpty,
              let output = try? await git(["rev-list", "--count", "HEAD", "--not", "--remotes", "--"]) else { return nil }
        return Int(output.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether this branch once pointed at `commit` (its reflog has it): when the upstream is
    /// at such a commit, the local branch rewrote it (amend, rebase, reset), so pushing needs
    /// force. A commit only the remote has means someone else pushed.
    public func branchHadCommit(_ branch: String, commit: String) async -> Bool {
        guard let output = try? await git(["reflog", "show", "--format=%H", "refs/heads/\(branch)", "--"], accepted: [0, 128]),
              output.status == 0 else { return false }
        return output.text.split(separator: "\n").contains { $0 == commit }
    }
}

// MARK: - The index, for ⌘Z

extension GitRepository {
    /// The index as a tree object (`git write-tree`), `nil` while files are in conflict.
    public func writeIndexTree() async -> String? {
        guard let output = try? await git(["write-tree"]) else { return nil }
        let id = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// Moves the current branch (or a detached HEAD) to `target` like `git reset --keep`, which
    /// keeps uncommitted changes but resets index entries, then puts back what was staged: ⌘Z of a
    /// cherry-pick, revert or merge mustn't unstage the user's files. A staged file the move
    /// touches makes git refuse, as `--keep` does for local changes.
    public func resetKeepingStaged(to target: String) async throws {
        let staged = try await indexDifferences(from: "HEAD")
        let tree = staged.isEmpty ? nil : await writeIndexTree()
        try await reset(to: target, mode: .keep)
        if let tree {
            try await restoreIndex(paths: staged, from: tree)
        }
    }

    /// Paths whose index entries differ from `tree` (`git diff-index --cached --name-only`).
    public func indexDifferences(from tree: String) async throws -> [String] {
        let output = try await git(["diff-index", "--cached", "--name-only", "-z", "--no-renames", tree, "--"])
        return Records.splitNUL(output.stdout)
    }

    /// Whether the index entries of `paths` match `tree` (`git diff-index --cached --quiet`).
    public func indexMatches(_ tree: String, paths: [String]) async -> Bool {
        guard let output = try? await git(["diff-index", "--cached", "--quiet", tree, "--"] + paths.map { ":(literal)" + $0 },
                                          accepted: [0, 1]) else { return false }
        return output.status == 0
    }

    /// Sets the index entries of `paths` to what `tree` has (paths it doesn't have leave the
    /// index). The working tree isn't touched.
    public func restoreIndex(paths: [String], from tree: String) async throws {
        guard !paths.isEmpty else { return }
        let listing = try await git(["ls-tree", "-r", "-z", "--full-tree", tree, "--"] + paths.map { ":(literal)" + $0 })
        var entries: [String] = []
        var present = Set<String>()
        for record in Records.splitNUL(listing.stdout) {
            // <mode> SP <type> SP <object> TAB <path>
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let fields = record[..<tab].split(separator: " ")
            let path = String(record[record.index(after: tab)...])
            guard fields.count == 3 else { continue }
            present.insert(path)
            entries.append("\(fields[0]) \(fields[2])\t\(path)")
        }
        let zero = String(repeating: "0", count: 40)
        for path in paths where !present.contains(path) {
            entries.append("0 \(zero)\t\(path)")
        }
        let input = entries.joined(separator: "\0") + "\0"
        try await git(["update-index", "-z", "--index-info"], input: Data(input.utf8))
    }
}

// MARK: - Applying a stash, and taking it back

/// A stash that was applied or popped, with what ⌘Z needs to take it back out.
public struct AppliedStash: Sendable, Hashable {
    public var stash: Stash
    public var popped: Bool
    /// Tracked files the stash changed.
    public var tracked: [String]
    /// Files the stash brought back that git doesn't track.
    public var untracked: [String]
    /// `git diff --binary HEAD` of `tracked` right after, to tell whether they changed since.
    public var after: Data
    public var untrackedContents: [String: Data]
}

extension GitRepository {
    /// Applies (or pops) a stash. Returns what ⌘Z needs, or `nil` with the stash still applied
    /// when its files had changes before (taking it back out would lose them).
    public func applyStashUndoably(_ stash: Stash, pop: Bool) async throws -> AppliedStash? {
        let tracked = try await git(["stash", "show", "--name-only", "-z", stash.id]).stdout
        let untracked = (try? await git(["stash", "show", "--only-untracked", "--name-only", "-z", stash.id]).stdout) ?? Data()
        let trackedPaths = Records.splitNUL(tracked)
        let untrackedPaths = Records.splitNUL(untracked)
        let before = trackedPaths.isEmpty ? Data() : try await patch(against: "HEAD", paths: trackedPaths)
        let clean = before.isEmpty && untrackedPaths.allSatisfy {
            !FileManager.default.fileExists(atPath: root.appending(path: $0).path(percentEncoded: false))
        }
        try await applyStash(stash, pop: pop)
        guard clean else { return nil }
        let after = trackedPaths.isEmpty ? Data() : try await patch(against: "HEAD", paths: trackedPaths)
        var contents: [String: Data] = [:]
        for path in untrackedPaths {
            contents[path] = FileManager.default.contents(atPath: root.appending(path: path).path(percentEncoded: false))
        }
        return AppliedStash(stash: stash, popped: pop, tracked: trackedPaths, untracked: untrackedPaths, after: after,
                            untrackedContents: contents)
    }

    /// Takes an applied stash back out of the working tree, and puts a popped one back in the list.
    public func unapply(_ applied: AppliedStash) async throws {
        let now = applied.tracked.isEmpty ? Data() : try await patch(against: "HEAD", paths: applied.tracked)
        var unchanged = now == applied.after
        for (path, data) in applied.untrackedContents where unchanged {
            unchanged = FileManager.default.contents(atPath: root.appending(path: path).path(percentEncoded: false)) == data
        }
        guard unchanged else {
            throw GitError(arguments: ["stash"], status: -1,
                           message: "The files from \(applied.stash.reference) changed since, so Kaern can't take them back out.")
        }
        if applied.popped {
            try await storeStash(applied.stash.id, message: applied.stash.message)
        }
        if !applied.tracked.isEmpty {
            try await git(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + applied.tracked.map { ":(literal)" + $0 })
        }
        for path in applied.untracked {
            try? FileManager.default.removeItem(at: root.appending(path: path))
        }
    }

    /// `git diff --binary <revision> -- <paths>`: index and working tree against a commit.
    func patch(against revision: String, paths: [String]) async throws -> Data {
        try await git(["diff", "--binary", "--no-ext-diff", "--no-color", revision, "--"] + paths.map { ":(literal)" + $0 }).stdout
    }
}

// MARK: - Web pages

extension RemoteURL {
    /// Where a pull request from `branch` starts (GitHub's compare page, GitLab's new merge request).
    public func pullRequestPage(branch: String) -> URL? {
        guard let webPage else { return nil }
        let encoded = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        switch host.lowercased() {
        case "gitlab.com":
            return URL(string: webPage.absoluteString + "/-/merge_requests/new?merge_request%5Bsource_branch%5D=" + encoded)
        case "bitbucket.org":
            return URL(string: webPage.absoluteString + "/pull-requests/new?source=" + encoded)
        default:
            return URL(string: webPage.absoluteString + "/compare/" + encoded + "?expand=1")
        }
    }

    /// A new release for `tag` (GitHub).
    public func newReleasePage(tag: String) -> URL? {
        guard let webPage else { return nil }
        let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tag
        return URL(string: webPage.absoluteString + "/releases/new?tag=" + encoded)
    }
}
