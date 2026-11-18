import AppKit
import Foundation
import KaernKit

// MARK: - State the phase-3 flows keep

/// Compare with the current branch.
struct BranchCompareState: Equatable {
    var other: String
}

/// A line picked in Review: which diff (staged or unstaged), which hunk, which line.
struct LinePick: Hashable {
    var stage: ReviewHunk.Stage
    var hunk: Int
    var line: Int
}

/// The lines picked in one working-copy file.
struct LinePicks: Equatable {
    var path: String?
    var lines: Set<LinePick> = []
    var anchor: LinePick?

    var isEmpty: Bool { lines.isEmpty }
    var unstaged: [LinePick] { lines.filter { $0.stage == .unstaged } }
    var staged: [LinePick] { lines.filter { $0.stage == .staged } }

    /// Hunk id → line ids of one side, for `FileDiff.patch(picking:)`.
    func selection(_ stage: ReviewHunk.Stage) -> [Int: Set<Int>] {
        var result: [Int: Set<Int>] = [:]
        for pick in lines where pick.stage == stage { result[pick.hunk, default: []].insert(pick.line) }
        return result
    }
}

/// The pre-commit hook HUD.
struct HookRun: Equatable {
    var hook: String
    var command: String
    var started: Date
}

/// One line of a hook's output; `path:line:col: error: …` lines can be opened.
struct HookOutputLine: Identifiable, Equatable {
    let id: Int
    var path: String?
    var line: Int?
    var kind: String?
    var message: String
    var text: String
}

/// A commit a hook stopped: the sheet with the hook's output.
struct HookFailure: Identifiable, Equatable {
    let id = UUID()
    var hook: String
    var command: String?
    var lines: [HookOutputLine]
    var status: Int32
    var seconds: Double
    var errors: Int
    var warnings: Int

    init(hook: String, command: String?, output: String, status: Int32, seconds: Double) {
        self.hook = hook
        self.command = command
        self.status = status
        self.seconds = seconds
        let pattern = /^(.+?):(\d+)(?::\d+)?:\s*(error|warning|note):\s*(.*)$/
        var parsed: [HookOutputLine] = []
        for (index, raw) in output.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let text = String(raw).trimmingCharacters(in: .whitespaces)
            if let match = text.wholeMatch(of: pattern) {
                parsed.append(HookOutputLine(id: index, path: String(match.output.1), line: Int(match.output.2),
                                             kind: String(match.output.3), message: String(match.output.4), text: text))
            } else {
                parsed.append(HookOutputLine(id: index, path: nil, line: nil, kind: nil, message: text, text: text))
            }
        }
        lines = parsed
        errors = parsed.count { $0.kind == "error" }
        warnings = parsed.count { $0.kind == "warning" }
    }

    /// "2 errors, 1 warning · exited with 1 after 1.4s"
    var summary: String {
        var parts: [String] = []
        if errors > 0 { parts.append(Formatters.count(errors, "error", "errors")) }
        if warnings > 0 { parts.append(Formatters.count(warnings, "warning", "warnings")) }
        let counts = parts.isEmpty ? "" : parts.joined(separator: ", ") + " · "
        return counts + "exited with \(status) after \(String(format: "%.1f", seconds))s"
    }
}

/// The publish popover's fields.
struct PublishDraft: Equatable {
    var branch: String
    var remote: String
    var name: String
    var track: Bool
}

/// A question before something that can't be taken back (or that throws work away), with the
/// safe button as the default.
struct Confirmation: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    /// Commits shown struck through (Force Push: the versions that get replaced).
    var lost: [CommitSummary] = []
    var note: String?
    var confirmTitle: String
    var confirm: () -> Void
}

/// What the compare panel shows, loaded from git.
struct Comparison: Equatable {
    enum Kind: Equatable {
        case commits(older: String, newer: String)
        case branches(theirs: String)
    }

    var key: String
    var kind: Kind
    /// Two commits: what `git log older..newer` lists (newest first).
    var between: [CommitSummary] = []
    var betweenCount = 0
    /// Branches: commits only on the current branch, only on the other one.
    var ours: [CommitSummary] = []
    var theirs: [CommitSummary] = []
    var oursCount = 0
    var theirsCount = 0
    var base: String?
    /// The older commit is an ancestor of the newer one.
    var linear = true
    var files: [FileChange] = []
    /// Rows to tint in the graph.
    var rangeIDs: Set<String> = []
    var oursIDs: Set<String> = []
    var theirsIDs: Set<String> = []
}

/// A thrown error the action already reported (a sheet is showing), so `perform` stays quiet.
struct AlreadyReported: Error {}

// MARK: - Commits and branches

extension RepositoryModel {
    func short(_ id: String) -> String { String(id.prefix(7)) }

    /// Rows newer first: a lower index is newer.
    private func row(_ id: String) -> Int { commits.firstIndex { $0.id == id } ?? Int.max }

