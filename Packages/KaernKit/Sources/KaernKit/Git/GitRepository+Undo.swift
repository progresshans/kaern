import Foundation

// MARK: - Reset, and the plumbing Kaern's ⌘Z needs

extension GitRepository {
    public enum ResetMode: String, Sendable, Hashable, CaseIterable {
        /// Moves the branch; the changes stay staged.
        case soft
        /// Moves the branch; the changes stay in the working tree, unstaged.
        case mixed
        /// Moves the branch and throws the changes away.
        case hard
        /// Moves the branch like `hard`, but stops if that would overwrite local changes.
        case keep
    }

    /// `git reset --<mode> <target>`
    public func reset(to target: String, mode: ResetMode) async throws {
        try await git(["reset", "--\(mode.rawValue)", "-q", target, "--"])
    }

    /// The object name `revision` resolves to, `nil` when it doesn't exist.
    public func resolve(_ revision: String) async -> String? {
        guard let output = try? await git(["rev-parse", "--verify", "--quiet", revision], accepted: [0, 1]),
              output.status == 0 else { return nil }
        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Whether `commit` is reachable from `other`.
    public func isAncestor(_ commit: String, of other: String) async -> Bool {
        guard let output = try? await git(["merge-base", "--is-ancestor", commit, other], accepted: [0, 1]) else { return false }
        return output.status == 0
    }

    /// Commits reachable from `revision` but not from `base` (`git rev-list --count base..revision`).
    public func countCommits(from base: String, to revision: String) async -> Int {
        guard let output = try? await git(["rev-list", "--count", "\(base)..\(revision)", "--"]) else { return 0 }
        return Int(output.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// The changes of `paths` as a binary-safe patch: unstaged (`git diff`) or staged (`--cached`).
    public func patch(paths: [String], staged: Bool) async throws -> Data {
        guard !paths.isEmpty else { return Data() }   // no paths would mean "everything"
        var arguments = ["diff", "--binary", "--no-ext-diff", "--no-color"]
        if staged { arguments.append("--cached") }
        arguments += ["--"] + Self.literal(paths)
        return try await git(arguments).stdout
    }

    /// `git apply` of raw patch bytes. `index` applies to the index and the working tree together.
    public func apply(patchData: Data, cached: Bool = false, index: Bool = false, reverse: Bool = false) async throws {
        guard !patchData.isEmpty else { return }
        var arguments = ["apply", "--whitespace=nowarn"]
        if cached { arguments.append("--cached") }
        if index { arguments.append("--index") }
        if reverse { arguments.append("--reverse") }
        arguments.append("-")
        try await git(arguments, input: patchData)
    }

    /// Keeps a copy of the changes of `paths` in the stash list without changing anything: the
    /// stash commit is built with a scratch index (`git stash store` adds it to the list), so the
    /// working tree and the index are never touched. Staged and unstaged changes of `paths` go
    /// in like `git stash push -- <paths>` would put them; with `includeUntracked`, untracked
    /// files among `paths` go in the stash's third parent. Returns the stash's object name,
    /// `nil` when there was nothing to keep.
    public func snapshotStash(paths: [String], message: String, includeUntracked: Bool) async throws -> String? {
        // The Command Log shows the `git stash store` under the action; the plumbing that builds
        // the entry is filed as that action's background work.
        let action = GitCommandTrigger.current
        guard let commit = try await GitCommandTrigger.$current.withValue(
            GitCommandTrigger((action?.action ?? "Keeping a copy") + " › building the copy", background: true),
            operation: { try await snapshotCommit(paths: paths, message: message, includeUntracked: includeUntracked) }
        ) else { return nil }
        try await git(["stash", "store", "-m", commit.title, commit.id])
        return commit.id
    }

    /// The stash commit `snapshotStash` stores.
    private func snapshotCommit(paths: [String], message: String, includeUntracked: Bool) async throws -> (id: String, title: String)? {
        guard !paths.isEmpty, let head = await resolve("HEAD") else { return nil }
        let literal = paths.map { ":(literal)" + $0 }
        let untracked = includeUntracked
            ? Records.splitNUL(try await git(["ls-files", "-z", "--others", "--exclude-standard", "--"] + literal).stdout)
            : []
        let untrackedSet = Set(untracked)
        let tracked = paths.filter { !untrackedSet.contains($0) }
        let branch = await currentBranchName() ?? "(no branch)"
        let subject = (try? await git(["log", "-1", "--format=%h %s", head, "--"]).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        let scratch = gitDirectory.appending(path: "kaern-snapshot-\(UUID().uuidString).index")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let env = ["GIT_INDEX_FILE": scratch.path(percentEncoded: false)]

        // The index part: HEAD with the real index's entries for the tracked paths.
        try await git(["read-tree", head], environment: env)
        var entries: [String] = []
        var inIndex = Set<String>()
        if !tracked.isEmpty {
            let staged = try await git(["ls-files", "-s", "-z", "--"] + tracked.map { ":(literal)" + $0 }).stdout
            for record in Records.splitNUL(staged) {
                // <mode> SP <object> SP <stage> TAB <path>
                guard let tab = record.firstIndex(of: "\t") else { continue }
                let fields = record[..<tab].split(separator: " ")
                let path = String(record[record.index(after: tab)...])
                guard fields.count == 3, fields[2] == "0" else { continue }
                inIndex.insert(path)
                entries.append("\(fields[0]) \(fields[1])\t\(path)")
            }
        }
        let zero = String(repeating: "0", count: 40)
        for path in tracked where !inIndex.contains(path) { entries.append("0 \(zero)\t\(path)") }
        if !entries.isEmpty {
            try await git(["update-index", "-z", "--index-info"], input: Data((entries.joined(separator: "\0") + "\0").utf8), environment: env)
        }
        let indexTree = try await git(["write-tree"], environment: env).text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The working-tree part: the files as they are on disk (deleted ones leave).
        if !tracked.isEmpty {
            // update-index takes plain paths, not pathspecs.
            try await git(["update-index", "--add", "--remove", "--"] + tracked, environment: env)
        }
        let workTree = try await git(["write-tree"], environment: env).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let headTree = await treeID(of: head)
        guard workTree != headTree || indexTree != headTree || !untracked.isEmpty else { return nil }

        let indexCommit = try await git(["commit-tree", indexTree, "-p", head], input: Data("index on \(branch): \(subject)\n".utf8))
            .text.trimmingCharacters(in: .whitespacesAndNewlines)
        var parents = ["-p", head, "-p", indexCommit]
        if !untracked.isEmpty {
            try await git(["read-tree", "--empty"], environment: env)
            try await git(["update-index", "--add", "--"] + untracked, environment: env)
            let untrackedTree = try await git(["write-tree"], environment: env).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let untrackedCommit = try await git(["commit-tree", untrackedTree], input: Data("untracked files on \(branch): \(subject)\n".utf8))
                .text.trimmingCharacters(in: .whitespacesAndNewlines)
            parents += ["-p", untrackedCommit]
        }
        let title = "On \(branch): \(message)"
        let stash = try await git(["commit-tree", workTree] + parents, input: Data((title + "\n").utf8))
            .text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (stash, title)
    }

    /// Stashes all local changes with `message` and returns the new stash's object name.
    public func stashAll(message: String, includeUntracked: Bool) async throws -> String? {
        let before = await resolve("refs/stash")
        try await stash(message: message, includeUntracked: includeUntracked)
        guard let after = await resolve("refs/stash"), after != before else { return nil }
        return after
    }

    /// The stash entry with `message` made since `previous` was the top of the list, or `nil`.
    /// For putting things back after a stop: a stop that comes right after `git stash push` keeps
    /// the read that finds the new entry from starting, so the entry looks like none was made.
    /// This reads in a task of its own.
    func stashMade(since previous: String?, message: String) async -> String? {
        let found = try? await Self.uncancelled { () async -> String? in
            guard let top = await self.resolve("refs/stash"), top != previous,
                  let entry = await self.stash(withObject: top), entry.message.hasSuffix(message) else { return nil }
            return top
        }
        return found ?? nil
    }

    /// Reset Hard: what `git reset --hard <target>` would lose goes to Stashes first
    /// (`stashBeforeHardReset`), then the reset runs. When the reset doesn't happen (git fails, or
    /// it's stopped before it starts), the stash comes straight back, so no "Before reset" entry is
    /// left for a reset that didn't happen. Returns the stash's commit (`nil`: nothing was put aside).
    public func resetHard(to target: String, message: String) async throws -> String? {
        let head = await resolve("HEAD")
        let stashBefore = await resolve("refs/stash")
        do {
            let stash = try await stashBeforeHardReset(to: target, message: message)
            try await reset(to: target, mode: .hard)
            return stash
        } catch {
            let failure = error
            // Looked up again, in a task of its own: after a stop, git commands in this one don't
            // start, so a stash made just before can look like none was made.
            guard let stash = await stashMade(since: stashBefore, message: message) else { throw failure }
            // Back only while the branch and its files are as they were: a reset that got that far is done.
            let back = (try? await Self.uncancelled { () async throws -> Bool in
                let untouched = (try? await self.git(["diff-index", "--quiet", "HEAD", "--"], accepted: [0, 1]))?.status == 0
                guard await self.resolve("HEAD") == head, untouched else { return false }
                try await self.popStash(object: stash)
                return true
            }) ?? false
            guard back else {
                throw GitError(arguments: ["stash", "pop"], status: -1,
                               message: "\(Self.describe(failure)) Your uncommitted changes are kept in the stash list as “\(message)”.")
            }
            throw failure
        }
    }

    /// Puts aside what `git reset --hard <target>` would lose, in one stash entry, and returns its
    /// commit (`nil` when nothing would be lost): the uncommitted changes of tracked files, and the
    /// untracked or ignored files the reset would write over or delete (`untrackedInTheWay(of:)`).
    /// git does that to them without a word, an ignored `.env` written again by hand included.
    /// Other untracked and ignored files stay where they are, as the reset leaves them. A git
    /// repository of its own in the way (`repositoryInTheWay`) stops it before anything changes:
    /// git can't stash one, and the reset would delete it or write over its files.
    public func stashBeforeHardReset(to target: String, message: String) async throws -> String? {
        let inTheWay = try await untrackedInTheWay(of: target)
        guard !inTheWay.isEmpty else { return try await stashAll(message: message, includeUntracked: false) }
        if let repository = repositoryInTheWay(inTheWay) {
            throw GitError(arguments: ["reset", "--hard", target], status: -1,
                           message: "\(repository) is a git repository of its own inside this one, and the reset would delete it or write over its files. git can’t put a repository aside, so Kaern didn’t reset anything. Move it out of the folder first.")
        }
        // `--all` takes ignored files too; the paths keep it to those in the way and to the
        // tracked changes (staged or not), so nothing else leaves the working tree.
        let unstaged = Records.splitNUL(try await git(["diff", "--name-only", "--no-renames", "-z"]).stdout)
        let staged = Records.splitNUL(try await git(["diff", "--cached", "--name-only", "--no-renames", "-z"]).stdout)
        let paths = Set(unstaged + staged + inTheWay).sorted().map { ":(literal)" + $0 }
        let before = await resolve("refs/stash")
        try await git(["stash", "push", "--all", "-q", "-m", message, "--pathspec-from-file=-", "--pathspec-file-nul"],
                      input: Data(paths.joined(separator: "\0").utf8))
        guard let after = await resolve("refs/stash"), after != before else { return nil }
        return after
    }

    /// Untracked or ignored files (and folders holding some) that `git reset --hard <target>`
    /// would write over or delete: what is at a path where `target` has a file and the index has
    /// none, and a file where `target` needs a folder.
    func untrackedInTheWay(of target: String) async throws -> [String] {
        let wanted = Records.splitNUL(try await git(["ls-tree", "-r", "--name-only", "-z", target]).stdout)
        let tracked = Set(Records.splitNUL(try await git(["ls-files", "-z"]).stdout))
        var found = Set<String>()
        for path in wanted where !tracked.contains(path) {
            if let isFolder = itemIsFolder(path) {
                // An empty folder loses nothing (and a path matching no file would stop the stash).
                if !isFolder || folderHoldsFiles(path) { found.insert(path) }
                continue
            }
            var prefix = ""
            for part in path.split(separator: "/").dropLast() {
                prefix += (prefix.isEmpty ? "" : "/") + part
                guard let isFolder = itemIsFolder(prefix) else { break }   // nothing there: git makes the folder
                if !isFolder {
                    if !tracked.contains(prefix) { found.insert(prefix) }
                    break
                }
            }
        }
        return found.sorted()
    }

    /// `nil` when nothing is at `path` in the working tree; whether it's a folder otherwise (a
    /// link counts as a file, as git sees it).
    private func itemIsFolder(_ path: String) -> Bool? {
        let full = root.appending(path: path).path(percentEncoded: false)
        guard let type = (try? FileManager.default.attributesOfItem(atPath: full))?[.type] as? FileAttributeType else { return nil }
        return type == .typeDirectory
    }

    private func folderHoldsFiles(_ path: String) -> Bool {
        let folder = root.appending(path: path, directoryHint: .isDirectory)
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return false }
        for case let url as URL in items where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            return true
        }
        return false
    }

    /// A git repository of its own in the working tree (a clone kept in the folder, a submodule's
    /// folder) that `git reset --hard` would delete or write into for `inTheWay`: one around a
    /// path in the way, or one in a folder in the way. `git stash` skips it (an embedded
    /// repository), so nothing would bring it back. Its path, or `nil` when there's none.
    func repositoryInTheWay(_ inTheWay: [String]) -> String? {
        for path in inTheWay {
            var prefix = ""
            for part in path.split(separator: "/").dropLast() {
                prefix += (prefix.isEmpty ? "" : "/") + part
                if isRepositoryFolder(prefix) { return prefix }
            }
            if itemIsFolder(path) == true, let inside = repositoryFolder(at: path) { return inside }
        }
        return nil
    }

    /// Whether the folder `path` is the top of a git repository of its own (`.git`, a folder or a
    /// file, in it).
    private func isRepositoryFolder(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: path).appending(path: ".git").path(percentEncoded: false))
    }

