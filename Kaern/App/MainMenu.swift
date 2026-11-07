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
        main.addItem(submenu(commitMenu()))
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
        menu.addItem(MenuAction.item("Create New Repository…", key: "n", modifiers: [.option, .command], enabled: { window != nil }) {
            if let window { app.showCreate(in: window) }
        })
        menu.addItem(MenuAction.item("Clone Repository…", key: "c", modifiers: [.shift, .command], enabled: { window != nil }) {
            if let window { app.showClone(in: window) }
        })
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

    /// The text view being typed in (a field's editor, the description), if any.
    private static var textView: NSTextView? { NSApp.keyWindow?.firstResponder as? NSTextView }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        // ⌘Z undoes typing while a text field has focus, and the last git action otherwise
        // ("Undo Checkout develop").
        menu.addItem(MenuAction.item("Undo", key: "z", enabled: {
            if let text = textView { return text.undoManager?.canUndo == true }
            return repository?.canUndo == true
        }, title: {
            if let text = textView { return text.undoManager?.undoMenuItemTitle ?? "Undo" }
            return repository?.canUndo == true ? repository?.undoTitle ?? "Undo" : "Undo"
        }) {
            if let text = textView { text.undoManager?.undo() } else { repository?.from("Edit menu") { repository?.undo() } }
        })
        menu.addItem(MenuAction.item("Redo", key: "z", modifiers: [.shift, .command], enabled: {
            if let text = textView { return text.undoManager?.canRedo == true }
            return repository?.canRedo == true
        }, title: {
            if let text = textView { return text.undoManager?.redoMenuItemTitle ?? "Redo" }
            return repository?.canRedo == true ? repository?.redoTitle ?? "Redo" : "Redo"
        }) {
            if let text = textView { text.undoManager?.redo() } else { repository?.from("Edit menu") { repository?.redo() } }
        })
        menu.addItem(.separator())
        menu.addItem(system("Cut", #selector(NSText.cut(_:)), key: "x"))
        menu.addItem(system("Copy", #selector(NSText.copy(_:)), key: "c"))
        menu.addItem(MenuAction.item("Copy Commit Message", key: "c", modifiers: [.option, .command],
                                    enabled: { textView == nil && repository?.selectedCommitID != nil }) {
            if let id = repository?.selectedCommitID { repository?.copyMessage(of: id) }
        })
        menu.addItem(system("Paste", #selector(NSText.paste(_:)), key: "v"))
        menu.addItem(system("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        menu.addItem(.separator())
        let find = NSMenu(title: "Find")
        find.addItem(MenuAction.item("Find…", key: "f", enabled: { repository?.isReady == true }) {
            guard let repository else { return }
            repository.openSearch()
            NotificationCenter.default.post(name: .kaernFocusSearch, object: repository.id)
        })
        find.addItem(MenuAction.item("Find Next", key: "g", enabled: { repository?.search.matches.isEmpty == false }) {
            repository?.stepSearch(1)
        })
        find.addItem(MenuAction.item("Find Previous", key: "g", modifiers: [.shift, .command],
                                    enabled: { repository?.search.matches.isEmpty == false }) {
            repository?.stepSearch(-1)
        })
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = find
        menu.addItem(findItem)
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(MenuAction.item("Show Sidebar", key: "s", modifiers: [.control, .command],
                                    enabled: { window?.activeTab != nil },
                                    checked: { window?.showsSidebar == true && window?.isFocused == false }) {
            window?.toggleSidebar()
        })
        menu.addItem(MenuAction.item("Show Details", key: "i", modifiers: [.option, .command],
                                    enabled: { window?.activeTab != nil },
                                    checked: { window?.showsDetails == true && window?.isFocused == false }) {
            window?.toggleDetails()
        })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Graph", enabled: { repository?.isReady == true },
                                    checked: { repository?.isReady == true && repository?.review == nil }) {
            repository?.review = nil
        })
        menu.addItem(MenuAction.item("Review", key: "r", modifiers: [.option, .command],
                                    enabled: { repository?.isReady == true && (repository?.canReview == true || repository?.review != nil) },
                                    checked: { repository?.review != nil }) {
            repository?.toggleReview()
        })
        menu.addItem(MenuAction.item("Focus", key: "g", modifiers: [.option, .command],
                                    enabled: { repository?.isReady == true }, checked: { window?.isFocused == true }) {
            window?.toggleFocus()
            repository?.review = nil
        })
        menu.addItem(.separator())
        let diff = NSMenu(title: "Diff Layout")
        diff.addItem(MenuAction.item("Split", checked: { diffLayout == .split }) { diffLayout = .split })
        diff.addItem(MenuAction.item("Unified", checked: { diffLayout == .unified }) { diffLayout = .unified })
        diff.addItem(.separator())
        diff.addItem(MenuAction.item("Toggle Layout", key: "d", modifiers: [.option, .command]) {
            diffLayout = diffLayout == .split ? .unified : .split
        })
        diff.addItem(MenuAction.item("Ignore Whitespace", checked: { DiffPreferences.ignoresWhitespace }) {
            UserDefaults.kaern.set(!DiffPreferences.ignoresWhitespace, forKey: DiffPreferences.ignoreWhitespaceKey)
            repository?.reloadDiffs()
        })
        let diffItem = NSMenuItem(title: "Diff Layout", action: nil, keyEquivalent: "")
        diffItem.submenu = diff
        menu.addItem(diffItem)
        menu.addItem(.separator())
        menu.addItem(system("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.control, .command]))
        return menu
    }

    private static func repositoryMenu() -> NSMenu {
        let menu = NSMenu(title: "Repository")
        menu.addItem(MenuAction.item("Fetch", key: "f", modifiers: [.option, .command],
                                    enabled: { isIdle && repository?.remotes.isEmpty == false }) { repository?.from("Repository menu") { repository?.fetch() } })
        menu.addItem(MenuAction.item("Fetch All Repositories", key: "f", modifiers: [.option, .shift, .command],
                                    enabled: { !AutoFetcher.shared.isFetchingAll && !app.openRepositories.isEmpty }) {
            AutoFetcher.shared.fetchAll(auto: false)
        })
        menu.addItem(MenuAction.item("Pull", key: arrow(NSDownArrowFunctionKey), modifiers: [.option, .command],
                                    enabled: { isIdle && repository?.status.upstream != nil }) {
            repository?.from("Repository menu") { repository?.pull(repository?.pullChoice.strategy ?? .merge) }
        })
        menu.addItem(MenuAction.item("Push", key: arrow(NSUpArrowFunctionKey), modifiers: [.option, .command],
                                    enabled: { isIdle && repository?.remotes.isEmpty == false && repository?.status.branch != nil }) {
            repository?.from("Repository menu") { repository?.push() }
        })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Stash Changes", key: "s", modifiers: [.option, .command],
                                    enabled: { isIdle && repository?.status.isClean == false }) { repository?.from("Repository menu") { repository?.stash() } })
        menu.addItem(MenuAction.item("Pop Stash", key: "s", modifiers: [.option, .shift, .command],
                                    enabled: { isIdle && repository?.stashes.isEmpty == false }) { repository?.from("Repository menu") { repository?.popStash() } })
        menu.addItem(.separator())
        // While a merge, rebase, cherry-pick or revert waits on conflicts.
        menu.addItem(MenuAction.item("Continue", enabled: { isIdle && repository?.operation != nil && repository?.status.conflictCount == 0 },
                                    title: { repository?.operation.map { "Continue \($0.kind.title)" } ?? "Continue" }) {
            repository?.from("Repository menu") { repository?.continueOperation() }
        })
        menu.addItem(MenuAction.item("Abort", enabled: { isIdle && repository?.operation != nil },
                                    title: { repository?.operation.map { "Abort \($0.kind.title)" } ?? "Abort" }) {
            repository?.from("Repository menu") { repository?.abortOperation() }
        })
        menu.addItem(MenuAction.item("Resolve Conflicts", enabled: { repository?.isReady == true && repository?.conflictedPaths.isEmpty == false }) {
            repository?.openConflicts()
        })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("File History…", enabled: { repository?.isReady == true }) {
            repository?.askFileToExplore(.history)
        })
        menu.addItem(MenuAction.item("Blame…", enabled: { repository?.isReady == true }) {
            repository?.askFileToExplore(.blame)
        })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Repository Settings…", key: ",", modifiers: [.option, .command], enabled: { repository?.isReady == true }) {
            repository?.sheet = .repositorySettings
        })
        return menu
    }

    private static func branchMenu() -> NSMenu {
        let menu = NSMenu(title: "Branch")
        let current = { repository?.status.branch ?? "HEAD" }
        let canAct = { isIdle && repository?.isMidOperation == false }
        menu.addItem(MenuAction.item("Switch Branch…", key: "b", modifiers: [.shift, .command], enabled: { repository?.isReady == true }) {
            if let repository { NotificationCenter.default.post(name: .kaernShowBranchMenu, object: repository.id) }
        })
        menu.addItem(MenuAction.item("New Branch…", key: "n", modifiers: [.shift, .command], enabled: { isIdle }) {
            if let window { NotificationCenter.default.post(name: .kaernNewBranch, object: window.id) }
        })
        menu.addItem(MenuAction.item("New Tag…", enabled: { isIdle && (repository?.selectedCommitID ?? repository?.status.headID) != nil }) {
            guard let repository, let id = repository.selectedCommitID ?? repository.status.headID else { return }
            repository.askCreateTag(at: id)
        })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Merge into…", enabled: { canAct() && repository?.status.branch != nil },
                                    title: { "Merge into “\(current())”…" }) {
            repository?.from("Branch menu") { repository?.askMerge() }
        })
        menu.addItem(MenuAction.item("Rebase onto…", enabled: { canAct() && repository?.status.branch != nil },
                                    title: { "Rebase “\(current())” onto…" }) {
            repository?.from("Branch menu") { repository?.askRebase() }
        })
        menu.addItem(MenuAction.item("Interactive Rebase…", enabled: { canAct() && interactiveRebaseBase != nil }) {
            if let base = interactiveRebaseBase { repository?.from("Branch menu") { repository?.askInteractiveRebase(onto: base) } }
        })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Publish Branch…", enabled: {
            isIdle && repository?.status.branch != nil && repository?.status.upstream == nil && repository?.remotes.isEmpty == false
        }) {
            repository?.from("Branch menu") { repository?.push() }
        })
        menu.addItem(MenuAction.item("Create Pull Request…", enabled: { pullRequestPage != nil }) {
            if let page = pullRequestPage { NSWorkspace.shared.open(page) }
        })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Rename Branch…", enabled: { isIdle && repository?.status.branch != nil }) {
            if let branch = repository?.status.branch { repository?.from("Branch menu") { repository?.askRename(branch: branch) } }
        })
        // ⌘⌫ deletes to the start of the line while typing, so the item steps aside then.
        menu.addItem(MenuAction.item("Delete Branch…", key: "\u{8}", enabled: {
            textView == nil && canAct() && (repository?.refs.localBranches.contains { !$0.isHead } ?? false)
        }) {
            repository?.from("Branch menu") { repository?.askDeleteBranch() }
        })
        return menu
    }

    /// Branch › Interactive Rebase…: the selected commit when it's on this branch, else the upstream.
    private static var interactiveRebaseBase: String? {
        guard let repository, repository.status.branch != nil else { return nil }
        if let id = repository.selectedCommitID, id != repository.status.headID, repository.isOnCurrentBranch(id) { return id }
        if let upstream = repository.status.upstream, repository.status.ahead > 0 { return upstream }
        return nil
    }

    /// The current branch's pull request page on its host.
    private static var pullRequestPage: URL? {
        guard let repository, let upstream = repository.status.upstream,
              let tracked = repository.refs.remoteBranch(named: upstream) else { return nil }
        return repository.remoteURL?.pullRequestPage(branch: tracked.branchName)
    }

    /// The commits the Commit menu acts on: the picked ones, or the selected one.
    private static var targetCommits: [String] {
        guard let repository else { return [] }
        if !repository.picked.isEmpty { return repository.picked }
        return [repository.selectedCommitID].compactMap { $0 }
    }

    private static func commitMenu() -> NSMenu {
        let menu = NSMenu(title: "Commit")
        menu.addItem(MenuAction.item("Commit", key: "\r", enabled: { repository?.canCommit == true }) {
            repository?.commit()
        })
        menu.addItem(MenuAction.item("Amend Last Commit", key: "\r", modifiers: [.option, .command],
                                    enabled: { isIdle && repository?.status.headID != nil }) {
            guard let repository else { return }
            if repository.composer.amend {
                repository.commit()
            } else {
                // Turns Amend on in the composer: the last message fills in to edit first.
                repository.selection = .workingCopy
                repository.setAmend(true)
            }
        })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Stage All", key: "a", modifiers: [.shift, .command],
                                    enabled: { isIdle && repository?.status.entries.contains(where: \.hasUnstagedChanges) == true }) {
            repository?.stageAll()
        })
        menu.addItem(MenuAction.item("Unstage All", key: "a", modifiers: [.option, .shift, .command],
                                    enabled: { isIdle && (repository?.status.stagedCount ?? 0) > 0 }) {
            repository?.unstageAll()
        })
        // Reversible (a copy goes to the stash list), so it doesn't ask.
        menu.addItem(MenuAction.item("Discard All Changes", enabled: { isIdle && repository?.status.isClean == false }) {
            guard let repository else { return }
            let entries = repository.status.entries.filter { !$0.isConflicted }
            repository.from("Commit menu") { repository.discard(entries, keepingStaged: false) }
        })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Cherry-pick", enabled: {
            guard isIdle, let repository, !targetCommits.isEmpty else { return false }
            return targetCommits.allSatisfy { !repository.isOnCurrentBranch($0) }
        }, title: { commitTitle("Cherry-pick") }) {
            let ids = targetCommits
            repository?.from("Commit menu") { repository?.cherryPick(ids) }
        })
        menu.addItem(MenuAction.item("Revert", enabled: {
            guard isIdle, let repository, !targetCommits.isEmpty else { return false }
            return targetCommits.allSatisfy { repository.isOnCurrentBranch($0) }
        }, title: { commitTitle("Revert") }) {
            let ids = targetCommits
            repository?.from("Commit menu") { repository?.revert(ids) }
        })
        let reset = NSMenu(title: "Reset Branch to Here")
        for (title, mode) in [("Soft — keep changes staged", GitRepository.ResetMode.soft),
                              ("Mixed — keep changes unstaged", .mixed), ("Hard — discard changes…", .hard)] {
            reset.addItem(MenuAction.item(title, enabled: { canResetToSelection }) {
                if let id = repository?.selectedCommitID { repository?.from("Commit menu") { repository?.reset(to: id, mode: mode) } }
            })
        }
        let resetItem = NSMenuItem(title: "Reset Branch to Here", action: nil, keyEquivalent: "")
        resetItem.submenu = reset
        menu.addItem(resetItem)
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Compare Selected Commits", enabled: { repository?.pickedPair != nil }) {
            guard let repository, let pair = repository.pickedPair else { return }
            repository.review = ReviewState(showsAllFiles: true, compare: CompareRange(base: pair.older, target: pair.newer))
        })
        menu.addItem(MenuAction.item("Compare with Working Copy", enabled: { repository?.selectedCommitID != nil && repository?.picked.isEmpty == true }) {
            if let id = repository?.selectedCommitID { repository?.compareWithWorkingCopy(id) }
        })
        return menu
    }

    private static var canResetToSelection: Bool {
        guard isIdle, let repository, repository.picked.isEmpty, let id = repository.selectedCommitID,
              repository.status.branch != nil else { return false }
        return id != repository.status.headID && repository.isOnCurrentBranch(id)
    }

    /// "Cherry-pick 3e71b0c" / "Revert 3 Commits".
    private static func commitTitle(_ verb: String) -> String {
        let ids = targetCommits
        guard let repository, !ids.isEmpty else { return verb }
        return ids.count == 1 ? "\(verb) \(repository.short(ids[0]))" : "\(verb) \(ids.count) Commits"
    }

    /// Split or Unified for every diff (View › Diff Layout).
    private static var diffLayout: DiffLayout {
        get { DiffLayout(rawValue: UserDefaults.kaern.string(forKey: DiffPreferences.layoutKey) ?? "") ?? .split }
        set { UserDefaults.kaern.set(newValue.rawValue, forKey: DiffPreferences.layoutKey) }
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
        menu.addItem(MenuAction.item("Quick Open", key: "o", modifiers: [.shift, .command], enabled: { repository?.isReady == true },
                                    checked: { window?.showsQuickOpen == true }) {
            window?.showsQuickOpen.toggle()
        })
        menu.addItem(MenuAction.item("Activity", key: "a", modifiers: [.option, .command], enabled: { repository?.isReady == true }) {
            if let repository { NotificationCenter.default.post(name: .kaernShowActivity, object: repository.id) }
        })
        menu.addItem(MenuAction.item("Command Log", key: "l", modifiers: [.shift, .command]) {
            CommandLogWindowController.shared.show(repository: repository?.path)
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
    private let currentTitle: (() -> String)?

    private init(run: @escaping () -> Void, isAvailable: @escaping () -> Bool, isChecked: (() -> Bool)?, title: (() -> String)?) {
        self.run = run
        self.isAvailable = isAvailable
        self.isChecked = isChecked
        self.currentTitle = title
        super.init()
    }

    /// `title`: when set, the item's title is updated each time it's validated ("Undo Checkout develop").
    static func item(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
                     enabled: @escaping () -> Bool = { true }, checked: (() -> Bool)? = nil, title currentTitle: (() -> String)? = nil,
                     run: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(run: run, isAvailable: enabled, isChecked: checked, title: currentTitle)
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
        if let currentTitle { menuItem.title = currentTitle() }
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
