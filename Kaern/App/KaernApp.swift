import AppKit
import KaernKit
import SwiftUI

@main
struct KaernApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel = AppModel.shared

    var body: some Scene {
        // Shown at launch when no repository window is restored, and when the last one closes.
        Window("Welcome to Kaern", id: SceneID.welcome) {
            WelcomeView()
                .environment(appModel)
                .windowMinimizeBehavior(.disabled)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)

        // Settings › General › Toolbar (the default): one window per repository.
        WindowGroup("Repository", id: SceneID.repository, for: URL.self) { $url in
            RepositoryWindowRoot(url: $url)
                .environment(appModel)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            KaernCommands(appModel: appModel)
        }

        // Window › Repositories: every open and recent repository with what it needs.
        Window("Repositories", id: SceneID.repositories) {
            RepositoriesView()
                .environment(appModel)
        }
        .keyboardShortcut("r", modifiers: [.shift, .command])
        .defaultSize(width: 1080, height: 600)
        .restorationBehavior(.disabled)

        // Every git command Kaern ran (Settings › Advanced › Show Command Log…).
        Window("Command Log", id: SceneID.commandLog) {
            CommandLogView()
                .environment(appModel)
        }
        .defaultSize(width: 760, height: 460)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(appModel)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.register()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // `-KaernAppearance dark|light` to check both appearances without touching System Settings.
        switch UserDefaults.standard.string(forKey: "KaernAppearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        DebugDriver.shared.start()
        #endif
        Task { await AppModel.shared.checkGit() }
        // `-KaernOpen <path>` opens a repository at launch (handy for scripts and testing).
        if let path = UserDefaults.standard.string(forKey: "KaernOpen"), !path.isEmpty {
            AppModel.shared.open(URL(filePath: path, directoryHint: .isDirectory))
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Back from the Command Line Tools installer (or Terminal): look for git again.
        if AppModel.shared.isGitAvailable == false {
            Task { await AppModel.shared.checkGit() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            AppModel.shared.open(url)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppModel.shared.showWelcome()
            return false
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppModel.shared.isTerminating = true
        return .terminateNow
    }
}
