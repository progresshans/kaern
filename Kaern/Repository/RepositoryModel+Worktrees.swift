import AppKit
import KaernKit

/// Another working tree's page in the right panel (ScreenMarks › 워크트리): its uncommitted files.
struct WorktreeDetails: Equatable {
    let path: String
    let entries: [StatusEntry]
    let lineStats: WorkingLineStats
    /// HEAD's subject, when the commit is in this repository's loaded history or could be read.
    let headSubject: String?
}

extension RepositoryModel {
    /// The working tree this tab shows (its own folder).
    var currentWorktreePath: String {
        canonicalPath(repository?.root.path(percentEncoded: false).trimmingTrailingSlash ?? path).trimmingTrailingSlash
    }

    func isCurrent(_ worktree: Worktree) -> Bool {
        canonicalPath(worktree.path).trimmingTrailingSlash == currentWorktreePath
    }

    /// The other working trees (not bare, not this one).
    var otherWorktrees: [Worktree] {
        worktrees.filter { !$0.isBare && !isCurrent($0) }
    }

    /// The working tree that has `branch` checked out, when it isn't this one: git won't check it
    /// out here too (the sidebar's and the label's worktree mark).
    func otherWorktree(checkingOut branch: String) -> Worktree? {
        otherWorktrees.first { $0.branch == branch }
    }

    /// Branch → the name of the other worktree that has it checked out.
    var branchesInOtherWorktrees: [String: String] {
        Dictionary(otherWorktrees.compactMap { tree in tree.branch.map { ($0, tree.name) } }, uniquingKeysWith: { first, _ in first })
    }

    /// Counts the other working trees' uncommitted changes (the sidebar's "2 changes" and dot).
    func refreshWorktreeChanges() async {
        guard let runner = repository?.runner else { return }
        var counts: [String: Int] = [:]
        for tree in otherWorktrees where FileManager.default.fileExists(atPath: tree.path) {
            guard let other = try? await GitRepository.open(URL(filePath: tree.path, directoryHint: .isDirectory), runner: runner),
                  let status = try? await other.status(untrackedFiles: .normal) else { continue }
            counts[tree.path] = status.entries.count
        }
        if counts != worktreeChanges { worktreeChanges = counts }
        if let selected = selectedWorktree {
            if otherWorktrees.contains(where: { $0.path == selected }) { await loadWorktreeDetails(selected) } else { selectedWorktree = nil }
        }
    }

    /// A worktree picked in the sidebar: its page in the right panel (this tab's own clears it).
    func showWorktree(_ worktree: Worktree?) {
        guard let worktree, !isCurrent(worktree) else {
            selectedWorktree = nil
            return
        }
        clearPicks()
        review = nil
        selectedWorktree = worktree.path
        Task { await loadWorktreeDetails(worktree.path) }
    }

    func loadWorktreeDetails(_ path: String) async {
        guard let runner = repository?.runner else { return }
        guard let other = try? await GitRepository.open(URL(filePath: path, directoryHint: .isDirectory), runner: runner),
              let status = try? await other.status() else { return }
        let untracked = status.entries.filter(\.isUntracked).map(\.path)
        let stats = await other.stagedAndUnstagedLineStats(untracked: untracked)
        var subject: String?
        if let head = worktrees.first(where: { $0.path == path })?.head {
            subject = commit(head)?.subject
            if subject == nil { subject = try? await other.commit(head).subject }
        }
        guard selectedWorktree == path else { return }
        worktreeDetails = WorktreeDetails(path: path, entries: status.entries, lineStats: stats, headSubject: subject)
    }

    // MARK: Actions

    /// Open in New Tab: the worktree opens in a tab of its own, in the window showing this one.
    func openWorktree(_ path: String) {
        let app = AppModel.shared
        guard let window = app.windows.first(where: { $0.model.activeTab?.path == self.path })?.model
            ?? app.windows.first(where: { $0.model.tabs.contains { $0.path == self.path } })?.model else { return }
        app.open([URL(filePath: path, directoryHint: .isDirectory)], in: window)
    }

