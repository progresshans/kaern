import Foundation

/// What a batch of file-system events touched.
public struct ChangeScope: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Files in the working tree (needs `git status`).
    public static let workTree = ChangeScope(rawValue: 1 << 0)
    /// The index (needs `git status`).
    public static let index = ChangeScope(rawValue: 1 << 1)
    /// HEAD, branches, tags, remotes, stash or an operation in progress (needs refs + history).
    public static let refs = ChangeScope(rawValue: 1 << 2)
}

/// A local repository with a working tree, driven through the git CLI.
public struct GitRepository: Sendable, Hashable {
    /// Top level of the working tree (canonical path).
    public let root: URL
    /// Absolute path of the git directory (canonical path).
    public let gitDirectory: URL
    public let runner: GitRunner

    public init(root: URL, gitDirectory: URL, runner: GitRunner) {
        self.root = root
        self.gitDirectory = gitDirectory
        self.runner = runner
    }

    public static func == (lhs: GitRepository, rhs: GitRepository) -> Bool { lhs.root == rhs.root }
    public func hash(into hasher: inout Hasher) { hasher.combine(root) }

    public var name: String { root.lastPathComponent }

    // MARK: - Opening

    /// Opens the repository containing `url`.
    public static func open(_ url: URL, runner: GitRunner = GitRunner()) async throws -> GitRepository {
        let output: GitOutput
        do {
            output = try await runner.run(["rev-parse", "--show-toplevel", "--absolute-git-dir"], in: url)
        } catch let error as GitError {
            if error.message.contains("not a git repository") {
                throw NotARepositoryError(folder: url)
            }
            if error.message.contains("must be run in a work tree") {
                throw GitError(arguments: error.arguments, status: error.status,
                               message: "“\(url.lastPathComponent)” is a bare repository. Kaern needs a working tree.")
            }
            throw error
        }
        let lines = output.text.split(separator: "\n").map(String.init)
        guard lines.count >= 2 else {
            throw GitError(arguments: ["rev-parse"], status: 0, message: "Couldn't read the repository at \(url.path(percentEncoded: false)).")
        }
        return GitRepository(
            root: URL(filePath: canonicalPath(lines[0]), directoryHint: .isDirectory),
            gitDirectory: URL(filePath: canonicalPath(lines[1]), directoryHint: .isDirectory),
            runner: runner
        )
    }

    /// `git init -b <branch> <url>`
    public static func initialize(at url: URL, defaultBranch: String, runner: GitRunner = GitRunner()) async throws -> GitRepository {
        try await runner.run(["init", "-b", defaultBranch, url.path(percentEncoded: false)], in: nil)
        return try await open(url, runner: runner)
    }

