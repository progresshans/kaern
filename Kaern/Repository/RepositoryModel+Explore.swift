import AppKit
import Foundation
import KaernKit

/// File History and Blame (ScreenExplore): one file, the commits that changed it or who last
/// changed each line.
struct ExploreState: Equatable {
    enum Mode: Equatable { case history, blame }

    var path: String
    var mode: Mode
    /// History: the commit whose change to the file shows below the list.
    var selected: String?
    /// Blame: as of this commit; `nil` is the working copy.
    var blameAt: String?
    var ignoreWhitespace = true
    var detectMoves = false
    /// Blame: the commit whose lines are highlighted (its details on the right).
    var focused: String?
    /// Blame: the block that was clicked (its gutter is selected; the commit's other blocks are tinted).
    var focusedChunk: Int?
}

/// The commit the right panel shows while exploring a file.
struct ExploreCommit: Equatable {
    var id: String
    var details: CommitDetails
    var files: [FileChange]
}

extension RepositoryModel {
    // MARK: Opening

    /// Show File History for `path` (selecting `commit` when given).
    func showFileHistory(_ path: String, at commit: String? = nil) {
        review = nil
        clearPicks()
        let previous = explore
        explore = ExploreState(path: path, mode: .history, selected: commit, blameAt: nil,
                               ignoreWhitespace: previous?.ignoreWhitespace ?? true, detectMoves: previous?.detectMoves ?? false)
        screen = .explore
        loadFileHistory()
    }

    /// Blame `path` in the working copy, or as of `revision`.
    func showBlame(_ path: String, at revision: String? = nil) {
        review = nil
        clearPicks()
        let previous = explore
        explore = ExploreState(path: path, mode: .blame, selected: previous?.path == path ? previous?.selected : nil, blameAt: revision,
                               ignoreWhitespace: previous?.ignoreWhitespace ?? true, detectMoves: previous?.detectMoves ?? false)
        screen = .explore
        loadBlame()
    }

    func setExploreMode(_ mode: ExploreState.Mode) {
        guard var state = explore, state.mode != mode else { return }
        state.mode = mode
        explore = state
        if mode == .history { loadFileHistory() } else { loadBlame() }
    }