    func revealWorktree(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path, directoryHint: .isDirectory)])
    }

    /// Remove…: always asks. Its uncommitted changes go to Stashes first (git would refuse, or
    /// lose them with --force); ⌘Z puts the worktree back with its branch and changes.
    func askRemoveWorktree(_ worktree: Worktree) {
        let changes = worktreeChanges[worktree.path] ?? 0
        confirmation = Confirmation(
            title: "Remove the worktree \(worktree.name)?",
            message: "Kaern deletes the folder \((worktree.path as NSString).abbreviatingWithTildeInPath)"
                + (worktree.branch.map { ". \($0) stays a branch here, and can be checked out again" } ?? "")
                + (changes > 0 ? ". Its \(Formatters.count(changes, "uncommitted change", "uncommitted changes")) go to Stashes first" : "")
                + ". ⌘Z puts it back.",
            confirmTitle: "Remove",
            confirm: { [weak self] in self?.removeWorktree(worktree) }
        )
    }

    private func removeWorktree(_ worktree: Worktree) {
        let label = "Remove Worktree \(worktree.name)"
        perform(.working("Removing \(worktree.name)…"), trigger: label) { [weak self] repository in
            let stash = try await repository.removeWorktree(worktree.path, keepingChangesAs: "Worktree \(worktree.name)")
            guard let self else { return }
            if self.selectedWorktree == worktree.path { self.selectedWorktree = nil }
            self.record(.removedWorktree(worktree, stash: stash, label: label),
                        toast: "Removed the worktree \(worktree.name)" + (stash != nil ? " · its changes are in Stashes" : ""))
        }
    }

    /// Add Worktree…: `branch` checked out in a new folder (a branch checked out nowhere else).
    func addWorktree(branch: String, folder: URL) {
        let name = folder.lastPathComponent
        let label = "Add Worktree \(name)"
        perform(.working("Adding \(name)…"), trigger: label) { [weak self] repository in
            try await repository.addWorktree(at: folder, branch: branch, newBranchFrom: nil)
            self?.record(.addedWorktree(path: folder.path(percentEncoded: false), branch: branch, label: label),
                         toast: "Added the worktree \(name) with \(branch) · open it from the sidebar")
        }
    }

    /// The folder Add Worktree… suggests: next to this repository, "<repository>-<branch's last part>".
    func suggestedWorktreeFolder(for branch: String) -> URL {
        let parent = URL(filePath: currentWorktreePath, directoryHint: .isDirectory).deletingLastPathComponent()
        let last = branch.split(separator: "/").last.map(String.init) ?? branch
        return parent.appending(path: "\(name)-\(last)", directoryHint: .isDirectory)
    }

    /// Local branches no working tree has checked out (the ones Add Worktree… can use).
    var branchesForNewWorktree: [String] {
        let taken = Set(worktrees.compactMap(\.branch))
        return refs.localBranches.map(\.name).filter { !taken.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

nonisolated extension ReversibleStep {
    /// A worktree was removed (its changes in the stash `stash`). Undo adds it again at the same
    /// folder with its branch (or detached at its commit) and pops the changes there.
    static func removedWorktree(_ worktree: Worktree, stash: String?, label: String) -> ReversibleStep {
        ReversibleStep(label: label) { repository in
            let folder = URL(filePath: worktree.path, directoryHint: .isDirectory)
            guard !FileManager.default.fileExists(atPath: worktree.path) else {
                throw UndoRefusal(message: "Something is at \((worktree.path as NSString).abbreviatingWithTildeInPath) again, so Kaern can’t put the worktree back.")
            }
            if let branch = worktree.branch {
                try await repository.addWorktree(at: folder, branch: branch, newBranchFrom: nil)
            } else if let head = worktree.head {
                try await repository.addWorktree(at: folder, detachedAt: head)
            }
            if let stash {
                let restored = try await GitRepository.open(folder, runner: repository.runner)
                try await restored.popStash(object: stash)
            }
            return ReversibleStep(label: label) { repository in
                let again = try await repository.removeWorktree(worktree.path, keepingChangesAs: "Worktree \(worktree.name)")
                return removedWorktree(worktree, stash: again, label: label)
            }
        }
    }

    /// A worktree was added. Undo removes it while it has no changes of its own.
    static func addedWorktree(path: String, branch: String, label: String) -> ReversibleStep {
        ReversibleStep(label: label) { repository in
            try await repository.removeWorktree(path)
            return ReversibleStep(label: label) { repository in
                try await repository.addWorktree(at: URL(filePath: path, directoryHint: .isDirectory), branch: branch, newBranchFrom: nil)
                return addedWorktree(path: path, branch: branch, label: label)
            }
        }
    }
}