    func checkout(branch name: String) {
        guard let shown = headPosition, shown != .branch(name) else { return }
        if case .branch(let old) = shown {
            switchedBranches.removeAll { $0 == old || $0 == name }
            switchedBranches.insert(old, at: 0)
        }
        let changes = status.entries.count
        let label = "Checkout \(name)"
        perform(.switching(name), trigger: label) { [weak self] repository in
            // HEAD as git has it now, not as the status showed it (see `headNow`).
            let now = await Self.headNow(in: repository)
            let previous = now.map { HeadPosition(branch: $0.branch, id: $0.id) } ?? shown
            try await repository.switchBranch(name)
            self?.record(.checkout(label: label, from: previous, to: .branch(name)),
                         toast: "Switched to \(name)" + (changes > 0 ? " · your \(Formatters.count(changes, "change", "changes")) came along" : ""))
        }
    }

    func checkout(commit id: String) {
        guard let shown = headPosition else { return }
        let label = "Checkout \(short(id))"
        perform(.switching(short(id)), trigger: label) { [weak self] repository in
            // HEAD as git has it now, not as the status showed it (see `headNow`).
            let now = await Self.headNow(in: repository)
            let previous = now.map { HeadPosition(branch: $0.branch, id: $0.id) } ?? shown
            try await repository.detach(at: id)
            self?.record(.checkout(label: label, from: previous, to: .detached(id)),
                         toast: "HEAD is now at \(String(id.prefix(7))) (detached) · new commits won’t belong to a branch")
        }
    }

    /// Cherry-picks commits onto the current branch, oldest first.
    func cherryPick(_ ids: [String]) {
        let list = ids.compactMap(commit).sorted { row($0.id) > row($1.id) }
        guard !list.isEmpty, let shownHead = status.headID else { return }
        let shownBranch = status.branch
        let label = list.count == 1 ? "Cherry-pick \(list[0].shortID)" : "Cherry-pick \(list.count) Commits"
        perform(.working("Cherry-picking \(list.count == 1 ? list[0].shortID : "\(list.count) commits")…"), trigger: label) { [weak self] repository in
            // HEAD as git has it now, not as the status showed it (see `headNow`).
            let now = await Self.headNow(in: repository)
            let before = now?.id ?? shownHead
            let branch = now.map { $0.branch } ?? shownBranch
            let onto = branch ?? "HEAD"
            // git won't pick with staged changes: they're put aside in the stash list and come back.
            let result = try await repository.withChangesStashed(message: "Before \(label)") {
                try await repository.cherryPick(list)
            }
            guard let self else { return }
            guard result.outcome == .finished, let after = await repository.resolve("HEAD") else {
                self.stoppedOnConflicts("Cherry-pick", start: OperationStart(label: label, branch: branch, head: before, kept: result.kept))
                return
            }
            let text = list.count == 1
                ? "Cherry-picked \(list[0].shortID) onto \(onto) as \(self.short(after))"
                : "Cherry-picked \(list.count) commits onto \(onto)"
            self.recordMove(label: label, branch: branch, from: before, to: after, kept: result.kept, toast: text)
        }
    }

    /// Reverts commits on the current branch, newest first, one new commit each.
    func revert(_ ids: [String]) {
        let list = ids.compactMap(commit).sorted { row($0.id) < row($1.id) }
        guard !list.isEmpty, let shownHead = status.headID else { return }
        let shownBranch = status.branch
        let label = list.count == 1 ? "Revert \(list[0].shortID)" : "Revert \(list.count) Commits"
        perform(.working("Reverting \(list.count == 1 ? list[0].shortID : "\(list.count) commits")…"), trigger: label) { [weak self] repository in
            // HEAD as git has it now, not as the status showed it (see `headNow`).
            let now = await Self.headNow(in: repository)
            let before = now?.id ?? shownHead
            let branch = now.map { $0.branch } ?? shownBranch
            let result = try await repository.withChangesStashed(message: "Before \(label)") {
                try await repository.revert(list)
            }
            guard let self else { return }
            guard result.outcome == .finished, let after = await repository.resolve("HEAD") else {
                self.stoppedOnConflicts("Revert", start: OperationStart(label: label, branch: branch, head: before, kept: result.kept))
                return
            }
            let text = list.count == 1
                ? "Reverted \(list[0].shortID) with a new commit, \(self.short(after))"
                : "Reverted \(list.count) commits"
            self.recordMove(label: label, branch: branch, from: before, to: after, kept: result.kept, toast: text)
        }
    }

