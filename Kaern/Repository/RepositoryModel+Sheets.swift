import Foundation
import KaernKit

/// New Branch, Rename Branch, or Create Branch from Stash.
struct BranchSheetRequest: Equatable {
    enum Kind: Equatable {
        /// A new branch; `at` is the start point picked first (a commit), `nil`: HEAD.
        case new(at: String?)
        case rename(String)
        case fromStash(Stash)
    }

    var kind: Kind
    var name = ""
}

/// New Tag on a commit.
struct TagSheetRequest: Equatable {
    var commit: String
}

/// Merge into…, Rebase onto…, Delete Branch…: a branch picked from a list.
struct PickSheetRequest: Equatable {
    enum Kind: Equatable { case merge, rebase, delete }
    var kind: Kind
    var selection: String?
}

/// A sheet over the window (`.sheet` on its shade).
enum RepositorySheet: Equatable, Identifiable {
    case branch(BranchSheetRequest)
    case tag(TagSheetRequest)
    case pick(PickSheetRequest)
    /// Finish Feature…: the branch goes into develop.
    case finish(FinishSheetRequest)
    case renameStash(Stash)
    case repositorySettings
    case interactiveRebase(RebaseDraft)
    /// Add Worktree… (ScreenMarks): a branch and a folder, the branch picked when given.
    case addWorktree(String?)

    var id: String {
        switch self {
        case .branch(let request): "branch:\(request.kind)"
        case .tag(let request): "tag:\(request.commit)"
        case .pick(let request): "pick:\(request.kind)"
        case .finish(let request): "finish:\(request.branch)"
        case .renameStash(let stash): "stash:\(stash.id)"
        case .repositorySettings: "settings"
        case .interactiveRebase(let draft): "rebase:\(draft.base)"
        case .addWorktree: "worktree"
        }
    }
}

/// What a typed branch name becomes, and what's wrong with it.
struct BranchNameCheck: Equatable {
    enum Tone { case plain, note, error }
    /// Spaces turned into dashes.
    var name: String
    var isValid: Bool
    var message: String
    var tone: Tone
}

extension RepositoryModel {
    /// The branch menu's Recent Branches: the current one, the ones switched to here before, then
    /// the usual bases (develop, main…), at most six.
    var recentBranches: [String] {
        var names: [String] = []
        if let current = status.branch { names.append(current) }
        for name in switchedBranches where !names.contains(name) { names.append(name) }
        for name in ["develop", "main", "master", "trunk"] where !names.contains(name) && refs.localBranch(named: name) != nil {
            names.append(name)
        }
        for ref in refs.localBranches where names.count < 6 && !names.contains(ref.name) && (ref.ahead > 0 || ref.behind > 0) {
            names.append(ref.name)
        }
        return Array(names.filter { refs.localBranch(named: $0) != nil }.prefix(6))
    }

    func showBranchSheet(_ request: BranchSheetRequest) {
        sheet = .branch(request)
    }

    /// New Branch (toolbar, ⇧⌘N, Create Branch Here… on a commit).
    func askCreateBranch(at id: String?) {
        showBranchSheet(BranchSheetRequest(kind: .new(at: id)))
    }

    /// Rename Branch… (the Branch menu, a branch's menu).
    func askRename(branch name: String) {
        showBranchSheet(BranchSheetRequest(kind: .rename(name), name: name))
    }

    /// New Tag on a commit (`Create Tag Here…`, Branch › New Tag… on HEAD).
    func askCreateTag(at id: String) {
        sheet = .tag(TagSheetRequest(commit: id))
    }

    func askMerge() { sheet = .pick(PickSheetRequest(kind: .merge, selection: nil)) }
    func askRebase() { sheet = .pick(PickSheetRequest(kind: .rebase, selection: nil)) }
    func askDeleteBranch(_ preselected: String? = nil) { sheet = .pick(PickSheetRequest(kind: .delete, selection: preselected)) }

