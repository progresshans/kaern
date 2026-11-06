import KaernKit
import SwiftUI

// MARK: - Branches, stashes and commits

extension RepositoryModel {
    /// Switches to `ref`, asking what to do with uncommitted changes when needed.
    /// The other working tree that has `branch` checked out (git refuses to check it out twice).
    func worktree(using branch: String) -> Worktree? {
        let here = repository?.root.plainPath
        return worktrees.first { $0.branch == branch && $0.path != here && URL(filePath: $0.path).plainPath != here }
    }

    func requestSwitch(to ref: Ref) {
        if ref.kind == .localBranch, ref.isHead { return }
        let target = ref.kind == .remoteBranch ? ref.branchName : ref.name
        if let other = worktree(using: target) {
            alert = AlertItem(
                title: String(localized: "“\(target)” Is Checked Out in \(title(of: other))"),
                message: String(localized: "Git doesn't let two working trees use the same branch. Open \(title(of: other)) to work on it, or create another branch from it.")
            )
            return
        }
        let hasTrackedChanges = status.entries.contains { !$0.isUntracked }
        guard hasTrackedChanges else {
            Task { await switchBranch(to: ref, stashingChanges: false) }
            return
        }
        switch Preferences.branchSwitch {
        case .ask: sheet = .switchWithChanges(ref)
        case .stash: Task { await switchBranch(to: ref, stashingChanges: true) }
        case .bring: Task { await switchBranch(to: ref, stashingChanges: false) }
        }
    }

    func switchBranch(to ref: Ref, stashingChanges: Bool) async {
        let target = ref.kind == .remoteBranch ? ref.branchName : ref.name
        let existingLocal = ref.kind == .remoteBranch ? refs.localBranch(named: ref.branchName) : nil
        let previous = status.branch ?? status.headID
        let wasDetached = status.branch == nil
        var stashObject: String?
        let switched = await perform(.switching(target), failureTitle: String(localized: "Couldn't Switch to “\(target)”")) { repository in
            if stashingChanges {
                stashObject = try await repository.stashAll(message: "Before switching to \(target)", includeUntracked: true)
            }
            switch ref.kind {
            case .localBranch:
                try await repository.switchBranch(ref.name)
            case .remoteBranch:
                if let existingLocal {
                    try await repository.switchBranch(existingLocal.name)
                } else {
                    try await repository.switchToRemoteBranch(ref.name, localName: ref.branchName)
                }
            case .tag:
                try await repository.detach(at: ref.fullName)
            }
        }
        guard switched else { return }
        selection = .workingCopy
        registerSwitchBack(to: previous, detached: wasDetached, popping: stashObject, hint: String(localized: "Switched to \(target)"))
    }

    /// ⌘Z after a checkout: back to the previous branch (or commit), with the stash Kaern made on
    /// the way out applied again.
    private func registerSwitchBack(to previous: String?, detached: Bool, popping stashObject: String?, hint: String) {
        guard let previous else { return }
        registerUndo(String(localized: "Checkout"), hint: hint) { model in
            await model.undoStep(String(localized: "Checkout")) { repository in
                if detached {
                    try await repository.detach(at: previous)
                } else {
                    try await repository.switchBranch(previous)
                }
                if let stashObject {
                    try await repository.popStash(object: stashObject)
                }
            }
        }
    }

    func checkOut(commit: Commit) async {
        let previous = status.branch ?? status.headID
        let wasDetached = status.branch == nil
        let switched = await perform(.switching(commit.shortID), failureTitle: String(localized: "Couldn't Check Out \(commit.shortID)")) { repository in
            try await repository.detach(at: commit.id)
        }
        if switched {
            registerSwitchBack(to: previous, detached: wasDetached, popping: nil, hint: String(localized: "Checked out \(commit.shortID)"))
        }
    }

    @discardableResult
    func createBranch(named name: String, startPoint: String?, checkout: Bool) async -> Bool {
        let previous = status.branch ?? status.headID
        let wasDetached = status.branch == nil
        let created = await perform(.working(String(localized: "Creating \(name)…")), failureTitle: String(localized: "Couldn't Create Branch")) { repository in
            try await repository.createBranch(name, startPoint: startPoint, checkout: checkout)
        }
        guard created, let object = refs.localBranch(named: name)?.target else { return created }
        registerUndo(String(localized: "New Branch"), hint: String(localized: "Created \(name)")) { model in
            await model.undoStep(String(localized: "New Branch")) { repository in
                guard await repository.resolve("refs/heads/\(name)") == object else {
                    throw GitError(arguments: ["branch"], status: -1, message: String(localized: "“\(name)” has new commits since it was created."))
                }
                if checkout, let previous {
                    if wasDetached {
                        try await repository.detach(at: previous)
                    } else {
                        try await repository.switchBranch(previous)
                    }
                }
                try await repository.deleteBranch(name, force: true)
            }
        }
        return true
    }

