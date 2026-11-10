import Foundation
import KaernKit

/// Where HEAD is: on a branch, or detached at a commit.
nonisolated enum HeadPosition: Equatable, Sendable {
    case branch(String)
    case detached(String)

    var name: String {
        switch self {
        case .branch(let name): name
        case .detached(let id): String(id.prefix(7))
        }
    }

    /// On `branch`, or detached at `id` when there's none.
    init(branch: String?, id: String) {
        self = branch.map { .branch($0) } ?? .detached(id)
    }
}

/// The toast at the bottom of the window (`.toast`), with Undo when the action can be taken back.
struct Toast: Equatable, Identifiable {
    let id = UUID()
    var message: String
    var canUndo: Bool
}

/// One step ⌘Z (or ⇧⌘Z) can take: running it reverses an action and returns the step that
/// reverses it again. Each step first checks that the repository is still where the action
/// left it, and refuses with a message instead of guessing.
nonisolated struct ReversibleStep: Sendable {
    /// "Checkout develop": the toolbar says "Undo Checkout develop".
    let label: String
    let run: @Sendable (GitRepository) async throws -> ReversibleStep
}

/// Why ⌘Z couldn't take an action back.
nonisolated struct UndoRefusal: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

nonisolated extension ReversibleStep {
    // MARK: Checks

    static func requireHead(_ repository: GitRepository, branch: String?, at commit: String, _ label: String) async throws {
        let current = await repository.currentBranchName()
        let head = await repository.resolve("HEAD")
        guard current == branch, head == commit else {
            throw UndoRefusal(message: branch.map { "\($0) moved since “\(label)”, so Kaern can’t take it back." }
                ?? "HEAD moved since “\(label)”, so Kaern can’t take it back.")
        }
    }

    static func requirePosition(_ repository: GitRepository, _ position: HeadPosition, _ label: String) async throws {
        let current = await repository.currentBranchName()
        switch position {
        case .branch(let name):
            guard current == name else {
                throw UndoRefusal(message: "You’re not on \(name) anymore, so Kaern can’t take back “\(label)”.")
            }
        case .detached(let id):
            let head = await repository.resolve("HEAD")
            guard current == nil, head == id else {
                throw UndoRefusal(message: "HEAD moved since “\(label)”, so Kaern can’t take it back.")
            }
        }
    }

    static func go(to position: HeadPosition, in repository: GitRepository) async throws {
        switch position {
        case .branch(let name): try await repository.switchBranch(name)
        case .detached(let id): try await repository.detach(at: id)
        }
    }

    // MARK: Steps

    /// A branch (or a detached HEAD) moved from `from` to `to`: commits were added on top
    /// (cherry-pick, revert, merge, pull) or replayed (rebase). Undo moves it back with
    /// `git reset --keep`, which keeps uncommitted changes.
    static func moveBranch(label: String, branch: String?, from: String, to: String) -> ReversibleStep {
        ReversibleStep(label: label) { repository in
            try await requireHead(repository, branch: branch, at: to, label)
            try await repository.resetKeepingStaged(to: from)
            return ReversibleStep(label: label) { repository in
                try await requireHead(repository, branch: branch, at: from, label)
                try await repository.resetKeepingStaged(to: to)
                return moveBranch(label: label, branch: branch, from: from, to: to)
            }
        }
    }

    /// Like `moveBranch`, when the uncommitted changes had to stay in the stash list (they touch
    /// files the action changed): ⌘Z moves the branch back and pops them; ⇧⌘Z puts them aside
    /// again and moves the branch forward.
    static func moveBranchKeepingStash(label: String, branch: String?, from: String, to: String, stash: String) -> ReversibleStep {
        ReversibleStep(label: label) { repository in
            try await requireHead(repository, branch: branch, at: to, label)
            try await repository.resetKeepingStaged(to: from)
            try await repository.popStash(object: stash)
            return ReversibleStep(label: label) { repository in
                try await requireHead(repository, branch: branch, at: from, label)
                guard let again = try await repository.stashAll(message: "Before \(label)", includeUntracked: false) else {
                    try await repository.resetKeepingStaged(to: to)
                    return moveBranch(label: label, branch: branch, from: from, to: to)
                }
                try await repository.resetKeepingStaged(to: to)
                return moveBranchKeepingStash(label: label, branch: branch, from: from, to: to, stash: again)
            }
        }
    }

    /// HEAD went from one branch (or commit) to another.
    static func checkout(label: String, from: HeadPosition, to: HeadPosition) -> ReversibleStep {
        ReversibleStep(label: label) { repository in
            try await requirePosition(repository, to, label)
            try await go(to: from, in: repository)
            return ReversibleStep(label: label) { repository in
                try await requirePosition(repository, from, label)
                try await go(to: to, in: repository)
                return checkout(label: label, from: from, to: to)
            }
        }
    }

    /// Update to Recorded moved the submodule at `path` from `from` to `commit` (detached).
    /// Undo checks out what it had before, which also brings back commits no branch held.
    static func submoduleCheckout(label: String, path: String, from: HeadPosition, to commit: String) -> ReversibleStep {
        ReversibleStep(label: label) { repository in
            let submodule = try await repository.submodule(at: path)
            try await requirePosition(submodule, .detached(commit), label)
            try await go(to: from, in: submodule)
            return ReversibleStep(label: label) { repository in
                let submodule = try await repository.submodule(at: path)
                try await requirePosition(submodule, from, label)
                try await go(to: .detached(commit), in: submodule)
                return submoduleCheckout(label: label, path: path, from: from, to: commit)
            }
        }
    }

    /// A branch was made at `tip` and checked out. Undo goes back and deletes it.
    static func createdBranch(label: String, name: String, at tip: String, upstream: String?, previous: HeadPosition) -> ReversibleStep {
        ReversibleStep(label: label) { repository in
            try await requireHead(repository, branch: name, at: tip, label)
            try await go(to: previous, in: repository)
            try await repository.deleteBranch(name, force: true)
            return ReversibleStep(label: label) { repository in
                try await requirePosition(repository, previous, label)
                try await repository.createBranch(name, startPoint: tip, checkout: true)
                if let upstream { try await repository.setUpstream(of: name, to: upstream) }
                return createdBranch(label: label, name: name, at: tip, upstream: upstream, previous: previous)
            }
        }
    }

    /// A branch that wasn't checked out was deleted. Undo makes it again at the same commit,
    /// tracking what it tracked.
    static func deletedBranch(name: String, tip: String, upstream: String?) -> ReversibleStep {
        let label = "Delete \(name)"
        return ReversibleStep(label: label) { repository in
            try await repository.createBranch(name, startPoint: tip, checkout: false)
            if let upstream { try? await repository.setUpstream(of: name, to: upstream) }
            return ReversibleStep(label: label) { repository in
                guard await repository.resolve("refs/heads/\(name)") == tip else {
                    throw UndoRefusal(message: "\(name) moved since, so Kaern won’t delete it again.")
                }
                try await repository.deleteBranch(name, force: true)
                return deletedBranch(name: name, tip: tip, upstream: upstream)
            }
        }
    }

    static func renamedBranch(from old: String, to new: String) -> ReversibleStep {
        let label = "Rename \(old)"
        return ReversibleStep(label: label) { repository in
            try await repository.renameBranch(new, to: old)
            return ReversibleStep(label: label) { repository in
                try await repository.renameBranch(old, to: new)
                return renamedBranch(from: old, to: new)
            }
        }
    }

    static func createdTag(name: String, object: String) -> ReversibleStep {
        let label = "Create Tag \(name)"
        return ReversibleStep(label: label) { repository in
            guard await repository.resolve("refs/tags/\(name)") == object else {
                throw UndoRefusal(message: "The tag \(name) changed since, so Kaern won’t delete it.")
            }
            try await repository.deleteTag(name)
            return ReversibleStep(label: label) { repository in
                try await repository.restoreTag(name, object: object)
                return createdTag(name: name, object: object)
            }
        }
    }

    /// Reset Branch to Here. Soft and Mixed keep the changes; Hard stashed them first, and Undo
    /// puts them back after moving the branch back.
    static func reset(label: String, branch: String?, from: String, to: String, mode: GitRepository.ResetMode,
                      indexBefore: String?, stash: String?) -> ReversibleStep {
        ReversibleStep(label: label) { repository in
            try await requireHead(repository, branch: branch, at: to, label)
            switch mode {
            case .soft:
                try await repository.reset(to: from, mode: .soft)
            case .mixed:
                try await repository.reset(to: from, mode: .soft)
                if let indexBefore {
                    let paths = try await repository.indexDifferences(from: indexBefore)
                    try await repository.restoreIndex(paths: paths, from: indexBefore)
                }
            case .hard, .keep:
                try await repository.resetKeepingStaged(to: from)
                if let stash { try await repository.popStash(object: stash) }
            }
            return ReversibleStep(label: label) { repository in
                try await requireHead(repository, branch: branch, at: from, label)
                var newStash: String?
                if mode == .hard {
                    newStash = try await repository.stashAll(message: "Before reset to \(to.prefix(7))", includeUntracked: false)
                }
                let index = mode == .mixed ? await repository.writeIndexTree() : nil
                try await repository.reset(to: to, mode: mode)
                return reset(label: label, branch: branch, from: from, to: to, mode: mode, indexBefore: index ?? indexBefore,
                             stash: newStash)
            }
        }
    }

    /// A commit (or an amend) moved the branch from `from` to `to`. Undo is a soft reset: the
    /// changes are staged again, as they were before committing.
    static func committed(label: String, branch: String?, from: String, to: String) -> ReversibleStep {
        ReversibleStep(label: label) { repository in
            try await requireHead(repository, branch: branch, at: to, label)
            try await repository.reset(to: from, mode: .soft)
            return ReversibleStep(label: label) { repository in
                try await requireHead(repository, branch: branch, at: from, label)
                guard let tree = await repository.treeID(of: to), await repository.writeIndexTree() == tree else {
                    throw UndoRefusal(message: "The staged changes changed since, so Kaern can’t make “\(label)” again.")
                }
                try await repository.reset(to: to, mode: .soft)
                return committed(label: label, branch: branch, from: from, to: to)
            }
        }
    }

    /// Staging or unstaging changed the index entries of `paths` from `before` to `after`.
    static func index(label: String, paths: [String], before: String, after: String) -> ReversibleStep {
        ReversibleStep(label: label) { repository in
            guard await repository.indexMatches(after, paths: paths) else {
                throw UndoRefusal(message: "What’s staged changed since “\(label)”, so Kaern can’t take it back.")
            }
            try await repository.restoreIndex(paths: paths, from: before)
            return ReversibleStep(label: label) { repository in
                guard await repository.indexMatches(before, paths: paths) else {
                    throw UndoRefusal(message: "What’s staged changed since, so Kaern can’t do “\(label)” again.")
                }
                try await repository.restoreIndex(paths: paths, from: after)
                return index(label: label, paths: paths, before: before, after: after)
            }
        }
    }

    static func discarded(label: String, record: DiscardRecord, message: String) -> ReversibleStep {
        ReversibleStep(label: label) { repository in
            try await repository.restore(record)
            return ReversibleStep(label: label) { repository in
                let again = try await repository.discardAgain(record, message: message)
                return discarded(label: label, record: again, message: message)
            }
        }
    }

    static func discardedLines(label: String, path: String, patch: String, stash: String?, message: String) -> ReversibleStep {
        ReversibleStep(label: label) { repository in
            try await repository.restoreDiscardedLines(patch)
            if let stash { try? await repository.dropStash(object: stash) }
            return ReversibleStep(label: label) { repository in
                let copy = try await repository.snapshotStash(paths: [path], message: message, includeUntracked: false)
                try await repository.apply(patch: patch, cached: false, reverse: true)
                return discardedLines(label: label, path: path, patch: patch, stash: copy, message: message)
            }
        }
    }

    static func ignored(edit: IgnoreEdit) -> ReversibleStep {
        let label = "Ignore \(edit.pattern)"
        return ReversibleStep(label: label) { repository in
            guard repository.ignoreFileContents() == edit.written else {
                throw UndoRefusal(message: ".gitignore changed since “\(label)”, so Kaern can’t take it back.")
            }
            try repository.restoreIgnoreFile(edit)
            return ReversibleStep(label: label) { repository in
                let again = try repository.addIgnorePattern(edit.pattern)
                return ignored(edit: again)
            }
        }
    }

    /// Stash Changes made `object`. Undo pops it.
    static func stashed(object: String) -> ReversibleStep {
        let label = "Stash Changes"
        return ReversibleStep(label: label) { repository in
            try await repository.popStash(object: object)
            return ReversibleStep(label: label) { repository in
                guard let again = try await repository.stashAll(message: "", includeUntracked: true) else {
                    throw UndoRefusal(message: "There’s nothing to stash anymore.")
                }
                return stashed(object: again)
            }
        }
    }

    /// A stash was applied or popped.
    static func applied(_ applied: AppliedStash) -> ReversibleStep {
        let label = (applied.popped ? "Pop " : "Apply ") + applied.stash.reference
        return ReversibleStep(label: label) { repository in
            try await repository.unapply(applied)
            return ReversibleStep(label: label) { repository in
                guard let stash = await repository.stash(withObject: applied.stash.id),
                      let again = try await repository.applyStashUndoably(stash, pop: applied.popped) else {
                    throw UndoRefusal(message: "Kaern can’t apply \(applied.stash.reference) again.")
                }
                return ReversibleStep.applied(again)
            }
        }
    }

    static func droppedStash(_ stash: Stash) -> ReversibleStep {
        let label = "Drop \(stash.reference)"
        return ReversibleStep(label: label) { repository in
            try await repository.storeStash(stash.id, message: stash.message)
            return ReversibleStep(label: label) { repository in
                try await repository.dropStash(object: stash.id)
                return droppedStash(stash)
            }
        }
    }

    /// A branch was made without switching to it; ⌘Z deletes it, ⇧⌘Z makes it again.
    static func createdBranchOnly(label: String, name: String, at tip: String) -> ReversibleStep {
        ReversibleStep(label: label) { repository in
            guard await repository.resolve("refs/heads/\(name)") == tip else {
                throw UndoRefusal(message: "\(name) moved since it was created, so Kaern can’t take it back.")
            }
            try await repository.deleteBranch(name, force: true)
            return ReversibleStep(label: label) { repository in
                try await repository.createBranch(name, startPoint: tip, checkout: false)
                return createdBranchOnly(label: label, name: name, at: tip)
            }
        }
    }

    /// A stash got a new message; ⌘Z gives it the old one back (it keeps its place).
    static func renamedStash(object: String, from: String, to: String) -> ReversibleStep {
        let label = "Rename Stash"
        return ReversibleStep(label: label) { repository in
            guard let stash = await repository.stash(withObject: object), stash.message == to else {
                throw UndoRefusal(message: "That stash changed since it was renamed, so Kaern can’t take it back.")
            }
            try await repository.renameStash(stash, to: from)
            return ReversibleStep(label: label) { repository in
                guard let stash = await repository.stash(withObject: object) else {
                    throw UndoRefusal(message: "That stash isn’t in the list anymore.")
                }
                try await repository.renameStash(stash, to: to)
                return renamedStash(object: object, from: from, to: to)
            }
        }
    }
}

