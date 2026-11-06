import AppKit
import KaernKit

/// What the file lists show for a submodule or a file in Git LFS, in place of line counts.
enum FileAnnotation: Equatable {
    /// The commits a submodule moves between.
    case submodule(SubmoduleMove)
    case lfs(LFSSizes)

    var tag: String {
        switch self {
        case .submodule: String(localized: "Submodule")
        case .lfs: "LFS"
        }
    }

    var isSubmodule: Bool {
        if case .submodule = self { return true }
        return false
    }

    /// "a41c9e2 → 9f8e7d6", "48.2 MB → 51.0 MB", or one side when the other doesn't exist.
    var detail: String {
        switch self {
        case .submodule(let move):
            let old = move.old.map { String($0.prefix(7)) }
            let new = move.new.map { String($0.prefix(7)) }
            if let old, let new { return old == new ? String(localized: "changes inside") : "\(old) → \(new)" }
            return new ?? old ?? ""
        case .lfs(let sizes):
            let old = sizes.old.map(Formatters.fileSize)
            let new = sizes.new.map(Formatters.fileSize)
            if let old, let new, old != new { return "\(old) → \(new)" }
            return new ?? old ?? ""
        }
    }
}

extension Formatters {
    /// "48.2 MB", "51.0 MB" (the decimal stays, so sizes in a list line up).
    static func fileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.zeroPadsFractionDigits = true
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - File annotations

extension RepositoryModel {
    func annotation(for entry: StatusEntry) -> FileAnnotation? {
        if let move = submoduleMove(for: entry) { return .submodule(move) }
        return workingLFSSizes[entry.path].map(FileAnnotation.lfs)
    }

    func annotation(for file: FileChange) -> FileAnnotation? {
        if let move = file.submodule { return .submodule(move) }
        return detailLFSSizes[file.path].map(FileAnnotation.lfs)
    }

    /// A changed submodule goes from what HEAD records (the index, when nothing is staged) to
    /// what's checked out inside it.
    func submoduleMove(for entry: StatusEntry) -> SubmoduleMove? {
        guard let submodule = entry.submodule else { return nil }
        let checkedOut = submodules.first { $0.path == entry.path }?.commit
        let old = entry.hasStagedChanges ? submodule.headCommit : submodule.indexCommit
        let new = submodule.commitChanged ? (checkedOut ?? submodule.indexCommit) : submodule.indexCommit
        return SubmoduleMove(old: old, new: new)
    }

    func submodule(at path: String) -> Submodule? {
        submodules.first { $0.path == path }
    }

    func openSubmodule(_ path: String) {
        guard let root = repository?.root else { return }
        AppModel.shared.openInNewWindow(root.appending(path: path, directoryHint: .isDirectory))
    }

    /// Distances of the moved submodules' checked-out commits from the recorded ones.
    func reloadSubmoduleDistances() async {
        guard let repository else { return }
        var distances: [String: CommitDistance] = [:]
        for submodule in submodules where submodule.state == .moved {
            guard let recorded = status.entries.first(where: { $0.path == submodule.path })?.submodule?.indexCommit else { continue }
            distances[submodule.path] = await repository.submoduleDistance(submodule.path, recorded: recorded, checkedOut: submodule.commit)
        }
        if distances != submoduleDistances { submoduleDistances = distances }
    }

    /// Git LFS sizes of the changed files; with `countPointers`, the files git-lfs never
    /// downloaded too (that reads every LFS path's first bytes, so not on each status refresh).
    func reloadWorkingLFS(countPointers: Bool) async {
        guard let repository, repository.usesLFS else {
            if !workingLFSSizes.isEmpty { workingLFSSizes = [:] }
            if !lfsPointerFiles.isEmpty { lfsPointerFiles = [] }
            return
        }
        let entries = status.entries.filter { $0.submodule == nil }
        var renames: [String: String] = [:]
        for entry in entries { if let original = entry.originalPath { renames[entry.path] = original } }
        let sizes = await repository.lfsSizes(of: entries.map(\.path), oldPaths: renames, from: hasHead ? "HEAD" : nil, to: nil)
        if sizes != workingLFSSizes { workingLFSSizes = sizes }
        if countPointers {
            lfsPointerFiles = repository.runner.isLFSInstalled ? [] : await repository.lfsPointerFiles()
        }
    }