    /// `git clone --progress <remote> <destination>`
    public static func clone(
        _ remote: String,
        to destination: URL,
        runner: GitRunner = GitRunner(),
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> GitRepository {
        try await runner.run(
            ["clone", "--progress", "--", remote, destination.path(percentEncoded: false)],
            in: destination.deletingLastPathComponent(),
            onProgress: onProgress
        )
        return try await open(destination, runner: runner)
    }

    @discardableResult
    func git(
        _ arguments: [String],
        input: Data? = nil,
        accepted: Set<Int32> = [0],
        environment: [String: String] = [:],
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> GitOutput {
        try await runner.run(arguments, in: root, input: input, acceptedStatus: accepted, environment: environment, onProgress: onProgress)
    }

    // MARK: - Reading

    /// Which untracked files `git status` lists.
    public enum UntrackedFiles: String, Sendable {
        /// Every untracked file, inside untracked folders too (the file list needs these).
        case all
        /// Untracked folders as one entry, without looking inside them. Cheaper, and enough to
        /// tell whether a repository has changes (the tab bar's change dot).
        case normal
    }

    public func status(untrackedFiles: UntrackedFiles = .all) async throws -> WorkingTreeStatus {
        let output = try await git([
            "status", "--porcelain=v2", "--branch", "--show-stash", "-z", "--untracked-files=\(untrackedFiles.rawValue)",
        ])
        return StatusParser.parse(output.stdout)
    }

    /// Added/removed lines per changed path, staged and unstaged combined. Untracked text files
    /// count every line as added (the first 500 files up to 1 MB each; others show no count).
    public func workingTreeLineStats(untracked: [String]) async -> [String: LineStat] {
        async let unstaged = try? git(["diff", "--numstat", "-z", "--no-ext-diff"])
        async let staged = try? git(["diff", "--cached", "--numstat", "-z", "--no-ext-diff"])
        var result = ChangeListParser.parseNumstat(await unstaged?.stdout ?? Data())
        for (path, stat) in ChangeListParser.parseNumstat(await staged?.stdout ?? Data()) {
            result[path] = result[path].map { $0 + stat } ?? stat
        }
        for path in untracked.prefix(500) {
            result[path] = Self.lineStat(ofUntrackedFile: root.appending(path: path))
        }
        return result
    }

    /// Added/removed lines per changed path, staged (HEAD → index) and unstaged (index → work
    /// tree, untracked files included) kept apart, so a partially staged file shows each part.
    public func stagedAndUnstagedLineStats(untracked: [String]) async -> WorkingLineStats {
        async let unstaged = try? git(["diff", "--numstat", "-z", "--no-ext-diff"])
        async let staged = try? git(["diff", "--cached", "--numstat", "-z", "--no-ext-diff"])
        var result = WorkingLineStats(
            staged: ChangeListParser.parseNumstat(await staged?.stdout ?? Data()),
            unstaged: ChangeListParser.parseNumstat(await unstaged?.stdout ?? Data())
        )
        for path in untracked.prefix(500) {
            result.unstaged[path] = Self.lineStat(ofUntrackedFile: root.appending(path: path))
        }
        return result
    }

    static func lineStat(ofUntrackedFile url: URL) -> LineStat {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let size = attributes[.size] as? Int, size <= 1_000_000,
              let data = try? Data(contentsOf: url) else {
            return LineStat(additions: nil, deletions: nil)
        }
        if data.prefix(8000).contains(0) {
            return LineStat(additions: nil, deletions: nil)
        }
        var lines = data.count { $0 == 0x0A }
        if let last = data.last, last != 0x0A { lines += 1 }
        return LineStat(additions: lines, deletions: 0)
    }

    public func refs() async throws -> RefSnapshot {
        let output = try await git([
            "for-each-ref", "--format=\(RefParser.format)", "refs/heads", "refs/remotes", "refs/tags",
        ])
        return RefSnapshot(refs: RefParser.parse(output.text))
    }

    /// One page of history across all branches, remote branches and tags (or the one branch
    /// `scope` keeps), newest first.
    public func log(skip: Int, limit: Int, includeHEAD: Bool, scope: HistoryScope = .all(hidden: [])) async throws -> [Commit] {
        var arguments = [
            "log", "--date-order", "-z", "--format=\(LogParser.format)",
            "--max-count=\(limit)", "--skip=\(skip)",
        ]
        arguments += Self.revisionArguments(for: scope, head: includeHEAD ? headState() : .leftOut)
        arguments.append("--")
        let output = try await git(arguments)
        return LogParser.parse(output.stdout)
    }

    public func commitDetails(_ id: String) async throws -> CommitDetails {
        let output = try await git(["show", "-s", "--format=\(CommitDetailsParser.format)", id, "--"])
        guard let details = CommitDetailsParser.parse(output.text) else {
            throw GitError(arguments: ["show", id], status: 0, message: "Couldn't read commit \(id.prefix(7)).")
        }
        return details
    }

    /// Files changed by `commit` compared with its first parent.
    public func changedFiles(in commit: Commit) async throws -> [FileChange] {
        try await changedFiles(from: commit.parents.first, to: commit.id)
    }

    /// Files that differ between two commits (`base` `nil`: everything in `target`, as for a
    /// root commit).
    public func changedFiles(from base: String?, to target: String) async throws -> [FileChange] {
        let range: [String]
        if let base {
            range = ["diff", "-z", "-M", "--no-ext-diff", base, target, "--"]
        } else {
            range = ["diff-tree", "-r", "-z", "-M", "--root", "--no-commit-id", target, "--"]
        }
        var raw = range
        raw.insert(contentsOf: ["--raw", "--no-abbrev"], at: 1)
        var numstat = range
        numstat.insert("--numstat", at: 1)
        async let names = git(raw)
        async let stats = git(numstat)
        let changes = ChangeListParser.parseRaw(try await names.stdout)
        let lineStats = ChangeListParser.parseNumstat(try await stats.stdout)
        return changes.map { change in
            var change = change
            change.stat = lineStats[change.path]
            return change
        }
    }

    /// The diff of one file in `commit`.
    public func diff(of change: FileChange, in commit: Commit, ignoringWhitespace: Bool = false) async throws -> FileDiff {
        try await diff(of: change, from: commit.parents.first, to: commit.id, ignoringWhitespace: ignoringWhitespace)
    }

    /// The diff of one file between two commits (`base` `nil`: as added in `target`).
    /// `ignoringWhitespace` is `git diff -w`: lines that only changed in white space drop out.
    public func diff(of change: FileChange, from base: String?, to target: String, ignoringWhitespace: Bool = false) async throws -> FileDiff {
        let paths = [change.oldPath, change.path].compactMap { $0 }
        let whitespace = ignoringWhitespace ? ["-w"] : []
        let arguments: [String]
        if let base {
            arguments = ["diff", "--no-ext-diff", "-M"] + whitespace + [base, target, "--"] + paths
        } else {
            arguments = ["diff-tree", "-p", "-M", "--root", "--no-commit-id"] + whitespace + [target, "--"] + paths
        }
        let output = try await git(arguments)
        var diff = DiffParser.parse(output.stdout).first ?? FileDiff(path: change.path, oldPath: change.oldPath)
        diff.ignoresWhitespace = ignoringWhitespace
        return diff
    }

    /// Staged (`git diff --cached`) or unstaged (`git diff`) changes of one path.
    public func workingDiff(path: String, staged: Bool, ignoringWhitespace: Bool = false) async throws -> FileDiff? {
        try await workingDiff(paths: [path], staged: staged, ignoringWhitespace: ignoringWhitespace)
    }

    /// Staged or unstaged changes of the given paths (pass both sides of a staged rename).
    /// Hunks of a diff that ignores white space can't be staged on their own: they don't match
    /// the file exactly.
    public func workingDiff(paths: [String], staged: Bool, ignoringWhitespace: Bool = false) async throws -> FileDiff? {
        var arguments = ["diff", "--no-ext-diff", "-M"]
        if staged { arguments.append("--cached") }
        if ignoringWhitespace { arguments.append("-w") }
        arguments += ["--"] + paths
        let output = try await git(arguments)
        var diff = DiffParser.parse(output.stdout).first
        diff?.ignoresWhitespace = ignoringWhitespace
        return diff
    }

    /// How many commits each side has that the other doesn't (`git rev-list --left-right`).
    public func distance(from base: String, to target: String) async -> CommitDistance? {
        guard let output = try? await git(["rev-list", "--left-right", "--count", "\(base)...\(target)", "--"]) else { return nil }
        let counts = output.text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard counts.count == 2 else { return nil }
        return CommitDistance(ahead: counts[1], behind: counts[0])
    }

    /// Local branches that contain `commit`.
    public func branchesContaining(_ commit: String) async throws -> [String] {
        let output = try await git(["branch", "--format=%(refname:short)", "--contains", commit])
        return output.text.split(separator: "\n").map(String.init)
    }

    /// An untracked file shown as a new file.
    public func untrackedDiff(path: String) async throws -> FileDiff? {
        let output = try await git(["diff", "--no-index", "--no-ext-diff", "--", "/dev/null", path], accepted: [0, 1])
        guard var diff = DiffParser.parse(output.stdout).first else { return nil }
        diff.path = path
        diff.oldPath = nil
        diff.isNewFile = true
        return diff
    }

    public func stashes() async throws -> [Stash] {
        let output = try await git(["stash", "list", "--format=\(StashParser.format)"])
        return StashParser.parse(output.text)
    }

    public func remotes() async throws -> [String] {
        let output = try await git(["remote"])
        return output.text.split(separator: "\n").map(String.init)
    }

    /// Number of commits the history shows for `scope`.
    public func commitCount(in scope: HistoryScope) async throws -> Int {
        let output = try await git(["rev-list", "--count"] + Self.revisionArguments(for: scope, head: headState()) + ["--"])
        return Int(output.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Number of commits reachable from `ref`.
    public func commitCount(_ ref: String = "HEAD") async throws -> Int {
        let output = try await git(["rev-list", "--count", ref, "--"])
        return Int(output.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// `git config --get <key>` (repository, global and system scopes), `nil` when unset.
    public func config(_ key: String) async -> String? {
        guard let output = try? await git(["config", "--get", key], accepted: [0, 1]), output.status == 0 else {
            return nil
        }
        let value = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// When a fetch last finished, from `FETCH_HEAD`.
    public var lastFetchDate: Date? {
        let path = gitDirectory.appending(path: "FETCH_HEAD").path(percentEncoded: false)
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Checks a new branch name with `git check-ref-format --branch`.
    public func isValidBranchName(_ name: String) async -> Bool {
        guard !name.isEmpty, let output = try? await git(["check-ref-format", "--branch", name], accepted: [0, 1, 128]) else {
            return false
        }
        return output.status == 0
    }

    // MARK: - Staging and committing

    public func stage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await git(["add", "--all", "--"] + paths)
    }

    public func stageAll() async throws {
        try await git(["add", "--all"])
    }

    public func unstage(_ paths: [String], hasHead: Bool) async throws {
        guard !paths.isEmpty else { return }
        if hasHead {
            try await git(["restore", "--staged", "--"] + paths)
        } else {
            try await git(["rm", "--cached", "-r", "-q", "--"] + paths)
        }
    }

    public func unstageAll(hasHead: Bool) async throws {
        if hasHead {
            try await git(["reset", "-q"])
        } else {
            try await git(["rm", "--cached", "-r", "-q", "--", "."])
        }
    }

    /// Throws away unstaged changes of tracked files (the index is kept).
    public func discardUnstaged(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await git(["restore", "--worktree", "--"] + paths)
    }

    /// Restores files to HEAD in both the index and the working tree.
    public func discardAll(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await git(["restore", "--staged", "--worktree", "--source=HEAD", "--"] + paths)
    }

    /// `git apply [--cached] [--reverse] --recount -` with `patch` on standard input.
    public func apply(patch: String, cached: Bool, reverse: Bool) async throws {
        var arguments = ["apply", "--recount", "--whitespace=nowarn"]
        if cached { arguments.append("--cached") }
        if reverse { arguments.append("--reverse") }
        arguments.append("-")
        try await git(arguments, input: Data(patch.utf8))
    }

    /// Commits the index. Hooks and signing follow the user's git config.
    /// `runHooks: false` skips `pre-commit` and `commit-msg` (Repository Settings › Hooks).
    public func commit(message: String, amend: Bool, runHooks: Bool = true) async throws {
        var arguments = ["commit", "--file=-", "--cleanup=whitespace"]
        if amend { arguments.append("--amend") }
        if !runHooks { arguments.append("--no-verify") }
        try await git(arguments, input: Data(message.utf8))
    }

    // MARK: - Remotes

    public func fetch(remote: String? = nil, onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        var arguments = ["fetch", "--progress", "--prune"]
        if let remote {
            arguments.append(remote)
        } else {
            arguments.append("--all")
        }
        try await git(arguments, onProgress: onProgress)
    }

    public enum PullStrategy: Sendable {
        case gitConfig
        case merge
        case rebase
        case fastForwardOnly
    }

    /// `git pull`. When the merge or rebase it runs stops on conflicts, the pull returns
    /// ``OperationOutcome/stopped`` (it waits in ``operationState()``) instead of throwing, like
    /// ``merge(_:fastForward:)``. git refuses `--rebase` with uncommitted changes to tracked files;
    /// ``withChangesStashed(message:_:)`` puts them aside first.
    @discardableResult
    public func pull(strategy: PullStrategy = .gitConfig, onProgress: (@Sendable (String) -> Void)? = nil) async throws -> OperationOutcome {
        var arguments = ["pull", "--progress"]
        switch strategy {
        case .gitConfig: break
        case .merge: arguments.append("--no-rebase")
        case .rebase: arguments.append("--rebase")
        case .fastForwardOnly: arguments.append("--ff-only")
        }
        return try await runStoppable(arguments, onProgress: onProgress)
    }

    /// Pushes the current branch. Without an upstream, publishes it to `remote` and sets the upstream.
    public func push(
        setUpstreamOn remote: String? = nil,
        forceWithLease: Bool = false,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        var arguments = ["push", "--progress"]
        if forceWithLease { arguments.append("--force-with-lease") }
        if let remote {
            arguments += ["--set-upstream", remote, "HEAD"]
        }
        try await git(arguments, onProgress: onProgress)
    }

    // MARK: - Stashes

    public func stash(message: String?, includeUntracked: Bool, keepIndex: Bool = false) async throws {
        var arguments = ["stash", "push"]
        if includeUntracked { arguments.append("--include-untracked") }
        if keepIndex { arguments.append("--keep-index") }
        if let message, !message.isEmpty { arguments += ["-m", message] }
        try await git(arguments)
    }

    public func applyStash(_ stash: Stash, pop: Bool) async throws {
        try await git(["stash", pop ? "pop" : "apply", stash.reference])
    }

    public func dropStash(_ stash: Stash) async throws {
        try await git(["stash", "drop", stash.reference])
    }

    // MARK: - Branches

    public func switchBranch(_ name: String) async throws {
        try await git(["switch", name])
    }

    /// Creates a local branch tracking `remoteBranch` (e.g. `origin/feature/x`) and switches to it.
    public func switchToRemoteBranch(_ remoteBranch: String, localName: String) async throws {
        try await git(["switch", "-c", localName, "--track", remoteBranch])
    }

    public func createBranch(_ name: String, startPoint: String?, checkout: Bool) async throws {
        var arguments = checkout ? ["switch", "-c", name] : ["branch", name]
        if let startPoint { arguments.append(startPoint) }
        try await git(arguments)
    }

    public func deleteBranch(_ name: String, force: Bool) async throws {
        try await git(["branch", force ? "-D" : "-d", name])
    }

    public func detach(at commit: String) async throws {
        try await git(["switch", "--detach", commit])
    }

    /// `git revert --no-edit <commit>`; merge commits are reverted against their first parent.
    public func revert(_ commit: Commit) async throws {
        var arguments = ["revert", "--no-edit"]
        if commit.isMerge { arguments += ["-m", "1"] }
        arguments.append(commit.id)
        try await git(arguments)
    }

    // MARK: - File-system events

    /// Sorts changed paths reported by ``FileSystemWatcher`` into what needs refreshing.
    public func classify(_ paths: [String]) -> ChangeScope {
        let gitDir = gitDirectory.path(percentEncoded: false).trimmingSuffix("/") + "/"
        var scope: ChangeScope = []
        for path in paths {
            guard path.hasPrefix(gitDir) || path + "/" == gitDir else {
                scope.insert(.workTree)
                continue
            }
            let relative = String(path.dropFirst(gitDir.count))
            if relative.hasSuffix(".lock") || relative.hasPrefix("objects") || relative.hasPrefix("logs") {
                continue
            }
            if relative == "index" {
                scope.insert(.index)
            } else if relative.hasPrefix("refs") || relative == "HEAD" || relative == "packed-refs"
                        || relative == "FETCH_HEAD" || relative == "ORIG_HEAD" || relative == "config"
                        || relative.hasPrefix("MERGE_") || relative.hasPrefix("REBASE_")
                        || relative.hasPrefix("rebase-") || relative.hasPrefix("CHERRY_PICK")
                        || relative.hasPrefix("REVERT_") {
                scope.insert(.refs)
            }
        }
        return scope
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
