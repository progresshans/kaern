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
        worktreeChangeReads += 1
        let read = worktreeChangeReads
        var counts: [String: Int] = [:]
        for tree in otherWorktrees where FileManager.default.fileExists(atPath: tree.path) {
            guard let other = try? await GitRepository.open(URL(filePath: tree.path, directoryHint: .isDirectory), runner: runner),
                  let status = try? await other.status(untrackedFiles: .normal) else { continue }
            counts[tree.path] = status.entries.count
        }
        // A read that started later has the newer counts (or will have them).
        guard read == worktreeChangeReads else { return }
        if counts != worktreeChanges { worktreeChanges = counts }
        if let selected = selectedWorktree {
            if otherWorktrees.contains(where: { $0.path == selected }) { await loadWorktreeDetails(selected) } else { selectedWorktree = nil }
        }
    }

    /// While this tab shows (and Settings › Advanced › File changes is on), the other worktrees'
    /// folders are watched: a file saved there updates that worktree's count in the sidebar, as
    /// a file saved here updates this one's status. Ones inside this working tree are left to
    /// its own watcher.
    func updateWorktreeWatching() {
        let root = currentWorktreePath + "/"
        let paths = isVisible && AppSettings.watchesFiles
            ? otherWorktrees.map(\.path).filter { !canonicalPath($0).hasPrefix(root) && FileManager.default.fileExists(atPath: $0) }.sorted()
            : []
        guard paths != watchedWorktreePaths else { return }
        worktreeWatcher?.stop()
        worktreeWatcher = nil
        watchedWorktreePaths = paths
        guard !paths.isEmpty else { return }
        // A second of quiet first: a build writing there shouldn't run git status over and over.
        let watcher = FileSystemWatcher(paths: paths, latency: 1.0) { [weak self] changed in
            // Their git state (`.git` inside them) doesn't change the count of changed files.
            guard changed.contains(where: { !$0.contains("/.git/") && !$0.hasSuffix("/.git") }) else { return }
            Task { @MainActor in await self?.refreshWorktreeChanges() }
        }
        watcher.start()
        worktreeWatcher = watcher
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
    /// lose them with --force) and the files git ignores there go to the Trash (git would delete
    /// them with the folder); ⌘Z puts the worktree back with its branch, changes and those files.
    /// `deletingBranch` (Remove and Delete Branch…): its branch goes too, even unmerged, and the
    /// same ⌘Z brings both back.
    func askRemoveWorktree(_ worktree: Worktree, deletingBranch: Bool = false) {
        guard !worktree.isMain, let runner = repository?.runner else { return }
        let branch = deletingBranch ? worktree.branch : nil
        let unmerged = branch.flatMap { refs.localBranch(named: $0) }.map { !isOnCurrentBranch($0.target) } ?? false
        let changes = worktreeChanges[worktree.path] ?? 0
        Task { [weak self] in
            let ignored = await (try? GitRepository.open(URL(filePath: worktree.path, directoryHint: .isDirectory), runner: runner))?.ignoredItems() ?? []
            guard let self else { return }
            var names = ignored.prefix(3).map { $0.contains("/") ? ($0 as NSString).lastPathComponent : $0 }.joined(separator: ", ")
            if ignored.count > 3 { names += " and \(ignored.count - 3) more" }
            let kept = branch.map { " and the branch \($0)" + (unmerged ? ", which isn’t merged" : "") }
                ?? worktree.branch.map { ". \($0) stays a branch here, and can be checked out again" } ?? ""
            confirmation = Confirmation(
                title: branch.map { "Remove the worktree \(worktree.name) and delete \($0)?" } ?? "Remove the worktree \(worktree.name)?",
                message: "Kaern deletes the folder \(Formatters.abbreviatedPath(worktree.path))" + kept
                    + (changes > 0 ? ". Its \(Formatters.count(changes, "uncommitted change", "uncommitted changes")) go to Stashes first" : "")
                    + (ignored.isEmpty ? "" : ". Files git ignores there (\(names)) go to the Trash")
                    + (branch == nil ? ". ⌘Z puts it back." : ". ⌘Z puts both back."),
                confirmTitle: branch == nil ? "Remove" : "Remove and Delete",
                confirm: { [weak self] in self?.removeWorktree(worktree, deletingBranch: branch) }
            )
        }
    }

    private func removeWorktree(_ worktree: Worktree, deletingBranch branch: String?) {
        let label = branch.map { "Remove Worktree \(worktree.name) and \($0)" } ?? "Remove Worktree \(worktree.name)"
        let upstream = branch.flatMap { refs.localBranch(named: $0)?.upstream }
        let unmerged = branch.flatMap { refs.localBranch(named: $0) }.map { !isOnCurrentBranch($0.target) } ?? false
        perform(.working("Removing \(worktree.name)…"), trigger: label) { [weak self] repository in
            let removed = try await repository.removeWorktree(worktree.path, keepingChangesAs: "Worktree \(worktree.name)")
            guard let self else { return }
            if self.selectedWorktree == worktree.path { self.selectedWorktree = nil }
            var kept: [String] = []
            if removed.stash != nil { kept.append("its changes are in Stashes") }
            if !removed.trashed.isEmpty { kept.append("ignored files are in the Trash") }
            let keptNote = kept.isEmpty ? "" : " · " + kept.joined(separator: ", ")
            let removal = ReversibleStep.removedWorktree(path: worktree.path, name: worktree.name, removed: removed, label: label)
            guard let branch else {
                self.record(removal, toast: "Removed the worktree \(worktree.name)" + keptNote)
                return
            }
            // The tip as git has it now: ⌘Z makes the branch again there (Delete does the same).
            let tip = await repository.resolve("refs/heads/\(branch)") ?? removed.head
            do {
                try await repository.deleteBranch(branch, force: true)
            } catch {
                // The worktree is gone and its branch stays: ⌘Z still brings the worktree back.
                self.record(removal, toast: "Removed the worktree \(worktree.name)" + keptNote)
                throw error
            }
            self.record(.both(removal, then: .deletedBranch(name: branch, tip: tip, upstream: upstream), label: label),
                        toast: "Removed the worktree \(worktree.name) and deleted \(branch)" + (unmerged ? " (it wasn’t merged)" : "") + keptNote)
        }
    }

    /// Lock / Unlock: git leaves a locked worktree alone (`git worktree remove` and `prune` refuse
    /// it), and so does Remove… here until it's unlocked. The main worktree can't be locked.
    func setWorktreeLocked(_ worktree: Worktree, _ locked: Bool) {
        guard !worktree.isMain else { return }
        let label = "\(locked ? "Lock" : "Unlock") Worktree \(worktree.name)"
        perform(.working("\(locked ? "Locking" : "Unlocking") \(worktree.name)…"), trigger: label) { [weak self] repository in
            if locked { try await repository.lockWorktree(worktree.path) } else { try await repository.unlockWorktree(worktree.path) }
            self?.record(.lockedWorktree(path: worktree.path, locked: locked, label: label),
                         toast: locked ? "Locked \(worktree.name) · it can’t be removed until it’s unlocked" : "Unlocked \(worktree.name)")
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
    /// A worktree was removed (`removed`: where its HEAD was, its stash, its ignored files in the
    /// Trash). Undo adds it again at the same folder, on its branch or detached at its commit, and
    /// brings back its changes and those files; redo removes it the same careful way.
    static func removedWorktree(path: String, name: String, removed: RemovedWorktree, label: String) -> ReversibleStep {
        ReversibleStep(label: label) { repository in
            let folder = URL(filePath: path, directoryHint: .isDirectory)
            guard !FileManager.default.fileExists(atPath: path) else {
                throw UndoRefusal(message: "Something is at \(Formatters.abbreviatedPath(path)) again, so Kaern can’t put the worktree back.")
            }
            if let branch = removed.branch {
                try await repository.addWorktree(at: folder, branch: branch, newBranchFrom: nil)
            } else {
                try await repository.addWorktree(at: folder, detachedAt: removed.head)
            }
            let restored = try await GitRepository.open(folder, runner: repository.runner)
            GitRepository.putBack(removed.trashed, into: restored.root)
            if let stash = removed.stash { try await restored.popStash(object: stash) }
            return ReversibleStep(label: label) { repository in
                let again = try await repository.removeWorktree(path, keepingChangesAs: "Worktree \(name)")
                return removedWorktree(path: path, name: name, removed: again, label: label)
            }
        }
    }

    /// A worktree was locked (`locked`) or unlocked: undo does the other.
    static func lockedWorktree(path: String, locked: Bool, label: String) -> ReversibleStep {
        ReversibleStep(label: label) { repository in
            if locked { try await repository.unlockWorktree(path) } else { try await repository.lockWorktree(path) }
            return lockedWorktree(path: path, locked: !locked, label: label)
        }
    }

    /// Two actions done in that order, taken back as one (Remove and Delete Branch…): `first` and
    /// `second` take back each. Undo takes back the second, then the first, and redo does them
    /// again in order; when the other half fails, the half already done is put back as it was.
    static func both(_ first: ReversibleStep, then second: ReversibleStep, label: String) -> ReversibleStep {
        ReversibleStep(label: label) { repository in
            let secondAgain = try await second.run(repository)
            let firstAgain: ReversibleStep
            do { firstAgain = try await first.run(repository) } catch { _ = try? await secondAgain.run(repository); throw error }
            return ReversibleStep(label: label) { repository in
                let firstBack = try await firstAgain.run(repository)
                let secondBack: ReversibleStep
                do { secondBack = try await secondAgain.run(repository) } catch { _ = try? await firstBack.run(repository); throw error }
                return both(firstBack, then: secondBack, label: label)
            }
        }
    }

    /// A worktree was added. Undo removes it only while it's as it was made: on `branch`, with no
    /// changes and no files git ignores (a removal would lose work done there since).
    static func addedWorktree(path: String, branch: String, label: String) -> ReversibleStep {
        ReversibleStep(label: label) { repository in
            let worktree = try await repository.linkedWorktree(at: path)
            let name = (path as NSString).lastPathComponent
            let status = try? await worktree.status(untrackedFiles: .normal)
            let ignored = await worktree.ignoredItems()
            guard let status, status.entries.isEmpty, ignored.isEmpty, await worktree.currentBranchName() == branch else {
                throw UndoRefusal(message: "\(name) has work of its own since “\(label)”, so Kaern won’t take it back. Use Remove… instead.")
            }
            try await repository.removeWorktree(path)
            return ReversibleStep(label: label) { repository in
                try await repository.addWorktree(at: URL(filePath: path, directoryHint: .isDirectory), branch: branch, newBranchFrom: nil)
                return addedWorktree(path: path, branch: branch, label: label)
            }
        }
    }
}
