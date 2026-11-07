import Foundation
import KaernKit

/// The interactive rebase sheet: the commits after `base`, oldest first, and what to do with each.
struct RebaseDraft: Equatable {
    /// The commit (or branch) the commits are replayed onto.
    var base: String
    /// What the Onto pop-up shows for `base` ("develop · 1d77f5b").
    var baseTitle: String
    var steps: [RebaseStep]
    /// Commits already on the upstream (pushed).
    var pushed: Set<String> = []
    var hasUpstream = false
    /// The first `base` the sheet opened with (moving onto another one rewrites every commit).
    var originalBase: String
    /// Put uncommitted changes aside first and back afterwards.
    var stashChanges = true
    /// Full messages of commits being reworded (subject edited in the row, body kept).
    var bodies: [String: String] = [:]
    var isLoading = false

    /// Commits left after the rebase (squash, fixup and drop make fewer).
    var resultCount: Int { steps.count { $0.action != .drop && !$0.action.joinsPrevious } }

    /// The first kept commit can't be squashed or fixed up.
    var firstJoinsNothing: Bool {
        guard let first = steps.first(where: { $0.action != .drop }) else { return false }
        return first.action.joinsPrevious
    }

    /// The rebase rewrites commits that are on the upstream (Push will need force).
    var rewritesPushed: Bool {
        guard !pushed.isEmpty else { return false }
        if base != originalBase { return true }
        let pushedSteps = steps.prefix { pushed.contains($0.commit.id) }
        // The pushed commits must stay first, in order, untouched.
        let pushedInOrder = steps.filter { pushed.contains($0.commit.id) }
        return pushedSteps.count != pushedInOrder.count || pushedSteps.contains { $0.action != .pick }
    }

    var canStart: Bool { !isLoading && !steps.isEmpty && !firstJoinsNothing && resultCount > 0 }

    /// What each row says on the right ("on origin", "into c92aa17", "removed").
    func meta(at index: Int) -> String {
        let step = steps[index]
        if step.action == .drop { return "removed" }
        if step.action.joinsPrevious {
            guard let target = steps[..<index].last(where: { $0.action != .drop && !$0.action.joinsPrevious }) else {
                return "nothing above to join"
            }
            return "into \(target.commit.shortID)"
        }
        return pushed.contains(step.commit.id) ? "on origin" : ""
    }
}

extension RepositoryModel {
    /// Interactively Rebase from Here…: the commits after `base` up to HEAD.
    func askInteractiveRebase(onto base: String, squashing: Set<String> = []) {
        guard let repository, status.branch != nil || operation == nil else { return }
        var draft = RebaseDraft(base: base, baseTitle: rebaseBaseTitle(base), steps: [], originalBase: base)
        draft.isLoading = true
        draft.stashChanges = !status.isClean
        sheet = .interactiveRebase(draft)
        Task {
            let loaded = await GitCommandTrigger.$current.withValue(.background("Interactive rebase")) { () async -> RebaseDraft? in
                guard let commits = try? await repository.commitsToRebase(onto: base) else { return nil }
                var draft = draft
                draft.isLoading = false
                draft.steps = commits.map { RebaseStep(commit: $0) }
                if let unpushed = await repository.unpushedCommits() {
                    draft.hasUpstream = true
                    draft.pushed = Set(commits.map(\.id)).subtracting(unpushed)
                }
                // Squash N into One: the oldest picked commit stays, the others fold into it.
                if !squashing.isEmpty {
                    var seenFirst = false
                    for index in draft.steps.indices where squashing.contains(draft.steps[index].commit.id) {
                        if seenFirst { draft.steps[index].action = .squash } else { seenFirst = true }
                    }
                }
                return draft
            }
            guard case .interactiveRebase(let current) = sheet, current.originalBase == base else { return }
            if let loaded {
                sheet = .interactiveRebase(loaded)
            } else {
                sheet = nil
                alert = RepositoryAlert(title: "Couldn’t read the commits to rebase", message: "Kaern couldn’t list the commits after \(short(base)).")
            }
        }
    }

    /// Squash N into One… on picked commits: they must be in a row on the current branch.
    func askSquash(_ ids: [String]) {
        guard let base = squashBase(ids) else { return }
        askInteractiveRebase(onto: base, squashing: Set(ids))
    }

    /// The parent of the oldest picked commit, when the picked commits can be squashed: on this
    /// branch, no merges, and next to each other.
    func squashBase(_ ids: [String]) -> String? {
        guard ids.count >= 2, status.branch != nil, operation == nil else { return nil }
        let rows = ids.compactMap { id in commits.firstIndex { $0.id == id } }.sorted()
        guard rows.count == ids.count, let oldest = rows.last, let newest = rows.first else { return nil }
        guard rows == Array(newest...oldest) else { return nil }
        for row in rows {
            let commit = commits[row]
            guard isOnCurrentBranch(commit.id), commit.parents.count == 1 else { return nil }
        }
        return commits[oldest].parents.first
    }

    /// Why Squash isn't available for these commits (the menu's reason).
    func squashUnavailableReason(_ ids: [String]) -> String? {
        if operation != nil { return "Finish the \(operation!.kind.title.lowercased()) first" }
        if status.branch == nil { return "Not on a branch" }
        if ids.contains(where: { !isOnCurrentBranch($0) }) { return "Only commits on this branch" }
        if ids.contains(where: { (commit($0)?.parents.count ?? 1) > 1 }) { return "Merge commits can’t be squashed" }
        if squashBase(ids) == nil { return "Pick commits next to each other" }
        return nil
    }