    /// Reset Branch to Here. Hard asks first (it stashes the changes, and ⌘Z brings them back).
    func reset(to id: String, mode: GitRepository.ResetMode) {
        guard let head = status.headID, let branch = status.branch else { return }
        if mode == .hard {
            let changes = status.entries.filter { !$0.isUntracked }.count
            confirmation = Confirmation(
                title: "Reset “\(branch)” to \(short(id)) and throw away changes?",
                message: "Commits above \(short(id)) leave this branch"
                    + (changes > 0 ? " and your \(Formatters.count(changes, "uncommitted change", "uncommitted changes")) are put aside. Kaern stashes them first" : ". Kaern keeps them in the reflog")
                    + ", so ⌘Z brings everything back.",
                note: "Return cancels. Reset needs a click.",
                confirmTitle: "Reset",
                confirm: { [weak self] in self?.resetNow(to: id, mode: .hard, head: head, branch: branch) }
            )
        } else {
            resetNow(to: id, mode: mode, head: head, branch: branch)
        }
    }

    /// `shownHead` and `branch` are what the status showed when the reset was asked for. What the
    /// reset does goes by git, read here: that status can be older than the working tree (a
    /// refresh still reading, the file watcher off, a file saved a moment ago).
    private func resetNow(to id: String, mode: GitRepository.ResetMode, head shownHead: String, branch: String) {
        let label = "Reset \(branch) to \(short(id)) (\(mode.rawValue))"
        perform(.working("Resetting \(branch)…"), trigger: label) { [weak self] repository in
            // The branch the question named, not whatever is checked out by now.
            guard await repository.currentBranchName() == branch else {
                throw GitError(arguments: ["reset", "--\(mode.rawValue)"], status: -1,
                               message: "\(branch) isn’t checked out anymore, so Kaern didn’t reset anything.")
            }
            // Where the branch is now: ⌘Z goes back there (a commit made in Terminal included).
            let head = await repository.resolve("HEAD") ?? shownHead
            let leaving = await repository.countCommits(from: id, to: head)
            var stash: String?
            let index = mode == .mixed ? await repository.writeIndexTree() : nil
            if mode == .hard {
                // Whatever git finds uncommitted goes to Stashes first, listed or not, with the
                // untracked and ignored files the reset would write over; with nothing to put aside,
                // no stash is made. If the reset doesn't happen, the stash comes back.
                stash = try await repository.resetHard(to: id, message: "Before reset to \(id.prefix(7))")
            } else {
                try await repository.reset(to: id, mode: mode)
            }
            guard let self else { return }
            let commits = leaving == 1 ? "1 commit’s" : "\(leaving) commits’"
            let text: String
            switch mode {
            case .hard: text = "Reset \(branch) to \(self.short(id))" + (stash != nil ? " · your changes were stashed first" : "")
            case .soft: text = "Reset \(branch) to \(self.short(id)) · \(commits) changes are now staged"
            default: text = "Reset \(branch) to \(self.short(id)) · \(commits) changes are now unstaged"
            }
            self.record(.reset(label: label, branch: branch, from: head, to: id, mode: mode, indexBefore: index, stash: stash), toast: text)
        }
    }

    /// Merges `revision` (a branch, remote branch or commit) into the current branch;
    /// `noFastForward` always makes a merge commit.
    func merge(_ revision: String, noFastForward: Bool = false) {
        guard let shownHead = status.headID else { return }
        let shownBranch = status.branch
        let label = "Merge \(revision)"
        perform(.working("Merging \(revision) into \(shownBranch ?? "HEAD")…"), trigger: label) { [weak self] repository in
            // HEAD as git has it now, not as the status showed it (see `headNow`).
            let now = await Self.headNow(in: repository)
            let before = now?.id ?? shownHead
            let branch = now.map { $0.branch } ?? shownBranch
            let into = branch ?? "HEAD"
            // Like a cherry-pick: uncommitted changes go aside and come back staged as they were
            // (git's own --autostash brings them back unstaged).
            let result = try await repository.withChangesStashed(message: "Before \(label)") {
                try await repository.merge(revision, fastForward: noFastForward ? .never : .allowed)
            }
            guard let self else { return }
            guard result.outcome == .finished, let after = await repository.resolve("HEAD") else {
                self.stoppedOnConflicts("Merge", start: OperationStart(label: label, branch: branch, head: before, kept: result.kept))
                return
            }
            guard after != before else {
                self.showToast("\(revision) is already part of \(into)")
                return
            }
            let tip = await repository.resolve(revision)
            let text = tip == after ? "Fast-forwarded \(into) to \(revision)" : "Merged \(revision) into \(into) with \(self.short(after))"
            self.recordMove(label: label, branch: branch, from: before, to: after, kept: result.kept, toast: text)
        }
    }

