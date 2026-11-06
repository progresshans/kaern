import AppKit
import IOKit.ps
import KaernKit
import OSLog
import SwiftUI

private let log = Logger(subsystem: "com.progresshans.kaern", category: "repository")

@Observable
final class RepositoryModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    let url: URL
    private(set) var repository: GitRepository?
    private(set) var phase: Phase = .loading

    // MARK: Repository state

    private(set) var refs: RefSnapshot = .empty
    private(set) var status: WorkingTreeStatus = .empty
    private(set) var lineStats: [String: LineStat] = [:]
    private(set) var stashes: [Stash] = []
    private(set) var remotes: [String] = []
    private(set) var headCommitCount: Int?
    private(set) var lastFetch: Date?
    /// Set when the last fetch couldn't reach the remote.
    private(set) var fetchError: String?

    // MARK: Operation in progress

    /// A merge, rebase, cherry-pick or revert waiting for the user (usually on conflicts).
    private(set) var operation: OperationState?
    /// The message under the conflicts. Starts as the one git prepared; edits are used on Continue.
    var operationMessage = ""
    /// Conflicted paths resolved in Kaern during the current step (listed as "Resolved").
    var resolvedConflicts: Set<String> = []
    @ObservationIgnored private var operationIdentity: String?
    /// Local branches from the reflog, most recently checked out first.
    private(set) var recentBranches: [String] = []

    // MARK: History

    private(set) var commits: [Commit] = []
    private(set) var commitIndex: [String: Int] = [:]
    /// `graph[0]` is the working-copy row, `graph[i + 1]` belongs to `commits[i]`.
    private(set) var graph: [GraphRow] = []
    /// Bumped whenever `commits`/`graph` change so the table knows to reload.
    private(set) var historyVersion = 0
    private(set) var hasMoreHistory = false
    private(set) var isLoadingMore = false
    @ObservationIgnored private var graphBuilder = CommitGraphBuilder()

    // MARK: Selection

    var selection: HistorySelection = .workingCopy {
        didSet {
            guard selection != oldValue else { return }
            // Picking another commit (or the working copy) ends a comparison.
            if !isStartingComparison { comparisonBase = nil }
            selectionDidChange()
        }
    }
    /// Two commits compared (⌘-click a second one in the history): `selection` is the newer
    /// one, this the older. The inspector and the diffs show what differs between them.
    private(set) var comparisonBase: String?
    /// How far apart the compared commits are.
    private(set) var comparisonDistance: CommitDistance?
    @ObservationIgnored private var isStartingComparison = false
    private(set) var details: CommitDetails?
    private(set) var detailFiles: [FileChange] = []
    private(set) var detailBranches: [String] = []
    private(set) var isLoadingDetails = false

    var selectedFile: FileSelection? {
        didSet {
            guard selectedFile != oldValue else { return }
            // Another file picked in the inspector leaves File History for that file's diff.
            if fileHistory != nil, !fileHistoryKeeps(selectedFile) {
                fileHistory = nil
            }
            loadDiff()
        }
    }
    /// File History or Blame of one file, in place of the history table.
    var fileHistory: FileHistoryState?
    /// A stash picked in the sidebar: all its changes in the center, its details on the right.
    var stashView: StashViewState?
    /// Sidebar › Pull Requests.
    var pullRequests: PullRequestsState?
    @ObservationIgnored var isInspectingForFileHistory = false
    /// Commits outside the loaded history pages that File History or Blame shows.
    var knownCommits: [String: Commit] = [:]
    /// The remote people open in the browser (the upstream's, else origin).
    private(set) var primaryRemote: RemoteURL?
    private(set) var submodules: [Submodule] = []
    /// How far each moved submodule's checked-out commit is from the recorded one (Sidebar's ↑3).
    var submoduleDistances: [String: CommitDistance] = [:]
    /// All working trees of the repository, this one included.
    private(set) var worktrees: [Worktree] = []
    /// The selected commit's signature (checked when it's selected; `nil` when unsigned).
    private(set) var detailSignature: CommitSignature?
    /// Sizes of the changed files that are in Git LFS (the file lists show them instead of lines).
    var workingLFSSizes: [String: LFSSizes] = [:]
    var detailLFSSizes: [String: LFSSizes] = [:]
    /// Tracked files that are still Git LFS pointers on disk, counted when git-lfs is missing.
    var lfsPointerFiles: [String] = []
    /// Notices closed with × (until the window closes).
    var dismissedNotices: Set<String> = []
    /// Branches left out of the history graph (full ref names, `refs/remotes/<remote>/*` for all
    /// of a remote's), and the one branch it shows alone. Remembered per repository.
    var hiddenRefs: Set<String> = []
    var soloRef: String?
    /// `%G?` of the history rows that have been on screen (the Commit column's seal).
    @ObservationIgnored private(set) var signatureCodes: [String: Character] = [:]
    @ObservationIgnored private var signaturesInFlight: Set<String> = []
    /// Bumped when signature codes arrive, so the table redraws the Commit column.
    private(set) var signatureVersion = 0

    /// Checks the signatures of rows that came on screen.
    func loadSignatures(for ids: [String]) {
        let missing = ids.filter { signatureCodes[$0] == nil && !signaturesInFlight.contains($0) }
        guard !missing.isEmpty, let repository else { return }
        signaturesInFlight.formUnion(missing)
        Task { [weak self] in
            let codes = await repository.signatureCodes(of: missing)
            guard let self else { return }
            self.signaturesInFlight.subtract(missing)
            for id in missing { self.signatureCodes[id] = codes[id] ?? "N" }
            if codes.values.contains(where: { $0 != "N" }) { self.signatureVersion += 1 }
        }
    }

    /// After the allowed signers changed: the seals and the selected commit's signature again.
    func recheckSignatures() {
        signatureCodes = [:]
        signatureVersion += 1
        guard case .commit(let id) = selection, let repository else { return }
        Task { [weak self] in
            let signature = await repository.signature(of: id)
            guard let self, self.selection == .commit(id) else { return }
            self.detailSignature = signature
        }
    }
    private(set) var diff: DiffContent?
    /// Bumped whenever `diff` is replaced, so the diff view rebuilds its rows from scratch.
    private(set) var diffVersion = 0
    private(set) var diffError: String?
    private(set) var isLoadingDiff = false

    // MARK: Search

    var searchText = "" {
        didSet { if searchText != oldValue { updateSearch() } }
    }
    /// Message · Author · Path · SHA, picked with a token in the search field.
    var searchScope: CommitSearchScope = .all {
        didSet { if searchScope != oldValue { updateSearch() } }
    }
    /// Commits matching the search, `nil` when not searching. Non-matching rows are dimmed.
    var searchMatches: Set<String>?
    var searchVersion = 0
    /// Matches in the whole history (beyond the loaded pages), once git has answered.
    var historySearch: HistorySearchResult?
    var isSearchingHistory = false
    @ObservationIgnored var historySearchKey: String?
    @ObservationIgnored var historySearchTask: Task<Void, Never>?

    // MARK: Commit composer

    var summary = ""
    var messageBody = ""
    var amend = false {
        didSet { if amend != oldValue { amendDidChange() } }
    }

    // MARK: Activity and presentation

    private(set) var activity: Activity?
    var alert: AlertItem?
    var sheet: RepositorySheet?
    var confirmation: Confirmation?
    /// The window's undo manager, for ⌘Z on local changes (see RepositoryModel+Undo.swift).
    @ObservationIgnored weak var undoManager: UndoManager?
    /// "Discarded changes to a.txt · Undo" for a few seconds after an undoable change.
    var undoHint: UndoHint?
    /// A remote that turned us down or didn't answer (sign in, SSH, Try Again sheets).
    var remoteProblem: RemoteProblem?
    /// Work Offline: background fetches pause until a remote command gets through again.
    var isWorkingOffline = false
    /// Changed by View › Find Commits (⌘F) and View › Filter Sidebar (⌥⌘F) to move focus.
    var searchFocusRequest = 0
    var filterFocusRequest = 0
    /// Bumped to move keyboard focus to the history table (after committing, so ⌘Z undoes the
    /// commit rather than the text field's typing).
    var historyFocusRequest = 0
    /// The quick switcher (⇧⌘O) is showing, starting with this text.
    var quickSwitcherQuery: String?

    /// A ref for the sidebar to select and scroll to (⌥Return in the quick switcher).
    var sidebarReveal: String?

    func showQuickSwitcher(query: String) {
        quickSwitcherQuery = query
    }

    /// Selects a ref's commit in the history and its row in the sidebar.
    func reveal(_ ref: Ref) {
        showSidebar = true
        if ref.kind == .localBranch {
            didRenameBranch(from: ref.name, to: ref.name)   // opens its folders
        }
        if commit(withID: ref.target) != nil {
            selectedFile = nil
            selection = .commit(ref.target)
        }
        sidebarReveal = ref.fullName
    }

    /// A file from the quick switcher: its changes when it has any, otherwise its history.
    func showFile(_ path: String) {
        if status.entries.contains(where: { $0.path == path }) {
            selection = .workingCopy
            selectedFile = .working(path)
        } else {
            showFileHistory(path)
        }
    }

    // MARK: Layout

    var showSidebar = true
    var showInspector = true
    /// The window is too narrow for the inspector column; it can still be shown as an overlay.
    var isInspectorCompact = false
    var showInspectorOverlay = false
    /// Narrow window: the toolbar search field collapses to a magnifier button.
    var isSearchCompact = false
    /// Narrower still: Stash moves into the » menu and the branch name is shortened.
    var isToolbarCompact = false
    var expandedSidebarFolders: Set<String> = []

    var isInspectorVisible: Bool {
        isInspectorCompact ? showInspectorOverlay : showInspector
    }

    func toggleInspector() {
        if isInspectorCompact {
            showInspectorOverlay.toggle()
        } else {
            showInspector.toggle()
        }
    }

    @ObservationIgnored private var watcher: FileSystemWatcher?
    @ObservationIgnored private var pendingScope: ChangeScope = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var autoFetchTask: Task<Void, Never>?
    @ObservationIgnored private var detailsTask: Task<Void, Never>?
    @ObservationIgnored private var diffTask: Task<Void, Never>?
    @ObservationIgnored private var didExpandCurrentBranch = false
    @ObservationIgnored private var openStart: ContinuousClock.Instant?
    /// A file to show once the selected commit's file list has loaded.
    @ObservationIgnored var pendingFileSelection: String?

    init(url: URL) {
        self.url = url
    }

    var displayName: String { repository?.name ?? url.lastPathComponent }

    var hasHead: Bool { status.headID != nil }

    /// Name shown in the Branch pop-up. A rebase detaches HEAD, but it's still that branch's work.
    var headTitle: String {
        if operation?.kind == .rebase, let branch = operation?.branch { return branch }
        switch status.head {
        case .branch(let name), .unborn(let name): return name
        case .detached(let id): return String(localized: "Detached HEAD · \(String(id.prefix(7)))")
        }
    }

    /// HEAD is detached outside of an operation (a rebase detaches it on purpose).
    var isDetached: Bool { status.branch == nil && hasHead && operation == nil }

    /// The branch HEAD was on before it was detached, if it still exists.
    var previousBranch: String? {
        recentBranches.first
    }

    /// Nothing is running and no operation waits: safe to start a merge, pull, switch…
    var canStartOperation: Bool { activity == nil && operation == nil }

    var headCommit: Commit? {
        status.headID.flatMap { commitIndex[$0] }.map { commits[$0] }
    }

    var selectedCommit: Commit? {
        guard case .commit(let id) = selection else { return nil }
        return commit(withID: id)
    }

    func commit(withID id: String) -> Commit? {
        commitIndex[id].map { commits[$0] } ?? knownCommits[id]
    }

    var upstreamRemote: String? {
        status.upstream?.split(separator: "/", maxSplits: 1).first.map(String.init)
    }

    // MARK: - Loading

    func load() async {
        guard repository == nil else { return }
        let start = ContinuousClock.now
        openStart = start
        do {
            let repository = try await GitRepository.open(url, runner: AppModel.shared.makeRunner())
            self.repository = repository
            loadGraphFilters()
            AppModel.shared.noteOpened(repository.root)
            lastFetch = repository.lastFetchDate
            await refreshEverything()
            phase = .ready
            log.info("Opened \(repository.name, privacy: .public): \(self.commits.count) commits in \(ContinuousClock.now - start, privacy: .public)")
            if Preferences.watchFileChanges {
                startWatching(repository)
            }
            startAutoFetch()
            #if DEBUG
            applyLaunchSelection()
            #endif
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Stops watching and background work when the window closes.
    func close() {
        watcher?.stop()
        watcher = nil
        autoFetchTask?.cancel()
        refreshTask?.cancel()
        detailsTask?.cancel()
        diffTask?.cancel()
    }

    /// Reloads refs, status, stashes, history and the current selection.
    func refreshEverything() async {
        guard let repository else { return }
        let start = ContinuousClock.now
        defer { log.debug("Refreshed \(repository.name, privacy: .public) in \(ContinuousClock.now - start, privacy: .public)") }
        async let statusResult = try? repository.status()
        async let refsResult = try? repository.refs()
        async let stashResult = try? repository.stashes()
        async let remotesResult = try? repository.remotes()
        async let recentResult = repository.recentlyCheckedOut()
        let (newStatus, newRefs, newStashes, newRemotes) = await (statusResult, refsResult, stashResult, remotesResult)
        if let newStatus { status = newStatus }
        if let newRefs {
            refs = newRefs
            pruneGraphFilters()
        }
        stashes = newStashes ?? []
        remotes = newRemotes ?? []
        if let shown = stashView?.stash {
            // Popped or dropped: nothing left to show. Otherwise its stash@{n} may have moved.
            if let current = stashes.first(where: { $0.id == shown.id }) {
                if current != shown { stashView?.stash = current }
            } else {
                stashView = nil
            }
        }
        updateOperation(repository.operationState())
        let localBranches = Set(refs.localBranches.map(\.name))
        recentBranches = await recentResult.filter { localBranches.contains($0) }
        lastFetch = repository.lastFetchDate ?? lastFetch
        expandFolderOfCurrentBranchOnce()

        // Line counts and the commit count don't need to wait for the history.
        let untracked = status.entries.filter(\.isUntracked).map(\.path)
        async let lineStatsResult = repository.workingTreeLineStats(untracked: untracked.count > 2000 ? [] : untracked)
        async let countResult = hasHead ? try? repository.commitCount() : 0
        await reloadHistory()
        if phase == .loading {
            // First paint: the history is there; line counts, the commit count and the rest follow.
            phase = .ready
            if let openStart { log.info("First paint of \(repository.name, privacy: .public) after \(ContinuousClock.now - openStart, privacy: .public)") }
        }
        lineStats = await lineStatsResult
        headCommitCount = await countResult
        reloadSelectionAfterRefresh()
        let remote = upstreamRemote ?? (remotes.contains("origin") ? "origin" : remotes.first)
        if let remote, let url = await repository.configuredRemoteURL(remote) {
            primaryRemote = RemoteURL(url)
        } else {
            primaryRemote = nil
        }
        // Who made the latest commits, for the authors' GitHub avatars (once per launch).
        AvatarStore.shared.prime(primaryRemote)
        async let submoduleList = repository.submodules()
        async let worktreeList = repository.worktrees()
        submodules = await submoduleList
        worktrees = await worktreeList
        await reloadSubmoduleDistances()
        await reloadWorkingLFS(countPointers: true)
        if fileHistory != nil {
            // A new commit may have changed the file.
            await loadFileHistory()
            if fileHistory?.mode == .blame { await loadBlame() }
        }
    }

    func refreshStatus() async {
        guard let repository, let newStatus = try? await repository.status() else { return }
        let headMoved = newStatus.headID != status.headID || newStatus.branch != status.branch
        let submodulesChanged = newStatus.entries.filter { $0.submodule != nil } != status.entries.filter { $0.submodule != nil }
        status = newStatus
        updateOperation(repository.operationState())
        if headMoved {
            await refreshEverything()
            return
        }
        await reloadLineStats()
        if submodulesChanged {
            // A commit checked out inside a submodule: what it records and how far it moved.
            submodules = await repository.submodules()
            await reloadSubmoduleDistances()
        }
        await reloadWorkingLFS(countPointers: false)
        if let fileHistory, fileHistory.mode == .blame, fileHistory.blameRevision == .workingCopy {
            // The file on disk may have changed.
            await loadBlame()
        }
        if case .working(let path) = selectedFile {
            // The file may have been committed, discarded or reverted meanwhile.
            if status.entries.contains(where: { $0.path == path }) {
                loadDiff()
            } else {
                selectedFile = nil
            }
        }
    }

    private func reloadLineStats() async {
        guard let repository else { return }
        let untracked = status.entries.filter(\.isUntracked).map(\.path)
        // Counting lines of thousands of untracked files isn't worth it.
        lineStats = await repository.workingTreeLineStats(untracked: untracked.count > 2000 ? [] : untracked)
    }

    /// The first screenful comes from a small page so a big repository paints at once; the
    /// rest of the first page follows in the background.
    static let firstPaintCount = 400

    private func reloadHistory() async {
        guard let repository else { return }
        let pageSize = Preferences.historyPageSize
        let isFirstLoad = commits.isEmpty
        let limit = isFirstLoad ? Self.firstPaintCount : max(pageSize, min(commits.count, pageSize * 10))
        let includeHEAD = hasHead
        let scope = historyScope
        var loaded: [Commit] = []
        if includeHEAD || !refs.refs.isEmpty {
            do {
                loaded = try await repository.log(skip: 0, limit: limit, includeHEAD: includeHEAD, scope: scope)
            } catch {
                alert = AlertItem(title: String(localized: "Couldn't Load History"), message: error.localizedDescription)
            }
        }
        let logged = ContinuousClock.now
        var head = status.headID
        if case .only = scope, let id = head, !loaded.contains(where: { $0.id == id }) {
            // Another branch shown alone: the working copy has nothing to link to.
            head = nil
        }
        let builder = await Task.detached(priority: .userInitiated) {
            var builder = CommitGraphBuilder()
            builder.appendWorkingCopy(head: head)
            builder.append(loaded)
            return builder
        }.value
        log.debug("History: \(loaded.count) commits, graph built in \(ContinuousClock.now - logged, privacy: .public)")
        graphBuilder = builder
        graph = builder.rows
        commits = loaded
        commitIndex = Dictionary(loaded.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        hasMoreHistory = loaded.count == limit
        historyVersion += 1
        // New commits may match too: ask git again.
        updateSearch(rerunHistorySearch: true)
        if isFirstLoad, hasMoreHistory {
            Task { [weak self] in await self?.loadMoreHistory() }
        }
    }

    /// Loads the next page when the table scrolls near the end.
    func loadMoreHistory() async {
        guard hasMoreHistory, !isLoadingMore, let repository else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let pageSize = Preferences.historyPageSize
        do {
            let page = try await repository.log(skip: commits.count, limit: pageSize, includeHEAD: hasHead, scope: historyScope)
            let fresh = page.filter { commitIndex[$0.id] == nil }
            let current = graphBuilder
            let builder = await Task.detached(priority: .userInitiated) {
                var builder = current
                builder.append(fresh)
                return builder
            }.value
            for (offset, commit) in fresh.enumerated() {
                commitIndex[commit.id] = commits.count + offset
            }
            commits += fresh
            graphBuilder = builder
            graph = builder.rows
            hasMoreHistory = page.count == pageSize
            historyVersion += 1
            updateSearch()
            log.debug("Loaded \(fresh.count) more commits (\(self.commits.count) total)")
        } catch {
            hasMoreHistory = false
        }
    }

    // MARK: - File-system events

    /// Settings › Advanced › File changes. Without the watcher the window refreshes when Kaern
    /// becomes active (and with ⌘R).
    func setWatching(_ enabled: Bool) {
        guard let repository else { return }
        if enabled, watcher == nil {
            startWatching(repository)
            scheduleRefresh(.refs)
        } else if !enabled {
            watcher?.stop()
            watcher = nil
        }
    }

    private func startWatching(_ repository: GitRepository) {
        let root = repository.root.plainPath
        var paths = [root]
        let gitDirectory = repository.gitDirectory.plainPath
        if !gitDirectory.hasPrefix(root + "/") {
            paths.append(gitDirectory)
        }
        let watcher = FileSystemWatcher(paths: paths, latency: 0.3) { [weak self] changed in
            Task { @MainActor [weak self] in
                self?.fileSystemChanged(changed)
            }
        }
        watcher.start()
        self.watcher = watcher
    }

    private func fileSystemChanged(_ paths: [String]) {
        guard let repository else { return }
        let scope = repository.classify(paths)
        guard !scope.isEmpty else { return }
        if scope == .workTree {
            // Only working-tree files: skip what .gitignore excludes (build output, caches).
            Task { [weak self] in
                guard !(await repository.notIgnored(paths)).isEmpty, let self else { return }
                self.scheduleRefresh(.workTree)
            }
            return
        }
        scheduleRefresh(scope)
    }

    /// Coalesces refresh requests: one refresh runs at a time and picks up whatever arrived meanwhile.
    func scheduleRefresh(_ scope: ChangeScope) {
        pendingScope.formUnion(scope)
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while let self, !self.pendingScope.isEmpty, !Task.isCancelled {
                let next = self.pendingScope
                self.pendingScope = []
                if next.contains(.refs) {
                    await self.refreshEverything()
                } else {
                    await self.refreshStatus()
                }
            }
            self?.refreshTask = nil
        }
    }

    // MARK: - Background fetch

    private func startAutoFetch() {
        autoFetchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                guard let self else { return }
                if self.shouldFetchInBackground() {
                    await self.fetch(userInitiated: false)
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func shouldFetchInBackground() -> Bool {
        guard Preferences.fetchAutomatically, activity == nil, !remotes.isEmpty, !isWorkingOffline,
              AppModel.shared.isOnline, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        var interval = TimeInterval(Preferences.fetchInterval.rawValue * 60)
        if Self.isOnBatteryPower {
            interval = max(interval, 15 * 60)
        }
        return Date.now.timeIntervalSince(lastFetch ?? .distantPast) >= interval
    }

    private static var isOnBatteryPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == "Battery Power"
    }

    // MARK: - Selection

    private func selectionDidChange() {
        // Picking something else (the sidebar, search, the quick switcher) leaves File History
        // and the stash view.
        if fileHistory != nil, !isInspectingForFileHistory {
            fileHistory = nil
        }
        if stashView != nil {
            stashView = nil
        }
        if pullRequests != nil {
            pullRequests = nil
        }
        selectedFile = nil
        detailsTask?.cancel()
        switch selection {
        case .workingCopy:
            details = nil
            detailFiles = []
            detailBranches = []
        case .commit(let id):
            loadDetails(for: id)
        }
    }

    private func reloadSelectionAfterRefresh() {
        switch selection {
        case .workingCopy:
            if case .working(let path) = selectedFile {
                if status.entries.contains(where: { $0.path == path }) {
                    loadDiff()
                } else {
                    selectedFile = nil
                }
            }
        case .commit(let id):
            if commit(withID: id) == nil {
                selection = .workingCopy
            }
        }
    }

    #if DEBUG
    /// `-KaernSelectCommit <sha prefix>` and `-KaernSelectFile <path>` (debug builds) for scripted checks.
    private func applyLaunchSelection() {
        let defaults = UserDefaults.standard
        if let prefix = defaults.string(forKey: "KaernSelectCommit"),
           let commit = commits.first(where: { $0.id.hasPrefix(prefix) }) {
            selection = .commit(commit.id)
        }
        if let path = defaults.string(forKey: "KaernSelectFile") {
            if case .commit = selection {
                pendingFileSelection = path
            } else {
                selectedFile = .working(path)
            }
        }
    }
    #endif

    private func loadDetails(for id: String) {
        guard let repository, let commit = commit(withID: id) else { return }
        isLoadingDetails = true
        let base = comparisonBase
        comparisonDistance = nil
        detailsTask = Task { [weak self] in
            async let detailsResult = try? repository.commitDetails(id)
            async let filesResult = Self.changedFiles(of: commit, since: base, in: repository)
            async let branchesResult = try? repository.branchesContaining(id)
            async let distanceResult = Self.distance(since: base, to: id, in: repository)
            let (details, files, branches, distance) = await (detailsResult, filesResult, branchesResult, distanceResult)
            guard let self, !Task.isCancelled, self.selection == .commit(id), self.comparisonBase == base else { return }
            self.details = details
            self.detailFiles = files ?? []
            self.detailBranches = branches ?? []
            self.detailLFSSizes = [:]
            self.comparisonDistance = distance
            self.isLoadingDetails = false
            self.detailSignature = nil
            Task { [weak self] in
                // Checking a signature runs gpg or ssh-keygen: after the rest has shown.
                let signature = await repository.signature(of: id)
                guard let self, self.selection == .commit(id) else { return }
                self.detailSignature = signature
            }
            if let files {
                Task { [weak self] in await self?.loadDetailLFSSizes(for: commit, since: base, files: files) }
            }
            if let pending = self.pendingFileSelection, self.detailFiles.contains(where: { $0.path == pending }) {
                self.pendingFileSelection = nil
                self.selectedFile = .commit(commitID: id, path: pending)
            }
        }
    }

    private func loadDiff() {
        diffTask?.cancel()
        guard let selectedFile, let repository else {
            diff = nil
            diffError = nil
            return
        }
        isLoadingDiff = true
        let status = self.status
        let files = self.detailFiles
        let base = comparisonBase
        let ignoresWhitespace = Preferences.diffIgnoreWhitespace
        diffTask = Task { [weak self] in
            do {
                let content: DiffContent?
                switch selectedFile {
                case .working(let path):
                    if let entry = status.entries.first(where: { $0.path == path }) {
                        if entry.isConflicted {
                            // The conflict editor reads the file itself.
                            guard let self, !Task.isCancelled else { return }
                            self.diff = nil
                            self.diffError = nil
                            self.isLoadingDiff = false
                            return
                        }
                        content = .working(try await Self.workingDiff(for: entry, in: repository, ignoringWhitespace: ignoresWhitespace))
                    } else {
                        content = nil
                    }
                case .commit(let commitID, let path):
                    if let commit = self?.commit(withID: commitID), let change = files.first(where: { $0.path == path }) {
                        let diff = try await repository.diff(of: change, from: base ?? commit.parents.first, to: commit.id,
                                                             ignoringWhitespace: ignoresWhitespace)
                        content = .commit(commit, change, diff)
                    } else {
                        content = nil
                    }
                }
                guard let self, !Task.isCancelled, self.selectedFile == selectedFile else { return }
                guard let content else {
                    // Nothing left to show (the file is gone from the status or the commit).
                    self.isLoadingDiff = false
                    self.selectedFile = nil
                    return
                }
                if self.diff != content {
                    self.diff = content
                    self.diffVersion += 1
                }
                self.diffError = nil
                self.isLoadingDiff = false
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.diffError = error.localizedDescription
                self.isLoadingDiff = false
            }
        }
    }

    private static func workingDiff(for entry: StatusEntry, in repository: GitRepository, ignoringWhitespace: Bool) async throws -> WorkingDiff {
        if entry.isUntracked {
            return WorkingDiff(entry: entry, staged: nil, unstaged: try await repository.untrackedDiff(path: entry.path))
        }
        let stagedPaths = [entry.originalPath, entry.path].compactMap { $0 }
        async let staged = entry.hasStagedChanges
            ? repository.workingDiff(paths: stagedPaths, staged: true, ignoringWhitespace: ignoringWhitespace) : nil
        async let unstaged = entry.hasUnstagedChanges
            ? repository.workingDiff(path: entry.path, staged: false, ignoringWhitespace: ignoringWhitespace) : nil
        return WorkingDiff(entry: entry, staged: try await staged, unstaged: try await unstaged, ignoresWhitespace: ignoringWhitespace)
    }

    private static func distance(since base: String?, to target: String, in repository: GitRepository) async -> CommitDistance? {
        guard let base else { return nil }
        return await repository.distance(from: base, to: target)
    }

    /// What a commit changed, or everything that differs since `base` in a comparison.
    private static func changedFiles(of commit: Commit, since base: String?, in repository: GitRepository) async -> [FileChange]? {
        if let base { return try? await repository.changedFiles(from: base, to: commit.id) }
        return try? await repository.changedFiles(in: commit)
    }

    /// The diff again, after its Ignore Whitespace toggle changed.
    func reloadDiff() {
        loadDiff()
    }

    // MARK: - Comparing commits

    /// Compares two commits: the newer one becomes the selection, the older one the base.
    func compare(_ first: String, _ second: String) {
        guard first != second else { return }
        let (base, target) = isOlder(first, than: second) ? (first, second) : (second, first)
        guard comparisonBase != base || selection != .commit(target) else { return }
        comparisonBase = base
        isStartingComparison = true
        if selection == .commit(target) {
            selectionDidChange()
        } else {
            selection = .commit(target)
        }
        isStartingComparison = false
    }

    /// Back to the newer commit on its own.
    func endComparison() {
        guard comparisonBase != nil else { return }
        comparisonBase = nil
        selectionDidChange()
    }

    /// Swaps which side is the base: what the newer commit removed shows as added.
    func swapComparison() {
        guard let base = comparisonBase, case .commit(let target) = selection else { return }
        comparisonBase = target
        isStartingComparison = true
        selection = .commit(base)
        isStartingComparison = false
    }

    /// The history lists newer commits first; a commit outside the loaded pages goes by date.
    private func isOlder(_ a: String, than b: String) -> Bool {
        if let ia = commitIndex[a], let ib = commitIndex[b] { return ia > ib }
        if let ca = commit(withID: a), let cb = commit(withID: b) { return ca.author.date < cb.author.date }
        return false
    }

    // MARK: - Graph filters

    var historyScope: HistoryScope {
        if let soloRef { return .only(soloRef) }
        return .all(hidden: hiddenRefs.sorted())
    }

    /// After a branch was hidden or shown alone: the history again, and the filter remembered.
    func graphFiltersChanged() async {
        saveGraphFilters()
        await reloadHistory()
        reloadSelectionAfterRefresh()
    }

    /// Hidden branches that were deleted (or renamed) since are forgotten.
    private func pruneGraphFilters() {
        let names = Set(refs.refs.map(\.fullName))
        let kept = hiddenRefs.filter { $0.hasSuffix("/*") || names.contains($0) }
        let solo = soloRef.flatMap { names.contains($0) ? $0 : nil }
        if kept != hiddenRefs || solo != soloRef {
            hiddenRefs = kept
            soloRef = solo
            saveGraphFilters()
        }
    }

    func loadGraphFilters() {
        guard let path = repository?.root.plainPath,
              let all = UserDefaults.standard.dictionary(forKey: PreferenceKey.graphFilters),
              let entry = all[path] as? [String: Any] else { return }
        hiddenRefs = Set(entry["hidden"] as? [String] ?? [])
        soloRef = entry["solo"] as? String
    }

    private func saveGraphFilters() {
        guard let path = repository?.root.plainPath else { return }
        var all = UserDefaults.standard.dictionary(forKey: PreferenceKey.graphFilters) ?? [:]
        if hiddenRefs.isEmpty && soloRef == nil {
            all[path] = nil
        } else {
            var entry: [String: Any] = ["hidden": hiddenRefs.sorted()]
            if let soloRef { entry["solo"] = soloRef }
            all[path] = entry
        }
        UserDefaults.standard.set(all, forKey: PreferenceKey.graphFilters)
    }

    // MARK: - Composer

    var composedMessage: String {
        let subject = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = messageBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? subject : subject + "\n\n" + body
    }

    var canCommit: Bool {
        activity == nil
            && operation == nil
            && status.conflictCount == 0
            && !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (status.stagedCount > 0 || (amend && hasHead))
    }

    private func amendDidChange() {
        guard amend, summary.isEmpty, messageBody.isEmpty, let head = status.headID, let repository else { return }
        Task { [weak self] in
            guard let details = try? await repository.commitDetails(head), let self, self.amend else { return }
            self.summary = details.commit.subject
            self.messageBody = details.body
        }
    }

    // MARK: - Sidebar

    /// Opens the folders of a branch's new name, so a rename doesn't hide it.
    func didRenameBranch(from old: String, to new: String) {
        var components = new.split(separator: "/").map(String.init)
        components.removeLast()
        var prefix = "local"
        for component in components {
            prefix += "/" + component
            expandedSidebarFolders.insert(prefix)
        }
    }

    private func expandFolderOfCurrentBranchOnce() {
        guard !didExpandCurrentBranch, let branch = status.branch else { return }
        didExpandCurrentBranch = true
        var components = branch.split(separator: "/").map(String.init)
        components.removeLast()
        var prefix = "local"
        for component in components {
            prefix += "/" + component
            expandedSidebarFolders.insert(prefix)
        }
    }

    // MARK: - Operations plumbing

    /// Runs a git operation, shows failures as an alert and refreshes afterwards. A command that
    /// stops on conflicts (a pull, merge or rebase) isn't a failure: the operation bar takes over.
    @discardableResult
    func perform(
        _ activity: Activity,
        failureTitle: String,
        remote: RemoteAction? = nil,
        _ work: (GitRepository) async throws -> Void
    ) async -> Bool {
        guard let repository else { return false }
        guard self.activity == nil else {
            NSSound.beep()
            return false
        }
        self.activity = activity
        defer { self.activity = nil }
        let hadOperation = operation != nil
        do {
            try await work(repository)
            if remote != nil { isWorkingOffline = false }
            await refreshEverything()
            return true
        } catch {
            await refreshEverything()
            if !hadOperation, operation != nil {
                return false
            }
            if let remote, await handleRemoteFailure(error, retry: remote) {
                return false
            }
            alert = AlertItem(title: failureTitle, message: error.localizedDescription)
            return false
        }
    }

    /// Picks up the operation git has in progress. A new step starts with git's prepared message.
    private func updateOperation(_ state: OperationState?) {
        let identity = state.map { "\($0.kind.rawValue)-\($0.incoming ?? "")-\($0.step ?? 0)" }
        if identity != operationIdentity {
            let started = operationIdentity == nil && identity != nil
            operationIdentity = identity
            operationMessage = state?.message ?? ""
            resolvedConflicts = []
            if started {
                // Show the conflicts right away.
                selection = .workingCopy
            }
        }
        if operation != state {
            operation = state
        }
    }

    /// Quick index/work-tree changes (staging) that only need a status refresh.
    @discardableResult
    func performIndexChange(failureTitle: String, _ work: (GitRepository) async throws -> Void) async -> Bool {
        guard let repository else { return false }
        var succeeded = true
        do {
            try await work(repository)
        } catch {
            alert = AlertItem(title: failureTitle, message: error.localizedDescription)
            succeeded = false
        }
        await refreshStatus()
        return succeeded
    }

    func showError(_ error: any Error, title: String) {
        alert = AlertItem(title: title, message: error.localizedDescription)
    }

    /// Used by fetch (RepositoryModel+Remote.swift); the properties stay read-only elsewhere.
    func setFetchResult(date: Date?, error: String?) {
        lastFetch = date ?? lastFetch
        fetchError = error
    }

    func setActivity(_ value: Activity?) {
        activity = value
    }
}
