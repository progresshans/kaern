import Foundation
import KaernKit

/// What Review shows: the selection's files, all of them one under another or one at a time.
struct ReviewState: Equatable {
    /// All files one under another (`false`: one file, with ‹ › between files).
    var showsAllFiles = true
    /// The file shown in One File mode, or scrolled to in All Files (`nil`: the first).
    var path: String?
}

/// Asks the history to bring a row into view ("wip" or a commit id). A new token scrolls again
/// to the same row.
struct ScrollRequest: Equatable {
    let id: String
    var token = UUID()
}

/// The commit composer's text and Amend switch.
struct CommitDraft: Equatable {
    var summary = ""
    var body = ""
    var amend = false
    /// What was typed before Amend filled in the last commit's message (restored when Amend
    /// goes off again).
    var beforeAmend: Saved?

    struct Saved: Equatable {
        var summary: String
        var body: String
    }

    /// The commit message: summary, a blank line, then the description.
    var message: String {
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? summary : summary + "\n\n" + body
    }

    static let summaryLimit = 72
}

/// One working-copy file's diffs: staged (HEAD → index) and unstaged (index → work tree).
struct WorkingFileDiff: Equatable {
    var staged: FileDiff?
    var unstaged: FileDiff?
}

/// The Search find bar: what to look for, and which loaded commits match.
struct HistorySearch: Equatable {
    var isOpen = false
    var query = ""
    var scope: CommitSearchScope = .all
    /// Commits git found in the whole history for `gitKey` (full messages and paths need git).
    var gitMatches: Set<String> = []
    var gitKey: String?
    /// Matching loaded commits, newest first.
    private(set) var matches: [String] = []
    private(set) var matchSet: Set<String> = []

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    /// The find bar is open with something typed: rows that don't match are dimmed.
    var isFiltering: Bool { isOpen && !trimmedQuery.isEmpty }
    var key: String { scope.rawValue + ":" + trimmedQuery }

    func isDimmed(_ id: String) -> Bool { isFiltering && !matchSet.contains(id) }

    mutating func refreshLocalMatches(in commits: [Commit]) {
        guard isFiltering else {
            matches = []
            matchSet = []
            return
        }
        let query = trimmedQuery
        let scope = scope
        let git = gitKey == key ? gitMatches : []
        matches = commits.filter { Self.matches($0, query: query, scope: scope) || git.contains($0.id) }.map(\.id)
        matchSet = Set(matches)
    }

    /// What a loaded row shows is enough for these; full messages and paths come from git.
    static func matches(_ commit: Commit, query: String, scope: CommitSearchScope) -> Bool {
        switch scope {
        case .all:
            return scope.matchesLoaded(commit, query: query) || commit.bodyPreview.localizedCaseInsensitiveContains(query)
        case .message:
            return scope.matchesLoaded(commit, query: query) || commit.bodyPreview.localizedCaseInsensitiveContains(query)
        case .author, .sha, .path:
            return scope.matchesLoaded(commit, query: query)
        }
    }

    /// Scopes git has to search (the loaded rows can't tell everything).
    var needsGit: Bool { scope == .all || scope == .message || scope == .path }
}

extension CommitSearchScope {
    var title: String {
        switch self {
        case .all: "All"
        case .message: "Message"
        case .author: "Author"
        case .path: "Path"
        case .sha: "SHA"
        }
    }

    var hint: String {
        switch self {
        case .all: "messages, authors and hashes"
        case .message: "summary and description"
        case .author: "name or email"
        case .path: "changed files"
        case .sha: "commit hash prefix"
        }
    }

    var placeholder: String {
        switch self {
        case .all: "Search messages, authors and commit hashes"
        case .message: "Search commit messages"
        case .author: "Search authors"
        case .path: "Search changed file paths"
        case .sha: "Search commit hashes"
        }
    }
}

// MARK: - Review

extension RepositoryModel {
    /// There's something to review: a commit, or changes in the working copy.
    var canReview: Bool {
        switch selection {
        case .workingCopy: !status.isClean
        case .commit: true
        }
    }

    /// Review on the toolbar or ⌥⌘R: all files of the selection, or back to the graph.
    func toggleReview() {
        review = review == nil && canReview ? ReviewState(showsAllFiles: true) : nil
    }
}

// MARK: - Staging and committing

extension RepositoryModel {
    var canChangeIndex: Bool { isReady && repository != nil && activity == nil }

    func stage(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        changeIndex { try await $0.stage(paths) }
    }

