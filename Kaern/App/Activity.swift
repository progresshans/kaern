import AppKit
import KaernKit
import Network
import Observation

/// What Kaern is doing across all repositories (ScreenStatusBar's Activity): the tasks running
/// now, with Cancel, and the ones that finished lately, failures with their fix.
@MainActor @Observable
final class ActivityCenter {
    static let shared = ActivityCenter()

    struct Item: Identifiable, Equatable {
        let id: UUID
        /// The repository's folder (`nil`: several, like Fetch All).
        var repositoryPath: String?
        var repositoryName: String
        /// "Fetching origin", "Pushing to origin".
        var title: String
        /// A second line while it runs ("9 of 11 · godj next").
        var detail: String?
        /// How far it is (0…1), when git says (Receiving objects: 62%); `nil` draws a moving bar.
        var fraction: Double?
        var started: Date
        var finished: Date?
        /// What it did ("Pulled 3 commits") or why it failed.
        var result: String?
        var failure: GitFailure?
        var failed = false
        /// Background work (auto-fetch) only shows here when it fails.
        var isAuto = false
    }

    private(set) var running: [Item] = []
    /// Newest first.
    private(set) var recent: [Item] = []
    /// Cancels for running tasks.
    @ObservationIgnored private var cancels: [UUID: () -> Void] = [:]

    var runningCount: Int { running.count }

    func begin(repositoryPath: String?, repositoryName: String, title: String, isAuto: Bool = false,
               cancel: (() -> Void)? = nil) -> UUID {
        let task = Item(id: UUID(), repositoryPath: repositoryPath, repositoryName: repositoryName, title: title,
                        started: .now, isAuto: isAuto)
        running.append(task)
        if let cancel { cancels[task.id] = cancel }
        return task.id
    }

    func update(_ id: UUID, detail: String?, fraction: Double? = nil) {
        guard let index = running.firstIndex(where: { $0.id == id }) else { return }
        running[index].detail = detail
        if let fraction { running[index].fraction = fraction }
    }

    func finish(_ id: UUID, result: String?, failure: GitFailure? = nil, failed: Bool = false) {
        cancels[id] = nil
        guard let index = running.firstIndex(where: { $0.id == id }) else { return }
        var task = running.remove(at: index)
        task.finished = .now
        task.result = result
        task.failure = failure
        task.failed = failed
        task.detail = nil
        // Quiet background work that went fine isn't news.
        guard !task.isAuto || failed else { return }
        recent.insert(task, at: 0)
        if recent.count > 8 { recent.removeLast(recent.count - 8) }
    }

    func canCancel(_ id: UUID) -> Bool { cancels[id] != nil }

    func cancel(_ id: UUID) {
        cancels[id]?()
    }

    func clearRecent() {
        recent.removeAll()
    }
}

// MARK: - Auto-fetch

/// Settings › General › Fetch in the background every N minutes: every open repository with a
/// remote fetches, one after another, while the Mac is online. A repository whose sign-in was
/// turned down waits until you fetch it yourself or sign in again.
@MainActor @Observable
final class AutoFetcher {
    static let shared = AutoFetcher()

    @ObservationIgnored private var timer: Task<Void, Never>?
    private var run: Task<Void, Never>?
    @ObservationIgnored private let monitor = NWPathMonitor()
    /// Whether the Mac has a network path right now.
    private(set) var isOnline = true
    /// When the Mac went offline (the status bar says how long the counts are from).
    private(set) var offlineSince: Date?
    /// When Fetch All (or auto-fetch) last went through every repository.
    private(set) var lastFetchAll: Date?

    func start() {
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AutoFetcher.shared.setOnline(online) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.progresshans.kaern.network"))
        schedule()
        NotificationCenter.default.addObserver(forName: .kaernSettingsChanged, object: nil, queue: .main) { note in
            guard (note.object as? String) == SettingsKey.autoFetch else { return }
            MainActor.assumeIsolated { AutoFetcher.shared.schedule() }
        }
    }

    private func setOnline(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        offlineSince = online ? nil : .now
        // Back online: catch up a little later.
        if online, AppSettings.autoFetch {
            Task {
                try? await Task.sleep(for: .seconds(3))
                fetchAll(auto: true)
            }
        }
    }

    /// Restarts the timer with the current setting.
    func schedule() {
        timer?.cancel()
        guard AppSettings.autoFetch else { return }
        let minutes = AppSettings.autoFetchMinutes
        timer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                guard !Task.isCancelled else { return }
                fetchAll(auto: true)
            }
        }
    }

    var isFetchingAll: Bool { run != nil }

    /// Fetches every open repository with a remote, one at a time. `auto`: the timer did it —
    /// quiet unless something fails, and skipped while offline.
    func fetchAll(auto: Bool) {
        guard run == nil else { return }
        if auto, !isOnline { return }
        let models = AppModel.shared.openRepositories.filter { $0.repository != nil && !$0.remotes.isEmpty }
        guard !models.isEmpty else { return }
        let minutes = AppSettings.autoFetchMinutes
        let center = ActivityCenter.shared
        var taskID: UUID?
        run = Task {
            var done = 0
            for model in models {
                guard !Task.isCancelled else { break }
                if let taskID {
                    let next = models.dropFirst(done + 1).prefix(2).map(\.name).joined(separator: ", ")
                    center.update(taskID, detail: "\(done) of \(models.count)" + (next.isEmpty ? "" : " · \(next) next"))
                }
                await model.fetchInBackground(trigger: auto ? "Auto-fetch (every \(minutes) min)" : "Fetch All Repositories", auto: auto)
                done += 1
            }
            if let taskID {
                center.finish(taskID, result: Task.isCancelled ? "Stopped fetching after \(done) of \(models.count)" : "Fetched \(Formatters.count(done, "repository", "repositories"))")
            }
            if !Task.isCancelled { lastFetchAll = .now }
            run = nil
        }
        if !auto || models.count > 1 {
            taskID = center.begin(repositoryPath: nil, repositoryName: "", title: "Fetching all repositories", isAuto: auto,
                                  cancel: { [weak self] in self?.run?.cancel() })
            center.update(taskID!, detail: "0 of \(models.count)")
        }
    }
}
