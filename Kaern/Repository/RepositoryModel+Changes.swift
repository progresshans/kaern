import Foundation
import KaernKit

/// What Review shows: the selection's files, all of them one under another or one at a time.
struct ReviewState: Equatable {
    /// All files one under another (`false`: one file, with ‹ › between files).
    var showsAllFiles = true
    /// The file shown in One File mode, or scrolled to in All Files (`nil`: the first).
    var path: String?
    /// Compare instead of the selection: two commits, or a commit and the working tree.
    var compare: CompareRange?
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

    /// The paths of entries, with the old path of a staged rename.
    private func pathsWithRenames(_ paths: [String]) -> [String] {
        var result = paths
        for entry in status.entries where paths.contains(entry.path) {
            if let original = entry.originalPath { result.append(original) }
        }
        return Array(Set(result)).sorted()
    }

    func stage(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let label = paths.count == 1 ? "Stage \((paths[0] as NSString).lastPathComponent)" : "Stage \(paths.count) Files"
        changeIndex(label: label, paths: pathsWithRenames(paths)) { try await $0.stage(paths) }
    }

    func unstage(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let hasHead = status.headID != nil
        let label = paths.count == 1 ? "Unstage \((paths[0] as NSString).lastPathComponent)" : "Unstage \(paths.count) Files"
        changeIndex(label: label, paths: pathsWithRenames(paths)) { try await $0.unstage(paths, hasHead: hasHead) }
    }

    func stageAll() {
        guard status.entries.contains(where: \.hasUnstagedChanges) else { return }
        changeIndex(label: "Stage All", paths: pathsWithRenames(status.entries.map(\.path))) { try await $0.stageAll() }
    }

    func unstageAll() {
        guard status.stagedCount > 0 else { return }
        let hasHead = status.headID != nil
        changeIndex(label: "Unstage All", paths: pathsWithRenames(status.entries.map(\.path))) { try await $0.unstageAll(hasHead: hasHead) }
    }

    /// Stages one hunk of the file's unstaged diff (as Review shows it).
    func stageHunk(path: String, hunk: Int) {
        guard let diff = workingDiffs[path]?.unstaged else { return }
        changeIndex(label: "Stage Hunk", paths: pathsWithRenames([path])) { try await $0.stage(hunk: hunk, of: diff) }
    }

    /// Unstages one hunk of the file's staged diff.
    func unstageHunk(path: String, hunk: Int) {
        guard let diff = workingDiffs[path]?.staged else { return }
        let hasHead = status.headID != nil
        changeIndex(label: "Unstage Hunk", paths: pathsWithRenames([path])) { try await $0.unstage(hunk: hunk, of: diff, hasHead: hasHead) }
    }

