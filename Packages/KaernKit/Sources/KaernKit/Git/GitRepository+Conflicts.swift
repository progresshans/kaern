import Foundation

// MARK: - A stash that stopped on conflicts

/// Applying or popping a stash stopped on conflicts. git leaves the conflicted files with markers
/// (and the clean ones applied), and keeps the stash in the list even for a pop.
public struct StashApplyConflict: Error, LocalizedError, Sendable, Hashable {
    public var stash: Stash
    /// Pop was asked for (git didn't drop the stash: it does that only when the pop succeeds).
    public var wasPop: Bool
    /// Files with conflict markers.
    public var conflicted: [String]
    /// Tracked files the stash changes.
    public var tracked: [String]
    /// Untracked files the stash brought back that weren't there before.
    public var addedUntracked: [String]
    /// The index as a tree just before the stash went in: what Undo Pop puts back, staged
    /// changes included. `nil` falls back to HEAD.
    public var indexBefore: String?
    /// Files that had unstaged changes just before. git doesn't apply a stash over unstaged
    /// changes it would touch, so Undo Pop leaves these files alone.
    public var unstagedBefore: [String]

    public init(stash: Stash, wasPop: Bool, conflicted: [String], tracked: [String], addedUntracked: [String],
                indexBefore: String? = nil, unstagedBefore: [String] = []) {
        self.stash = stash
        self.wasPop = wasPop
        self.conflicted = conflicted
        self.tracked = tracked
        self.addedUntracked = addedUntracked
        self.indexBefore = indexBefore
        self.unstagedBefore = unstagedBefore
    }

    public var errorDescription: String? {
        let names = conflicted.map { ($0 as NSString).lastPathComponent }
        let list = names.count == 1 ? names[0] : "\(names.count) files"
        return "\(wasPop ? "Pop" : "Apply") stopped: \(list) \(names.count == 1 ? "has a conflict" : "have conflicts")."
    }
}

extension GitRepository {
    /// Files with unmerged entries (conflicts), in path order.
    public func unmergedPaths() async -> [String] {
        guard let output = try? await git(["diff", "--name-only", "--diff-filter=U", "-z"]) else { return [] }
        return Array(Set(Records.splitNUL(output.stdout))).sorted()
    }

    /// Applies or pops a stash; when git stops on conflicts this throws ``StashApplyConflict``
    /// instead of git's error, so the app can open the conflict editor.
    public func applyStashReportingConflicts(_ stash: Stash, pop: Bool) async throws -> AppliedStash? {
        let untracked = (try? await git(["stash", "show", "--only-untracked", "--name-only", "-z", stash.id]).stdout) ?? Data()
        let untrackedPaths = Records.splitNUL(untracked)
        let existing = Set(untrackedPaths.filter { FileManager.default.fileExists(atPath: root.appending(path: $0).path(percentEncoded: false)) })
        // What Undo Pop goes back to. git writes the index as a tree to apply a stash too, so
        // when this fails (the index has conflicts already), the stash can't stop on new ones.
        let indexBefore = try? await git(["write-tree"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let unstagedBefore = Records.splitNUL((try? await git(["diff", "--name-only", "-z"]).stdout) ?? Data())
        do {
            return try await applyStashUndoably(stash, pop: pop)
        } catch {
            let conflicted = await unmergedPaths()
            guard !conflicted.isEmpty, let indexBefore, !indexBefore.isEmpty else { throw error }
            let tracked = Records.splitNUL((try? await git(["stash", "show", "--name-only", "-z", stash.id]).stdout) ?? Data())
            throw StashApplyConflict(stash: stash, wasPop: pop, conflicted: conflicted, tracked: tracked,
                                     addedUntracked: untrackedPaths.filter { !existing.contains($0) },
                                     indexBefore: indexBefore, unstagedBefore: unstagedBefore)
        }
    }

    /// Undo Pop after a conflict: the stash's files go back to how they were just before, staged
    /// changes included (the stash is still in the list), and the untracked files it brought
    /// back are removed.
    public func takeBack(_ conflict: StashApplyConflict) async throws {
        // Files with unstaged changes before weren't touched: git refuses to apply over them.
        let untouched = Set(conflict.unstagedBefore)
        let paths = Set(conflict.tracked + conflict.conflicted).subtracting(untouched).sorted()
        if !paths.isEmpty {
            let source = conflict.indexBefore ?? "HEAD"
            try await git(["restore", "--source=\(source)", "--staged", "--worktree", "--"] + paths.map { ":(literal)" + $0 })
        }
        for path in conflict.addedUntracked {
            try? FileManager.default.removeItem(at: root.appending(path: path))
        }
    }

    // MARK: Renaming a stash

    /// Gives a stash a new message and keeps its place in the list. git can't rename a stash:
    /// the entries above it are dropped and stored again in the same order, all with the same
    /// commits. If git fails halfway, every entry it dropped goes back, so no stash is lost.
    public func renameStash(_ stash: Stash, to message: String) async throws {
        let list = try await stashes()
        guard let index = list.firstIndex(where: { $0.id == stash.id }) else {
            throw GitError(arguments: ["stash", "store"], status: -1, message: "\(stash.reference) isn't in the stash list anymore.")
        }
        let moving = Array(list[...index])
        do {
            for entry in moving {
                // Only the entry expected on top: something else (Terminal) may have stashed meanwhile.
                let top = try await git(["rev-parse", "--verify", "-q", "refs/stash"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard top == entry.id else {
                    throw GitError(arguments: ["stash", "drop"], status: -1, message: "The stash list changed while renaming \(stash.reference).")
                }
                try await git(["stash", "drop", "-q", "stash@{0}"])
            }
            // Oldest first, so the newest ends up on top again.
            for entry in moving.reversed() {
                try await storeStash(entry.id, message: entry.id == stash.id ? message : entry.message)
            }
        } catch {
            await restoreMissingStashes(moving)
            throw error
        }
    }

    /// Stores again, oldest first, every entry of `entries` (newest first, as listed) that's no
    /// longer in the stash list. A listing that fails counts as all missing: a stash twice in the
    /// list is better than one lost.
    func restoreMissingStashes(_ entries: [Stash]) async {
        let present = Set(((try? await stashes()) ?? []).map(\.id))
        for entry in entries.reversed() where !present.contains(entry.id) {
            try? await storeStash(entry.id, message: entry.message)
        }
    }
}