    /// The first git repository at the folder `path` or inside it.
    private func repositoryFolder(at path: String) -> String? {
        if isRepositoryFolder(path) { return path }
        let folder = root.appending(path: path, directoryHint: .isDirectory)
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return nil }
        let base = folder.standardizedFileURL.path(percentEncoded: false)
        for case let url as URL in items where url.lastPathComponent == ".git" {
            let holder = url.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
            guard holder.hasPrefix(base) else { return path }
            let inner = holder.dropFirst(base.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return inner.isEmpty ? path : path + "/" + inner
        }
        return nil
    }

    /// The stash entry whose commit is `object`.
    public func stash(withObject object: String) async -> Stash? {
        (try? await stashes())?.first { $0.id == object }
    }

    /// `stash` as the list has it now. Its number (`stash@{n}`) counts from the top, so in a list
    /// read earlier it may name another entry by now (a stash made since takes stash@{0}): a stash
    /// is named by its number only right after this.
    func entryNow(_ stash: Stash) async throws -> Stash {
        guard let entry = await self.stash(withObject: stash.id) else {
            throw GitError(arguments: ["stash"], status: -1, message: "\(stash.reference) isn't in the stash list anymore.")
        }
        return entry
    }

    /// Applies (and drops) the stash entry with commit `object`, restoring what was staged too.
    public func popStash(object: String) async throws {
        guard let stash = await stash(withObject: object) else {
            throw GitError(arguments: ["stash", "pop"], status: -1, message: "The stash Kaern made isn't in the stash list anymore.")
        }
        try await git(["stash", "pop", "--index", "-q", stash.reference])
    }

    /// `git stash store`: puts a dropped stash back into the list.
    public func storeStash(_ object: String, message: String) async throws {
        try await git(["stash", "store", "-m", message, object])
    }

    public func setUpstream(of branch: String, to upstream: String) async throws {
        try await git(["branch", "--set-upstream-to=\(upstream)", branch])
    }

    /// Points `refs/tags/<name>` at `object` again (annotated tags keep their tag object).
    public func restoreTag(_ name: String, object: String) async throws {
        try await git(["update-ref", "refs/tags/\(name)", object, ""])
    }
}
