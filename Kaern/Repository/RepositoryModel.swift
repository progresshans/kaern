import Foundation
import KaernKit
import Observation
import OSLog

/// What the tab shows in its slot when it isn't showing the close button.
enum TabMark: Equatable {
    case none
    /// Uncommitted changes (gray dot).
    case changes
    /// Fetch, pull or push running (ring).
    case busy
    /// A merge, rebase, cherry-pick or revert stopped, or files in conflict.
    case warning
    /// The repository couldn't be read.
    case error
    /// The folder isn't there anymore.
    case missing
}

/// A git action running in the background of one repository.
enum RepositoryActivity: Equatable {
    case fetching(remote: String?)
    case pulling
    case pushing(remote: String?)
    case stashing
    case popping
    case switching(String)
    case creatingBranch(String)
    case committing
    case amending
    /// Any other action, with the status bar's text ("Cherry-picking 3e71b0c…").
    case working(String)
    /// An action that talks to a remote ("Publishing feature/x to origin…").
    case network(String)

    var statusText: String {
        switch self {
        case .fetching(let remote): remote.map { "Fetching \($0)…" } ?? "Fetching…"
        case .pulling: "Pulling…"
        case .pushing(let remote): remote.map { "Pushing to \($0)…" } ?? "Pushing…"
        case .stashing: "Stashing changes…"
        case .popping: "Popping the latest stash…"
        case .switching(let name): "Switching to \(name)…"
        case .creatingBranch(let name): "Creating \(name)…"
        case .committing: "Committing…"
        case .amending: "Amending the last commit…"
        case .working(let text), .network(let text): text
        }
    }

    /// Network activity shows the ring in the tab.
    var isNetwork: Bool {
        switch self {
        case .fetching, .pulling, .pushing, .network: true
        default: false
        }
    }
}

/// Which row of the history is selected.
enum HistorySelection: Hashable {
    case workingCopy
    case commit(String)
}

enum SidebarSection: String, CaseIterable, Hashable {
    case local, remote, tags, stashes, worktrees
}

/// Sidebar state kept per repository, so it survives tab switches.
struct SidebarState: Equatable {
    var collapsed: Set<SidebarSection> = []
    /// Branch folders the user folded ("feature" under Local).
    var foldedFolders: Set<String> = []
    /// Remotes the user unfolded (remotes start folded, like the board's origin).
    var openRemotes: Set<String> = []
    var showsAllTags = false
    var filter = ""
}

/// One open repository. It lives as long as a tab shows it, so switching tabs never reloads.
///
/// Refresh rules:
/// - The visible tab refreshes fully on file changes: status, and on ref changes also refs,
///   tags, history, stashes and worktrees.
/// - A background tab only runs a light `git status` (untracked folders folded) for the tab
///   bar's mark. What else changed is remembered and caught up when the tab is shown again.
@MainActor @Observable
final class RepositoryModel: Identifiable {
    nonisolated let id: String
    /// The folder the tab was opened with (canonical, the working tree's top level).
    let path: String
    var name: String { (path as NSString).lastPathComponent }

    enum Phase: Equatable {
        /// Not opened yet (git is still being located, or the tab hasn't been reached).
        case waiting
        case opening
        /// Opened, with only the light status known (a background tab after launch).
        case light
        /// The first full load is running.
        case loading
        case ready
        case failed(String)
        case missing
    }

    private(set) var phase: Phase = .waiting
    private(set) var repository: GitRepository?
    private(set) var status: WorkingTreeStatus = .empty
    /// `false` while `status` comes from the light check (untracked folders folded).
    private(set) var statusIsFull = false
    private(set) var refs: RefSnapshot = .empty
    private(set) var tags: [TagInfo] = []
    private(set) var commits: [Commit] = []
    private(set) var graph: [GraphRow] = []
    /// The history has a working-copy row on top (`graph[0]` is it).
    private(set) var showsWorkingCopy = false
    private(set) var hasMoreHistory = false
    private(set) var isLoadingMoreHistory = false
    private(set) var stashes: [Stash] = []
    private(set) var worktrees: [Worktree] = []
    private(set) var remotes: [RemoteInfo] = []
    private(set) var operation: OperationState?
    private(set) var lastFetch: Date?
    /// Line counts of the working copy's changes, staged and unstaged apart.
    private(set) var lineStats = WorkingLineStats.empty
    private(set) var activity: RepositoryActivity?
    /// The selected commit's details (the panel).
    private(set) var selectedDetails: CommitDetails?
    private(set) var selectedFiles: [FileChange] = []
    var alert: RepositoryAlert?

