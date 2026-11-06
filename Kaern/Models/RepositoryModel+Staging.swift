import Foundation
import KaernKit

// MARK: - Staging

extension RepositoryModel {
    enum PatchAction {
        case stage
        case unstage
        case discard
    }

    func toggleStaging(_ entry: StatusEntry) async {
        if entry.stageState == .staged {
            await unstage([entry])
        } else {
            await stage([entry])
        }
    }

    func stage(_ entries: [StatusEntry]) async {
        let paths = entries.map(\.path)
        await performIndexChange(failureTitle: String(localized: "Couldn't Stage")) { repository in
            try await repository.stage(paths)
        }
    }

    func unstage(_ entries: [StatusEntry]) async {
        let paths = entries.flatMap { [$0.originalPath, $0.path].compactMap { $0 } }
        let hasHead = hasHead
        await performIndexChange(failureTitle: String(localized: "Couldn't Unstage")) { repository in
            try await repository.unstage(paths, hasHead: hasHead)
        }
    }

    func stageAll() async {
        await performIndexChange(failureTitle: String(localized: "Couldn't Stage")) { repository in
            try await repository.stageAll()
        }
    }

    func unstageAll() async {
        let hasHead = hasHead
        await performIndexChange(failureTitle: String(localized: "Couldn't Unstage")) { repository in
            try await repository.unstageAll(hasHead: hasHead)
        }
    }

    /// The selected working-copy file, when Restore to HEAD (⌥⌘Z) can throw its changes away.
    var restorableEntry: StatusEntry? {
        guard selection == .workingCopy, case .working(let path) = selectedFile,
              let entry = status.entries.first(where: { $0.path == path }), !entry.isConflicted else { return nil }
        return entry
    }

    /// "Restore “release.yml” to HEAD", or "Move “notes.txt” to Trash" for a new file.
    func restoreTitle(for entry: StatusEntry) -> String {
        let name = (entry.path as NSString).lastPathComponent
        return entry.isUntracked ? String(localized: "Move “\(name)” to Trash") : String(localized: "Restore “\(name)” to HEAD")
    }

    /// What Discard All Changes throws away: not conflicts (resolve those) and not submodules
    /// (their changes belong to their own window; the diff's "Check Out" moves them back).
    var discardableEntries: [StatusEntry] {
        status.entries.filter { !$0.isConflicted && $0.submodule == nil }
    }

    /// Throws away changes — no confirmation: a copy goes to the stash list ("Before discarding
    /// changes to …"), untracked files go to the Trash, and ⌘Z puts everything back.
    func discard(_ entries: [StatusEntry]) async {
        guard let repository, !entries.isEmpty else { return }
        let untracked = entries.filter(\.isUntracked)
        let unstaged = entries.filter { !$0.isUntracked && $0.hasUnstagedChanges }.map(\.path)
        let stagedOnly = entries.filter { !$0.isUntracked && !$0.hasUnstagedChanges }
            .flatMap { [$0.originalPath, $0.path].compactMap { $0 } }
        let name = entries.count == 1
            ? (entries[0].path as NSString).lastPathComponent
            : String(localized: "\(entries.count) files")

        // Keep what's about to go: a stash for later, patches for ⌘Z.
        let unstagedPatch: Data
        let stagedPatch: Data
        do {
            let paths = entries.flatMap { [$0.originalPath, $0.path].compactMap { $0 } }
            _ = try await repository.snapshotStash(paths: paths, message: "Before discarding changes to \(name)", includeUntracked: !untracked.isEmpty)
            unstagedPatch = try await repository.patch(paths: unstaged, staged: false)
            stagedPatch = try await repository.patch(paths: stagedOnly, staged: true)
        } catch {
            // Nothing was discarded yet.
            showError(error, title: String(localized: "Couldn't Discard Changes"))
            return
        }

        let discarded = await performIndexChange(failureTitle: String(localized: "Couldn't Discard Changes")) { repository in
            try await repository.discardUnstaged(unstaged)
            try await repository.discardAll(stagedOnly)
        }
        var trashed: [(original: URL, trash: URL)] = []
        for entry in untracked {
            let url = repository.root.appending(path: entry.path)
            do {
                var result: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                if let result { trashed.append((url, result as URL)) }
            } catch {
                showError(error, title: String(localized: "Couldn't Move “\(entry.path)” to the Trash"))
            }
        }
        if !untracked.isEmpty {
            await refreshStatus()
        }
        guard discarded else { return }
        let items = trashed
        registerUndo(String(localized: "Discard Changes"), hint: String(localized: "Discarded changes to \(name)")) { model in
            await model.undoStep(String(localized: "Discard Changes")) { repository in
                try await repository.apply(patchData: unstagedPatch)
                try await repository.apply(patchData: stagedPatch, index: true)
                for item in items {
                    try FileManager.default.createDirectory(at: item.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: item.trash, to: item.original)
                }
            }
        }
    }

    /// Stages, unstages or discards one hunk (or some of its lines). Discarding is undone with ⌘Z.
    func applyPatch(_ action: PatchAction, diff: FileDiff, hunk: Int, lines: Set<Int>? = nil) async {
        let reverse = action != .stage
        guard let patch = diff.patch(hunk: hunk, selectedLines: lines, reverse: reverse) else { return }
        let title: String
        switch action {
        case .stage: title = String(localized: "Couldn't Stage")
        case .unstage: title = String(localized: "Couldn't Unstage")
        case .discard: title = String(localized: "Couldn't Discard")
        }
        let applied = await performIndexChange(failureTitle: title) { repository in
            try await repository.apply(patch: patch, cached: action != .discard, reverse: reverse)
        }
        guard applied, action == .discard else { return }
        let what = lines.map { $0.count == 1 ? String(localized: "1 line") : String(localized: "\($0.count) lines") } ?? String(localized: "a hunk")
        let file = (diff.path as NSString).lastPathComponent
        registerUndo(String(localized: "Discard"), hint: String(localized: "Discarded \(what) in \(file)")) { model in
            await model.undoStep(String(localized: "Discard")) { repository in
                // The patch that was applied in reverse, applied forward again.
                try await repository.apply(patch: patch, cached: false, reverse: false)
            }
        }
    }
}
