import AppKit
import KaernKit
import Observation
import OSLog

/// App-wide state: the git Kaern runs, the open windows and the repositories their tabs show.
///
/// Repositories live in a registry keyed by folder, so a tab's model stays alive while other
/// tabs are selected (switching never reloads), and two windows showing the same repository
/// share one model.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var git: GitLocator.Resolution?
    private(set) var runner: GitRunner?
    private(set) var windows: [MainWindowController] = []
    private(set) var lastClosed: Session.ClosedWindow?
    private(set) var recent: [Session.RecentRepository] = []
    /// The window whose menu commands apply (the key window, or the last one that was).
    private(set) var activeWindow: MainWindowController?

    @ObservationIgnored private var repositories: [String: RepositoryModel] = [:]
    @ObservationIgnored private let store = SessionStore()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    @ObservationIgnored var isTerminating = false
    /// Closed tabs per window, for Reopen Closed Tab (⇧⌘T).
    @ObservationIgnored private var closedTabs: [UUID: [ClosedTab]] = [:]
    @ObservationIgnored private static let log = Logger(subsystem: "com.progresshans.kaern", category: "app")

    struct ClosedTab {
        var path: String
        var group: TabGroup?
    }

    // MARK: Launch and quit

    /// Restores the last session (or opens one empty window) and locates git.
    func launch() {
        let session = store.load()
        lastClosed = session.lastClosed
        recent = session.recent

        // Back to front, so the first saved window ends up in front and key.
        let states = session.windows.isEmpty ? [Session.WindowState(id: UUID())] : session.windows
        for state in states.reversed() {
            let model = WindowModel(state: state)
            for tab in model.tabs { _ = repository(for: tab.path) }
            addWindow(model)
        }
        updateVisibility()
        // Repositories open in the session belong in the recent list too.
        for controller in windows {
            for tab in controller.model.tabs where !recent.contains(where: { $0.path == tab.path }) {
                let group = tab.group.flatMap { controller.model.group($0) }
                recent.append(Session.RecentRepository(path: tab.path, name: tab.name, groupName: group?.name,
                                                       groupColor: group?.color, lastOpened: .now))
            }
        }

        Task {
            let userPath = UserDefaults.kaern.string(forKey: GitLocator.userPathKey)
            let resolution = await GitLocator.resolve(userPath: userPath)
            git = resolution
            // Every command goes to Window › Command Log (secrets masked by KaernKit).
            runner = GitRunner(executableURL: resolution.url, onCommand: { CommandLog.receive($0) })
            Self.log.info("Using git at \(resolution.url.path(percentEncoded: false), privacy: .public) (\(resolution.source.rawValue, privacy: .public)), version \(resolution.version ?? "unknown", privacy: .public)")
            startRepositories()
        }
    }

    /// Saves now (on quit).
    func saveNow() {
        saveTask?.cancel()
        store.save(currentSession)
    }

    private var currentSession: Session {
        // Front to back, as macOS orders the windows.
        let ordered = NSApp.orderedWindows.compactMap { window in windows.first { $0.window === window } }
        let rest = windows.filter { controller in !ordered.contains { $0 === controller } }
        return Session(
            windows: (ordered + rest).map(\.model.state),
            lastClosed: lastClosed,
            recent: recent
        )
    }

    func scheduleSave() {
        guard !isTerminating else { return }
        refreshRecentGroups()
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            store.save(currentSession)
        }
    }

    // MARK: Windows

    @discardableResult
    func addWindow(_ model: WindowModel, show: Bool = true) -> MainWindowController {
        model.onChange = { [weak self] in self?.scheduleSave() }
        model.onActiveTabChange = { [weak self, weak model] in
            self?.updateVisibility()
            if let model { self?.noteRecent(model) }
        }
        let controller = MainWindowController(model: model, app: self)
        windows.append(controller)
        if show { controller.showWindow(nil) }
        if activeWindow == nil { activeWindow = controller }
        return controller
    }

    func newWindow() {
        let controller = addWindow(WindowModel())
        controller.window?.makeKeyAndOrderFront(nil)
        scheduleSave()
    }

    func windowBecameKey(_ controller: MainWindowController) {
        activeWindow = controller
    }

    func windowWillClose(_ controller: MainWindowController) {
        guard !isTerminating else { return }
        windows.removeAll { $0 === controller }
        if activeWindow === controller { activeWindow = windows.last }
        if !controller.model.tabs.isEmpty {
            lastClosed = Session.ClosedWindow(window: controller.model.state, date: .now)
        }
        closedTabs[controller.model.id] = nil
        releaseUnusedRepositories()
        updateVisibility()
        scheduleSave()
    }

    /// The Dock icon was clicked with no window open: an empty window.
    func reopen() {
        if windows.isEmpty { newWindow() }
    }

    /// Opens the last closed window's tabs in `window` (the empty state's Reopen button).
    func reopenLastSession(in window: WindowModel) {
        guard let closed = lastClosed else { return }
        let state = closed.window
        for tab in state.tabs { _ = repository(for: tab.path) }
        window.restore(from: state)
        lastClosed = nil
        startRepositories()
        updateVisibility()
        scheduleSave()
    }

    // MARK: Repositories

    func repository(for path: String) -> RepositoryModel {
        if let model = repositories[path] { return model }
        let model = RepositoryModel(path: path)
        repositories[path] = model
        if let runner { model.start(runner: runner) }
        return model
    }

    private func startRepositories() {
        guard let runner else { return }
        // Visible tabs first; the rest get their light status.
        let ordered = repositories.values.sorted { $0.isVisible && !$1.isVisible }
        for model in ordered { model.start(runner: runner) }
        schedulePreload()
    }

    /// Which repositories are on screen: the selected tab of each window.
    func updateVisibility() {
        let visible = Set(windows.compactMap { $0.model.activeTab?.path })
        for (path, model) in repositories {
            model.isVisible = visible.contains(path)
        }
    }

    /// After launch, background tabs load their history one at a time, so the first switch to
    /// them is instant. Afterwards they only run the light status.
    private func schedulePreload() {
        preloadTask?.cancel()
        preloadTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            let order = windows.flatMap { $0.model.tabs.map(\.path) }
            for path in order {
                guard !Task.isCancelled else { return }
                guard let model = repositories[path] else { continue }
                // Wait for the light open to finish.
                var waited = 0
                while model.phase == .opening || model.phase == .waiting, waited < 100 {
                    try? await Task.sleep(for: .milliseconds(100))
                    waited += 1
                }
                if model.phase == .light {
                    await model.loadEverything()
                }
            }
        }
    }

    private func releaseUnusedRepositories() {
        let used = Set(windows.flatMap { $0.model.tabs.map(\.path) })
        for (path, model) in repositories where !used.contains(path) {
            model.close()
            repositories[path] = nil
        }
    }

    /// Opens folders as tabs. Any folder inside a repository opens that repository.
    func open(_ urls: [URL], in window: WindowModel) {
        Task {
            guard let runner = await waitForRunner() else { return }
            var paths: [String] = []
            var failures: [String] = []
            for url in urls {
                do {
                    let repository = try await GitRepository.open(url, runner: runner)
                    paths.append(repository.root.path(percentEncoded: false).trimmingTrailingSlash)
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            if !paths.isEmpty {
                for path in paths { _ = repository(for: path) }
                window.open(paths: paths)
                for path in paths.reversed() { noteRecent(path: path, in: window) }
                releaseUnusedRepositories()
                updateVisibility()
            }
            if !failures.isEmpty {
                let alert = NSAlert()
                alert.messageText = failures.count == 1 ? "Couldn't open the folder" : "Couldn't open \(failures.count) folders"
                alert.informativeText = failures.joined(separator: "\n")
                if let window = windows.first(where: { $0.model === window })?.window {
                    alert.beginSheetModal(for: window) { _ in }
                } else {
                    alert.runModal()
                }
            }
        }
    }

    private func waitForRunner() async -> GitRunner? {
        for _ in 0..<100 {
            if let runner { return runner }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return runner
    }

    func showOpenPanel(for window: WindowModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose one or more repository folders to open as tabs."
        let host = windows.first { $0.model === window }?.window
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.open(panel.urls, in: window)
        }
        if let host { panel.beginSheetModal(for: host, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    // MARK: Tabs

    func close(_ tabIDs: [UUID], in window: WindowModel) {
        var stack = closedTabs[window.id] ?? []
        for id in tabIDs {
            guard let tab = window.tab(id) else { continue }
            stack.append(ClosedTab(path: tab.path, group: tab.group.flatMap { window.group($0) }))
        }
        closedTabs[window.id] = Array(stack.suffix(30))
        window.close(tabIDs)
        releaseUnusedRepositories()
        updateVisibility()
    }

    var canReopenClosedTab: Bool {
        guard let window = activeWindow?.model else { return false }
        return !(closedTabs[window.id] ?? []).isEmpty
    }

    func reopenClosedTab(in window: WindowModel) {
        guard var stack = closedTabs[window.id], let last = stack.popLast() else { return }
        closedTabs[window.id] = stack
        _ = repository(for: last.path)
        window.open(paths: [last.path])
        if let group = last.group, let tab = window.tabs.first(where: { $0.path == last.path }) {
            if window.group(group.id) != nil {
                window.add(tab.id, to: group.id)
            } else {
                window.newGroup(named: group.name, color: group.color, with: [tab.id])
            }
        }
        updateVisibility()
    }

    /// Moves a tab (with its group's name and color) into a window of its own.
    func moveToNewWindow(_ tabID: UUID, from window: WindowModel) {
        guard let tab = window.tab(tabID), window.tabs.count > 1 else { return }
        let group = tab.group.flatMap { window.group($0) }
        window.close([tabID])
        let model = WindowModel()
        model.open(paths: [tab.path])
        if let group {
            model.newGroup(named: group.name, color: group.color, with: model.tabs.map(\.id))
        }
        let controller = addWindow(model)
        controller.window?.makeKeyAndOrderFront(nil)
        updateVisibility()
        scheduleSave()
    }

    func retry(_ repository: RepositoryModel) {
        guard let runner else { return }
        repository.start(runner: runner)
    }

    // MARK: Recent repositories

    private func noteRecent(_ window: WindowModel) {
        guard let tab = window.activeTab else { return }
        noteRecent(path: tab.path, in: window)
    }

    private func noteRecent(path: String, in window: WindowModel) {
        guard let tab = window.tabs.first(where: { $0.path == path }) else { return }
        let group = tab.group.flatMap { window.group($0) }
        recent.removeAll { $0.path == tab.path }
        recent.insert(Session.RecentRepository(path: tab.path, name: tab.name, groupName: group?.name,
                                               groupColor: group?.color, lastOpened: .now), at: 0)
        if recent.count > 30 { recent.removeLast(recent.count - 30) }
        scheduleSave()
    }

    /// Keeps each recent repository's folder group current (the empty window groups the list
    /// by it).
    private func refreshRecentGroups() {
        for controller in windows {
            let model = controller.model
            for tab in model.tabs {
                guard let index = recent.firstIndex(where: { $0.path == tab.path }) else { continue }
                let group = tab.group.flatMap { model.group($0) }
                if recent[index].groupName != group?.name || recent[index].groupColor != group?.color {
                    recent[index].groupName = group?.name
                    recent[index].groupColor = group?.color
                }
            }
        }
    }

    /// Recent repositories that aren't open in `window`.
    func recentNotOpen(in window: WindowModel) -> [Session.RecentRepository] {
        let open = Set(window.tabs.map(\.path))
        return recent.filter { !open.contains($0.path) }
    }

    func clearRecent() {
        recent.removeAll()
        scheduleSave()
    }
}

extension WindowModel {
    /// Replaces the strip with a saved window's tabs (Reopen N Tabs).
    func restore(from state: Session.WindowState) {
        let restored = WindowModel(state: state)
        restoreContents(of: restored)
    }
}

extension String {
    var trimmingTrailingSlash: String {
        hasSuffix("/") && count > 1 ? String(dropLast()) : self
    }
}