    // UI state that survives tab switches.
    var selection: HistorySelection = .workingCopy {
        didSet {
            guard selection != oldValue else { return }
            loadSelectionDetails()
            drawerPath = nil
            if review != nil { review?.path = nil }
            clearLinePicksIfNeeded()
            diffsAreStale = true
            refreshDiffsIfNeeded()
        }
    }

    func clearLinePicksIfNeeded() {
        if !linePicks.isEmpty || linePicks.path != nil { linePicks = LinePicks() }
    }
    var sidebar = SidebarState()
    /// The first visible history row when the tab was last shown (scroll restore).
    var historyScrollAnchor: String?
    /// Review mode: the center shows the selection's diff instead of the graph (`nil`: graph).
    var review: ReviewState? {
        didSet {
            if review?.compare != oldValue?.compare {
                diffsAreStale = true
                refreshDiffsIfNeeded()
            }
            if review == nil || review?.compare != nil { clearLinePicksIfNeeded() }
        }
    }
    /// Diffs Review shows for a compare (`key`: base, target, white space).
    var compareDiffs: (key: String, diffs: [FileDiff])?
    /// The Search find bar over the graph.
    var search = HistorySearch()
    /// The commit composer's text and Amend switch (kept per repository).
    var composer = CommitDraft()
    /// The file the Focus drawer shows (`nil`: the first one).
    var drawerPath: String?
    /// Asks the history to scroll a row into view (search steps, selecting from elsewhere).
    var scrollRequest: ScrollRequest?

    // Phase 3: picking several commits, comparing, ⌘Z, toasts, hooks.
    /// Commits picked with ⌘-click or ⇧-click, in the order they were picked (2: compare, 3+: the
    /// multi-select panel).
    var picked: [String] = [] {
        didSet { if picked != oldValue { refreshComparisonIfNeeded() } }
    }
    /// Where ⇧-click ranges start.
    var pickAnchor: String?
    /// Compare Two Commits shows the diff the other way round (Swap).
    var compareSwapped = false {
        didSet { if compareSwapped != oldValue { refreshComparisonIfNeeded() } }
    }
    /// Branch compare against the current branch ("Compare with “develop”").
    var branchCompare: BranchCompareState? {
        didSet { if branchCompare != oldValue { refreshComparisonIfNeeded() } }
    }
    /// Lines picked in Review for staging or discarding.
    var linePicks = LinePicks()
    /// ⌘Z and ⇧⌘Z.
    var undoSteps: [ReversibleStep] = []
    var redoSteps: [ReversibleStep] = []
    /// The toast at the bottom of the window.
    var toast: Toast?
    /// The pre-commit hook running for a commit (the HUD).
    var hookRun: HookRun?
    /// A commit stopped by a hook: the sheet with its output.
    var hookFailure: HookFailure?
    /// The publish popover over Push.
    var publishDraft: PublishDraft?
    /// A confirmation (Reset Hard, Delete on origin, Force Push).
    var confirmation: Confirmation?
    /// Names asked for in a small sheet (Create Branch Here…, Rename…, Create Tag Here…).
    var nameRequest: NameRequest?
    /// Commits reachable from HEAD among the loaded ones ("on this branch").
    @ObservationIgnored private(set) var headAncestors: Set<String> = []
    /// Where the action that's about to run was started from ("Commit menu"), for the Command Log.
    @ObservationIgnored var uiSource: String?
    @ObservationIgnored var toastTask: Task<Void, Never>?
    @ObservationIgnored var activityTask: Task<Void, Never>?
    @ObservationIgnored var compareTask: Task<Void, Never>?
    /// Two picked commits or a branch compare, loaded for the panel.
    var comparison: Comparison?
    /// A branch without upstream: its commits no remote branch has (Push's badge).
    private(set) var unpublishedCount = 0
    /// The branch rewrote commits its upstream has (amend, rebase): Push needs force.
    private(set) var rewroteUpstream = false