    /// "develop · 1d77f5b" or "1d77f5b · subject".
    func rebaseBaseTitle(_ id: String) -> String {
        let full = commit(id)?.id ?? id
        if let branch = refs.localBranches.first(where: { $0.target == full && $0.name != status.branch }) {
            return "\(branch.name) · \(short(full))"
        }
        if let remote = refs.remoteBranches.first(where: { $0.target == full }) {
            return "\(remote.name) · \(short(full))"
        }
        if let commit = commit(full) { return "\(commit.shortID) · \(commit.subject)" }
        return short(id)
    }

    /// The Onto pop-up: the commit the sheet opened with, and the branches it could go onto.
    func rebaseOntoChoices(_ draft: RebaseDraft) -> [(id: String, title: String)] {
        var choices: [(String, String)] = [(draft.originalBase, rebaseBaseTitle(draft.originalBase))]
        let current = status.branch
        var names: [String] = []
        if let upstream = status.upstream { names.append(upstream) }
        names += refs.localBranches.map(\.name).filter { $0 != current }
        for name in names where !choices.contains(where: { $0.0 == name }) {
            choices.append((name, name))
        }
        return choices
    }

    /// Changes what the commits go onto (reloads the list).
    func changeRebaseBase(_ base: String) {
        guard case .interactiveRebase(let draft) = sheet, base != draft.base, let repository else { return }
        var next = draft
        next.base = base
        next.baseTitle = base == draft.originalBase ? rebaseBaseTitle(base) : base
        next.isLoading = true
        sheet = .interactiveRebase(next)
        Task {
            let commits = (try? await GitCommandTrigger.$current.withValue(.background("Interactive rebase")) {
                try await repository.commitsToRebase(onto: base)
            }) ?? []
            guard case .interactiveRebase(var current) = sheet, current.base == base else { return }
            let actions = Dictionary(draft.steps.map { ($0.commit.id, $0) }, uniquingKeysWith: { first, _ in first })
            current.steps = commits.map { actions[$0.id] ?? RebaseStep(commit: $0) }
            current.isLoading = false
            sheet = .interactiveRebase(current)
        }
    }

    func updateRebaseDraft(_ change: (inout RebaseDraft) -> Void) {
        guard case .interactiveRebase(var draft) = sheet else { return }
        change(&draft)
        sheet = .interactiveRebase(draft)
    }

    /// Reword: loads the whole message so the body survives a new subject.
    func loadRebaseBody(_ id: String) {
        guard let repository else { return }
        Task {
            guard let message = try? await repository.message(of: id) else { return }
            updateRebaseDraft { $0.bodies[id] = message }
        }
    }

    /// Start Rebase.
    func startInteractiveRebase(_ draft: RebaseDraft) {
        guard draft.canStart, let before = status.headID else { return }
        sheet = nil
        let branch = status.branch
        let steps = draft.steps.map { step -> RebaseStep in
            guard step.action == .reword, let subject = step.message else { return step }
            var step = step
            // The row edits the subject; the body stays.
            let original = draft.bodies[step.commit.id] ?? step.commit.subject
            let body = original.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            step.message = subject + (body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n" + body)
            return step
        }
        let count = steps.count
        let result = draft.resultCount
        // "Squash 2 Commits" when that's all it does, else "Rebase feature/x" (⌘Z's name).
        let folds = draft.steps.filter { $0.action.joinsPrevious }.count
        let onlyFolds = folds > 0 && draft.steps.allSatisfy { $0.action == .pick || $0.action.joinsPrevious }
        let label = onlyFolds ? "Squash \(folds + 1) Commits" : "Rebase \(branch ?? "HEAD")"
        let stash = draft.stashChanges && !status.isClean
        perform(.working("Rebasing \(branch ?? "HEAD")…"), trigger: label) { [weak self] repository in
            let work: @Sendable () async throws -> OperationOutcome = {
                try await repository.interactiveRebase(onto: draft.base, steps: steps, autostash: false)
            }
            let outcome: (outcome: OperationOutcome, kept: String?)
            if stash {
                outcome = try await repository.withChangesStashed(message: "Before \(label)", work)
            } else {
                outcome = (try await work(), nil)
            }
            guard let self else { return }
            guard outcome.outcome == .finished, let after = await repository.resolve("HEAD") else {
                let start = OperationStart(label: label, branch: branch, head: before, kept: outcome.kept)
                if !(await repository.unmergedPaths()).isEmpty {
                    self.stoppedOnConflicts("Rebase", start: start)
                } else {
                    self.operationStart = start
                    self.showToast("The rebase stopped to edit a commit · make your changes, then Continue in the bar above")
                }
                return
            }
            self.recordMove(label: label, branch: branch, from: before, to: after, kept: outcome.kept,
                            toast: count == result ? "Rebased \(branch ?? "HEAD") · \(Formatters.count(count, "commit", "commits")) rewritten"
                                : "Rebased \(branch ?? "HEAD") · \(count) commits became \(result)")
        }
    }
}