    /// Replays the current branch on top of `revision`.
    func rebase(onto revision: String) {
        guard let shownHead = status.headID, let shownBranch = status.branch else { return }
        let label = "Rebase onto \(revision)"
        perform(.working("Rebasing \(shownBranch) onto \(revision)…"), trigger: label) { [weak self] repository in
            // HEAD as git has it now, not as the status showed it (see `headNow`).
            let now = await Self.headNow(in: repository)
            let before = now?.id ?? shownHead
            let branch = now.map { $0.branch } ?? shownBranch
            // A HEAD detached since is rebased as git would; the texts call it HEAD.
            let name = branch ?? "HEAD"
            var replayed = 0
            if let base = await repository.mergeBase(before, revision) {
                replayed = await repository.countCommits(from: base, to: before)
            }
            let result = try await repository.withChangesStashed(message: "Before \(label)") {
                try await repository.rebase(onto: revision)
            }
            guard let self else { return }
            guard result.outcome == .finished, let after = await repository.resolve("HEAD") else {
                self.stoppedOnConflicts("Rebase", start: OperationStart(label: label, branch: branch, head: before, kept: result.kept))
                return
            }
            guard after != before else {
                self.showToast("\(name) is already on top of \(revision)")
                return
            }
            self.recordMove(label: label, branch: branch, from: before, to: after, kept: result.kept,
                            toast: "Rebased \(name) onto \(revision) · \(Formatters.count(replayed, "commit", "commits")) replayed")
        }
    }

    /// Deletes a local branch that isn't checked out. ⌘Z makes it again.
    func deleteBranch(_ name: String) {
        guard let ref = refs.localBranch(named: name), name != status.branch else { return }
        let merged = isOnCurrentBranch(ref.target)
        perform(.working("Deleting \(name)…"), trigger: "Delete \(name)") { [weak self] repository in
            // The tip as git has it now: ⌘Z makes the branch again there, with any commit made on it
            // since the refs were read (git deletes a branch's reflog with it, so nothing else has them).
            let tip = await repository.resolve("refs/heads/\(name)") ?? ref.target
            try await repository.deleteBranch(name, force: true)
            self?.record(.deletedBranch(name: name, tip: tip, upstream: ref.upstream),
                         toast: "Deleted \(name)" + (merged ? "" : " (it wasn’t merged)") + " · ⌘Z brings it back")
        }
    }

    /// Delete Here and on origin… / Delete from origin…: asks first, a remote can't be undone.
    func deleteOnRemote(branch name: String, remoteBranch: Ref, alsoLocal: Bool) {
        guard let remote = remoteBranch.remoteName else { return }
        let remoteName = remoteBranch.branchName
        confirmation = Confirmation(
            title: alsoLocal ? "Delete \(name) here and on \(remote)?" : "Delete \(remoteBranch.name)?",
            message: "\(remoteBranch.name) is removed for everyone who uses this remote. Kaern can’t undo changes on a remote.",
            confirmTitle: "Delete",
            confirm: { [weak self] in
                guard let self else { return }
                self.perform(.network("Deleting \(remoteBranch.name)…"), trigger: "Delete \(remoteBranch.name)") { [weak self] repository in
                    if alsoLocal {
                        try await repository.deleteBranchEverywhere(name, remote: remote, remoteBranch: remoteName)
                        self?.showToast("Deleted \(name) · \(remoteBranch.name) is gone from \(remote)")
                    } else {
                        try await repository.deleteRemoteBranch(remoteName, on: remote)
                        self?.showToast("Deleted \(remoteBranch.name)")
                    }
                }
            }
        )
    }

    /// Pull from outside the tab (the Repositories window, the Command Log). A tab in the
    /// background may not have read this repository's own pull setting yet, so that comes first.
    func pullWithItsSetting(from source: String) {
        Task {
            await refreshPullOverride()
            from(source) { pull(pullChoice.strategy) }
        }
    }

    /// Pull on a branch: the current one pulls; another one fast-forwards to its upstream.
    func pull(branch name: String) {
        if name == status.branch {
            pull(pullChoice.strategy)
            return
        }
        guard let ref = refs.localBranch(named: name), let upstream = ref.upstream,
              let tracked = refs.remoteBranch(named: upstream), let remote = tracked.remoteName else { return }
        let before = ref.target
        perform(.network("Pulling \(name)…"), trigger: "Pull \(name)") { [weak self] repository in
            try await repository.fastForward(branch: name, from: remote, remoteBranch: tracked.branchName)
            let after = await repository.resolve("refs/heads/\(name)") ?? before
            let count = await repository.countCommits(from: before, to: after)
            self?.showToast(count == 0 ? "\(name) is up to date" : "Pulled \(name) · fast-forwarded \(Formatters.count(count, "commit", "commits"))")
        }
    }

    /// Push on a branch: the current one goes through Push; another one is pushed to its upstream.
    func push(branch name: String) {
        if name == status.branch {
            push()
            return
        }
        guard let ref = refs.localBranch(named: name), let upstream = ref.upstream,
              let tracked = refs.remoteBranch(named: upstream), let remote = tracked.remoteName else { return }
        perform(.network("Pushing \(name)…"), trigger: "Push \(name)") { [weak self] repository in
            try await repository.push(branch: name, to: remote, as: tracked.branchName)
            self?.showToast("Pushed \(name) to \(remote)")
        }
    }