    /// The selected commit's files in Git LFS, with their sizes before and after (since `base`
    /// in a comparison, otherwise since the first parent).
    func loadDetailLFSSizes(for commit: Commit, since base: String?, files: [FileChange]) async {
        guard let repository, repository.usesLFS else { return }
        let plain = files.filter { $0.submodule == nil }
        var renames: [String: String] = [:]
        for file in plain { if let old = file.oldPath { renames[file.path] = old } }
        let sizes = await repository.lfsSizes(of: plain.map(\.path), oldPaths: renames, from: base ?? commit.parents.first, to: commit.id)
        guard selection == .commit(commit.id), comparisonBase == base else { return }
        detailLFSSizes = sizes
    }
}

// MARK: - Notices

/// A problem with the repository's files that doesn't block anything but explains what's missing
/// (the bar under the toolbar).
enum RepositoryNotice: Hashable, Identifiable {
    case submodulesNotCloned([Submodule])
    case lfsNotInstalled(pointers: Int)

    var id: String {
        switch self {
        case .submodulesNotCloned: "submodules"
        case .lfsNotInstalled: "lfs"
        }
    }
}

extension RepositoryModel {
    var notices: [RepositoryNotice] {
        var notices: [RepositoryNotice] = []
        let missing = submodules.filter { $0.state == .notInitialized }
        if !missing.isEmpty { notices.append(.submodulesNotCloned(missing)) }
        if !lfsPointerFiles.isEmpty { notices.append(.lfsNotInstalled(pointers: lfsPointerFiles.count)) }
        return notices.filter { !dismissedNotices.contains($0.id) }
    }

    /// Clones the submodules that aren't (`git submodule update --init`).
    func cloneSubmodules(_ submodules: [Submodule]) async {
        let title = submodules.count == 1
            ? String(localized: "Cloning \(submodules[0].name)…")
            : String(localized: "Cloning \(submodules.count) submodules…")
        await perform(.working(title), failureTitle: String(localized: "Couldn't Clone the Submodule"), remote: .fetch) { repository in
            for submodule in submodules {
                try await repository.updateSubmodule(submodule.path)
            }
        }
    }

    static let lfsInstallCommand = "brew install git-lfs && git lfs install"
}

// MARK: - Worktrees

extension RepositoryModel {
    /// What Kaern calls a worktree: its folder's name, or the folder above it when several share
    /// a name (tools that check out each task as …/<task>/<repository>). The main working tree,
    /// listed first, keeps its own name.
    func title(of worktree: Worktree) -> String {
        let namesakes = worktrees.count(where: { $0.name == worktree.name })
        guard worktree.id != worktrees.first?.id, namesakes > 1 else { return worktree.name }
        let parent = ((worktree.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return parent.isEmpty || parent == "/" ? worktree.name : parent
    }

    /// Branch › New Worktree…: checks out `branch` (new from `startPoint` when given) in `folder`
    /// and opens it in its own window.
    @discardableResult
    func addWorktree(branch: String, newBranchFrom startPoint: String?, at folder: URL) async -> Bool {
        let added = await perform(.working(String(localized: "Creating worktree…")), failureTitle: String(localized: "Couldn't Create the Worktree")) { repository in
            try await repository.addWorktree(at: folder, branch: branch, newBranchFrom: startPoint)
        }
        if added {
            AppModel.shared.openInNewWindow(folder)
        }
        return added
    }

    /// Removes another working tree's folder (git refuses while it has uncommitted changes, so
    /// nothing is lost: ⌘Z checks the branch out there again).
    func removeWorktree(_ worktree: Worktree) async {
        let branch = worktree.branch
        let removed = await perform(.working(String(localized: "Removing \(title(of: worktree))…")), failureTitle: String(localized: "Couldn't Remove the Worktree")) { repository in
            try await repository.removeWorktree(worktree.path)
        }
        guard removed, let branch else { return }
        let folder = URL(filePath: worktree.path, directoryHint: .isDirectory)
        registerUndo(String(localized: "Remove Worktree"), hint: String(localized: "Removed the worktree \(title(of: worktree))")) { model in
            await model.undoStep(String(localized: "Remove Worktree")) { repository in
                try await repository.addWorktree(at: folder, branch: branch, newBranchFrom: nil)
            }
        }
    }
}

// MARK: - Allowed signers

extension RepositoryModel {
    /// Adds an SSH key to the allowed signers file so git verifies its signatures. Without a
    /// `gpg.ssh.allowedSignersFile`, the file is ~/.config/git/allowed_signers and the setting
    /// goes to ~/.gitconfig.
    func addAllowedSigner(principal: String, key: String, to file: URL, setGlobalConfig: Bool) async {
        guard let repository else { return }
        do {
            try GitRepository.addAllowedSigner(principal: principal, key: key, to: file)
            if setGlobalConfig {
                try await repository.runner.setGlobalConfig("gpg.ssh.allowedSignersFile", file.path(percentEncoded: false))
            }
        } catch {
            showError(error, title: String(localized: "Couldn't Add the Key"))
            return
        }
        recheckSignatures()
    }

    static var defaultAllowedSignersFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/git/allowed_signers")
    }
}
