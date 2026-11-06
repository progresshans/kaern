import AppKit
import KaernKit

/// What ⌘Z would take back, shown for a few seconds in the status bar.
struct UndoHint: Equatable {
    var text: String
    var date: Date
}

// MARK: - Undo (⌘Z)

/// Local-only changes (discard, checkout, reset, deleting a branch or tag, dropping a stash,
/// merge, rebase, commit…) don't ask first; they register a way back on the window's undo
/// manager instead. Before each step Kaern notes where HEAD and the branches were; working-copy
/// changes that would be lost are kept in a "Before …" stash.
extension RepositoryModel {
    /// Registers the way back for a change that just happened: Edit › Undo <name> (⌘Z).
    func registerUndo(_ name: String, hint: String, undo: @escaping @MainActor @Sendable (RepositoryModel) async -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.undoHint = nil
                Task { await undo(model) }
            }
        }
        undoManager.setActionName(name)
        showUndoHint(hint)
    }

    /// Runs one undo step like any other operation. With `expectHead`, only while HEAD is still
    /// where the change left it: otherwise newer work would be thrown away.
    func undoStep(_ name: String, expectHead: String? = nil, _ work: (GitRepository) async throws -> Void) async {
        if let expectHead, status.headID != expectHead {
            alert = AlertItem(
                title: String(localized: "Can't Undo \(name)"),
                message: String(localized: "HEAD moved since then (a new commit, a checkout or a pull), so undoing would throw that work away.")
            )
            return
        }
        await perform(.working(String(localized: "Undoing \(name)…")), failureTitle: String(localized: "Couldn't Undo \(name)"), work)
    }

    func showUndoHint(_ text: String) {
        let hint = UndoHint(text: text, date: .now)
        undoHint = hint
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if self?.undoHint == hint { self?.undoHint = nil }
        }
    }

    /// After a merge, rebase, cherry-pick or revert: undo aborts it while it waits on conflicts,
    /// or moves the branch back once it's done.
    func registerHistoryUndo(_ name: String, hint: String, before: String?) {
        guard let before else { return }
        if let operation {
            let kind = operation.kind
            registerUndo(name, hint: hint) { model in
                guard model.operation?.kind == kind else {
                    NSSound.beep()
                    return
                }
                await model.abortOperation()
            }
        } else if let after = status.headID, after != before {
            registerUndo(name, hint: hint) { model in
                await model.undoStep(name, expectHead: after) { repository in
                    try await repository.reset(to: before, mode: .keep)
                }
            }
        }
    }

    // MARK: Reset

    /// Soft and mixed resets keep every change, so they just happen. Hard asks once — Cancel is
    /// the default — because it also puts the uncommitted changes aside.
    func requestReset(to commit: Commit, mode: GitRepository.ResetMode) {
        guard mode == .hard else {
            Task { await reset(to: commit, mode: mode) }
            return
        }
        Task {
            guard let repository else { return }
            let leaving = await repository.countCommits(from: commit.id, to: "HEAD")
            confirmation = .resetHard(commit, leaving: leaving)
        }
    }

    func reset(to commit: Commit, mode: GitRepository.ResetMode) async {
        guard let previous = status.headID else { return }
        let branch = currentBranchTitle
        let hasChanges = status.entries.contains { !$0.isUntracked }
        var stashObject: String?
        let done = await perform(.working(String(localized: "Resetting \(branch) to \(commit.shortID)…")), failureTitle: String(localized: "Couldn't Reset “\(branch)”")) { repository in
            if mode == .hard, hasChanges {
                stashObject = try await repository.stashAll(message: "Before reset to \(commit.shortID)", includeUntracked: false)
            }
            try await repository.reset(to: commit.id, mode: mode)
        }
        guard done else { return }
        let kept = stashObject
        registerUndo(String(localized: "Reset"), hint: String(localized: "Reset \(branch) to \(commit.shortID)")) { model in
            if mode == .hard, model.status.entries.contains(where: { !$0.isUntracked }) {
                model.alert = AlertItem(
                    title: String(localized: "Can't Undo Reset"),
                    message: String(localized: "There are new uncommitted changes. Commit or stash them first, then undo again.")
                )
                return
            }
            await model.undoStep(String(localized: "Reset"), expectHead: commit.id) { repository in
                try await repository.reset(to: previous, mode: mode)
                if let kept {
                    try await repository.popStash(object: kept)
                }
            }
        }
    }
}
