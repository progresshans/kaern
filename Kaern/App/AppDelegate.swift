import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Kaern restores its own session; never reopen windows through macOS state restoration.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = MainMenu.build(showSettings: { [weak self] in self?.showSettings() })
        #if DEBUG
        // `-KaernAppearance dark|light` checks both appearances without touching System Settings.
        switch UserDefaults.standard.string(forKey: "KaernAppearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        DebugDriver.shared.start()
        #endif
        AppModel.shared.launch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Save before AppKit closes the windows, so they're in the session as open windows.
        AppModel.shared.saveNow()
        AppModel.shared.isTerminating = true
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppModel.shared.reopen() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let app = AppModel.shared
        guard let window = app.activeWindow?.model ?? app.windows.last?.model else { return }
        app.open(urls, in: window)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Settings arrives in phase 4; for now the window shows which git Kaern uses.
    private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.contentView = NSHostingView(rootView: SettingsPlaceholder().environment(AppModel.shared))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsPlaceholder: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            LabeledContent("Git") {
                Text(app.git.map { "\($0.url.path(percentEncoded: false)) (\($0.source.rawValue))" } ?? "Looking for git…")
                    .textSelection(.enabled)
            }
            LabeledContent("Version") {
                Text(app.git?.version ?? "—")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize()
    }
}