    // Diffs for Review and the Focus drawer, loaded while one of them is on screen.
    /// The working copy's diffs by path, staged and unstaged apart.
    var workingDiffs: [String: WorkingFileDiff] = [:]
    var workingDiffsLoaded = false
    /// The selected commit's diffs (`id` is the commit).
    var commitDiffs: (id: String, diffs: [FileDiff])?
    @ObservationIgnored var commitDiffsIgnoreWhitespace = false
    @ObservationIgnored var workingDiffsIgnoreWhitespace = false
    /// Counts views that show diffs, so diffs are only kept current while someone looks.
    @ObservationIgnored var diffViewers = 0 {
        didSet { if diffViewers > oldValue { refreshDiffsIfNeeded() } }
    }
    @ObservationIgnored var diffTask: Task<Void, Never>?
    @ObservationIgnored var diffsAreStale = true
    /// Index changes (stage, unstage, commit) run one after another: git locks the index.
    @ObservationIgnored var indexTask: Task<Void, Never>?
    @ObservationIgnored var searchTask: Task<Void, Never>?

    /// Shown in a window as its selected tab. Set by the app.
    var isVisible = false {
        didSet { if isVisible != oldValue { visibilityChanged() } }
    }

    static let pageSize = 400

    /// The first history load: one page, or everything (Settings › Advanced › Large repositories).
    static var firstLoadLimit: Int { AppSettings.historyLoading == .all ? 5_000_000 : pageSize }

    @ObservationIgnored private var runner: GitRunner?
    @ObservationIgnored private var watcher: FileSystemWatcher?
    @ObservationIgnored private var pendingScope: ChangeScope = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var lightTask: Task<Void, Never>?
    @ObservationIgnored private var lightAgain = false
    @ObservationIgnored private var detailsTask: Task<Void, Never>?
    @ObservationIgnored private var detailsCache: [String: (CommitDetails, [FileChange])] = [:]
    @ObservationIgnored private static let log = Logger(subsystem: "com.progresshans.kaern", category: "repository")
    /// How often each load path ran (the debug driver checks that switching doesn't reload).
    @ObservationIgnored private(set) var debugFullLoads = 0
    @ObservationIgnored private(set) var debugRefreshes = 0
    @ObservationIgnored private(set) var debugLightRefreshes = 0

    init(path: String) {
        self.id = path
        self.path = path
    }

    // MARK: Derived state

    /// Staging or unstaging waiting or running (they run one after another).
    var pendingIndexChanges = 0
    var isChangingIndex: Bool { pendingIndexChanges > 0 }

    var tabMark: TabMark {
        switch phase {
        case .missing: return .missing
        case .failed: return .error
        default: break
        }
        if activity?.isNetwork == true { return .busy }
        if operation != nil || status.conflictCount > 0 { return .warning }
        if !status.isClean { return .changes }
        return .none
    }

    var currentBranch: String? { status.branch }
    /// Whether there's a repository to show (not a missing folder or an unreadable one).
    var hasContent: Bool { !isFailedOrMissing }
    var isReady: Bool { phase == .ready }
    var changeCount: Int { status.entries.count }
    var stagedCount: Int { status.stagedCount }

    // MARK: Opening

    /// Opens the repository: a light status when in the background, everything when visible.
    func start(runner: GitRunner) {
        guard phase == .waiting || isFailedOrMissing else { return }
        self.runner = runner
        Task { await open() }
    }

    private var isFailedOrMissing: Bool {
        if case .failed = phase { return true }
        return phase == .missing
    }