    /// Repository › File History… / Blame…: the file shown in Review, or one picked in a panel.
    func askFileToExplore(_ mode: ExploreState.Mode) {
        if let path = review?.path ?? explore?.path {
            if mode == .history { showFileHistory(path) } else { showBlame(path) }
            return
        }
        guard let root = repository?.root else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.prompt = mode == .history ? "Show History" : "Blame"
        panel.message = mode == .history ? "Choose a file to see the commits that changed it." : "Choose a file to see who last changed each line."
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let full = url.standardizedFileURL.path(percentEncoded: false)
            guard full.hasPrefix(rootPath) else { return }
            let relative = String(full.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if mode == .history { self.showFileHistory(relative) } else { self.showBlame(relative) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    // MARK: History

    func loadFileHistory() {
        guard let repository, let state = explore else { return }
        exploreTask?.cancel()
        if fileHistory?.path != state.path { fileHistory = nil }
        let path = state.path
        exploreTask = Task {
            let entries = (try? await GitCommandTrigger.$current.withValue(.background("File History")) {
                try await repository.fileHistory(path)
            }) ?? []
            guard !Task.isCancelled, explore?.path == path else { return }
            fileHistory = (path, entries)
            let selected = explore?.selected.flatMap { id in entries.first { $0.commit.id == id } } ?? entries.first
            if let selected { selectHistoryEntry(selected.commit.id) }
        }
    }

    func selectHistoryEntry(_ id: String) {
        guard var state = explore else { return }
        state.selected = id
        explore = state
        loadHistoryDiff()
        loadExploreCommit(id)
    }

    /// The selected history entry's change to the file.
    func loadHistoryDiff() {
        guard let repository, let state = explore, let id = state.selected,
              let entry = fileHistory?.entries.first(where: { $0.commit.id == id }) else { return }
        let key = "\(id):\(entry.path):\(DiffPreferences.ignoresWhitespace):\(AppSettings.diffContext)"
        guard fileHistoryDiff?.key != key else { return }
        historyDiffTask?.cancel()
        let ignore = DiffPreferences.ignoresWhitespace
        historyDiffTask = Task {
            let change = FileChange(path: entry.path, oldPath: entry.oldPath, kind: .modified)
            let diff = try? await GitCommandTrigger.$current.withValue(.background("File History")) {
                try await repository.diff(of: change, in: entry.commit, ignoringWhitespace: ignore)
            }
            guard !Task.isCancelled, let diff else { return }
            fileHistoryDiff = (key, diff)
        }
    }

    /// The history entry's diff as one Review file.
    var historyReviewFile: ReviewFile? {
        guard let diff = fileHistoryDiff?.diff else { return nil }
        let letter = diff.isNewFile ? "A" : diff.isDeletedFile ? "D" : diff.oldPath != nil ? "R" : "M"
        let stat = diff.lineStat
        var file = ReviewFile(path: diff.path, letter: letter, additions: stat.additions ?? 0, deletions: stat.deletions ?? 0)
        file.hunks = diff.hunks.map { ReviewHunk(id: "x\($0.id)", hunk: $0, stage: .committed, path: diff.path) }
        if diff.isBinary {
            file.note = "Binary file"
        } else if diff.hunks.isEmpty {
            file.note = diff.oldPath.map { "Moved from \($0) — no line changes" } ?? "No line changes (mode or type only)"
        }
        return file
    }

    /// "moved from Sources/PowerLens/", "as Sources/PowerLens/AlphaVersion.swift", "added as …".
    func historyNote(_ entry: FileHistoryEntry, index: Int, entries: [FileHistoryEntry]) -> String? {
        if let old = entry.oldPath {
            let oldDirectory = (old as NSString).deletingLastPathComponent
            let newDirectory = (entry.path as NSString).deletingLastPathComponent
            if (old as NSString).lastPathComponent == (entry.path as NSString).lastPathComponent, oldDirectory != newDirectory {
                return "moved from \(oldDirectory.isEmpty ? "the top folder" : oldDirectory + "/")"
            }
            return "renamed from \((old as NSString).lastPathComponent)"
        }
        guard entry.path != explore?.path else { return nil }
        let isOldest = index == entries.count - 1
        return (isOldest ? "added as " : "as ") + entry.path
    }

    // MARK: Blame

    func loadBlame() {
        guard let repository, let state = explore else { return }
        let key = blameKey(state)
        guard blame?.key != key else { return }
        exploreTask?.cancel()
        exploreTask = Task {
            let loaded = try? await GitCommandTrigger.$current.withValue(.background("Blame")) {
                try await repository.blame(state.path, at: state.blameAt, ignoreWhitespace: state.ignoreWhitespace, detectMoves: state.detectMoves)
            }
            guard !Task.isCancelled else { return }
            if let loaded {
                blame = (key, loaded)
                if explore?.focused == nil, let first = loaded.chunks.first(where: { !(loaded.commits[$0.commitID]?.isUncommitted ?? true) }) {
                    explore?.focused = first.commitID
                    explore?.focusedChunk = first.id
                    loadExploreCommit(first.commitID)
                }
            } else {
                blame = (key, Blame(lines: [], commits: [:]))
            }
        }
    }

    func blameKey(_ state: ExploreState) -> String {
        "\(state.path):\(state.blameAt ?? "worktree"):\(state.ignoreWhitespace):\(state.detectMoves)"
    }

    /// The blame for the current state, `nil` while it loads.
    var currentBlame: Blame? {
        guard let state = explore, let blame, blame.key == blameKey(state) else { return nil }
        return blame.blame
    }

    func setBlameOptions(ignoreWhitespace: Bool? = nil, detectMoves: Bool? = nil, at revision: String?? = nil) {
        guard var state = explore else { return }
        if let ignoreWhitespace { state.ignoreWhitespace = ignoreWhitespace }
        if let detectMoves { state.detectMoves = detectMoves }
        if let revision { state.blameAt = revision }
        explore = state
        loadBlame()
    }

    func focusBlame(_ commitID: String, chunk: Int? = nil) {
        explore?.focused = commitID
        explore?.focusedChunk = chunk ?? currentBlame?.chunks.first { $0.commitID == commitID }?.id
        loadExploreCommit(commitID)
    }

    /// Blame Before This Commit: the file as the commit's parent had it.
    func blameBefore(_ commitID: String) {
        guard let blame = currentBlame, let commit = blame.commits[commitID], let previous = commit.previousID else {
            showToast("\(String(commitID.prefix(7))) added these lines · there’s nothing before it")
            return
        }
        explore?.path = commit.previousPath ?? commit.path
        explore?.focused = nil
        setBlameOptions(at: .some(previous))
    }

    /// Show Commit in History: back to the graph with the commit selected.
    func showCommitInHistory(_ id: String) {
        guard commit(id) != nil else {
            showToast("\(String(id.prefix(7))) is further back than the loaded history · scroll down to load more")
            return
        }
        screen = nil
        selection = .commit(id)
        scrollRequest = ScrollRequest(id: id)
    }

    /// 1 (oldest) … 5 (newest) for the blame stripe; 0 for uncommitted lines.
    func blameAge(_ commitID: String, in blame: Blame) -> Int {
        guard let commit = blame.commits[commitID], !commit.isUncommitted else { return 0 }
        let committed = blame.commits.values.filter { !$0.isUncommitted }.sorted { $0.date < $1.date }
        guard committed.count > 1, let rank = committed.firstIndex(where: { $0.id == commitID }) else { return 5 }
        return 1 + Int((Double(rank) * 4 / Double(committed.count - 1)).rounded())
    }

    // MARK: The commit on the right

    func loadExploreCommit(_ id: String) {
        guard let repository, exploreCommit?.id != id else { return }
        exploreCommitTask?.cancel()
        exploreCommitTask = Task {
            let loaded = await GitCommandTrigger.$current.withValue(.background("File History › commit details")) { () async -> ExploreCommit? in
                guard let details = try? await repository.commitDetails(id) else { return nil }
                let files = (try? await repository.changedFiles(in: details.commit)) ?? []
                return ExploreCommit(id: id, details: details, files: files)
            }
            guard !Task.isCancelled, let loaded else { return }
            exploreCommit = loaded
        }
    }

    /// The commit the panel shows: the history selection, or the focused blame chunk.
    var exploreCommitID: String? {
        guard let state = explore else { return nil }
        return state.mode == .history ? state.selected : state.focused
    }

    /// The status bar's right side while exploring.
    var exploreSummary: String? {
        guard screen == .explore, let state = explore else { return nil }
        let name = (state.path as NSString).lastPathComponent
        switch state.mode {
        case .history:
            guard let entries = fileHistory?.entries, fileHistory?.path == state.path else { return "Reading the history of \(name)…" }
            let selected = state.selected.map { " · \(String($0.prefix(7))) selected" } ?? ""
            return "\(Formatters.count(entries.count, "commit", "commits")) changed \(name)" + selected
        case .blame:
            return "Blame of \(name) at " + (state.blameAt.map { String($0.prefix(7)) } ?? "Working Copy")
        }
    }
}