    /// Deletes right away when git would (the branch is merged); asks first when it isn't.
    func requestDeleteBranch(_ ref: Ref) {
        guard let repository, !ref.isHead else { return }
        Task {
            let base = ref.upstream ?? "HEAD"
            if await repository.isAncestor(ref.target, of: base) {
                await deleteBranch(ref, force: false)
            } else {
                confirmation = .forceDeleteBranch(ref)
            }
        }
    }

    func deleteBranch(_ ref: Ref, force: Bool = false) async {
        let deleted = await perform(.working(String(localized: "Deleting \(ref.name)…")), failureTitle: String(localized: "Couldn't Delete “\(ref.name)”")) { repository in
            try await repository.deleteBranch(ref.name, force: force)
        }
        guard deleted else { return }
        let object = ref.target
        let upstream = ref.upstream
        registerUndo(String(localized: "Delete Branch"), hint: String(localized: "Deleted \(ref.name)")) { model in
            await model.undoStep(String(localized: "Delete Branch")) { repository in
                try await repository.createBranch(ref.name, startPoint: object, checkout: false)
                if let upstream {
                    try? await repository.setUpstream(of: ref.name, to: upstream)
                }
            }
        }
    }

    @discardableResult
    func renameBranch(_ ref: Ref, to newName: String) async -> Bool {
        let renamed = await perform(.working(String(localized: "Renaming \(ref.name)…")), failureTitle: String(localized: "Couldn't Rename “\(ref.name)”")) { repository in
            try await repository.renameBranch(ref.name, to: newName)
        }
        if renamed {
            // Keep the renamed branch's folders open in the sidebar.
            didRenameBranch(from: ref.name, to: newName)
            let oldName = ref.name
            registerUndo(String(localized: "Rename Branch"), hint: String(localized: "Renamed \(oldName) to \(newName)")) { model in
                await model.undoStep(String(localized: "Rename Branch")) { repository in
                    try await repository.renameBranch(newName, to: oldName)
                }
            }
        }
        return renamed
    }

    func deleteRemoteBranch(_ ref: Ref) async {
        guard let remote = ref.remoteName else { return }
        await perform(.pushing, failureTitle: String(localized: "Couldn't Delete “\(ref.name)”")) { repository in
            try await repository.deleteRemoteBranch(ref.branchName, on: remote)
        }
    }

    // MARK: Tags

    /// Where new tags are pushed: the upstream's remote, else origin, else the first remote.
    var defaultRemote: String? {
        upstreamRemote ?? (remotes.contains("origin") ? "origin" : remotes.first)
    }

    @discardableResult
    func createTag(named name: String, at commitID: String, message: String?, push: Bool) async -> Bool {
        let remote = push ? defaultRemote : nil
        let created = await perform(.working(String(localized: "Creating tag \(name)…")), failureTitle: String(localized: "Couldn't Create Tag “\(name)”")) { repository in
            try await repository.createTag(name, at: commitID, message: message)
            if let remote {
                try await repository.pushTag(name, to: remote)
            }
        }
        // A pushed tag is on the remote too; taking back only the local one would be misleading.
        if created, remote == nil {
            registerUndo(String(localized: "New Tag"), hint: String(localized: "Tagged \(name)")) { model in
                await model.undoStep(String(localized: "New Tag")) { repository in
                    try await repository.deleteTag(name)
                }
            }
        }
        return created
    }

    func deleteTag(_ ref: Ref) async {
        guard let repository, let object = await repository.resolve(ref.fullName) else { return }
        let deleted = await perform(.working(String(localized: "Deleting tag \(ref.name)…")), failureTitle: String(localized: "Couldn't Delete Tag “\(ref.name)”")) { repository in
            try await repository.deleteTag(ref.name)
        }
        guard deleted else { return }
        registerUndo(String(localized: "Delete Tag"), hint: String(localized: "Deleted tag \(ref.name)")) { model in
            await model.undoStep(String(localized: "Delete Tag")) { repository in
                try await repository.restoreTag(ref.name, object: object)
            }
        }
    }