    func pushTag(_ name: String) {
        guard let remote = defaultRemote else { return }
        perform(.network("Pushing \(name)…"), trigger: "Push Tag \(name)") { [weak self] repository in
            try await repository.pushTag(name, to: remote)
            self?.showToast("Pushed \(name) to \(remote)")
        }
    }

    /// Records a branch move; when the uncommitted changes had to stay in the stash list, the
    /// toast says so and ⌘Z brings them back too.
    func recordMove(label: String, branch: String?, from: String, to: String, kept: String?, toast: String?) {
        if let kept {
            record(.moveBranchKeepingStash(label: label, branch: branch, from: from, to: to, stash: kept),
                   toast: toast.map { $0 + " · your changes touch the same files, so they’re in Stashes" })
        } else {
            record(.moveBranch(label: label, branch: branch, from: from, to: to), toast: toast)
        }
    }
}

extension OperationState.Kind {
    var title: String {
        switch self {
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        }
    }
}

// MARK: - Files

extension RepositoryModel {
    /// Discard Changes (or Discard Unstaged Changes): a copy goes to the stash list first, and
    /// ⌘Z puts everything back. No question asked.
    func discard(_ entries: [StatusEntry], keepingStaged: Bool) {
        guard !entries.isEmpty else { return }
        let paths = Array(Set(entries.flatMap { [$0.originalPath, $0.path].compactMap { $0 } })).sorted()
        let untracked = entries.filter(\.isUntracked).map(\.path)
        let name = entries.count == 1 ? (entries[0].path as NSString).lastPathComponent : Formatters.count(entries.count, "file", "files")
        let label = entries.count == 1 ? "Discard ‘\(name)’" : "Discard \(name)"
        let message = "Before discarding " + (entries.count == 1 ? name : Formatters.count(entries.count, "file", "files"))
        perform(.working("Discarding \(name)…"), trigger: keepingStaged ? "Discard Unstaged Changes" : "Discard Changes") { [weak self] repository in
            let record = try await repository.discard(paths: paths, untracked: untracked, keepingStaged: keepingStaged, message: message)
            self?.record(.discarded(label: label, record: record, message: message),
                         toast: "Discarded changes to \(name) · Kaern kept a copy in Stashes")
        }
    }

    /// Adds a pattern to `.gitignore`; ⌘Z puts the file back.
    func ignore(pattern: String) {
        let before = Set(status.entries.map(\.path))
        perform(.working("Updating .gitignore…"), trigger: "Ignore \(pattern)") { [weak self] repository in
            let edit = try repository.addIgnorePattern(pattern)
            let after = Set((try await repository.status()).entries.map(\.path))
            let gone = before.subtracting(after).count
            self?.record(.ignored(edit: edit),
                         toast: "Added \(pattern) to .gitignore · " + (gone == 1 ? "1 file is" : "\(gone) files are") + " no longer listed")
        }
    }

    // MARK: Lines