// MARK: - ⌘Z on the repository

extension RepositoryModel {
    var canUndo: Bool { !undoSteps.isEmpty && activity == nil && isReady }
    var canRedo: Bool { !redoSteps.isEmpty && activity == nil && isReady }

    /// "Undo Checkout develop" / "Nothing to Undo" (toolbar tooltip, Edit menu).
    var undoTitle: String { undoSteps.last.map { "Undo \($0.label)" } ?? "Nothing to Undo" }
    var redoTitle: String { redoSteps.last.map { "Redo \($0.label)" } ?? "Nothing to Redo" }

    /// HEAD when an action runs, read from git: its branch (`nil` when detached) and its commit
    /// (`nil` on an unborn branch). The status an action was asked from can be older than the
    /// repository (a refresh still reading, the file watcher off, something done in Terminal a
    /// moment ago), so what an action records for ⌘Z comes from here.
    static func headNow(in repository: GitRepository) async -> (branch: String?, id: String)? {
        guard let id = await repository.resolve("HEAD") else { return nil }
        return (await repository.currentBranchName(), id)
    }

    /// Where HEAD is now, as the status shows it.
    var headPosition: HeadPosition? {
        switch status.head {
        case .branch(let name): .branch(name)
        case .detached(let id): id.isEmpty ? nil : .detached(id)
        case .unborn: nil
        }
    }