    private func open() async {
        guard let runner else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            phase = .missing
            return
        }
        phase = .opening
        do {
            let repository = try await GitCommandTrigger.$current.withValue(.background("Opening the repository")) {
                try await GitRepository.open(URL(filePath: path, directoryHint: .isDirectory), runner: runner)
            }
            self.repository = repository
            if AppSettings.watchesFiles { startWatching(repository) }
            if isVisible {
                await loadEverything()
            } else {
                await lightRefresh()
                if phase == .opening { phase = .light }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Loads everything the window shows. Used for the first load of a tab; afterwards the
    /// refresh paths keep it current.
    func loadEverything() async {
        await GitCommandTrigger.$current.withValue(.background("Loading the repository")) {
            await loadEverythingNow()
        }
    }

    private func loadEverythingNow() async {
        guard let repository else { return }
        debugFullLoads += 1
        if phase != .ready { phase = .loading }
        async let status = try? repository.status()
        async let refs = try? repository.refs()
        async let tags = try? repository.tags()
        let limit = Self.firstLoadLimit
        async let history = try? repository.log(skip: 0, limit: limit, includeHEAD: true)
        async let stashes = try? repository.stashes()
        async let worktrees = repository.worktrees()
        async let remotes = repository.remoteInfos()

        let loadedStatus = await status
        let loadedHistory = await history
        if let loadedStatus {
            self.status = loadedStatus
            statusIsFull = true
        }
        self.refs = await refs ?? self.refs
        self.tags = await tags ?? self.tags
        self.stashes = await stashes ?? self.stashes
        self.worktrees = await worktrees
        self.remotes = await remotes
        operation = repository.operationState()
        lastFetch = repository.lastFetchDate
        if let loadedHistory {
            commits = loadedHistory
            hasMoreHistory = loadedHistory.count == limit
        }
        rebuildGraph()
        phase = .ready
        pendingScope = []
        await refreshBranchFacts()
        await refreshLineStats()
        loadSelectionDetails()
        diffsAreStale = true
        refreshDiffsIfNeeded()
    }

    // MARK: Refreshing

    private func startWatching(_ repository: GitRepository) {
        var paths = [repository.root.path(percentEncoded: false)]
        let gitDir = repository.gitDirectory.path(percentEncoded: false)
        if !gitDir.hasPrefix(paths[0]) { paths.append(gitDir) }
        let watcher = FileSystemWatcher(paths: paths, latency: 0.3) { [weak self] changed in
            Task { @MainActor in self?.filesChanged(changed) }
        }
        watcher.start()
        self.watcher = watcher
    }

    /// Settings › Advanced › File changes was switched: start or stop watching.
    func updateWatching() {
        guard let repository else { return }
        if AppSettings.watchesFiles {
            if watcher == nil {
                startWatching(repository)
                refreshAfterActivation()
            }
        } else {
            watcher?.stop()
            watcher = nil
        }
    }

    /// Without the file watcher: everything is checked when Kaern comes back to the front.
    func refreshAfterActivation() {
        guard repository != nil, phase == .ready || phase == .light else { return }
        pendingScope.formUnion([.refs, .workTree, .index])
        if isVisible, phase == .ready { runPendingRefresh(trigger: "Kaern became active") } else { scheduleLightRefresh() }
    }

    private func filesChanged(_ paths: [String]) {
        guard let repository else { return }
        let scope = repository.classify(paths)
        guard !scope.isEmpty else { return }
        pendingScope.formUnion(scope)
        if isVisible, phase == .ready {
            runPendingRefresh()
        } else {
            scheduleLightRefresh()
        }
    }

    private func visibilityChanged() {
        guard isVisible else { return }
        switch phase {
        case .light:
            Task { await loadEverything() }
        case .ready:
            if !pendingScope.isEmpty || !statusIsFull {
                pendingScope.insert(.workTree)
                runPendingRefresh(trigger: "Tab became visible")
            }
        default:
            break
        }
    }

    /// Re-reads the status right away (after staging): the file event would come 0.3 s later.
    func refreshStatusNow() async {
        guard let repository else { return }
        await GitCommandTrigger.$current.withValue(.background("Refreshing after a change")) {
            if let status = try? await repository.status() {
                self.status = status
                statusIsFull = true
            }
            rebuildGraph()
            await refreshLineStats()
        }
        diffsAreStale = true
        refreshDiffsIfNeeded()
    }

    /// Runs the refreshes that file events asked for, one at a time, until none are left.
    private func runPendingRefresh(trigger: String = "File watcher") {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await GitCommandTrigger.$current.withValue(.background(trigger)) {
                while let self, self.isVisible, self.phase == .ready, !self.pendingScope.isEmpty {
                    let scope = self.pendingScope
                    self.pendingScope = []
                    await self.refresh(scope)
                }
            }
            self?.refreshTask = nil
        }
    }

    /// The visible tab's refresh.
    private func refresh(_ scope: ChangeScope) async {
        guard let repository else { return }
        debugRefreshes += 1
        let start = ContinuousClock.now
        if scope.contains(.refs) {
            async let refs = try? repository.refs()
            async let tags = try? repository.tags()
            let limit = AppSettings.historyLoading == .all ? Self.firstLoadLimit : max(Self.pageSize, min(commits.count, 4000))
            async let history = try? repository.log(skip: 0, limit: limit, includeHEAD: true)
            async let stashes = try? repository.stashes()
            async let worktrees = repository.worktrees()
            async let remotes = repository.remoteInfos()
            async let status = try? repository.status()
            if let status = await status {
                self.status = status
                statusIsFull = true
            }
            self.refs = await refs ?? self.refs
            self.tags = await tags ?? self.tags
            if let history = await history {
                commits = history
                hasMoreHistory = history.count == limit
            }
            self.stashes = await stashes ?? self.stashes
            self.worktrees = await worktrees
            self.remotes = await remotes
            lastFetch = repository.lastFetchDate
        } else if let status = try? await repository.status() {
            self.status = status
            statusIsFull = true
        }
        operation = repository.operationState()
        rebuildGraph()
        await refreshBranchFacts()
        await refreshLineStats()
        diffsAreStale = true
        refreshDiffsIfNeeded()
        Self.log.debug("Refreshed \(self.name, privacy: .public) \(scope.rawValue) in \(ContinuousClock.now - start, privacy: .public)")
    }

    /// Background tabs: one light `git status`, at most every 1.5 s.
    private func scheduleLightRefresh() {
        guard lightTask == nil else {
            lightAgain = true
            return
        }
        lightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            await GitCommandTrigger.$current.withValue(.background("File watcher (background tab)")) {
                repeat {
                    self?.lightAgain = false
                    await self?.lightRefresh()
                } while self?.lightAgain == true
            }
            self?.lightTask = nil
        }
    }

