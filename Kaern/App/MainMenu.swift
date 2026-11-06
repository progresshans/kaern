import AppKit
import KaernKit

/// The menu bar, with the names and shortcuts of the Menu Bar board (modifiers in Apple order
/// ⌃⌥⇧⌘). Items are AppKit menu items validated against the current window each time a menu
/// opens or a shortcut is pressed, so their enabled state is never stale. Phase 1 wires the
/// tab, window, view and sync items.
@MainActor
enum MainMenu {
    private static var app: AppModel { AppModel.shared }
    private static var window: WindowModel? { app.activeWindow?.model }
    private static var repository: RepositoryModel? {
        guard let tab = window?.activeTab else { return nil }
        return app.repository(for: tab.path)
    }
    private static var isIdle: Bool { repository?.isReady == true && repository?.activity == nil }
    private static let recentDelegate = RecentMenuDelegate()

    static func build(showSettings: @escaping () -> Void) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(showSettings: showSettings)))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(repositoryMenu()))
        main.addItem(submenu(branchMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    // MARK: Menus

    private static func appMenu(showSettings: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu(title: "Kaern")
        menu.addItem(system("About Kaern", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Settings…", key: ",", run: showSettings))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(system("Hide Kaern", #selector(NSApplication.hide(_:)), key: "h"))
        menu.addItem(system("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.option, .command]))
        menu.addItem(system("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(system("Quit Kaern", #selector(NSApplication.terminate(_:)), key: "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(MenuAction.item("New Tab", key: "t", enabled: { window != nil }) { window?.showsNewTab = true })
        menu.addItem(MenuAction.item("New Window", key: "n") { app.newWindow() })
        menu.addItem(MenuAction.item("Open Repository…", key: "o", enabled: { window != nil }) {
            if let window { app.showOpenPanel(for: window) }
        })
        let recent = NSMenu(title: "Open Recent")
        recent.delegate = recentDelegate
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        menu.addItem(recentItem)
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Close Tab", key: "w", enabled: { app.activeWindow != nil }) {
            guard let controller = app.activeWindow else { return }
            if let id = controller.model.activeTabID {
                app.close([id], in: controller.model)
            } else {
                (controller.window as? KaernWindow)?.performCloseWindow()
            }
        })
        menu.addItem(MenuAction.item("Reopen Closed Tab", key: "t", modifiers: [.shift, .command], enabled: { app.canReopenClosedTab }) {
            if let window { app.reopenClosedTab(in: window) }
        })
        menu.addItem(MenuAction.item("Close Window", key: "w", modifiers: [.shift, .command], enabled: { app.activeWindow != nil }) {
            (app.activeWindow?.window as? KaernWindow)?.performCloseWindow()
        })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Show in Finder", enabled: { window?.activeTab != nil }) {
            if let path = window?.activeTab?.path { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
        })
        menu.addItem(MenuAction.item("Open in Terminal", enabled: { window?.activeTab != nil }) {
            if let path = window?.activeTab?.path { TabBar.openInTerminal(path) }
        })
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(system("Undo", Selector(("undo:")), key: "z"))
        menu.addItem(system("Redo", Selector(("redo:")), key: "z", modifiers: [.shift, .command]))
        menu.addItem(.separator())
        menu.addItem(system("Cut", #selector(NSText.cut(_:)), key: "x"))
        menu.addItem(system("Copy", #selector(NSText.copy(_:)), key: "c"))
        menu.addItem(system("Paste", #selector(NSText.paste(_:)), key: "v"))
        menu.addItem(system("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(MenuAction.item("Show Sidebar", key: "s", modifiers: [.control, .command],
                                    enabled: { window?.activeTab != nil }, checked: { window?.showsSidebar == true }) {
            window?.showsSidebar.toggle()
        })
        menu.addItem(MenuAction.item("Show Details", key: "i", modifiers: [.option, .command],
                                    enabled: { window?.activeTab != nil }, checked: { window?.showsDetails == true }) {
            window?.showsDetails.toggle()
        })
        menu.addItem(.separator())
        menu.addItem(system("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.control, .command]))
        return menu
    }

    private static func repositoryMenu() -> NSMenu {
        let menu = NSMenu(title: "Repository")
        menu.addItem(MenuAction.item("Fetch", key: "f", modifiers: [.option, .command],
                                    enabled: { isIdle && repository?.remotes.isEmpty == false }) { repository?.fetch() })
        menu.addItem(MenuAction.item("Pull", key: arrow(NSDownArrowFunctionKey), modifiers: [.option, .command],
                                    enabled: { isIdle && repository?.status.upstream != nil }) {
            let choice = PullChoice(rawValue: UserDefaults.standard.string(forKey: "KaernPullStrategy") ?? "") ?? .fastForwardIfPossible
            repository?.pull(choice.strategy)
        })
        menu.addItem(MenuAction.item("Push", key: arrow(NSUpArrowFunctionKey), modifiers: [.option, .command],
                                    enabled: { isIdle && repository?.remotes.isEmpty == false && repository?.status.branch != nil }) {
            repository?.push()
        })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Stash Changes", key: "s", modifiers: [.option, .command],
                                    enabled: { isIdle && repository?.status.isClean == false }) { repository?.stash() })
        menu.addItem(MenuAction.item("Pop Stash", key: "s", modifiers: [.option, .shift, .command],
                                    enabled: { isIdle && repository?.stashes.isEmpty == false }) { repository?.popStash() })
        return menu
    }

    private static func branchMenu() -> NSMenu {
        let menu = NSMenu(title: "Branch")
        menu.addItem(MenuAction.item("New Branch…", key: "n", modifiers: [.shift, .command], enabled: { isIdle }) {
            if let window { NotificationCenter.default.post(name: .kaernNewBranch, object: window.id) }
        })
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(system("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        menu.addItem(system("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Show Previous Tab", key: "\t", modifiers: [.control, .shift],
                                    enabled: { (window?.tabs.count ?? 0) > 1 }) { window?.activateNext(-1) })
        menu.addItem(MenuAction.item("Show Next Tab", key: "\t", modifiers: [.control],
                                    enabled: { (window?.tabs.count ?? 0) > 1 }) { window?.activateNext(1) })
        let goTo = NSMenu(title: "Go to Tab")
        for number in 1...9 {
            goTo.addItem(MenuAction.item(number == 9 ? "Last Tab" : "Tab \(number)", key: "\(number)",
                                        enabled: { !(window?.cycleOrder.isEmpty ?? true) }) {
                window?.activate(number: number)
            })
        }
        let goToItem = NSMenuItem(title: "Go to Tab", action: nil, keyEquivalent: "")
        goToItem.submenu = goTo
        menu.addItem(goToItem)
        menu.addItem(MenuAction.item("Move Tab to New Window", enabled: { (window?.tabs.count ?? 0) > 1 }) {
            if let window, let id = window.activeTabID { app.moveToNewWindow(id, from: window) }
        })
        menu.addItem(.separator())
        menu.addItem(system("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(MenuAction.item("Kaern Help", key: "?", enabled: { false }) {})
        return menu
    }

    // MARK: Building items

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// An item for a standard action that goes up the responder chain.
    private static func system(_ title: String, _ action: Selector, key: String = "",
                               modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func arrow(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt16(key))!))
    }
}

/// The target of a Kaern menu item: runs a closure, and is asked whether the item is available
/// (and checked) each time AppKit validates it. The item keeps it alive as its represented
/// object.
final class MenuAction: NSObject, NSMenuItemValidation {
    private let run: () -> Void
    private let isAvailable: () -> Bool
    private let isChecked: (() -> Bool)?

    private init(run: @escaping () -> Void, isAvailable: @escaping () -> Bool, isChecked: (() -> Bool)?) {
        self.run = run
        self.isAvailable = isAvailable
        self.isChecked = isChecked
        super.init()
    }

    static func item(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
                     enabled: @escaping () -> Bool = { true }, checked: (() -> Bool)? = nil,
                     run: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(run: run, isAvailable: enabled, isChecked: checked)
        // AppKit spells Shift with a letter as the uppercase letter (⇧⌘T is "T" with ⌘).
        var key = key
        var modifiers = modifiers
        if modifiers.contains(.shift), key.count == 1, key.lowercased() != key.uppercased() {
            key = key.uppercased()
            modifiers.remove(.shift)
        }
        let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = action
        item.representedObject = action
        return item
    }

    @objc func invoke(_ sender: Any?) {
        run()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let isChecked { menuItem.state = isChecked() ? .on : .off }
        return isAvailable()
    }
}

/// Fills File › Open Recent when it opens.
final class RecentMenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let app = AppModel.shared
        for item in app.recent.prefix(15) {
            menu.addItem(MenuAction.item(item.name, enabled: { app.activeWindow != nil }) {
                if let window = app.activeWindow?.model {
                    app.open([URL(filePath: item.path, directoryHint: .isDirectory)], in: window)
                }
            })
        }
        if !app.recent.isEmpty { menu.addItem(.separator()) }
        menu.addItem(MenuAction.item("Clear Menu", enabled: { !app.recent.isEmpty }) { app.clearRecent() })
    }
}