    /// Adds a step ⌘Z can take back and shows the toast (with Undo when there's a step).
    func record(_ step: ReversibleStep?, toast message: String?) {
        if let step {
            undoSteps.append(step)
            if undoSteps.count > 30 { undoSteps.removeFirst(undoSteps.count - 30) }
            redoSteps.removeAll()
        }
        if let message { showToast(message, undo: step != nil) }
    }

    /// Records a quiet step (staging): ⌘Z takes it back, no toast.
    func recordQuietly(_ step: ReversibleStep) {
        undoSteps.append(step)
        if undoSteps.count > 30 { undoSteps.removeFirst(undoSteps.count - 30) }
        redoSteps.removeAll()
    }

    func showToast(_ message: String, undo: Bool = false) {
        toast = Toast(message: message, canUndo: undo)
        toastTask?.cancel()
        let id = toast?.id
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(undo ? 5.2 : 3.2))
            guard !Task.isCancelled, self?.toast?.id == id else { return }
            self?.toast = nil
        }
    }

    func undo() {
        guard canUndo, let step = undoSteps.popLast() else { return }
        toast = nil
        perform(.working("Undoing \(step.label)…"), trigger: "Undo \(step.label)") { [weak self] repository in
            let redo = try await step.run(repository)
            self?.redoSteps.append(redo)
            self?.showToast("Undid " + Self.lowercasedFirst(step.label))
        } onFailure: { [weak self] error in
            self?.alert = RepositoryAlert(title: "Couldn’t undo “\(step.label)”", message: error.localizedDescription)
            return true
        }
    }

    func redo() {
        guard canRedo, let step = redoSteps.popLast() else { return }
        toast = nil
        perform(.working("Redoing \(step.label)…"), trigger: "Redo \(step.label)") { [weak self] repository in
            let undo = try await step.run(repository)
            self?.undoSteps.append(undo)
            self?.showToast("Redid " + Self.lowercasedFirst(step.label))
        } onFailure: { [weak self] error in
            self?.alert = RepositoryAlert(title: "Couldn’t redo “\(step.label)”", message: error.localizedDescription)
            return true
        }
    }

    static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        // Keep names that start with a capital in the middle of a label ("Undid checkout develop").
        return first.lowercased() + text.dropFirst()
    }
}