    /// The board's rules: trimmed, spaces become dashes, git's ref-name rules, and not an existing
    /// branch (`except` is the branch being renamed).
    func checkBranchName(_ raw: String, except: String? = nil) -> BranchNameCheck {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: "-")
        if name.isEmpty {
            return BranchNameCheck(name: name, isValid: false, message: "Use / to group branches in the sidebar.", tone: .plain)
        }
        if name != except, refs.localBranch(named: name) != nil {
            return BranchNameCheck(name: name, isValid: false, message: "A branch named “\(name)” already exists.", tone: .error)
        }
        if !Self.isWellFormedRefName(name) {
            return BranchNameCheck(name: name, isValid: false,
                                   message: "Branch names can’t contain ~ ^ : ? * [ \\ or “..”, or start or end with /.", tone: .error)
        }
        if trimmed.contains(where: \.isWhitespace) {
            return BranchNameCheck(name: name, isValid: true, message: "Spaces become dashes: \(name)", tone: .note)
        }
        return BranchNameCheck(name: name, isValid: true, message: "Use / to group branches in the sidebar.", tone: .plain)
    }

    /// git's `check-ref-format` rules for one branch name, checked as you type (git checks again
    /// when the branch is made).
    static func isWellFormedRefName(_ name: String) -> Bool {
        if name.hasPrefix("/") || name.hasSuffix("/") || name.hasPrefix("-") || name.hasSuffix(".") || name.hasSuffix(".lock") { return false }
        if name.contains("..") || name.contains("@{") || name.contains("//") || name == "@" { return false }
        for scalar in name.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7f { return false }
            if "~^:?*[\\ ".unicodeScalars.contains(scalar) { return false }
        }
        return !name.split(separator: "/").contains { $0.hasPrefix(".") || $0.hasSuffix(".lock") }
    }

    /// Tag names: no spaces or ~ ^ : ? * [ \, and not an existing tag.
    func checkTagName(_ raw: String) -> (isValid: Bool, message: String?) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return (false, nil) }
        if let existing = tags.first(where: { $0.name == name }) {
            return (false, "Tag “\(name)” already exists — on \(short(existing.target)).")
        }
        if !Self.isWellFormedRefName(name) {
            return (false, "Tag names can’t contain spaces or ~ ^ : ? * [ \\.")
        }
        return (true, nil)
    }

    // MARK: Doing what the sheets ask

    func createBranch(_ name: String, from startPoint: String?, checkout: Bool) {
        guard checkout else {
            let label = "Create Branch \(name)"
            perform(.creatingBranch(name), trigger: label) { [weak self] repository in
                try await repository.createBranch(name, startPoint: startPoint, checkout: false)
                guard let self, let tip = await repository.resolve("refs/heads/\(name)") else { return }
                self.record(.createdBranchOnly(label: label, name: name, at: tip),
                            toast: "Created \(name)" + (startPoint.map { " at \(self.short($0))" } ?? ""))
            }
            return
        }
        createBranch(name, at: startPoint)
    }

    /// Renames a branch; with `remote`, also publishes the new name there and deletes the old one.
    func renameBranch(_ name: String, to newName: String, alsoOn remote: String?) {
        guard newName != name else { return }
        let upstream = refs.localBranch(named: name)?.upstream
        perform(.working("Renaming \(name)…"), trigger: "Rename \(name)") { [weak self] repository in
            try await repository.renameBranch(name, to: newName)
            guard let self else { return }
            if let remote, let upstream, let tracked = self.refs.remoteBranch(named: upstream) {
                // Not undoable on the remote: the local rename still is.
                try await repository.push(branch: newName, to: remote, as: newName)
                try await repository.setUpstream(of: newName, to: "\(remote)/\(newName)")
                try await repository.deleteRemoteBranch(tracked.branchName, on: remote)
                self.showToast("Renamed \(name) to \(newName) · \(remote) updated")
            } else {
                self.record(.renamedBranch(from: name, to: newName), toast: "Renamed \(name) to \(newName)")
            }
        }
    }

    /// New Tag: lightweight, or annotated with a message; pushed when asked.
    func createTag(_ name: String, at id: String, message: String?, push: Bool) {
        let remote = defaultRemote
        perform(.working("Creating \(name)…"), trigger: "Create Tag \(name)") { [weak self] repository in
            try await repository.createTag(name, at: id, message: message)
            guard let self, let object = await repository.resolve("refs/tags/\(name)") else { return }
            if push, let remote {
                try await repository.pushTag(name, to: remote)
                self.showToast("Tagged \(self.short(id)) as \(name) and pushed it to \(remote)")
            } else {
                self.record(.createdTag(name: name, object: object), toast: "Tagged \(self.short(id)) as \(name)")
            }
        }
    }

    /// The pickers' Merge / Rebase / Delete.
    func confirmPick(_ kind: PickSheetRequest.Kind, branch: String, option: Bool) {
        switch kind {
        case .merge:
            merge(branch, noFastForward: option)
        case .rebase:
            if option {
                askInteractiveRebase(onto: branch)
            } else {
                rebase(onto: branch)
            }
        case .delete:
            guard let ref = refs.localBranch(named: branch) else { return }
            if option, let upstream = ref.upstream, let tracked = refs.remoteBranch(named: upstream) {
                deleteOnRemote(branch: branch, remoteBranch: tracked, alsoLocal: true)
            } else {
                deleteBranch(branch)
            }
        }
    }

    /// Branches a picker lists: local ones (not the current one), then remote ones.
    func pickCandidates(_ kind: PickSheetRequest.Kind) -> [String] {
        let current = status.branch
        let locals = refs.localBranches.map(\.name).filter { $0 != current }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if kind == .delete { return locals }
        let remotes = refs.remoteBranches.filter { !$0.name.hasSuffix("/HEAD") }.map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return locals + remotes
    }

    /// What the picker says next to a branch: "brings in 4 commits", "replays 2 commits on top"…
    func pickNote(_ kind: PickSheetRequest.Kind, branch: String) async -> String {
        guard let repository else { return "" }
        let trigger = GitCommandTrigger.background("Branch picker")
        return await GitCommandTrigger.$current.withValue(trigger) {
            switch kind {
            case .merge:
                let incoming = await repository.countCommits(from: "HEAD", to: branch)
                return incoming == 0 ? "already merged" : "brings in \(Formatters.count(incoming, "commit", "commits"))"
            case .rebase:
                let behind = await repository.countCommits(from: "HEAD", to: branch)
                guard behind > 0 else { return "already on top" }
                let replayed = await repository.countCommits(from: branch, to: "HEAD")
                return "replays \(Formatters.count(replayed, "commit", "commits")) on top"
            case .delete:
                let unmerged = await repository.countCommits(from: "HEAD", to: branch)
                return unmerged == 0 ? "merged" : "\(Formatters.count(unmerged, "commit", "commits")) not merged"
            }
        }
    }
}
