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
    case local, remote, tags, stashes, worktrees, submodules
}

/// Sidebar state kept per repository, so it survives tab switches.
struct SidebarState: Equatable {
    var collapsed: Set<SidebarSection> = []
    /// Branch folders the user folded ("feature" under Local).
    var foldedFolders: Set<String> = []
    /// Remotes the user unfolded (remotes start folded, like the board's origin).
    var openRemotes: Set<String> = []
    /// Remote branch folders the user unfolded ("origin/release"); they start folded.
    var openRemoteFolders: Set<String> = []
    /// How many names a remote branch folder shows beyond the first ones ("N more" adds to it).
    var remoteFolderExtra: [String: Int] = [:]
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
        /// The folder is there but isn't a Git repository (yet): ScreenInit's empty state.
        case notRepository
    }

    private(set) var phase: Phase = .waiting
    /// What's in the folder when it isn't a repository yet.
    private(set) var folderSurvey: FolderSurvey?
    /// "Created travel-blog · 1 commit · 7 files": the status bar after Create New Repository.
    var createdNote: String?
    /// The banner over a repository Kaern just made that's only on this Mac (Publish to GitHub…).
    var showsPublishBanner = false
    private(set) var repository: GitRepository?
    private(set) var status: WorkingTreeStatus = .empty {
        didSet { updateBigChanges() }
    }
    /// Thousands of changed files: the panel lists folders and may suggest ignoring one (ScreenBigRepo).
    private(set) var bigChanges: BigChanges?
    /// Folders whose .gitignore suggestion was put away with Not Now.
    var dismissedIgnoreSuggestions: Set<String> = []
    /// Folders opened in the big changes list, and how many more files each shows.
    var openChangeFolders: Set<String> = []
    var changeFolderExtra: [String: Int] = [:]
    /// `false` while `status` comes from the light check (untracked folders folded).
    private(set) var statusIsFull = false
    private(set) var refs: RefSnapshot = .empty
    private(set) var tags: [TagInfo] = []
    private(set) var commits: [Commit] = []
    /// What the graph shows: `commits` with runs of bot commits folded or left out (View › Bot
    /// Commits). `graph` lines up with it.
    private(set) var displayCommits: [Commit] = []
    /// Folded runs by the id of their row, and which commits are inside one.
    private(set) var botRuns: [String: BotRun] = [:]
    private(set) var insideRun: [String: String] = [:]
    private(set) var foldedBotCount = 0
    private(set) var hiddenBotCount = 0
    private(set) var hasBotCommits = false
    /// Runs opened with their chevron.
    var expandedRuns: Set<String> = [] {
        didSet { if expandedRuns != oldValue { rebuildGraph() } }
    }
    /// Every commit in history (the bot bar's count), read when the bar shows.
    var totalCommitCount: Int?
    private(set) var graph: [GraphRow] = []
    /// The history has a working-copy row on top (`graph[0]` is it).
    private(set) var showsWorkingCopy = false
    private(set) var hasMoreHistory = false
    private(set) var isLoadingMoreHistory = false
    /// The last history read failed (`git log` exited with an error, as opposed to being
    /// stopped): the list keeps what it had, and the status bar shows git's message with Try Again.
    private(set) var historyError: String?
    /// What the graph draws (ScreenBigRepo's Graph: chip). Decided on the first load: a choice
    /// kept for this repository, else Local + main when it has many remote branches.
    var graphScope: GraphScope = .all
    @ObservationIgnored var graphScopeDecided = false
    /// Remote-only branches picked in the sidebar to be drawn while the graph shows local branches.
    var drawnRemoteBranches: [String] = []
    /// A commit to select once history was read again (a remote branch picked to be drawn).
    @ObservationIgnored var selectAfterReload: String?

    // Phase 6 (ScreenMarks): signatures and worktrees.
    /// `%G?` of the history rows that have been on screen (the Commit column's shields).
    var signatureCodes: [String: Character] = [:]
    @ObservationIgnored var signaturesInFlight: Set<String> = []
    /// Ids waiting for the next signature read (one read runs at a time).
    @ObservationIgnored var signaturesWanted: Set<String> = []
    @ObservationIgnored var signatureReadTask: Task<Void, Never>?
    /// The selected commit's signature, once read (the panel's card).
    var selectedSignature: SelectedSignature?
    /// The card shows its details (they open when a commit is picked, like the board).
    var signatureCardOpen = true
    @ObservationIgnored var signatureTask: Task<Void, Never>?
    /// Another worktree's page in the right panel (its path); `nil`: the selection's details.
    var selectedWorktree: String? {
        didSet { if selectedWorktree != oldValue { worktreeDetails = nil } }
    }
    /// Uncommitted changes in the other worktrees, by path (the sidebar's "2 changes" and dot).
    var worktreeChanges: [String: Int] = [:]
    var worktreeDetails: WorktreeDetails?
    private(set) var stashes: [Stash] = []
    private(set) var worktrees: [Worktree] = []
    private(set) var remotes: [RemoteInfo] = []
    private(set) var operation: OperationState?
    private(set) var lastFetch: Date?
    /// Line counts of the working copy's changes, staged and unstaged apart.
    private(set) var lineStats = WorkingLineStats.empty
    /// Git LFS sizes and pointers, and how far moved submodules are (ScreenMarks).
    var workingMarks = WorkingMarks.empty
    /// The same for the selected commit's files.
    var commitMarks: CommitMarks?
    /// The file Quick Look shows (Space, ⌘Y).
    var quickLookURL: URL?
    /// The sidebar's Submodules section (ScreenMarks).
    var submoduleItems: [SubmoduleItem] = []
    /// A shallow clone: the history ends with Fetch 100 More / Fetch Full History (ScreenBigRepo).
    var isShallow = false
    private(set) var activity: RepositoryActivity?
    /// The selected commit's details (the panel).
    private(set) var selectedDetails: CommitDetails?
    private(set) var selectedFiles: [FileChange] = []
    var alert: RepositoryAlert?

    // UI state that survives tab switches.
    var selection: HistorySelection = .workingCopy {
        didSet {
            guard selection != oldValue else { return }
            selectedWorktree = nil
            signatureCardOpen = true
            // A commit inside a folded run of bot commits: the run opens.
            if case .commit(let id) = selection, let run = insideRun[id] { expandedRuns.insert(run) }
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
            if review != nil, screen != nil { screen = nil }
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
    /// The end of the range ⇧↑ / ⇧↓ moves (the anchor stays).
    var pickFocus: String?
    /// Asks the graph to take keyboard focus (the debug driver; a background window gets no clicks).
    var historyFocusRequest = 0
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
    /// The sheet over the window (New Branch, New Tag, the branch pickers, Repository Settings…).
    var sheet: RepositorySheet?

    // Phase 4: the stash view, the conflict editor and the operation bar.
    /// What the center shows instead of the graph (a stash, the conflict editor); `nil`: graph or Review.
    var screen: CenterScreen? {
        didSet {
            guard screen != oldValue else { return }
            if case .stash(let id) = screen { loadStashDetails(id) } else { stashTask?.cancel() }
        }
    }
    /// The conflict editor's files, picks and message.
    var conflictSession: ConflictSession?
    /// A stash apply or pop that stopped on conflicts (Undo Pop · Resolve Conflict).
    var stashConflict: StashApplyConflict?
    /// The stash the stash view shows.
    var stashDetails: StashDetails?
    /// The green bar after a merge, rebase, cherry-pick or revert finished.
    var operationFinish: OperationFinish?
    /// Where the stopped operation began (⌘Z once it's finished).
    var operationStart: OperationStart?
    /// The last fetch failed (sign-in, network): the status bar says so with the fix.
    var fetchProblem: FetchProblem?
    /// Auto-fetch waits for you after the server turned down the sign-in.
    var autoFetchPaused = false
    /// File History and Blame: the file, the mode and what's picked.
    var explore: ExploreState?
    var fileHistory: (path: String, entries: [FileHistoryEntry])?
    var fileHistoryDiff: (key: String, diff: FileDiff)?
    var blame: (key: String, blame: Blame)?
    /// The commit the right panel shows while exploring.
    var exploreCommit: ExploreCommit?
    @ObservationIgnored var exploreTask: Task<Void, Never>?
    @ObservationIgnored var historyDiffTask: Task<Void, Never>?
    @ObservationIgnored var exploreCommitTask: Task<Void, Never>?
    /// Branches switched to in this session, newest first (the branch menu's Recent Branches).
    var switchedBranches: [String] = []
    /// Repository Settings › Run hooks when committing from Kaern (`kaern.runHooks` in .git/config).
    var runsHooks = true
    /// Repository Settings › Pull, when this repository sets its own (pull.rebase / pull.ff).
    var pullOverride: PullChoice?
    @ObservationIgnored var stashTask: Task<Void, Never>?
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


    @ObservationIgnored private var runner: GitRunner?
    @ObservationIgnored private var watcher: FileSystemWatcher?
    /// The `git log` the history reads more from as you scroll (one per visible repository).
    @ObservationIgnored var historyStream: CommitStream?
    @ObservationIgnored var allHistoryTask: Task<Void, Never>?
    /// A history read was cut short (the tab went to the background while it read): history
    /// loads again the next time the tab shows.
    @ObservationIgnored private var historyIsStale = false
    /// Line counts, LFS and submodule marks were skipped because the tab wasn't visible.
    @ObservationIgnored private var lineStatsAreStale = false
    /// A first load or a refresh is reading history from a new stream; pages for scrolling wait
    /// for it, so they never come from the new stream on top of the old list.
    @ObservationIgnored private var isReloadingHistory = false
    /// Scrolling asked for more while history was reloading.
    @ObservationIgnored private var wantsMoreHistory = false
    /// How long the last full `git status` took (the fsmonitor suggestion, the status bar).
    var statusDuration: Duration?
    /// `core.fsmonitor` is on here (read once a slow status makes it matter).
    var fsmonitorOn: Bool?
    /// Not Now on the fsmonitor suggestion (kept in the settings by folder).
    private(set) var fsmonitorDismissed = false
    @ObservationIgnored private var pendingScope: ChangeScope = []
    /// How often Kaern itself has changed the repository (``noteOwnChange()``: an action ended,
    /// staging ran). A `git status` that began before such a change may be from before it, or
    /// from the middle of it. So whoever reads one notes the count first, and the answer is
    /// shown only if the count hasn't moved (``show(_:isFull:readAt:)``); the read that follows
    /// the change brings the status. The file watcher starts refreshes while actions run: one of
    /// them came back with a status from just before a stash pop stopped on a conflict, no
    /// conflict in it, and the conflict bar went away as "resolved".
    @ObservationIgnored private var ownChanges = 0
    /// ``ownChanges`` when the read `status` came from began.
    @ObservationIgnored private var statusReadAt = 0
    /// `status` was read after everything Kaern itself has done to the repository. Only then
    /// does it say that a conflict is gone (``conflictsChanged()``).
    var statusIsCurrent: Bool { statusReadAt == ownChanges }
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
    /// How many `git status` answers weren't shown because Kaern changed the repository after
    /// git began reading (see `ownChanges`), and how many refreshes concluded nothing because
    /// it did while they ran.
    @ObservationIgnored private(set) var debugStaleReads = 0
    @ObservationIgnored private(set) var debugCrossedRefreshes = 0
    /// The last marker file the file watcher reported (see `filesChanged`).
    @ObservationIgnored private(set) var debugWatchMarker = ""
    /// An action, a first load, a refresh or a history read is under way (the debug dump: scripts
    /// wait for this to clear instead of sleeping).
    var debugIsBusy: Bool {
        activity != nil || phase == .opening || phase == .loading || refreshTask != nil || isReloadingHistory || isLoadingMoreHistory
    }
    /// How long loading steps took, in seconds (the debug dump's measurements).
    @ObservationIgnored var debugTimings: [String: Double] = [:]

    func noteTiming(_ name: String, since start: ContinuousClock.Instant) {
        let elapsed = ContinuousClock.now - start
        debugTimings[name] = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    init(path: String) {
        self.id = path
        self.path = path
        fsmonitorDismissed = (UserDefaults.kaern.stringArray(forKey: SettingsKey.fsmonitorDismissed) ?? []).contains(path)
        dismissedIgnoreSuggestions = Self.dismissedIgnoreSuggestions(for: path)
    }

    /// Works out the folder list when the status has thousands of files (once per status).
    private func updateBigChanges() {
        if status.entries.count >= BigChanges.threshold {
            let changes = BigChanges(status.entries)
            if changes != bigChanges { bigChanges = changes }
        } else if bigChanges != nil {
            bigChanges = nil
        }
    }

    /// Kaern has just changed the repository itself: an action's git commands are done (however
    /// they ended), or staging has run. What git read before this point isn't shown anymore
    /// (see `ownChanges`), so call it as soon as the change is over, before the model shows what
    /// came of it.
    func noteOwnChange() {
        ownChanges += 1
    }

    /// Shows a status git read, unless Kaern changed the repository after git began reading
    /// (`made`: ``ownChanges`` at that time): then it may be from before that change, and the
    /// read that follows the change brings the status. Returns whether it's shown.
    @discardableResult
    private func show(_ status: WorkingTreeStatus?, isFull: Bool, readAt made: Int) -> Bool {
        guard let status else { return false }
        guard made == ownChanges else {
            debugStaleReads += 1
            return false
        }
        self.status = status
        statusIsFull = isFull
        statusReadAt = made
        return true
    }

    // MARK: Derived state

    /// Staging or unstaging waiting or running (they run one after another).
    var pendingIndexChanges = 0
    var isChangingIndex: Bool { pendingIndexChanges > 0 }

    var tabMark: TabMark {
        switch phase {
        case .missing: return .missing
        case .failed: return .error
        case .notRepository: return .none
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
        return phase == .missing || phase == .notRepository
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
        } catch is NotARepositoryError {
            phase = .notRepository
            let folder = URL(filePath: path, directoryHint: .isDirectory)
            folderSurvey = await Task.detached { FolderSurvey.survey(folder) }.value
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
        let loadStart = ContinuousClock.now
        let made = ownChanges
        if phase != .ready { phase = .loading }
        // The graph's scope depends on how many remote branches there are, so on the first load
        // the refs come before history.
        let firstRefs: RefSnapshot? = graphScopeDecided ? nil : try? await repository.refs()
        if let firstRefs { self.refs = firstRefs }
        decideGraphScope()
        async let status = timedStatus(repository)
        async let refs = firstRefs != nil ? firstRefs : try? await repository.refs()
        async let tags = try? repository.tags()
        let limit = Self.pageSize
        let stream = restartHistoryStream(repository)
        isReloadingHistory = true
        async let history = Self.read(stream, limit)
        async let stashes = try? repository.stashes()
        async let worktrees = repository.worktrees()
        async let remotes = repository.remoteInfos()

        let loadedStatus = await status
        let loadedHistory = await history
        show(loadedStatus, isFull: true, readAt: made)
        self.refs = await refs ?? self.refs
        self.tags = await tags ?? self.tags
        self.stashes = await stashes ?? self.stashes
        self.worktrees = await worktrees
        self.remotes = await remotes
        operation = repository.operationState()
        lastFetch = repository.lastFetchDate
        isShallow = repository.isShallow
        await refreshPullOverride()
        runsHooks = (await repository.localConfig("kaern.runHooks"))?.lowercased() != "false"
        switch loadedHistory {
        case .commits(let loaded):
            commits = loaded
            hasMoreHistory = !stream.isFinished
            historyIsStale = false
            historyError = nil
        case .cut:
            historyIsStale = true
        case .failed(let message):
            historyFailed(message, stream: stream)
        }
        isReloadingHistory = false
        rebuildGraph()
        phase = .ready
        selectPendingCommit()
        noteTiming("firstLoad", since: loadStart)
        loadAllHistoryIfAsked()
        if made == ownChanges {
            // What changed while this read is in what it read.
            pendingScope = []
        } else if isVisible {
            // Not what Kaern did itself meanwhile (a fetch that ended while this tab loaded): the
            // refresh that action asked for is still to come.
            runPendingRefresh(trigger: "After loading the repository")
        }
        historyReloaded()
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
        #if DEBUG
        // The debug driver's marker file (in the git folder, where `classify` ignores it): once it
        // shows here, every file change made before it has been delivered too.
        if let marker = paths.last(where: { $0.contains("/kaern-debug-sync-") }) {
            debugWatchMarker = (marker as NSString).lastPathComponent
        }
        #endif
        guard let repository, !noticeMissingFolder() else { return }
        let scope = repository.classify(paths)
        guard !scope.isEmpty else { return }
        pendingScope.formUnion(scope)
        if isVisible, phase == .ready {
            runPendingRefresh()
        } else {
            scheduleLightRefresh()
        }
    }

    /// The folder went away while the tab was open (moved, renamed, deleted, disk ejected).
    @discardableResult
    func noticeMissingFolder() -> Bool {
        guard phase != .missing, !FileManager.default.fileExists(atPath: path) else { return false }
        watcher?.stop()
        watcher = nil
        phase = .missing
        return true
    }

    private func visibilityChanged() {
        guard isVisible else {
            // A tab in the background lets go of its git log; scrolling later starts a new one.
            historyStream?.cancel()
            historyStream = nil
            allHistoryTask?.cancel()
            return
        }
        if noticeMissingFolder() { return }
        switch phase {
        case .light:
            Task { await loadEverything() }
        case .ready:
            // A read cut short when the tab went to the background: history loads again.
            if historyIsStale { pendingScope.insert(.refs) }
            if !pendingScope.isEmpty || !statusIsFull {
                pendingScope.insert(.workTree)
                runPendingRefresh(trigger: "Tab became visible")
            } else if lineStatsAreStale {
                // Loaded in the background: what that load left for the visible tab.
                Task { await GitCommandTrigger.$current.withValue(.background("Tab became visible")) { await refreshLineStats() } }
            }
        default:
            break
        }
    }

    /// Re-reads the status right away (after staging, after an action stopped on conflicts): the
    /// file event would come 0.3 s later. Returns whether git gave a status.
    @discardableResult
    func refreshStatusNow() async -> Bool {
        guard let repository else { return false }
        let isIn = await GitCommandTrigger.$current.withValue(.background("Refreshing after a change")) {
            var made: Int
            var status: WorkingTreeStatus?
            repeat {
                // Once more when Kaern changed the repository while git read: the caller goes on
                // with this status (the conflict editor opens on it), so it has to be from after
                // that change.
                made = ownChanges
                status = try? await repository.status()
                #if DEBUG
                // The debug driver's `hold statusNow`: git has answered, and the answer waits here.
                await debugHold(.statusNow)
                #endif
            } while made != ownChanges
            let isIn = show(status, isFull: true, readAt: made)
            operation = repository.operationState()
            rebuildGraph()
            await refreshLineStats()
            return isIn
        }
        #if DEBUG
        // The debug driver's `hold decideNow`: the status is shown, and what follows from it
        // waits here (the conclusions below, then the caller's: the conflict editor opening).
        await debugHold(.decideNow)
        #endif
        // Only the status was read: the conflict editor follows it. (The stash view follows the
        // stash list, which a refresh reads.)
        conflictsChanged()
        diffsAreStale = true
        refreshDiffsIfNeeded()
        return isIn
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
        // File events start refreshes while actions run too: one may end while git reads.
        let made = ownChanges
        if scope.contains(.refs) {
            async let refs = try? repository.refs()
            async let tags = try? repository.tags()
            // As much history as was loaded (a refresh shouldn't shrink what you scrolled to).
            let limit = max(Self.pageSize, min(commits.count, AppSettings.historyLoading == .all ? Int.max : 20_000))
            let stream = restartHistoryStream(repository)
            isReloadingHistory = true
            async let history = Self.read(stream, limit)
            async let stashes = try? repository.stashes()
            async let worktrees = repository.worktrees()
            async let remotes = repository.remoteInfos()
            async let status = timedStatus(repository)
            show(await status, isFull: true, readAt: made)
            self.refs = await refs ?? self.refs
            self.tags = await tags ?? self.tags
            switch await history {
            case .commits(let loaded):
                commits = loaded
                hasMoreHistory = !stream.isFinished
                totalCommitCount = nil
                historyIsStale = false
                historyError = nil
            case .cut:
                historyIsStale = true
            case .failed(let message):
                // The list keeps what it had: a failed read isn't an empty history.
                historyFailed(message, stream: stream)
            }
            isReloadingHistory = false
            self.stashes = await stashes ?? self.stashes
            self.worktrees = await worktrees
            self.remotes = await remotes
            lastFetch = repository.lastFetchDate
            isShallow = repository.isShallow
        } else {
            show(await timedStatus(repository), isFull: true, readAt: made)
        }
        operation = repository.operationState()
        rebuildGraph()
        if scope.contains(.refs) {
            selectPendingCommit()
            loadAllHistoryIfAsked()
            historyReloaded()
        }
        await refreshBranchFacts()
        await refreshLineStats()
        diffsAreStale = true
        refreshDiffsIfNeeded()
        #if DEBUG
        // The debug driver's `hold decide`: what was read is shown, and what the screens
        // conclude from it waits here.
        await debugHold(.decide)
        #endif
        if made == ownChanges {
            screenStateChanged()
        } else {
            // Kaern changed the repository while this ran: what it read is from before that, or
            // from the middle of it, and nothing is concluded from it. Once more, for the status
            // as it is now and for what the screens make of it.
            debugCrossedRefreshes += 1
            pendingScope.insert(.workTree)
        }
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
        guard let repository, !noticeMissingFolder() else { return }
        debugLightRefreshes += 1
        let made = ownChanges
        show(try? await repository.status(untrackedFiles: .normal), isFull: false, readAt: made)
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
        guard let repository else { return }
        guard isVisible else {
            // A tab loaded in the background (the preload after launch): line counts, LFS and
            // submodule marks come when it's shown.
            lineStatsAreStale = true
            return
        }
        lineStatsAreStale = false
        let untracked = status.entries.filter(\.isUntracked).map(\.path)
        lineStats = await repository.stagedAndUnstagedLineStats(untracked: untracked)
        await refreshWorkingMarks()
        await refreshSubmodules()
        await refreshWorktreeChanges()
    }

    /// Remotes again (Repository Settings added, edited or removed one).
    func refreshRemotes() async {
        guard let repository else { return }
        remotes = await repository.remoteInfos()
        pendingScope.insert(.refs)
        if isVisible, phase == .ready { runPendingRefresh(trigger: "Repository Settings") }
    }

    /// This repository's own pull setting, if any (Repository Settings › Pull).
    func refreshPullOverride() async {
        guard let repository else { return }
        async let rebase = repository.localConfig("pull.rebase")
        async let ff = repository.localConfig("pull.ff")
        let ffValue = await ff, rebaseValue = await rebase
        if ffValue == "only" {
            pullOverride = .fastForwardOnly
        } else if let rebaseValue {
            pullOverride = rebaseValue == "false" ? .fastForwardIfPossible : .rebase
        } else {
            pullOverride = nil
        }
    }

    /// How Pull pulls here: the repository's own setting, else Settings › General › Pull.
    var pullChoice: PullChoice { pullOverride ?? .app }

    /// The next page of history from the stream (a new one picks up where the last stopped).
    @discardableResult
    func loadMoreHistory(count: Int = RepositoryModel.pageSize) -> Task<Void, Never>? {
        // After a failed read, more comes with Try Again (or the next refresh), not every scroll.
        guard let repository, hasMoreHistory, !isLoadingMoreHistory, phase == .ready, historyError == nil else { return nil }
        if isReloadingHistory {
            // A refresh is reading the new history; this page comes once that's in.
            wantsMoreHistory = true
            return nil
        }
        isLoadingMoreHistory = true
        let task = Task {
            defer { isLoadingMoreHistory = false }
            let start = ContinuousClock.now
            let stream = historyStream ?? GitCommandTrigger.$current.withValue(.background("Scrolling the history")) {
                repository.historyStream(skip: commits.count, scope: historyScope)
            }
            historyStream = stream
            let read = await Self.read(stream, count)
            guard historyStream === stream else { return }
            let page: [Commit]
            switch read {
            case .commits(let commits): page = commits
            case .cut: return
            case .failed(let message):
                historyFailed(message, stream: stream)
                return
            }
            noteTiming("pageRead", since: start)
            appendHistory(page, finished: stream.isFinished)
            noteTiming("page", since: start)
        }
        return task
    }

    private func appendHistory(_ page: [Commit], finished: Bool) {
        let known = Set(commits.map(\.id))
        commits.append(contentsOf: page.filter { !known.contains($0.id) })
        hasMoreHistory = !finished
        rebuildGraph()
    }

    /// Reads older history until one of `targets` is loaded (Search stepping past the loaded
    /// commits): one read, one graph rebuild, however far it goes.
    func loadHistory(until targets: Set<String>) async -> Bool {
        guard let repository, hasMoreHistory, !isLoadingMoreHistory, !isReloadingHistory, phase == .ready, historyError == nil,
              !targets.isEmpty else {
            return false
        }
        isLoadingMoreHistory = true
        defer { isLoadingMoreHistory = false }
        let start = ContinuousClock.now
        let stream: CommitStream
        if let existing = historyStream {
            stream = existing
        } else {
            let skip = commits.count
            let scope = historyScope
            stream = GitCommandTrigger.$current.withValue(.background("Searching older history")) {
                repository.historyStream(skip: skip, scope: scope)
            }
            historyStream = stream
        }
        var read: [Commit] = []
        var found = false
        while !found, !stream.isFinished, !Task.isCancelled {
            let result = await Self.read(stream, 5_000)
            // A refresh replaced the history meanwhile: these pages belong to the old one.
            guard historyStream === stream else { return false }
            guard case .commits(let page) = result else {
                if case .failed(let message) = result { historyFailed(message, stream: stream) }
                break
            }
            if page.isEmpty { break }
            read += page
            found = page.contains { targets.contains($0.id) }
        }
        appendHistory(read, finished: stream.isFinished)
        noteTiming("searchPaging", since: start)
        return found
    }

    /// What one read of history gave.
    private enum HistoryRead {
        case commits([Commit])
        /// The stream was stopped before it had them (the tab went to the background).
        case cut
        /// git failed (git's message).
        case failed(String)
    }

    private static func read(_ stream: CommitStream, _ count: Int) async -> HistoryRead {
        do {
            return .commits(try await stream.next(count))
        } catch is CancellationError {
            return .cut
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// `git log` failed: the list stays as it was, the status bar says why, and the failed
    /// stream goes (Try Again or the next refresh starts a new one).
    private func historyFailed(_ message: String, stream: CommitStream) {
        historyError = message
        historyIsStale = false
        if historyStream === stream { historyStream = nil }
        allHistoryTask?.cancel()
        Self.log.error("History read failed in \(self.name, privacy: .public): \(message, privacy: .public)")
    }

    /// Try Again on the status bar's "Couldn’t read the history": history (and refs) again.
    func retryHistory() {
        historyError = nil
        reloadHistory(trigger: "Try Again (history)")
    }

    /// Reads refs and history again (the graph's scope changed, Try Again).
    func reloadHistory(trigger: String) {
        guard repository != nil, phase == .ready else { return }
        totalCommitCount = nil
        pendingScope.formUnion([.refs, .workTree])
        if isVisible { runPendingRefresh(trigger: trigger) }
    }

    /// After history was read again: the commit a picked remote branch points at.
    private func selectPendingCommit() {
        guard let id = selectAfterReload else { return }
        selectAfterReload = nil
        reveal(id)
    }

    /// A new `git log` stream for a first load or a refresh (the old one ends).
    private func restartHistoryStream(_ repository: GitRepository) -> CommitStream {
        historyStream?.cancel()
        allHistoryTask?.cancel()
        let stream = repository.historyStream(scope: historyScope)
        historyStream = stream
        return stream
    }

    /// After a first load or a refresh read its history: a tab in the background lets go of git
    /// (scrolling later starts a new `git log` where this one stopped), and a page scrolling
    /// asked for meanwhile is read now.
    private func historyReloaded() {
        if !isVisible, AppSettings.historyLoading != .all {
            historyStream?.cancel()
            historyStream = nil
        }
        if wantsMoreHistory {
            wantsMoreHistory = false
            loadMoreHistory()
        }
    }

    /// Settings › Advanced › Load all history: the rest comes in the background, 5,000 at a time.
    private func loadAllHistoryIfAsked() {
        guard AppSettings.historyLoading == .all, hasMoreHistory else { return }
        allHistoryTask?.cancel()
        allHistoryTask = Task {
            while !Task.isCancelled, hasMoreHistory, phase == .ready, historyError == nil {
                guard let task = loadMoreHistory(count: 5_000) else {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                await task.value
            }
        }
    }

    /// `git status`, timed (a slow one suggests Git's file system monitor).
    private func timedStatus(_ repository: GitRepository) async -> WorkingTreeStatus? {
        let start = ContinuousClock.now
        guard let status = try? await repository.status() else { return nil }
        statusDuration = ContinuousClock.now - start
        if fsmonitorOn == nil, isStatusSlow {
            let value = await repository.config("core.fsmonitor")?.lowercased()
            fsmonitorOn = value != nil && value != "false"
        }
        #if DEBUG
        // The debug driver's `hold status`: git has answered, and the answer waits here.
        await debugHold(.status)
        #endif
        return status
    }

    /// `git status` took longer than it should (ScreenBigRepo's 2.8 s).
    var isStatusSlow: Bool { (statusDuration ?? .zero) >= AppSettings.slowStatus }

    /// The card that suggests Git's file system monitor: slow status, monitor off, not put away.
    var suggestsFSMonitor: Bool { isStatusSlow && fsmonitorOn == false && !fsmonitorDismissed }

    /// Turn On: `core.fsmonitor` and `core.untrackedCache` in this repository's config.
    func turnOnFSMonitor() {
        perform(.working("Turning on the file system monitor…"), trigger: "Turn On File System Monitor") { [weak self] repository in
            try await repository.setLocalConfig("core.fsmonitor", "true")
            try await repository.setLocalConfig("core.untrackedCache", "true")
            self?.fsmonitorOn = true
            self?.showToast("File system monitor on — git status gets quick after the next change")
        }
    }

    /// Not Now: the card doesn't come back for this repository.
    func dismissFSMonitorSuggestion() {
        var dismissed = UserDefaults.kaern.stringArray(forKey: SettingsKey.fsmonitorDismissed) ?? []
        if !dismissed.contains(path) { dismissed.append(path) }
        UserDefaults.kaern.set(dismissed, forKey: SettingsKey.fsmonitorDismissed)
        fsmonitorDismissed = true
    }

    func rebuildGraph() {
        let rebuildStart = ContinuousClock.now
        defer { noteTiming("rebuild", since: rebuildStart) }
        var builder = CommitGraphBuilder()
        showsWorkingCopy = !status.isClean
        if showsWorkingCopy {
            builder.appendWorkingCopy(head: status.headID)
        }
        // Bot runs fold around what must show: refs, HEAD and the selected commit.
        var keep = Set(refs.refs.map(\.target))
        if let head = status.headID { keep.insert(head) }
        if case .commit(let id) = selection { keep.insert(id) }
        let folded = BotFolding.fold(commits, mode: AppSettings.botCommits, keep: keep, expanded: expandedRuns)
        displayCommits = folded.commits
        botRuns = folded.runs
        insideRun = folded.insideRun
        foldedBotCount = folded.foldedCount
        hiddenBotCount = folded.hiddenCount
        if hasBotCommits != folded.hasBotCommits { hasBotCommits = folded.hasBotCommits }
        if hasBotCommits || showsGraphScope, totalCommitCount == nil { countAllCommits() }
        builder.append(displayCommits)
        graph = builder.rows
        if case .commit(let id) = selection, !commits.contains(where: { $0.id == id }) {
            selection = .workingCopy
        }
        // Hide leaves bot commits out of the search too.
        search.refreshLocalMatches(in: hiddenBotCount > 0 ? displayCommits : commits)
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

    /// The bar's "212,408 commits" (what the graph's scope holds): once per load, in the background.
    private func countAllCommits() {
        guard let repository else { return }
        let scope = historyScope
        totalCommitCount = -1   // counting
        Task {
            let count = try? await GitCommandTrigger.$current.withValue(.background("Counting commits")) {
                try await repository.commitCount(in: scope)
            }
            totalCommitCount = count
        }
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
            selectedSignature = nil
            return
        }
        loadSelectedSignature(id)
        if let cached = detailsCache[id] {
            selectedDetails = cached.0
            selectedFiles = cached.1
            if commitMarks?.id != id {
                detailsTask = Task { await loadCommitMarks(cached.0.commit, files: cached.1) }
            }
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
            await loadCommitMarks(details.commit, files: files)
        }
    }

    // MARK: Actions

    /// Runs a git action with its activity shown in the tab and status bar, then refreshes.
    /// `trigger` names it in the Command Log (with ``uiSource`` in front). An error shows an alert
    /// unless `onFailure` handles it; a stop (the hook HUD, the Command Log) shows nothing.
    /// `background`: Kaern started it on its own (auto-fetch): the Command Log keeps it with the
    /// background commands and Activity lists it only when it fails.
    @discardableResult
    func perform(_ activity: RepositoryActivity, trigger: String? = nil, background: Bool = false,
                 _ work: @escaping (GitRepository) async throws -> Void,
                 onSuccess: (() -> Void)? = nil, onFailure: ((any Error) -> Bool)? = nil) -> Task<Void, Never>? {
        guard let repository, self.activity == nil else { return nil }
        self.activity = activity
        let previousIndexChange = indexTask
        let title = activity.statusText.replacingOccurrences(of: "…", with: "")
        let command = GitCommandTrigger(background ? (trigger ?? title) : triggerName(trigger ?? title), background: background)
        let center = ActivityCenter.shared
        let taskID = center.begin(repositoryPath: path, repositoryName: name, title: title, isAuto: background,
                                  cancel: { [weak self] in self?.activityTask?.cancel() })
        let toastBefore = toast?.id
        let task = Task {
            // Wait for staging that's still running (git locks the index).
            await previousIndexChange?.value
            do {
                // Network commands report git's progress lines to Activity (determinate bars).
                let reporter: @Sendable (GitProgress) -> Void = { progress in
                    Task { @MainActor in center.update(taskID, progress: progress) }
                }
                try await GitProgressReporter.$current.withValue(reporter) {
                    try await GitCommandTrigger.$current.withValue(command) {
                        // However it ends, the action's git commands are done here. What git
                        // read earlier stops counting before `onFailure` shows a stop on
                        // conflicts and before `activity` is nil again.
                        defer { noteOwnChange() }
                        try await work(repository)
                    }
                }
                onSuccess?()
                center.finish(taskID, result: toast?.id != toastBefore ? toast?.message : nil)
            } catch is CancellationError {
                // Stopped on purpose.
                center.finish(taskID, result: "Stopped")
            } catch {
                let failure = (error as? GitError).flatMap { GitFailure.explain(arguments: $0.arguments, errorOutput: $0.message, status: $0.status) }
                center.finish(taskID, result: error.localizedDescription, failure: failure, failed: true)
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
            self?.fetchProblem = nil
            self?.autoFetchPaused = false
            self?.showToast(remote.map { "Fetched \($0)" } ?? "Fetched all remotes")
        } onFailure: { [weak self] error in
            self?.noteFetchFailure(error, auto: false)
            return false
        }
    }

    func pull(_ strategy: GitRepository.PullStrategy) {
        let shownHead = status.headID
        let shownBranch = status.branch
        let upstream = status.upstream
        perform(.pulling, trigger: "Pull") { [weak self] repository in
            // HEAD as git has it now, not as the status showed it (see `headNow`).
            let now = await Self.headNow(in: repository)
            let before = now?.id ?? shownHead
            let branch = now.map { $0.branch } ?? shownBranch
            let result: (outcome: OperationOutcome, kept: String?)
            if strategy == .rebase {
                // git won't pull with rebase over uncommitted changes. Like Merge and Rebase, they
                // go aside in the stash list and come back with what was staged still staged
                // (git's own --autostash brings them back unstaged).
                result = try await repository.withChangesStashed(message: "Before Pull") {
                    try await repository.pull(strategy: strategy)
                }
            } else {
                result = (try await repository.pull(strategy: strategy), nil)
            }
            guard let self else { return }
            guard result.outcome == .finished, let after = await repository.resolve("HEAD") else {
                // Stopped on conflicts: the editor opens; ⌘Z after finishing goes back to `before`.
                self.stoppedOnConflicts("Pull", start: before.map { OperationStart(label: "Pull", branch: branch, head: $0, kept: result.kept) })
                return
            }
            guard let before, before != after, let branch else {
                self.showToast("Already up to date")
                return
            }
            // What came in: the upstream's commits that weren't here (a rebase also rewrites yours).
            let count = await repository.countCommits(from: before, to: upstream.map { "refs/remotes/\($0)" } ?? after)
            self.recordMove(label: "Pull", branch: branch, from: before, to: after, kept: result.kept,
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
            let shown = headPosition
            perform(.switching(local), trigger: "Checkout \(ref.name)") { [weak self] repository in
                // HEAD as git has it now, not as the status showed it (see `headNow`).
                let previous = await Self.headNow(in: repository).map { HeadPosition(branch: $0.branch, id: $0.id) } ?? shown
                try await repository.switchToRemoteBranch(ref.name, localName: local)
                guard let previous, let tip = await repository.resolve("HEAD") else { return }
                self?.record(ReversibleStep.createdBranch(label: "Checkout \(ref.name)", name: local, at: tip, upstream: ref.name,
                                                          previous: previous),
                             toast: "Created \(local) tracking \(ref.name) and checked it out")
            }
        }
    }

    func createBranch(_ name: String, at startPoint: String? = nil) {
        let shown = headPosition
        let label = "Create Branch \(name)"
        perform(.creatingBranch(name), trigger: label) { [weak self] repository in
            // HEAD as git has it now, not as the status showed it (see `headNow`).
            let now = await Self.headNow(in: repository)
            let previous = now.map { HeadPosition(branch: $0.branch, id: $0.id) } ?? shown
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
        historyStream?.cancel()
        historyStream = nil
        allHistoryTask?.cancel()
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
