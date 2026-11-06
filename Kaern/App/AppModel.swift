import AppKit
import KaernKit
import Network
import SwiftUI

enum SceneID {
    static let welcome = "welcome"
    static let repository = "repository"
    static let repositories = "repositories"
    static let commandLog = "commandLog"
}

/// A repository in File › Open Recent, the Welcome window and the repository pop-up.
struct RecentRepository: Codable, Hashable, Identifiable {
    var path: String
    var lastOpened: Date

    var id: String { path }
    var url: URL { URL(filePath: path, directoryHint: .isDirectory) }
    var name: String { url.lastPathComponent }
    var displayPath: String { Formatters.abbreviatedPath(url) }
}

/// App-wide state: recent repositories, open windows, network reachability and the command log.
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var recents: [RecentRepository] = []
    /// Bumped when Settings › Accounts changes, so views that look accounts up refresh.
    var accountsVersion = 0
    /// Icon Rail and Named List: a repository for the front window's list to open.
    var railOpenRequest: URL?
    /// Tabs: the + in the tab bar (or File › New Tab) asks the front window for the repository list.
    var tabChooserRequest = 0
    private(set) var isOnline = true
    private(set) var commandLog: [GitCommandRecord] = []
    /// Repositories that currently have a window, with the number of windows showing each.
    private(set) var openWindows: [URL: Int] = [:]
    var isTerminating = false
    /// The Welcome window SwiftUI shows at launch by itself, as opposed to one asked for later.
    /// A repository window that's restored or opened from the Finder replaces it.
    @ObservationIgnored var isLaunchWelcome = true
    @ObservationIgnored private let launchTime = ContinuousClock.now

    @ObservationIgnored private var openWindowAction: OpenWindowAction?
    @ObservationIgnored private var dismissWindowAction: DismissWindowAction?
    @ObservationIgnored private var pendingOpens: [URL] = []
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private let recentsKey = "recentRepositories"

    private init() {
        loadRecents()
        pathMonitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in
                AppModel.shared.isOnline = online
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.progresshans.kaern.network"))
    }

    // MARK: - Git

    /// `nil` until checked at launch; `false` when git can't run ("Kaern needs Git").
    private(set) var isGitAvailable: Bool?
    /// The "Kaern needs Git" alert steps aside while the installer runs; it comes back when
    /// Kaern becomes active again and git still isn't there.
    var isGitAlertSnoozed = false

    var showsGitAlert: Bool { isGitAvailable == false && !isGitAlertSnoozed }

    func checkGit() async {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "KaernPretendGitMissing") {
            isGitAvailable = false
            showWelcome()
            return
        }
        #endif
        let version = await GitRunner.availableVersion(at: Preferences.gitExecutableURL)
        isGitAvailable = version != nil
        isGitAlertSnoozed = false
        if version == nil {
            showWelcome()
        }
    }

    /// Install Developer Tools…: Apple's installer for the Command Line Tools (which include git).
    func installDeveloperTools() {
        isGitAlertSnoozed = true
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcode-select")
        process.arguments = ["--install"]
        try? process.run()
    }

    /// Choose Git…: use a git that's already installed somewhere else (Homebrew, MacPorts…).
    func chooseGit() {
        isGitAlertSnoozed = true
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(filePath: FileManager.default.fileExists(atPath: "/opt/homebrew/bin") ? "/opt/homebrew/bin" : "/usr/local/bin")
        panel.message = String(localized: "Choose the git program Kaern should use.")
        panel.prompt = String(localized: "Use This Git")
        guard panel.runModal() == .OK, let url = panel.url else {
            isGitAlertSnoozed = false
            return
        }
        Task {
            if await GitRunner.availableVersion(at: url) != nil {
                UserDefaults.standard.set(url.path(percentEncoded: false), forKey: PreferenceKey.gitPath)
                await checkGit()
            } else {
                isGitAlertSnoozed = false
                presentError(GitError(arguments: [], status: -1, message: String(localized: "“\(url.lastPathComponent)” didn't answer git --version.")),
                             title: String(localized: "That Isn't Git"))
            }
        }
    }

    /// A runner configured from Settings › Advanced.
    func makeRunner() -> GitRunner {
        GitRunner(executableURL: Preferences.gitExecutableURL,
                  removedEnvironment: Preferences.useSSHAgent ? [] : ["SSH_AUTH_SOCK"]) { record in
            Task { @MainActor in
                AppModel.shared.record(record)
            }
        }
    }

    private func record(_ record: GitCommandRecord) {
        guard Preferences.recordCommandLog else { return }
        commandLog.append(record)
        if commandLog.count > 500 {
            commandLog.removeFirst(commandLog.count - 500)
        }
    }

    func clearCommandLog() {
        commandLog.removeAll()
    }

    // MARK: - Windows

    /// Views call this so non-view code (menus, the app delegate) can open windows.
    func register(openWindow: OpenWindowAction, dismissWindow: DismissWindowAction) {
        openWindowAction = openWindow
        dismissWindowAction = dismissWindow
        let queued = pendingOpens
        pendingOpens.removeAll()
        for url in queued {
            open(url)
        }
    }

    func windowAppeared(for url: URL) {
        openWindows[url, default: 0] += 1
    }

    func windowDisappeared(for url: URL) {
        let count = (openWindows[url] ?? 1) - 1
        openWindows[url] = count > 0 ? count : nil
        if openWindows.isEmpty && !isTerminating {
            // Like Xcode: with no repository left, come back to the Welcome window.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                if AppModel.shared.openWindows.isEmpty && !AppModel.shared.isTerminating {
                    AppModel.shared.showWelcome()
                }
            }
        }
    }

    func isOpen(_ url: URL) -> Bool { windowURL(for: url) != nil }

    /// The value a window shows `url`'s folder with (a restored window's URL can be spelled a
    /// little differently, with or without the trailing slash).
    func windowURL(for url: URL) -> URL? {
        if openWindows[url] != nil { return url }
        let path = url.plainPath
        return openWindows.keys.first { $0.plainPath == path }
    }

    func showWelcome() {
        openWindowAction?(id: SceneID.welcome)
    }

    /// Window › Repositories (⇧⌘R).
    func showRepositories() {
        openWindowAction?(id: SceneID.repositories)
    }

    /// Settings › Advanced › Show Command Log….
    func showCommandLog() {
        openWindowAction?(id: SceneID.commandLog)
    }

    func dismissWelcome() {
        dismissWindowAction?(id: SceneID.welcome)
    }

    /// Opens (or brings forward) the window of the repository that contains `url`. With Icon
    /// Rail or Named List it joins the open window's list instead.
    func open(_ url: URL) {
        open(url, newWindow: false)
    }

    /// Always a window (or tab) of its own, whatever Settings › General says.
    func openInNewWindow(_ url: URL) {
        open(url, newWindow: true)
    }

    private func open(_ url: URL, newWindow: Bool) {
        guard let openWindowAction else {
            pendingOpens.append(url)
            return
        }
        Task {
            do {
                let repository = try await GitRepository.open(url, runner: makeRunner())
                noteOpened(repository.root)
                if ContinuousClock.now - launchTime < .seconds(5) {
                    // At launch SwiftUI may still be restoring this repository's window. Opening
                    // it before that window is up would give the repository a second one.
                    for _ in 0 ..< 8 where !isOpen(repository.root) {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                if !newWindow, RepositorySwitcher.current.sharesWindow, !openWindows.isEmpty, !isOpen(repository.root) {
                    railOpenRequest = repository.root
                } else {
                    openWindowAction(id: SceneID.repository, value: windowURL(for: repository.root) ?? repository.root)
                }
                dismissWelcome()
            } catch {
                presentError(error, title: "Couldn't Open Repository")
            }
        }
    }

    /// Shows an open panel for choosing repository folders.
    func chooseRepositories() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Open")
        panel.message = String(localized: "Choose a folder that contains a Git repository.")
        return panel.runModal() == .OK ? panel.urls : []
    }

    func presentError(_ error: any Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    // MARK: - Recents

    func noteOpened(_ url: URL) {
        let path = url.plainPath
        recents.removeAll { $0.path == path }
        recents.insert(RecentRepository(path: path, lastOpened: .now), at: 0)
        if recents.count > 20 {
            recents.removeLast(recents.count - 20)
        }
        saveRecents()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func removeRecent(_ recent: RecentRepository) {
        recents.removeAll { $0.id == recent.id }
        saveRecents()
    }

    func clearRecents() {
        recents.removeAll()
        saveRecents()
    }

    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: recentsKey),
              let decoded = try? JSONDecoder().decode([RecentRepository].self, from: data) else { return }
        recents = decoded.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: recentsKey)
        }
    }
}
