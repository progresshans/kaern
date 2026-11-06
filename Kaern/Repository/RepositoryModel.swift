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
        }
    }

    /// Network activity shows the ring in the tab.
    var isNetwork: Bool {
        switch self {
        case .fetching, .pulling, .pushing: true
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
            diffsAreStale = true
            refreshDiffsIfNeeded()
        }
    }
    var sidebar = SidebarState()
    /// The first visible history row when the tab was last shown (scroll restore).
    var historyScrollAnchor: String?
    /// Review mode: the center shows the selection's diff instead of the graph (`nil`: graph).
    var review: ReviewState?
    /// The Search find bar over the graph.
    var search = HistorySearch()
    /// The commit composer's text and Amend switch (kept per repository).
    var composer = CommitDraft()
    /// The file the Focus drawer shows (`nil`: the first one).
    var drawerPath: String?
    /// Asks the history to scroll a row into view (search steps, selecting from elsewhere).
    var scrollRequest: ScrollRequest?

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
            let repository = try await GitRepository.open(URL(filePath: path, directoryHint: .isDirectory), runner: runner)
            self.repository = repository
            startWatching(repository)
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
        guard let repository else { return }
        debugFullLoads += 1
        if phase != .ready { phase = .loading }
        async let status = try? repository.status()
        async let refs = try? repository.refs()
        async let tags = try? repository.tags()
        async let history = try? repository.log(skip: 0, limit: Self.pageSize, includeHEAD: true)
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
            hasMoreHistory = loadedHistory.count == Self.pageSize
        }
        rebuildGraph()
        phase = .ready
        pendingScope = []
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
                runPendingRefresh()
            }
        default:
            break
        }
    }

    /// Re-reads the status right away (after staging): the file event would come 0.3 s later.
    func refreshStatusNow() async {
        guard let repository else { return }
        if let status = try? await repository.status() {
            self.status = status
            statusIsFull = true
        }
        rebuildGraph()
        await refreshLineStats()
        diffsAreStale = true
        refreshDiffsIfNeeded()
    }

    /// Runs the refreshes that file events asked for, one at a time, until none are left.
    private func runPendingRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while let self, self.isVisible, self.phase == .ready, !self.pendingScope.isEmpty {
                let scope = self.pendingScope
                self.pendingScope = []
                await self.refresh(scope)
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
            async let history = try? repository.log(skip: 0, limit: max(Self.pageSize, min(commits.count, 4000)), includeHEAD: true)
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
                let limit = max(Self.pageSize, min(commits.count, 4000))
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
            repeat {
                self?.lightAgain = false
                await self?.lightRefresh()
            } while self?.lightAgain == true
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
            guard let page = try? await repository.log(skip: commits.count, limit: Self.pageSize, includeHEAD: true) else { return }
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
    }

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
            guard let details = try? await repository.commitDetails(id) else { return }
            let files = (try? await repository.changedFiles(in: details.commit)) ?? []
            guard !Task.isCancelled else { return }
            detailsCache[id] = (details, files)
            if detailsCache.count > 200 { detailsCache.removeAll() }
            selectedDetails = details
            selectedFiles = files
        }
    }

    // MARK: Actions

    /// Runs a git action with its activity shown in the tab and status bar, then refreshes.
    func perform(_ activity: RepositoryActivity, _ work: @escaping (GitRepository) async throws -> Void,
                 onSuccess: (() -> Void)? = nil) {
        guard let repository, self.activity == nil else { return }
        self.activity = activity
        let previousIndexChange = indexTask
        Task {
            // Wait for staging that's still running (git locks the index).
            await previousIndexChange?.value
            do {
                try await work(repository)
                onSuccess?()
            } catch {
                alert = RepositoryAlert(title: "Couldn't finish: \(activity.statusText.replacingOccurrences(of: "…", with: ""))",
                                        message: error.localizedDescription)
            }
            self.activity = nil
            pendingScope.formUnion([.refs, .workTree, .index])
            if isVisible, phase == .ready { runPendingRefresh() } else { scheduleLightRefresh() }
        }
    }

    var defaultRemote: String? {
        if let upstream = status.upstream, let remote = upstream.split(separator: "/").first { return String(remote) }
        return remotes.first { $0.name == "origin" }?.name ?? remotes.first?.name
    }

    func fetch() {
        perform(.fetching(remote: remotes.count == 1 ? remotes.first?.name : nil)) { try await $0.fetch() }
    }

    func pull(_ strategy: GitRepository.PullStrategy) {
        perform(.pulling) { try await $0.pull(strategy: strategy) }
    }

    func push() {
        let remote = defaultRemote
        let publish = status.upstream == nil ? remote : nil
        perform(.pushing(remote: remote)) { try await $0.push(setUpstreamOn: publish) }
    }

    func stash() {
        perform(.stashing) { try await $0.stash(message: nil, includeUntracked: true) }
    }

    func popStash() {
        guard let latest = stashes.first else { return }
        perform(.popping) { try await $0.applyStash(latest, pop: true) }
    }

    func switchBranch(_ name: String) {
        perform(.switching(name)) { try await $0.switchBranch(name) }
    }

    func checkoutRemoteBranch(_ ref: Ref) {
        let local = ref.branchName
        if refs.localBranch(named: local) != nil {
            switchBranch(local)
        } else {
            perform(.switching(local)) { try await $0.switchToRemoteBranch(ref.name, localName: local) }
        }
    }

    func createBranch(_ name: String) {
        perform(.creatingBranch(name)) { try await $0.createBranch(name, startPoint: nil, checkout: true) }
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

struct RepositoryAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}