    /// Runs an index change after the ones before it, then reads the status again. ⌘Z takes it
    /// back quietly (the index entries of `paths` go back to what they were).
    func changeIndex(label: String, paths: [String], _ work: @escaping @Sendable (GitRepository) async throws -> Void) {
        guard canChangeIndex, let repository else { return }
        let previous = indexTask
        let trigger = GitCommandTrigger(triggerName(label))
        pendingIndexChanges += 1
        indexTask = Task {
            await previous?.value
            await GitCommandTrigger.$current.withValue(trigger) {
                let before = await repository.writeIndexTree()
                do {
                    try await work(repository)
                    if let before, let after = await repository.writeIndexTree(), after != before {
                        recordQuietly(.index(label: label, paths: paths, before: before, after: after))
                    }
                } catch {
                    alert = RepositoryAlert(title: "Couldn’t change what’s staged", message: error.localizedDescription)
                }
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
        if let hookRun { return "Running \(hookRun.hook)…" }
        if composer.amend { return "Amend Previous Commit" }
        let staged = status.stagedCount
        if staged == 0 { return "Stage Changes to Commit" }
        return staged == 1 ? "Commit 1 File" : "Commit \(staged) Files"
    }

    /// Commits what's staged. While a `pre-commit` (or `commit-msg`) hook runs, the HUD shows it
    /// with Stop; when a hook stops the commit, the sheet shows its output with Try Again and
    /// Commit Without Hooks. ⌘Z takes the commit back (its changes are staged again).
    func commit(runHooks: Bool = true) {
        guard canCommit else { return }
        let message = composer.message
        let amend = composer.amend
        let count = status.stagedCount
        let branch = status.branch
        let before = status.headID
        let label = amend ? "Amend “\(composer.summary.trimmingCharacters(in: .whitespaces))”"
            : "Commit “\(composer.summary.trimmingCharacters(in: .whitespaces))”"
        hookFailure = nil
        perform(amend ? .amending : .committing, trigger: amend ? "Amend Previous Commit" : (count == 1 ? "Commit 1 File" : "Commit \(count) Files")) {
            [weak self] repository in
            let hooks = runHooks ? await repository.commitHooks().filter {
                $0.isInstalled && ($0.name == "pre-commit" || $0.name == "commit-msg")
            } : []
            let hook = hooks.first { $0.name == "pre-commit" } ?? hooks.first
            if let hook { self?.hookRun = HookRun(hook: hook.name, command: hook.summary ?? hook.name, started: .now) }
            let clock = ContinuousClock()
            let started = clock.now
            do {
                try await repository.commit(message: message, amend: amend, runHooks: runHooks)
                self?.hookRun = nil
            } catch let error as GitError where hook != nil && Self.isHookFailure(error) {
                self?.hookRun = nil
                let elapsed = clock.now - started
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                self?.hookFailure = HookFailure(hook: hook?.name ?? "pre-commit", command: hook?.summary, output: error.message,
                                                status: error.status, seconds: seconds)
                throw AlreadyReported()
            } catch {
                self?.hookRun = nil
                throw error
            }
            guard let self else { return }
            self.composer = CommitDraft()
            self.selection = .workingCopy
            guard let after = await repository.resolve("HEAD") else { return }
            let files = count == 1 ? "1 file" : "\(count) files"
            let text = amend ? "Amended \(self.short(before ?? after)) as \(self.short(after))"
                : "Committed \(files) as \(self.short(after))" + (runHooks ? "" : " without running hooks")
            self.record(before.map { ReversibleStep.committed(label: label, branch: branch, from: $0, to: after) }, toast: text)
        } onFailure: { error in
            error is AlreadyReported
        }
    }

    /// Stop in the hook HUD: ends the commit (and the hook); nothing is committed.
    func stopCommit() {
        guard let hook = hookRun else { return }
        activityTask?.cancel()
        hookRun = nil
        showToast("Stopped \(hook.hook) · nothing was committed")
    }

    /// Whether a failed `git commit` was stopped by a hook rather than by git itself: git's own
    /// failures print `fatal:` / known `error:` lines; a hook prints whatever it prints.
    static func isHookFailure(_ error: GitError) -> Bool {
        guard error.status != 0 else { return false }
        let known = ["fatal:", "error: gpg failed", "error: cannot", "error: unable", "nothing to commit", "no changes added to commit",
                     "Aborting commit due to empty commit message", "nothing added to commit"]
        return !error.message.split(separator: "\n").contains { line in known.contains { line.hasPrefix($0) } }
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
        if let compare = review?.compare {
            let key = "\(compare.base):\(compare.target ?? "worktree"):\(ignoreWhitespace)"
            if compareDiffs?.key == key, compare.target != nil { return }
            diffTask = Task {
                let diffs = await GitCommandTrigger.$current.withValue(.background("Review › Compare")) { () async -> [FileDiff] in
                    if let target = compare.target {
                        return (try? await repository.diffs(from: compare.base, to: target, ignoringWhitespace: ignoreWhitespace)) ?? []
                    }
                    return (try? await repository.diffsToWorkingTree(from: compare.base, ignoringWhitespace: ignoreWhitespace)) ?? []
                }
                guard !Task.isCancelled else { return }
                compareDiffs = (key, diffs)
            }
            return
        }
        // Tasks made here keep the trigger, so the Command Log files these under Review.
        GitCommandTrigger.$current.withValue(.background(review == nil ? "Diff drawer" : "Review")) {
            loadSelectionDiffs(repository: repository, ignoreWhitespace: ignoreWhitespace)
        }
    }

    private func loadSelectionDiffs(repository: GitRepository, ignoreWhitespace: Bool) {
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
