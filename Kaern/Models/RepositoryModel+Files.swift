import AppKit
import Foundation
import KaernKit

/// File History in place of the history table: the commits that changed one file (following
/// renames), with the file's diff in the selected commit below, or Blame — who last changed
/// each line.
struct FileHistoryState: Equatable {
    enum Mode: Hashable {
        case history
        case blame
    }

    /// The file as asked for (its current name).
    var path: String
    /// Where the history starts: HEAD, or the commit whose file list it was opened from.
    var startRevision: String
    var mode: Mode
    /// `nil` while loading.
    var entries: [FileHistoryEntry]?
    var error: String?
    var selectedID: String?

    var blameRevision: BlameRevision = .workingCopy
    /// The file's path at `blameRevision` (older commits may know it by an older name).
    var blamePath: String
    var blame: Blame?
    var blameError: String?
    var isLoadingBlame = false
    /// The first line index of the selected blame block.
    var selectedChunk: Int?

    /// The file's path in the commit the inspector shows. Picking another file there leaves
    /// File History for that file's diff.
    var inspectedPath: String?

    var selectedEntry: FileHistoryEntry? {
        guard let selectedID else { return nil }
        return entries?.first { $0.id == selectedID }
    }
}

/// What Blame looks at: the file on disk, the latest commit, or an older commit.
enum BlameRevision: Hashable {
    case workingCopy
    case head
    case commit(id: String, label: String)

    var revision: String? {
        switch self {
        case .workingCopy: nil
        case .head: "HEAD"
        case .commit(let id, _): id
        }
    }
}

extension RepositoryModel {
    /// Shows every commit that changed `path` (right-click a file › Show File History). From a
    /// commit's file list the history starts at that commit.
    func showFileHistory(_ path: String, from commitID: String? = nil, mode: FileHistoryState.Mode = .history) {
        var state = FileHistoryState(path: path, startRevision: commitID ?? "HEAD", mode: mode, blamePath: path)
        if let commitID, let commit = commit(withID: commitID), commitID != status.headID {
            state.blameRevision = .commit(id: commitID, label: "\(commit.shortID) · \(commit.subject)")
        }
        searchText = ""
        fileHistory = state
        Task { await loadFileHistory(preferring: commitID) }
        if mode == .blame {
            Task { await loadBlame() }
        }
    }

    /// "‹ History" or Esc in a diff: back to the history table, with keyboard focus there.
    func closeDiff() {
        selectedFile = nil
        historyFocusRequest += 1
    }

    func closeFileHistory() {
        guard fileHistory != nil else { return }
        fileHistory = nil
        selectedFile = nil
        historyFocusRequest += 1
        // A commit from further back than the loaded pages has no row to show as selected.
        if case .commit(let id) = selection, commitIndex[id] == nil {
            selection = .workingCopy
        }
    }

    /// Loads (or reloads, when HEAD moves) the commits that changed the file.
    func loadFileHistory(preferring preferred: String? = nil) async {
        guard let repository, let state = fileHistory else { return }
        do {
            let entries = try await repository.fileHistory(state.path, from: state.startRevision)
            guard fileHistory?.path == state.path, fileHistory?.startRevision == state.startRevision else { return }
            for entry in entries where commitIndex[entry.commit.id] == nil {
                knownCommits[entry.commit.id] = entry.commit
            }
            fileHistory?.entries = entries
            fileHistory?.error = nil
            let keep = fileHistory?.selectedID.flatMap { id in entries.first { $0.id == id } }
            let wanted = preferred.flatMap { id in entries.first { $0.id == id } }
            if fileHistory?.mode == .history, let entry = wanted ?? keep ?? entries.first {
                selectFileHistoryEntry(entry.id)
            } else if let entry = wanted ?? keep ?? entries.first {
                fileHistory?.selectedID = entry.id
            }
        } catch {
            guard fileHistory?.path == state.path else { return }
            fileHistory?.entries = []
            fileHistory?.error = error.localizedDescription
        }
    }

    func selectFileHistoryEntry(_ id: String?) {
        guard let id, let entry = fileHistory?.entries?.first(where: { $0.id == id }) else { return }
        fileHistory?.selectedID = id
        inspect(entry.commit, file: entry.path)
    }

    func setFileHistoryMode(_ mode: FileHistoryState.Mode) {
        guard let state = fileHistory, state.mode != mode else { return }
        fileHistory?.mode = mode
        switch mode {
        case .history:
            selectFileHistoryEntry(state.selectedID ?? state.entries?.first?.id)
        case .blame:
            if state.blame == nil {
                Task { await loadBlame() }
            } else if let chunk = state.blame?.chunks.first(where: { $0.id == state.selectedChunk }) {
                selectBlameChunk(chunk)
            }
        }
    }

