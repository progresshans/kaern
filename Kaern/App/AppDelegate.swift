import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        TestSession.moveScreensAside()
        #endif
        // Kaern restores its own session; never reopen windows through macOS state restoration.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        // View › Zoom: the scale the windows' sizes are made with.
        UIScale.load()
        NSApp.mainMenu = MainMenu.build(showSettings: { SettingsWindowController.shared.show() })
        // General › Appearance (a Debug run's `-KaernAppearance dark|light` wins, for tests).
        AppSettings.applyTheme()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // DEV or TEST on the Dock icon, so a Debug build isn't taken for the installed Kaern (DockTag).
        DockTag.install()
        // Debug commands (stage, commit, discard…) are broadcast to every running Kaern. Only an
        // instance on a test session listens, so a Debug build open on your own repositories never
        // acts on commands a test run sends to its sample repositories.
        if SessionStore.testSessionPath != nil { DebugDriver.shared.start() }
        #endif
        AppModel.shared.launch()
        QuickLookCopies.removeOld()
        // Release builds only (UpdateController.isAvailable).
        UpdateController.shared.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Save before AppKit closes the windows, so they're in the session as open windows.
        AppModel.shared.saveNow()
        AppModel.shared.isTerminating = true
        QuickLookCopies.removeLast()
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppModel.shared.reopen() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let app = AppModel.shared
        // The front main window or the start window; with no window open, a new main window.
        app.open(urls, in: app.openingWindow ?? app.pendingWindowModel())
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
