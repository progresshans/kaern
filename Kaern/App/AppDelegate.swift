import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Kaern restores its own session; never reopen windows through macOS state restoration.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = MainMenu.build(showSettings: { SettingsWindowController.shared.show() })
        // General › Appearance (a Debug run's `-KaernAppearance dark|light` wins, for tests).
        AppSettings.applyTheme()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
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
        // With no window open (On launch › Open nothing), the folders open in a new one.
        guard let window = app.activeWindow?.model ?? app.windows.last?.model else {
            app.open(urls, in: app.newWindowModel())
            return
        }
        app.open(urls, in: window)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