    private func lightRefresh() async {
        guard let repository else { return }
        debugLightRefreshes += 1
        if let status = try? await repository.status(untrackedFiles: .normal) {
            self.status = status
            statusIsFull = false
        }
        operation = repository.operationState()
    }

    /// What Push's badge and the status bar say beyond ahead/behind: commits not on any remote
    /// for a branch without upstream, and whether the branch rewrote commits on its upstream.
    private func refreshBranchFacts() async {
        guard let repository else { return }
        if status.branch != nil, status.upstream == nil, !remotes.isEmpty {
            unpublishedCount = await repository.unpublishedCount() ?? 0
        } else if unpublishedCount != 0 {
            unpublishedCount = 0
        }
        if status.ahead > 0, status.behind > 0, let branch = status.branch, let upstream = status.upstream,
           let tip = refs.remoteBranch(named: upstream)?.target {
            rewroteUpstream = await repository.branchHadCommit(branch, commit: tip)
        } else if rewroteUpstream {
            rewroteUpstream = false
        }
    }

    func refreshLineStats() async {
        guard let repository, isVisible else { return }
        let untracked = status.entries.filter(\.isUntracked).map(\.path)
        lineStats = await repository.stagedAndUnstagedLineStats(untracked: untracked)
    }

    func loadMoreHistory() {
        guard let repository, hasMoreHistory, !isLoadingMoreHistory, phase == .ready else { return }
        isLoadingMoreHistory = true
        Task {
            defer { isLoadingMoreHistory = false }
            let skip = commits.count
            guard let page = try? await GitCommandTrigger.$current.withValue(.background("Scrolling the history"), operation: {
                try await repository.log(skip: skip, limit: Self.pageSize, includeHEAD: true)
            }) else { return }
            let known = Set(commits.map(\.id))
            commits.append(contentsOf: page.filter { !known.contains($0.id) })
            hasMoreHistory = page.count == Self.pageSize
            rebuildGraph()
        }
    }

