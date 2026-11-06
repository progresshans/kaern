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
        arguments += ["--"] + paths
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
    /// changes are stashed and applied straight back. Returns the stash's object name, `nil` when
    /// there was nothing to keep.
    public func snapshotStash(paths: [String], message: String, includeUntracked: Bool) async throws -> String? {
        guard !paths.isEmpty else { return nil }
        let before = await resolve("refs/stash")
        var arguments = ["stash", "push", "-q", "-m", message]
        if includeUntracked { arguments.append("--include-untracked") }
        // Literal pathspecs: a file named "[draft].md" must not match "d.md". (Setting
        // GIT_LITERAL_PATHSPECS for the whole command breaks `stash -u` internally.)
        arguments += ["--"] + paths.map { ":(literal)" + $0 }
        try await git(arguments)
        guard let after = await resolve("refs/stash"), after != before else { return nil }
        try await git(["stash", "apply", "--index", "-q", "stash@{0}"])
        return after
    }

    /// Stashes all local changes with `message` and returns the new stash's object name.
    public func stashAll(message: String, includeUntracked: Bool) async throws -> String? {
        let before = await resolve("refs/stash")
        try await stash(message: message, includeUntracked: includeUntracked)
        guard let after = await resolve("refs/stash"), after != before else { return nil }
        return after
    }

    /// The stash entry whose commit is `object`.
    public func stash(withObject object: String) async -> Stash? {
        (try? await stashes())?.first { $0.id == object }
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
