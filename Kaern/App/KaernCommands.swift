import AppKit
import KaernKit
import SwiftUI

/// The menu bar, following the Menu Bar board's names and shortcuts (modifiers in Apple
/// order ⌃⌥⇧⌘). Phase 1 wires the tab, window, view and sync items.
struct KaernCommands: Commands {
    let app: AppModel

    private var window: WindowModel? { app.activeWindow?.model }

    private var repository: RepositoryModel? {
        guard let tab = window?.activeTab else { return nil }
        return app.repository(for: tab.path)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { window?.showsNewTab = true }
                .keyboardShortcut("t")
                .disabled(window == nil)
            Button("New Window") { app.newWindow() }
                .keyboardShortcut("n")
            Button("Open Repository…") {
                if let window { app.showOpenPanel(for: window) }
            }
            .keyboardShortcut("o")
            .disabled(window == nil)
            Menu("Open Recent") {
                ForEach(app.recent.prefix(15)) { item in
                    Button(item.name) {
                        if let window { app.open([URL(filePath: item.path, directoryHint: .isDirectory)], in: window) }
                    }
                }
                Divider()
                Button("Clear Menu") { app.clearRecent() }
                    .disabled(app.recent.isEmpty)
            }
            Divider()
            Button("Close Tab") { closeTab() }
                .keyboardShortcut("w")
            Button("Reopen Closed Tab") {
                if let window { app.reopenClosedTab(in: window) }
            }
            .keyboardShortcut("t", modifiers: [.shift, .command])
            .disabled(!app.canReopenClosedTab)
            Button("Close Window") { (app.activeWindow?.window as? KaernWindow)?.performCloseWindow() }
                .keyboardShortcut("w", modifiers: [.shift, .command])
                .disabled(app.activeWindow == nil)
            Divider()
            Button("Show in Finder") {
                if let path = window?.activeTab?.path {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
                }
            }
            .disabled(window?.activeTab == nil)
            Button("Open in Terminal") {
                if let path = window?.activeTab?.path { TabBar.openInTerminal(path) }
            }
            .disabled(window?.activeTab == nil)
        }
        CommandGroup(replacing: .saveItem) {}

        CommandGroup(before: .toolbar) {
            Toggle("Show Sidebar", isOn: Binding(get: { window?.showsSidebar ?? false }, set: { window?.showsSidebar = $0 }))
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(window?.activeTab == nil)
            Toggle("Show Details", isOn: Binding(get: { window?.showsDetails ?? false }, set: { window?.showsDetails = $0 }))
                .keyboardShortcut("i", modifiers: [.option, .command])
                .disabled(window?.activeTab == nil)
            Divider()
        }

        CommandMenu("Repository") {
            let ready = repository?.isReady == true && repository?.activity == nil
            Button("Fetch") { repository?.fetch() }
                .keyboardShortcut("f", modifiers: [.option, .command])
                .disabled(!ready || repository?.remotes.isEmpty == true)
            Button("Pull") {
                let choice = PullChoice(rawValue: UserDefaults.standard.string(forKey: "KaernPullStrategy") ?? "") ?? .fastForwardIfPossible
                repository?.pull(choice.strategy)
            }
            .keyboardShortcut(.downArrow, modifiers: [.option, .command])
            .disabled(!ready || repository?.status.upstream == nil)
            Button("Push") { repository?.push() }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                .disabled(!ready || repository?.remotes.isEmpty == true)
            Divider()
            Button("Stash Changes") { repository?.stash() }
                .keyboardShortcut("s", modifiers: [.option, .command])
                .disabled(!ready || repository?.status.isClean == true)
            Button("Pop Stash") { repository?.popStash() }
                .keyboardShortcut("s", modifiers: [.option, .shift, .command])
                .disabled(!ready || repository?.stashes.isEmpty == true)
        }

        CommandMenu("Branch") {
            Button("New Branch…") {
                if let window { NotificationCenter.default.post(name: .kaernNewBranch, object: window.id) }
            }
            .keyboardShortcut("n", modifiers: [.shift, .command])
            .disabled(repository?.isReady != true)
        }

        CommandGroup(before: .windowList) {
            Button("Show Previous Tab") { window?.activateNext(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled((window?.tabs.count ?? 0) < 2)
            Button("Show Next Tab") { window?.activateNext(1) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled((window?.tabs.count ?? 0) < 2)
            Menu("Go to Tab") {
                ForEach(1...9, id: \.self) { number in
                    Button(number == 9 ? "Last Tab" : "Tab \(number)") { window?.activate(number: number) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                }
            }
            .disabled(window?.tabs.isEmpty != false)
            Button("Move Tab to New Window") {
                if let window, let id = window.activeTabID { app.moveToNewWindow(id, from: window) }
            }
            .disabled((window?.tabs.count ?? 0) < 2)
            Divider()
        }
    }

    /// ⌘W: the selected tab; with no tab, the window.
    private func closeTab() {
        guard let controller = app.activeWindow else { return }
        if let id = controller.model.activeTabID {
            app.close([id], in: controller.model)
        } else {
            (controller.window as? KaernWindow)?.performCloseWindow()
        }
    }
}