    func unstage(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let hasHead = status.headID != nil
        changeIndex { try await $0.unstage(paths, hasHead: hasHead) }
    }

    func stageAll() {
        guard status.entries.contains(where: \.hasUnstagedChanges) else { return }
        changeIndex { try await $0.stageAll() }
    }

    func unstageAll() {
        guard status.stagedCount > 0 else { return }
        let hasHead = status.headID != nil
        changeIndex { try await $0.unstageAll(hasHead: hasHead) }
    }

    /// Stages one hunk of the file's unstaged diff (as Review shows it).
    func stageHunk(path: String, hunk: Int) {
        guard let diff = workingDiffs[path]?.unstaged else { return }
        changeIndex { try await $0.stage(hunk: hunk, of: diff) }
    }

    /// Unstages one hunk of the file's staged diff.
    func unstageHunk(path: String, hunk: Int) {
        guard let diff = workingDiffs[path]?.staged else { return }
        let hasHead = status.headID != nil
        changeIndex { try await $0.unstage(hunk: hunk, of: diff, hasHead: hasHead) }
    }

    /// Runs an index change after the ones before it, then reads the status again.
    private func changeIndex(_ work: @escaping @Sendable (GitRepository) async throws -> Void) {
        guard canChangeIndex, let repository else { return }
        let previous = indexTask
        pendingIndexChanges += 1
        indexTask = Task {
            await previous?.value
            do {
                try await work(repository)
            } catch {
                alert = RepositoryAlert(title: "Couldn’t change what’s staged", message: error.localizedDescription)
            }
            await refreshStatusNow()
            pendingIndexChanges -= 1
        }
    }

    // MARK: Composer

    /// Whether the composer's Commit button can run.
    var canCommit: Bool {
        guard canChangeIndex else { return false }
        let hasSummary = !composer.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasSummary && (status.stagedCount > 0 || composer.amend) && operationAllowsCommit
    }

    /// A stopped rebase or merge commits through its own Continue, not the composer.
    private var operationAllowsCommit: Bool { operation == nil || operation?.kind == .merge }

    /// "Commit 3 Files", "Amend Previous Commit", "Stage Changes to Commit".
    var commitButtonTitle: String {
        if composer.amend { return "Amend Previous Commit" }
        let staged = status.stagedCount
        if staged == 0 { return "Stage Changes to Commit" }
        return staged == 1 ? "Commit 1 File" : "Commit \(staged) Files"
    }

    func commit(runHooks: Bool = true) {
        guard canCommit else { return }
        let message = composer.message
        let amend = composer.amend
        perform(amend ? .amending : .committing, { try await $0.commit(message: message, amend: amend, runHooks: runHooks) }) {
            [weak self] in
            self?.composer = CommitDraft()
            self?.selection = .workingCopy
        }
    }

    /// Amend fills in the last commit's message (what was typed comes back when Amend goes off).
    func setAmend(_ on: Bool) {
        guard on != composer.amend else { return }
        if on {
            composer.beforeAmend = CommitDraft.Saved(summary: composer.summary, body: composer.body)
            composer.amend = true
            guard let repository, status.headID != nil else { return }
            Task {
                guard let message = try? await repository.message(of: "HEAD"), composer.amend else { return }
                let parts = message.components(separatedBy: "\n\n")
                composer.summary = parts.first?.replacingOccurrences(of: "\n", with: " ") ?? ""
                composer.body = parts.dropFirst().joined(separator: "\n\n")
            }
        } else {
            composer.amend = false
            if let saved = composer.beforeAmend {
                composer.summary = saved.summary
                composer.body = saved.body
            }
            composer.beforeAmend = nil
        }
    }

    // MARK: Diffs for Review and the drawer