    func pushTag(_ ref: Ref) async {
        guard let remote = defaultRemote else { return }
        await perform(.pushing, failureTitle: String(localized: "Couldn't Push Tag “\(ref.name)”")) { repository in
            try await repository.pushTag(ref.name, to: remote)
        }
    }

    /// The next version tag, from the existing tags.
    var suggestedTagName: String {
        TagNaming.suggestion(after: refs.tags.map(\.name)) ?? ""
    }

    // MARK: Merge and rebase

    /// "feature/x", or "HEAD" when detached.
    var currentBranchTitle: String {
        if operation?.kind == .rebase, let branch = operation?.branch { return branch }
        return status.branch ?? "HEAD"
    }

    /// Uses the short name: git writes it into the merge message ("Merge branch 'develop'").
    func merge(_ ref: Ref, noFastForward: Bool = false) async {
        await merge(ref.name, named: ref.name, noFastForward: noFastForward)
    }

    func rebase(onto ref: Ref) async {
        await rebase(onto: ref.name, named: ref.name)
    }

    func stash(message: String?, includeUntracked: Bool, keepIndex: Bool) async {
        guard let repository else { return }
        let before = await repository.resolve("refs/stash")
        let stashed = await perform(.stashing, failureTitle: String(localized: "Couldn't Stash Changes")) { repository in
            try await repository.stash(message: message, includeUntracked: includeUntracked, keepIndex: keepIndex)
        }
        guard stashed, let object = await repository.resolve("refs/stash"), object != before else { return }
        registerUndo(String(localized: "Stash"), hint: String(localized: "Stashed changes")) { model in
            await model.undoStep(String(localized: "Stash")) { repository in
                try await repository.popStash(object: object)
            }
        }
    }

    func drop(_ stash: Stash) async {
        let dropped = await perform(.working(String(localized: "Dropping stash…")), failureTitle: String(localized: "Couldn't Drop Stash")) { repository in
            try await repository.dropStash(stash)
        }
        guard dropped else { return }
        registerUndo(String(localized: "Drop Stash"), hint: String(localized: "Dropped “\(stash.message)”")) { model in
            await model.undoStep(String(localized: "Drop Stash")) { repository in
                try await repository.storeStash(stash.id, message: stash.message)
            }
        }
    }

    func revert(_ commit: Commit) async {
        let before = status.headID
        await perform(.working(String(localized: "Reverting \(commit.shortID)…")), failureTitle: String(localized: "Couldn't Revert")) { repository in
            try await repository.revert(commit)
        }
        registerHistoryUndo(String(localized: "Revert"), hint: String(localized: "Reverted \(commit.shortID)"), before: before)
    }

    func commit(andPush: Bool) async {
        guard canCommit else { return }
        let message = composedMessage
        let savedSummary = summary
        let savedBody = messageBody
        let amending = amend
        let before = status.headID
        // Leave the text fields first: their typing would otherwise sit above the commit in
        // the undo stack, and clearing them would register one more text change.
        historyFocusRequest += 1
        let committed = await perform(.committing, failureTitle: String(localized: "Couldn't Commit")) { repository in
            // Repository Settings › Hooks › Run hooks when committing from Kaern.
            let runHooks = await repository.localConfig(RepositorySettingKey.runHooks) != "false"
            try await repository.commit(message: message, amend: amending, runHooks: runHooks)
        }
        guard committed else { return }
        summary = ""
        messageBody = ""
        amend = false
        selectedFile = nil
        if andPush {
            await push()
        } else if let before, let after = status.headID, after != before {
            let name = amending ? String(localized: "Amend") : String(localized: "Commit")
            registerUndo(name, hint: amending ? String(localized: "Amended the last commit") : String(localized: "Committed “\(savedSummary)”")) { model in
                if let upstream = model.status.upstream, let repository = model.repository,
                   await repository.isAncestor(after, of: upstream) {
                    model.alert = AlertItem(
                        title: String(localized: "Can't Undo \(name)"),
                        message: String(localized: "The commit is already on \(upstream). Revert it instead.")
                    )
                    return
                }
                await model.undoStep(name, expectHead: after) { repository in
                    try await repository.reset(to: before, mode: .soft)
                }
                // Back in the composer, ready to commit again.
                if model.summary.isEmpty && model.messageBody.isEmpty {
                    model.summary = savedSummary
                    model.messageBody = savedBody
                }
            }
        }
    }
}