    private func rebuildGraph() {
        var builder = CommitGraphBuilder()
        showsWorkingCopy = !status.isClean
        if showsWorkingCopy {
            builder.appendWorkingCopy(head: status.headID)
        }
        builder.append(commits)
        graph = builder.rows
        if case .commit(let id) = selection, !commits.contains(where: { $0.id == id }) {
            selection = .workingCopy
        }
        search.refreshLocalMatches(in: commits)
        headAncestors = Self.ancestors(of: status.headID, in: commits)
        let known = Set(commits.map(\.id))
        if picked.contains(where: { !known.contains($0) }) {
            picked.removeAll { !known.contains($0) }
        }
        refreshComparisonIfNeeded()
    }

    /// The loaded commits reachable from `head` (through loaded parents).
    private static func ancestors(of head: String?, in commits: [Commit]) -> Set<String> {
        guard let head else { return [] }
        let byID = Dictionary(commits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var stack = [head]
        while let id = stack.popLast() {
            guard seen.insert(id).inserted, let commit = byID[id] else { continue }
            stack.append(contentsOf: commit.parents)
        }
        return seen.intersection(byID.keys)
    }

    /// The loaded commit with `id`.
    func commit(_ id: String) -> Commit? {
        commits.first { $0.id == id }
    }

    /// Whether `id` is on the branch HEAD is on (reachable from HEAD).
    func isOnCurrentBranch(_ id: String) -> Bool { headAncestors.contains(id) }

    // MARK: Selection details

    private func loadSelectionDetails() {
        detailsTask?.cancel()
        guard case .commit(let id) = selection, let repository else {
            selectedDetails = nil
            selectedFiles = []
            return
        }
        if let cached = detailsCache[id] {
            selectedDetails = cached.0
            selectedFiles = cached.1
            return
        }
        detailsTask = Task {
            let loaded = await GitCommandTrigger.$current.withValue(.background("Commit details")) {
                () async -> (CommitDetails, [FileChange])? in
                guard let details = try? await repository.commitDetails(id) else { return nil }
                return (details, (try? await repository.changedFiles(in: details.commit)) ?? [])
            }
            guard let (details, files) = loaded else { return }
            guard !Task.isCancelled else { return }
            detailsCache[id] = (details, files)
            if detailsCache.count > 200 { detailsCache.removeAll() }
            selectedDetails = details
            selectedFiles = files
        }
    }

    // MARK: Actions

    /// Runs a git action with its activity shown in the tab and status bar, then refreshes.
    /// `trigger` names it in the Command Log (with ``uiSource`` in front). An error shows an alert
    /// unless `onFailure` handles it; a stop (the hook HUD, the Command Log) shows nothing.
    @discardableResult
    func perform(_ activity: RepositoryActivity, trigger: String? = nil, _ work: @escaping (GitRepository) async throws -> Void,
                 onSuccess: (() -> Void)? = nil, onFailure: ((any Error) -> Bool)? = nil) -> Task<Void, Never>? {
        guard let repository, self.activity == nil else { return nil }
        self.activity = activity
        let previousIndexChange = indexTask
        let command = GitCommandTrigger(triggerName(trigger ?? activity.statusText.replacingOccurrences(of: "…", with: "")))
        let task = Task {
            // Wait for staging that's still running (git locks the index).
            await previousIndexChange?.value
            do {
                try await GitCommandTrigger.$current.withValue(command) {
                    try await work(repository)
                }
                onSuccess?()
            } catch is CancellationError {
                // Stopped on purpose.
            } catch {
                if onFailure?(error) != true {
                    alert = RepositoryAlert(title: "Couldn't finish: \(activity.statusText.replacingOccurrences(of: "…", with: ""))",
                                            message: error.localizedDescription)
                }
            }
            self.activity = nil
            activityTask = nil
            pendingScope.formUnion([.refs, .workTree, .index])
            if isVisible, phase == .ready { runPendingRefresh(trigger: "After \(command.action)") } else { scheduleLightRefresh() }
        }
        activityTask = task
        return task
    }

    /// "Commit menu › Cherry-pick 3e71b0c" when the action came from a menu.
    func triggerName(_ action: String) -> String {
        uiSource.map { "\($0) › \(action)" } ?? action
    }

    /// Runs `body` (which starts actions) as coming from `source` ("Toolbar", "Sidebar").
    func from(_ source: String, _ body: () -> Void) {
        let previous = uiSource
        uiSource = source
        body()
        uiSource = previous
    }

    var defaultRemote: String? {
        if let upstream = status.upstream, let remote = upstream.split(separator: "/").first { return String(remote) }
        return remotes.first { $0.name == "origin" }?.name ?? remotes.first?.name
    }

    func fetch() {
        let remote = remotes.count == 1 ? remotes.first?.name : nil
        perform(.fetching(remote: remote), trigger: "Fetch") { try await $0.fetch() } onSuccess: { [weak self] in
            self?.showToast(remote.map { "Fetched \($0)" } ?? "Fetched all remotes")
        }
    }

    func pull(_ strategy: GitRepository.PullStrategy) {
        let before = status.headID
        let branch = status.branch
        perform(.pulling, trigger: "Pull") { [weak self] repository in
            try await repository.pull(strategy: strategy)
            let after = await repository.resolve("HEAD")
            guard let self, let before, let after, before != after, let branch else {
                self?.showToast("Already up to date")
                return
            }
            let count = await repository.countCommits(from: before, to: after)
            self.record(ReversibleStep.moveBranch(label: "Pull", branch: branch, from: before, to: after),
                        toast: "Pulled \(Formatters.count(count, "commit", "commits")) into \(branch)")
        }
    }

    func stash() {
        let count = status.entries.count
        perform(.stashing, trigger: "Stash Changes") { [weak self] repository in
            guard let object = try await repository.stashAll(message: "", includeUntracked: true) else { return }
            self?.record(ReversibleStep.stashed(object: object), toast: "Stashed \(Formatters.count(count, "change", "changes"))")
        }
    }

    func popStash() {
        guard let latest = stashes.first else { return }
        applyStash(latest, pop: true)
    }

    func switchBranch(_ name: String) {
        checkout(branch: name)
    }

    func checkoutRemoteBranch(_ ref: Ref) {
        let local = ref.branchName
        if refs.localBranch(named: local) != nil {
            checkout(branch: local)
        } else {
            let previous = headPosition
            perform(.switching(local), trigger: "Checkout \(ref.name)") { [weak self] repository in
                try await repository.switchToRemoteBranch(ref.name, localName: local)
                guard let previous, let tip = await repository.resolve("HEAD") else { return }
                self?.record(ReversibleStep.createdBranch(label: "Checkout \(ref.name)", name: local, at: tip, upstream: ref.name,
                                                          previous: previous),
                             toast: "Created \(local) tracking \(ref.name) and checked it out")
            }
        }
    }

    func createBranch(_ name: String, at startPoint: String? = nil) {
        let previous = headPosition
        let label = "Create Branch \(name)"
        perform(.creatingBranch(name), trigger: label) { [weak self] repository in
            try await repository.createBranch(name, startPoint: startPoint, checkout: true)
            guard let previous, let tip = await repository.resolve("HEAD") else { return }
            self?.record(ReversibleStep.createdBranch(label: label, name: name, at: tip, upstream: nil, previous: previous),
                         toast: startPoint == nil ? "Created \(name)" : "Created \(name) at \(String(tip.prefix(7))) and switched to it")
        }
    }

    func isValidBranchName(_ name: String) async -> Bool {
        await repository?.isValidBranchName(name) ?? false
    }

    // MARK: Closing

    /// Stops watching (the last tab showing this repository closed).
    func close() {
        watcher?.stop()
        watcher = nil
        refreshTask?.cancel()
        lightTask?.cancel()
        detailsTask?.cancel()
        diffTask?.cancel()
        searchTask?.cancel()
    }
}

struct RepositoryAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    /// A second button besides OK ("Abort Cherry-pick").
    var actionTitle: String?
    var action: (() -> Void)?
}