    /// Picks a changed line: a click picks it alone (or clears it), ⇧ picks a range from the
    /// last pick, ⌘ adds or removes one. `order` is the file's changed lines as shown.
    func pickLine(_ pick: LinePick, path: String, order: [LinePick], command: Bool, shift: Bool) {
        if linePicks.path != path { linePicks = LinePicks(path: path) }
        if shift, let anchor = linePicks.anchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: pick) {
            linePicks.lines = Set(order[min(a, b)...max(a, b)])
        } else if command {
            if linePicks.lines.contains(pick) { linePicks.lines.remove(pick) } else { linePicks.lines.insert(pick) }
            linePicks.anchor = pick
        } else {
            linePicks.lines = linePicks.lines == [pick] ? [] : [pick]
            linePicks.anchor = pick
        }
    }

    func clearLinePicks() {
        linePicks = LinePicks()
    }

    /// Stages the picked unstaged lines, or unstages the picked lines when they're all staged.
    func stagePickedLines() {
        guard let path = linePicks.path, let diffs = workingDiffs[path] else { return }
        let unstaged = linePicks.selection(.unstaged)
        let staged = linePicks.selection(.staged)
        if !unstaged.isEmpty, let diff = diffs.unstaged {
            let count = linePicks.unstaged.count
            changeIndex(label: count == 1 ? "Stage 1 Line" : "Stage \(count) Lines", paths: [path]) {
                try await $0.stage(lines: unstaged, of: diff)
            }
        } else if !staged.isEmpty, let diff = diffs.staged {
            let count = linePicks.staged.count
            changeIndex(label: count == 1 ? "Unstage 1 Line" : "Unstage \(count) Lines", paths: [path]) {
                try await $0.unstage(lines: staged, of: diff)
            }
        }
        clearLinePicks()
    }

    /// Throws away the picked unstaged lines after keeping a copy of the file in the stash list.
    func discardPickedLines() {
        guard let path = linePicks.path, let diff = workingDiffs[path]?.unstaged else { return }
        let selection = linePicks.selection(.unstaged)
        let count = linePicks.unstaged.count
        guard count > 0 else { return }
        let label = count == 1 ? "Discard 1 Line" : "Discard \(count) Lines"
        let message = "Before discarding \(Formatters.count(count, "line", "lines")) of \((path as NSString).lastPathComponent)"
        clearLinePicks()
        perform(.working("Discarding \(Formatters.count(count, "line", "lines"))…"), trigger: label) { [weak self] repository in
            guard let result = try await repository.discardLines(selection, of: diff, message: message) else { return }
            self?.record(.discardedLines(label: label, path: path, patch: result.patch, stash: result.stash, message: message),
                         toast: "Discarded \(Formatters.count(count, "line", "lines")) · Kaern kept a copy in Stashes")
        }
    }

    // MARK: Opening files

    func fileURL(_ path: String) -> URL? {
        repository?.root.appending(path: path)
    }

    /// "Open in Xcode": the app macOS opens the file with.
    func defaultAppName(for path: String) -> String? {
        guard let url = fileURL(path), let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return FileManager.default.displayName(atPath: app.path(percentEncoded: false)).replacingOccurrences(of: ".app", with: "")
    }

    func open(path: String, line: Int? = nil) {
        guard let url = fileURL(path) else { return }
        if let line, FileManager.default.isExecutableFile(atPath: "/usr/bin/xed"),
           NSWorkspace.shared.urlForApplication(toOpen: url)?.lastPathComponent.hasPrefix("Xcode") == true {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/xed")
            process.arguments = ["--line", String(line), url.path(percentEncoded: false)]
            try? process.run()
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Stashes

extension RepositoryModel {
    /// Apply or Pop: no question; ⌘Z takes the changes back out (and puts a popped stash back).
    func applyStash(_ stash: Stash, pop: Bool) {
        let label = (pop ? "Pop " : "Apply ") + stash.reference
        perform(pop ? .popping : .working("Applying \(stash.reference)…"), trigger: label) { [weak self] repository in
            let applied = try await repository.applyStashReportingConflicts(stash, pop: pop)
            let text = pop ? "Popped \(stash.reference) · \(Self.stashTitle(stash))" : "Applied \(stash.reference) · the stash stays in the list"
            self?.record(applied.map(ReversibleStep.applied), toast: text)
            if pop, self?.screen == .stash(stash.id) { self?.screen = nil }
        } onFailure: { [weak self] error in
            // Stopped on conflicts: the operation bar offers Undo Pop and the editor opens.
            guard let self, let conflict = error as? StashApplyConflict else { return false }
            self.stashConflict = conflict
            self.conflictSession = nil
            self.openConflictsAfterRefresh()
            return true
        }
    }

    /// Drop: no question; ⌘Z puts the stash back in the list.
    func dropStash(_ stash: Stash) {
        perform(.working("Dropping \(stash.reference)…"), trigger: "Drop \(stash.reference)") { [weak self] repository in
            try await repository.dropStash(stash)
            self?.record(.droppedStash(stash), toast: "Dropped \(stash.reference) · ⌘Z brings it back")
        }
    }

    /// "release notes" from "On develop: release notes".
    /// A copy Kaern stashed itself: its messages start with "Before " ("Before discarding ci.yml").
    static func isKaernCopy(_ stash: Stash) -> Bool {
        stashTitle(stash).hasPrefix("Before ")
    }

    static func stashTitle(_ stash: Stash) -> String {
        guard let colon = stash.message.firstIndex(of: ":"), stash.message.hasPrefix("On ") || stash.message.hasPrefix("WIP on ") else {
            return stash.message
        }
        return stash.message[stash.message.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Push

extension RepositoryModel {
    /// Push: a branch without upstream opens the publish popover; a branch that rewrote commits
    /// already on its remote asks before force-pushing with lease; otherwise it pushes.
    func push() {
        guard let branch = status.branch else {
            showToast("Not on a branch — create a branch here to push these commits")
            return
        }
        guard !remotes.isEmpty else { return }
        guard let upstream = status.upstream else {
            publishDraft = PublishDraft(branch: branch, remote: defaultRemote ?? "origin", name: branch, track: true)
            return
        }
        let tracked = refs.remoteBranch(named: upstream)
        if status.ahead > 0, status.behind > 0, let tracked, let remote = tracked.remoteName, let repository {
            let source = uiSource
            Task {
                let check = GitCommandTrigger(source.map { "\($0) › Push › checking the remote branch" } ?? "Push › checking the remote branch")
                let (rewritten, lost) = await GitCommandTrigger.$current.withValue(check) {
                    let rewritten = await repository.branchHadCommit(branch, commit: tracked.target)
                    let lost = rewritten ? ((try? await repository.summaries(["HEAD..\(upstream)"], limit: 20)) ?? []) : []
                    return (rewritten, lost)
                }
                if rewritten {
                    askForcePush(branch: branch, remote: remote, remoteBranch: tracked.branchName, expected: tracked.target, lost: lost)
                } else {
                    pushNow(remote: remote, upstream: upstream)
                }
            }
            return
        }
        guard status.ahead > 0 else {
            showToast("Nothing to push · \(upstream) is up to date")
            return
        }
        pushNow(remote: tracked?.remoteName ?? defaultRemote, upstream: upstream)
    }

    private func pushNow(remote: String?, upstream: String) {
        let count = status.ahead
        perform(.pushing(remote: remote), trigger: "Push") { [weak self] repository in
            try await repository.push()
            self?.showToast("Pushed \(Formatters.count(count, "commit", "commits")) to \(upstream)")
        }
    }

    private func askForcePush(branch: String, remote: String, remoteBranch: String, expected: String, lost: [CommitSummary]) {
        confirmation = Confirmation(
            title: "Force push “\(branch)”?",
            message: "You rewrote \(Formatters.count(lost.count, "commit", "commits")) that \(lost.count == 1 ? "is" : "are") already on \(remote). Pushing replaces the old versions below. With lease, Kaern stops if someone else pushed since your last fetch.",
            lost: lost,
            note: "Teammates who pulled the old commits will need to rebase onto the new ones.",
            confirmTitle: "Force Push with Lease",
            confirm: { [weak self] in
                self?.perform(.pushing(remote: remote), trigger: "Push › Force Push with Lease") { [weak self] repository in
                    try await repository.forcePush(to: remote, branch: remoteBranch, expected: expected)
                    self?.showToast("Force-pushed with lease · \(remote) now matches your branch")
                }
            }
        )
    }

    /// The publish popover's Publish (or Push Once without tracking).
    func publish(_ draft: PublishDraft) {
        publishDraft = nil
        perform(.network("Publishing \(draft.branch) to \(draft.remote)…"), trigger: "Push › Publish \(draft.branch)") { [weak self] repository in
            try await repository.publish(to: draft.remote, as: draft.name, track: draft.track)
            self?.showToast("Published \(draft.branch) to \(draft.remote)" + (draft.track ? " · Pull and Push use it from now on" : ""))
        }
    }
}

// MARK: - Picking commits and comparing

extension RepositoryModel {
    /// A click on a commit row: plain selects it, ⌘ adds or removes it from the picked commits,
    /// ⇧ picks the rows between the last pick and this one.
    func click(commit id: String, command: Bool, shift: Bool) {
        selectedWorktree = nil
        if command {
            var set = picked
            if set.isEmpty, case .commit(let current) = selection, current != id { set = [current] }
            if let index = set.firstIndex(of: id) { set.remove(at: index) } else { set.append(id) }
            pickAnchor = id
            branchCompare = nil
            if set.count == 1 {
                picked = []
                selection = .commit(set[0])
            } else {
                picked = set
            }
        } else if shift, let anchor = pickAnchor ?? selectedCommitID,
                  let a = commits.firstIndex(where: { $0.id == anchor }), let b = commits.firstIndex(where: { $0.id == id }), a != b {
            picked = commits[min(a, b)...max(a, b)].map(\.id)
            pickFocus = id
            branchCompare = nil
        } else {
            picked = []
            pickAnchor = id
            pickFocus = nil
            branchCompare = nil
            selection = .commit(id)
        }
    }

    /// ⇧↑ / ⇧↓ in the graph: the picked range grows or shrinks by one row at its moving end, as
    /// ⇧-clicking the next row would (folded bot runs are stepped over). Returns the row the
    /// moving end is on, to scroll to.
    @discardableResult
    func extendPick(by step: Int) -> String? {
        guard let anchor = pickAnchor ?? selectedCommitID else { return nil }
        let rows = displayCommits.filter { botRuns[$0.id] == nil }.map(\.id)
        let end = pickFocus ?? anchor
        guard let index = rows.firstIndex(of: end) else { return nil }
        let next = min(max(index + step, 0), rows.count - 1)
        let target = rows[next]
        pickAnchor = anchor
        if target == anchor {
            // Back to one commit.
            picked = []
            pickFocus = nil
            branchCompare = nil
            selection = .commit(anchor)
        } else {
            click(commit: target, command: false, shift: true)
        }
        return target
    }

    var selectedCommitID: String? {
        if case .commit(let id) = selection { return id }
        return nil
    }

    func clearPicks() {
        picked = []
        pickFocus = nil
        branchCompare = nil
        compareSwapped = false
    }

    func compareWithHead(_ id: String) {
        guard let head = status.headID, head != id else { return }
        branchCompare = nil
        compareSwapped = false
        picked = [id, head]
        pickAnchor = id
    }

    func compare(branch name: String) {
        picked = []
        compareSwapped = false
        branchCompare = BranchCompareState(other: name)
    }

    /// Opens Review on the changes between `id` and the working tree.
    func compareWithWorkingCopy(_ id: String) {
        clearPicks()
        review = ReviewState(showsAllFiles: true, compare: CompareRange(base: id, target: nil))
    }

    /// The two picked commits, older first (by their row: newer rows are higher).
    var pickedPair: (older: String, newer: String)? {
        guard picked.count == 2 else { return nil }
        let a = picked[0], b = picked[1]
        return row(a) > row(b) ? (a, b) : (b, a)
    }

    /// Identity of what the compare panel should show now.
    var comparisonKey: String? {
        if let branchCompare {
            let tip = refs.localBranch(named: branchCompare.other)?.target ?? refs.remoteBranch(named: branchCompare.other)?.target ?? ""
            return "b:\(status.headID ?? ""):\(branchCompare.other):\(tip)"
        }
        if let pair = pickedPair {
            return "c:\(pair.older):\(pair.newer):\(compareSwapped)"
        }
        return nil
    }

    /// Loads the compare panel's data when what's picked changed.
    func refreshComparisonIfNeeded() {
        guard let key = comparisonKey, let repository, phase == .ready else {
            compareTask?.cancel()
            if comparison != nil { comparison = nil }
            return
        }
        guard comparison?.key != key else { return }
        // Being read already: this runs after every refresh, and each one started it over.
        if loadingComparison == key, compareTask?.isCancelled == false { return }
        compareTask?.cancel()
        loadingComparison = key
        if let branchCompare {
            let other = branchCompare.other
            compareTask = Task { [weak self] in
                let loaded = await GitCommandTrigger.$current.withValue(.background("Compare with \(other)")) { () async -> Comparison? in
                    guard let result = try? await repository.compare("HEAD", with: other) else { return nil }
                    async let ours = try? repository.summaries(["\(other)..HEAD"], limit: 50)
                    async let theirs = try? repository.summaries(["HEAD..\(other)"], limit: 50)
                    async let files = try? repository.changedFiles(from: "HEAD", to: other)
                    var comparison = Comparison(key: key, kind: .branches(theirs: other))
                    comparison.ours = await ours ?? []
                    comparison.theirs = await theirs ?? []
                    comparison.oursCount = result.ours.count
                    comparison.theirsCount = result.theirs.count
                    comparison.oursIDs = Set(result.ours)
                    comparison.theirsIDs = Set(result.theirs)
                    comparison.base = result.base
                    comparison.files = await files ?? []
                    return comparison
                }
                guard !Task.isCancelled else { return }
                self?.loadingComparison = nil
                guard let loaded else { return }
                self?.comparison = loaded
            }
        } else if let pair = pickedPair {
            let swapped = compareSwapped
            let picked = Set(picked)
            compareTask = Task { [weak self] in
                let loaded = await GitCommandTrigger.$current.withValue(.background("Compare two commits")) { () async -> Comparison? in
                    async let ids = try? repository.commitIDs(from: pair.older, to: pair.newer)
                    async let list = try? repository.summaries(["\(pair.older)..\(pair.newer)"], limit: 50)
                    async let linear = repository.isAncestor(pair.older, of: pair.newer)
                    async let files = try? repository.changedFiles(from: swapped ? pair.newer : pair.older, to: swapped ? pair.older : pair.newer)
                    var comparison = Comparison(key: key, kind: .commits(older: pair.older, newer: pair.newer))
                    let all = await ids ?? []
                    comparison.between = await list ?? []
                    comparison.betweenCount = all.count
                    comparison.linear = await linear
                    if comparison.linear {
                        comparison.base = pair.older
                    } else {
                        comparison.base = await repository.mergeBase(pair.older, pair.newer)
                    }
                    comparison.files = await files ?? []
                    comparison.rangeIDs = Set(all).subtracting(picked)
                    return comparison
                }
                guard !Task.isCancelled else { return }
                self?.loadingComparison = nil
                guard let loaded else { return }
                self?.comparison = loaded
            }
        }
    }

    // MARK: Copying and web pages

    func copy(_ text: String, toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(toast)
    }

    func copySHAs(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        copy(ids.joined(separator: " "), toast: ids.count == 1 ? "Copied \(short(ids[0]))" : "Copied \(ids.count) commit hashes")
    }

    func copyMessage(of id: String) {
        guard let repository else { return }
        Task {
            guard let message = try? await repository.message(of: id) else { return }
            copy(message, toast: "Copied “\(message.split(separator: "\n").first.map(String.init) ?? "")”")
        }
    }

    /// The default remote's address as a `RemoteURL`.
    var remoteURL: RemoteURL? {
        guard let name = defaultRemote, let info = remotes.first(where: { $0.name == name }) else { return nil }
        return RemoteURL(info.fetchURL)
    }

    /// "GitHub" for the menu ("Open on GitHub").
    var hostName: String? {
        guard let url = remoteURL, url.webPage != nil else { return nil }
        return url.hostName
    }
}

/// What Review compares when it isn't the selection: a commit with another, or with the
/// working tree (`target` `nil`).
struct CompareRange: Equatable {
    var base: String
    var target: String?
}
