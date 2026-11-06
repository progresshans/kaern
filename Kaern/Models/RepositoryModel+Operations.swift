import KaernKit
import SwiftUI

// MARK: - Merge, rebase and conflicts

extension RepositoryModel {
    var conflictedEntries: [StatusEntry] {
        status.entries.filter(\.isConflicted).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Staged, non-conflicted changes while an operation waits: what git merged on its own plus
    /// the files resolved so far. These go into the commit on Continue.
    var operationStagedEntries: [StatusEntry] {
        status.entries.filter { !$0.isConflicted && $0.hasStagedChanges }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Changes that aren't staged while an operation waits (they won't be part of the commit).
    var operationUnstagedEntries: [StatusEntry] {
        status.entries.filter { !$0.isConflicted && !$0.hasStagedChanges }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The best name for a commit: a local branch, a remote branch, a tag, then the short SHA.
    func displayName(forCommit id: String?) -> String {
        guard let id else { return "HEAD" }
        let refs = refs.refs(at: id)
        if let local = refs.first(where: { $0.kind == .localBranch }) { return local.name }
        if let remote = refs.first(where: { $0.kind == .remoteBranch }) { return remote.name }
        if let tag = refs.first(where: { $0.kind == .tag }) { return tag.name }
        return String(id.prefix(7))
    }

    /// The side already in place: the branch being rebased onto, or the current branch.
    var oursLabel: String {
        guard let operation else { return headTitle }
        if operation.kind == .rebase {
            return displayName(forCommit: operation.onto)
        }
        return status.branch ?? String(localized: "HEAD")
    }

    /// The side coming in: the commit being replayed, picked or reverted, or the branch being merged.
    var theirsLabel: String {
        guard let operation else { return "" }
        if operation.kind == .merge {
            return operation.incomingName ?? displayName(forCommit: operation.incoming)
        }
        return String((operation.incoming ?? "").prefix(7))
    }

    /// The subject of the commit being replayed, picked or reverted.
    var incomingSubject: String? {
        guard let id = operation?.incoming else { return nil }
        return commit(withID: id)?.subject
    }

    // MARK: Starting

    func merge(_ revision: String, named name: String, noFastForward: Bool = false) async {
        let before = status.headID
        let into = currentBranchTitle
        await perform(.working(String(localized: "Merging \(name)…")), failureTitle: String(localized: "Couldn't Merge “\(name)”")) { repository in
            _ = try await repository.merge(revision, fastForward: noFastForward ? .never : .allowed)
        }
        registerHistoryUndo(String(localized: "Merge"), hint: String(localized: "Merged \(name) into \(into)"), before: before)
    }

    func rebase(onto revision: String, named name: String) async {
        let before = status.headID
        let branch = currentBranchTitle
        await perform(.working(String(localized: "Rebasing onto \(name)…")), failureTitle: String(localized: "Couldn't Rebase onto “\(name)”")) { repository in
            _ = try await repository.rebase(onto: revision)
        }
        registerHistoryUndo(String(localized: "Rebase"), hint: String(localized: "Rebased \(branch) onto \(name)"), before: before)
    }

    /// Interactive Rebase sheet › Start Rebase. ⌘Z puts the branch back where it was.
    func interactiveRebase(onto base: String, label: String, steps: [RebaseStep], autostash: Bool) async {
        let before = status.headID
        let branch = currentBranchTitle
        await perform(.working(String(localized: "Rebasing \(branch)…")), failureTitle: String(localized: "Couldn't Rebase “\(branch)”")) { repository in
            _ = try await repository.interactiveRebase(onto: base, steps: steps, autostash: autostash)
        }
        registerHistoryUndo(String(localized: "Interactive Rebase"), hint: String(localized: "Rebased \(branch) onto \(label)"), before: before)
    }

    /// Branch › Interactive Rebase…: onto the upstream when there is one, otherwise the main branch.
    func requestInteractiveRebase(from commit: Commit? = nil) {
        if let commit {
            sheet = .interactiveRebase(onto: commit.id, label: "\(commit.shortID) · \(commit.subject)")
            return
        }
        if let upstream = status.upstream {
            sheet = .interactiveRebase(onto: upstream, label: upstream)
        } else if let main = ["main", "master", "develop", "trunk"].first(where: { refs.localBranch(named: $0) != nil && $0 != status.branch }) {
            sheet = .interactiveRebase(onto: main, label: main)
        } else if let parent = headCommit?.parents.first {
            sheet = .interactiveRebase(onto: parent, label: String(parent.prefix(7)))
        }
    }

    func cherryPick(_ commit: Commit) async {
        let before = status.headID
        await perform(.working(String(localized: "Cherry-picking \(commit.shortID)…")), failureTitle: String(localized: "Couldn't Cherry-Pick \(commit.shortID)")) { repository in
            _ = try await repository.cherryPick(commit.id)
        }
        registerHistoryUndo(String(localized: "Cherry-Pick"), hint: String(localized: "Cherry-picked \(commit.shortID)"), before: before)
    }

    // MARK: Finishing

    /// Continue (rebase, cherry-pick, revert) or Commit Merge, with the edited message if it changed.
    func continueOperation() async {
        guard let operation, status.conflictCount == 0 else { return }
        let edited = operationMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = edited.isEmpty || edited == operation.message ? nil : edited
        await perform(.working(String(localized: "Continuing…")), failureTitle: String(localized: "Couldn't Continue")) { repository in
            _ = try await repository.continueOperation(operation, message: message)
        }
    }

    func skipOperationStep() async {
        guard let operation, operation.kind.canSkip else { return }
        await perform(.working(String(localized: "Skipping…")), failureTitle: String(localized: "Couldn't Skip the Commit")) { repository in
            _ = try await repository.skipOperationStep(operation.kind)
        }
    }

    /// Asks first when conflicts were already resolved by hand, since aborting throws that work away.
    func requestAbortOperation() {
        guard let operation else { return }
        if resolvedConflicts.isEmpty {
            Task { await abortOperation() }
        } else {
            confirmation = .abortOperation(operation.kind)
        }
    }

    func abortOperation() async {
        guard let operation else { return }
        await perform(.working(String(localized: "Aborting…")), failureTitle: String(localized: "Couldn't Abort")) { repository in
            try await repository.abortOperation(operation.kind)
        }
    }

    // MARK: Resolving

    /// Takes one side for every conflict in the file. Text files keep the changes git merged on its
    /// own around the conflicts; binary files, and conflicts where a side deleted the file, take
    /// that side's whole file.
    func resolveConflict(_ path: String, taking side: ConflictSide) async {
        guard let repository else { return }
        let document = repository.conflictDocument(path)
        await performIndexChange(failureTitle: String(localized: "Couldn't Resolve “\(path)”")) { repository in
            if let document, document.hasConflicts {
                try await repository.writeResolution(document.resolvingAll(with: side == .ours ? .ours : .theirs).text, to: path)
            } else {
                try await repository.resolveConflict(path, taking: side)
            }
        }
        noteResolved(path)
    }

    /// Writes the result from the conflict editor and stages it.
    func saveResolution(_ text: String, for path: String) async {
        await performIndexChange(failureTitle: String(localized: "Couldn't Save “\(path)”")) { repository in
            try await repository.writeResolution(text, to: path)
        }
        noteResolved(path)
    }

    /// Stages a conflicted file as it is on disk (after resolving it in an editor).
    func markResolved(_ path: String) async {
        await performIndexChange(failureTitle: String(localized: "Couldn't Mark “\(path)” as Resolved")) { repository in
            try await repository.stage([path])
        }
        noteResolved(path)
    }

    func openInFileMerge(_ path: String) async {
        guard let repository else { return }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/opendiff") else {
            alert = AlertItem(title: String(localized: "FileMerge Isn't Available"),
                              message: String(localized: "FileMerge comes with Xcode. Install Xcode, or resolve the file in Kaern."))
            return
        }
        do {
            try await repository.openMergeTool(path)
        } catch {
            showError(error, title: String(localized: "Couldn't Open FileMerge"))
        }
        await refreshStatus()
        if !(status.entries.first { $0.path == path }?.isConflicted ?? false) {
            noteResolved(path)
        }
    }

    private func noteResolved(_ path: String) {
        guard operation != nil, !(status.entries.first { $0.path == path }?.isConflicted ?? false) else { return }
        resolvedConflicts.insert(path)
        // Move on to the next conflicted file, like the list's order suggests.
        if case .working(let selected) = selectedFile, selected == path {
            selectedFile = conflictedEntries.first.map { .working($0.path) }
        }
    }
}