    /// Shows a commit in the inspector, with the file selected in its file list, without
    /// leaving File History.
    private func inspect(_ commit: Commit, file: String?) {
        if commitIndex[commit.id] == nil {
            knownCommits[commit.id] = commit
        }
        fileHistory?.inspectedPath = file
        isInspectingForFileHistory = true
        defer { isInspectingForFileHistory = false }
        if selection == .commit(commit.id) {
            if let file, detailFiles.contains(where: { $0.path == file }) {
                selectedFile = .commit(commitID: commit.id, path: file)
            } else {
                // The file list is still loading; it selects the file when it arrives.
                pendingFileSelection = file
            }
        } else {
            pendingFileSelection = file
            selection = .commit(commit.id)
        }
    }

    /// Whether a change of `selection` or `selectedFile` came from File History itself.
    func fileHistoryKeeps(_ file: FileSelection?) -> Bool {
        guard let fileHistory else { return true }
        switch file {
        case nil: return true
        case .commit(_, let path): return path == fileHistory.inspectedPath
        case .working: return false
        }
    }

    // MARK: Blame

    func loadBlame() async {
        guard let repository, let state = fileHistory else { return }
        fileHistory?.isLoadingBlame = true
        let path = state.blamePath
        let revision = state.blameRevision
        do {
            let blame = try await repository.blame(
                path, at: revision.revision,
                ignoreWhitespace: Preferences.blameIgnoreWhitespace, detectMoves: Preferences.blameDetectMoves
            )
            guard fileHistory?.blamePath == path, fileHistory?.blameRevision == revision else { return }
            fileHistory?.blame = blame
            fileHistory?.blameError = nil
            if let selected = fileHistory?.selectedChunk, !blame.chunks.contains(where: { $0.id == selected }) {
                fileHistory?.selectedChunk = nil
            }
        } catch {
            guard fileHistory?.blamePath == path, fileHistory?.blameRevision == revision else { return }
            fileHistory?.blame = nil
            fileHistory?.blameError = Self.blameErrorText(error, path: path)
        }
        fileHistory?.isLoadingBlame = false
    }

    private static func blameErrorText(_ error: any Error, path: String) -> String {
        let message = (error as? GitError)?.message ?? error.localizedDescription
        if message.contains("no such path") {
            return String(localized: "“\((path as NSString).lastPathComponent)” isn't committed yet, so there's no one to blame.")
        }
        if message.contains("No such file") || message.contains("cannot stat") {
            return String(localized: "“\((path as NSString).lastPathComponent)” isn't in the working copy. Pick a commit in Blame at.")
        }
        return message
    }

    func setBlameRevision(_ revision: BlameRevision, path: String? = nil) {
        guard fileHistory != nil else { return }
        fileHistory?.blameRevision = revision
        fileHistory?.blamePath = path ?? fileHistory?.path ?? ""
        fileHistory?.selectedChunk = nil
        fileHistory?.blame = nil
        fileHistory?.blameError = nil
        Task { await loadBlame() }
    }

    /// Clicking a block shows its commit on the right.
    func selectBlameChunk(_ chunk: BlameChunk) {
        fileHistory?.selectedChunk = chunk.id
        guard let info = fileHistory?.blame?.commits[chunk.commitID] else { return }
        if info.isUncommitted {
            fileHistory?.inspectedPath = nil
            isInspectingForFileHistory = true
            selection = .workingCopy
            isInspectingForFileHistory = false
            return
        }
        if let commit = commit(withID: info.id) {
            inspect(commit, file: info.path)
        } else {
            Task {
                guard let commit = try? await repository?.commit(info.id), fileHistory?.selectedChunk == chunk.id else { return }
                inspect(commit, file: info.path)
            }
        }
    }

    /// Blame Before This Commit: the file as it was just before `commitID` changed those lines.
    func blameBefore(_ commitID: String) {
        guard let info = fileHistory?.blame?.commits[commitID], let previous = info.previousID else { return }
        setBlameRevision(.commit(id: previous, label: String(localized: "Before \(info.shortID)")), path: info.previousPath ?? info.path)
    }

    /// Show Commit in History: back to the history table with the commit selected (loading
    /// older pages when it's further back).
    func showCommitInHistory(_ id: String) {
        fileHistory = nil
        selectedFile = nil
        if commitIndex[id] != nil {
            selection = .commit(id)
        } else {
            Task { await loadHistory(until: id) }
        }
    }

    func copyMessage(of id: String) async {
        guard let message = try? await repository?.message(of: id) else { return }
        Pasteboard.copy(message)
    }

    /// Open Commit on GitHub (or the remote's host).
    func openCommitOnHost(_ id: String) {
        guard let url = primaryRemote?.commitPage(id) else { return }
        NSWorkspace.shared.open(url)
    }
}


// MARK: - Submodules and worktrees

extension RepositoryModel {
    /// Clone Submodule, or check out the commit this repository records for it.
    func updateSubmodule(_ submodule: Submodule) async {
        await perform(.working(String(localized: "Updating \(submodule.name)…")),
                      failureTitle: String(localized: "Couldn't Update \(submodule.name)"), remote: .fetch) { repository in
            try await repository.updateSubmodule(submodule.path)
        }
    }

    func isCurrentWorktree(_ worktree: Worktree) -> Bool {
        URL(filePath: worktree.path).plainPath == repository?.root.plainPath
    }
}