    /// Loads the selection's diffs when a view shows them and they're out of date.
    func refreshDiffsIfNeeded() {
        let ignoreWhitespace = DiffPreferences.ignoresWhitespace
        if workingDiffsIgnoreWhitespace != ignoreWhitespace { diffsAreStale = true }
        guard diffViewers > 0, diffsAreStale, phase == .ready, let repository else { return }
        diffsAreStale = false
        diffTask?.cancel()
        switch selection {
        case .workingCopy:
            let untracked = Array(status.entries.filter(\.isUntracked).prefix(300).map(\.path))
            diffTask = Task {
                async let staged = try? repository.workingDiffs(staged: true, ignoringWhitespace: ignoreWhitespace)
                async let unstaged = try? repository.workingDiffs(staged: false, ignoringWhitespace: ignoreWhitespace)
                // Untracked files are read from disk, off the main thread.
                let newFiles = await Task.detached { untracked.map { repository.untrackedFileDiff(path: $0) } }.value
                var result: [String: WorkingFileDiff] = [:]
                for diff in await staged ?? [] { result[diff.path, default: WorkingFileDiff()].staged = diff }
                for diff in await unstaged ?? [] { result[diff.path, default: WorkingFileDiff()].unstaged = diff }
                for diff in newFiles { result[diff.path, default: WorkingFileDiff()].unstaged = diff }
                guard !Task.isCancelled else { return }
                workingDiffs = result
                workingDiffsLoaded = true
                workingDiffsIgnoreWhitespace = ignoreWhitespace
            }
        case .commit(let id):
            if commitDiffs?.id == id, commitDiffsIgnoreWhitespace == ignoreWhitespace { return }
            guard let commit = commits.first(where: { $0.id == id }) else { return }
            diffTask = Task {
                let diffs = (try? await repository.diffs(of: commit, ignoringWhitespace: ignoreWhitespace)) ?? []
                guard !Task.isCancelled else { return }
                commitDiffs = (id, diffs)
                commitDiffsIgnoreWhitespace = ignoreWhitespace
            }
        }
    }

    /// Reloads the diffs (the white-space setting changed).
    func reloadDiffs() {
        diffsAreStale = true
        commitDiffs = nil
        refreshDiffsIfNeeded()
    }

    // MARK: Search

    func openSearch() {
        search.isOpen = true
        search.refreshLocalMatches(in: commits)
    }

    func closeSearch() {
        searchTask?.cancel()
        search = HistorySearch(scope: search.scope)
    }

    func setSearchQuery(_ text: String) {
        search.query = text
        search.refreshLocalMatches(in: commits)
        selectFirstMatchIfNeeded()
        scheduleGitSearch()
    }

    func setSearchScope(_ scope: CommitSearchScope) {
        search.scope = scope
        search.refreshLocalMatches(in: commits)
        selectFirstMatchIfNeeded()
        scheduleGitSearch()
    }

    /// Return / ⇧Return: the next or previous match after the selection, wrapping around.
    func stepSearch(_ direction: Int) {
        let matches = search.matches
        guard !matches.isEmpty else { return }
        let order = commits.map(\.id)
        let next: String
        if case .commit(let id) = selection, let at = matches.firstIndex(of: id) {
            next = matches[(at + direction + matches.count) % matches.count]
        } else {
            let selectedIndex: Int
            if case .commit(let id) = selection, let index = order.firstIndex(of: id) { selectedIndex = index } else { selectedIndex = -1 }
            let positions = matches.compactMap { id in order.firstIndex(of: id).map { (id, $0) } }
            if direction > 0 {
                next = positions.first { $0.1 > selectedIndex }?.0 ?? matches[0]
            } else {
                next = positions.last { $0.1 < selectedIndex }?.0 ?? matches[matches.count - 1]
            }
        }
        selection = .commit(next)
        scrollRequest = ScrollRequest(id: next)
    }

    /// The position of the selected match ("3 of 12"), or `nil`.
    var searchPosition: Int? {
        guard case .commit(let id) = selection else { return nil }
        return search.matches.firstIndex(of: id).map { $0 + 1 }
    }

    private func selectFirstMatchIfNeeded() {
        guard let first = search.matches.first else { return }
        if case .commit(let id) = selection, search.matchSet.contains(id) { return }
        selection = .commit(first)
        scrollRequest = ScrollRequest(id: first)
    }

    private func scheduleGitSearch() {
        searchTask?.cancel()
        guard search.isFiltering, search.needsGit, let repository else { return }
        let key = search.key
        let query = search.trimmedQuery
        let scope = search.scope
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled,
                  let result = try? await repository.searchHistory(query, scope: scope, includeHEAD: true),
                  !Task.isCancelled, search.key == key else { return }
            search.gitMatches = Set(result.matches)
            search.gitKey = key
            search.refreshLocalMatches(in: commits)
            selectFirstMatchIfNeeded()
        }
    }
}

/// Diff settings shared by every window (View › Diff Layout).
enum DiffPreferences {
    static let layoutKey = "KaernDiffLayout"
    static let ignoreWhitespaceKey = "KaernIgnoreWhitespace"
    static let treeKey = "KaernFileTree"

    static var ignoresWhitespace: Bool { UserDefaults.standard.bool(forKey: ignoreWhitespaceKey) }
}

enum DiffLayout: String {
    case split, unified
}
