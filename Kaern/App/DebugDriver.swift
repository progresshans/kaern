#if DEBUG
import AppKit
import KaernKit
import OSLog

/// Debug builds launched with `-KaernSessionFile <path>` only: lets scripts drive Kaern and render
/// its windows to PNG files, so the frame can be checked without controlling the screen. An
/// instance on the real session never listens (`AppDelegate`), so commands can't reach your repos.
///
/// Post a distributed notification named `com.progresshans.kaern.debug` whose object is a
/// command line, e.g. `snapshot /tmp/a.png`, `activate 3`, `toggleGroup godj`,
/// `moveBlock 0 2`, `appearance dark`, `dump /tmp/state.json`, `quit`.
///
/// Launched with `-KaernDebugChannel <id>` as well, the instance listens on
/// `com.progresshans.kaern.debug.<id>` instead, so several test instances can run side by side
/// and each takes only the commands sent to its own channel. `-KaernDebugIgnorePointer YES`
/// keeps the real mouse out of it.
@MainActor
final class DebugDriver {
    static let shared = DebugDriver()
    private static let log = Logger(subsystem: "com.progresshans.kaern", category: "debug")
    private var observer: NSObjectProtocol?

    /// The `-KaernDebugChannel <id>` launch argument (`nil`: every test instance's shared name).
    static var channel: String? {
        guard let channel = UserDefaults.standard.string(forKey: "KaernDebugChannel"), !channel.isEmpty else { return nil }
        return channel
    }

    /// The notification this instance takes commands from.
    static var notificationName: Notification.Name {
        let shared = "com.progresshans.kaern.debug"
        return Notification.Name(channel.map { shared + "." + $0 } ?? shared)
    }

    func start() {
        let name = Self.notificationName
        Self.log.info("debug commands on \(name.rawValue, privacy: .public)")
        observer = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { DebugDriver.shared.run(command) }
        }
        if UserDefaults.standard.bool(forKey: "KaernDebugIgnorePointer") { ignoreRealPointer() }
    }

    /// The mark on the pointer events the driver posts itself (`scrollWheel` goes through the
    /// event queue; clicks and drags go straight to the window).
    static let ownEventMark: Int64 = 0x4B41_4552
    private var pointerMonitor: Any?

    /// `-KaernDebugIgnorePointer YES`: the real pointer does nothing in this instance — no hover,
    /// no click, no scroll. A test window sits wherever the mouse happens to rest, and a hovered
    /// row would change a picture, or what Return picks in Quick Open.
    private func ignoreRealPointer() {
        let pointer: NSEvent.EventTypeMask = [
            .mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel, .magnify, .rotate, .swipe, .smartMagnify, .pressure, .gesture,
        ]
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: pointer) { event in
            event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Self.ownEventMark ? event : nil
        }
    }

    var app: AppModel { AppModel.shared }
    /// `useWindow <n>` points the driver at one window: background windows never become key.
    static var chosenWindow: Int?
    var controller: MainWindowController? {
        if let index = Self.chosenWindow, app.windows.indices.contains(index) { return app.windows[index] }
        return app.activeWindow ?? app.windows.last
    }
    var window: WindowModel? { controller?.model }

    func run(_ line: String) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let command = parts.first else { return }
        let args = Array(parts.dropFirst())
        Self.log.info("debug command: \(line, privacy: .public)")
        switch command {
        case "snapshot":
            snapshot(to: args.first ?? "/tmp/kaern.png", window: args.count > 1 ? Int(args[1]) : nil)
        case "appearance":
            NSApp.appearance = args.first == "dark" ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
        case "activate":
            if let number = args.first.flatMap(Int.init), let window {
                let order = window.cycleOrder
                if order.indices.contains(number) { window.activate(order[number].id) }
            }
        case "activateName":
            if let name = args.first, let window, let tab = window.tabs.first(where: { $0.name == name }) {
                window.activate(tab.id)
            }
        case "toggleGroup":
            if let name = args.first, let window, let group = window.groups.first(where: { $0.name == name }) {
                window.toggleCollapsed(group.id)
            }
        case "moveBlock":
            if args.count == 2, let from = Int(args[0]), let to = Int(args[1]) { window?.moveBlock(from: from, to: to) }
        case "moveMember":
            if args.count == 3, let window, let group = window.groups.first(where: { $0.name == args[0] }),
               let from = Int(args[1]), let to = Int(args[2]) {
                window.moveMember(of: group.id, from: from, to: to)
            }
        case "newGroup":
            // newGroup <name> <tab name> [<tab name>…]
            if args.count >= 2, let window {
                let ids = args.dropFirst().compactMap { name in window.tabs.first { $0.name == name }?.id }
                window.newGroup(named: args[0], color: window.nextGroupColor, with: ids)
            }
        case "addToGroup":
            if args.count == 2, let window, let tab = window.tabs.first(where: { $0.name == args[0] }),
               let group = window.groups.first(where: { $0.name == args[1] }) {
                window.add(tab.id, to: group.id)
            }
        case "removeFromGroup":
            if let name = args.first, let window, let tab = window.tabs.first(where: { $0.name == name }) {
                window.removeFromGroup(tab.id)
            }
        case "close":
            if let name = args.first, let window, let tab = window.tabs.first(where: { $0.name == name }) {
                app.close([tab.id], in: window)
            }
        case "open":
            if let path = args.first, let window { app.open([URL(filePath: path, directoryHint: .isDirectory)], in: window) }
        case "select":
            // select <commit index> | select wip
            if let tab = window?.activeTab {
                let repository = app.repository(for: tab.path)
                if args.first == "wip" {
                    repository.selection = .workingCopy
                } else if let index = args.first.flatMap(Int.init), repository.commits.indices.contains(index) {
                    repository.selection = .commit(repository.commits[index].id)
                }
                if window?.isFocused == true { window?.showsDrawer = true }
            }
        case "review", "focus", "drawer", "drawerFile", "search", "searchScope", "searchStep", "diff", "whitespace", "tree",
             "stage", "unstage", "stageAll", "unstageAll", "stageHunk", "unstageHunk", "summary", "body", "amend", "commit",
             "column", "scroll":
            phase2(command, args)
        case "menu", "menuClose", "menuHover", "rightClick", "pick", "clearPicks", "branchCompare", "swap", "undo", "redo", "checkout", "checkoutCommit",
             "cherryPick", "revert", "reset", "merge", "rebase", "deleteBranch", "discard", "ignore", "apply", "popStash", "drop",
             "pickLines", "stageLines", "discardLines", "clearLines", "publish", "publishDraft", "confirm", "dismiss", "commitHooks",
             "commandLog", "commandLogFilter", "commandLogSelect", "snapshotAll", "snapshotWindow", "compareWorking", "toast", "rename",
             "tag", "stopCommit", "hookAction":
            phase3(command, args)
        case _ where DebugDriver.phase4Commands.contains(command):
            phase4(command, args)
        case _ where DebugDriver.phase5Commands.contains(command):
            phase5(command, args)
        case _ where DebugDriver.phase6Commands.contains(command):
            phase6(command, args)
        case "sidebar":
            window?.showsSidebar = args.first != "off"
        case "details":
            window?.showsDetails = args.first != "off"
        case "resize":
            if args.count == 2, let width = Double(args[0]), let height = Double(args[1]), let nsWindow = controller?.window {
                var frame = nsWindow.frame
                frame.origin.y += frame.height - height
                frame.size = NSSize(width: width, height: height)
                nsWindow.setFrame(frame, display: true)
            }
        case "newTab":
            window?.showsNewTab = true
        case "newWindow":
            app.newWindow()
        case "closeWindow":
            (controller?.window as? KaernWindow)?.performCloseWindow()
        case "reopenClosedTab":
            if let window { app.reopenClosedTab(in: window) }
        case "reopenLastSession":
            if let window { app.reopenLastSession(in: window) }
        case "fetch", "push", "stash", "pop", "pull", "switch", "createBranch":
            guard let tab = window?.activeTab else { return }
            let repository = app.repository(for: tab.path)
            // As if from the toolbar, so the Command Log names it the way a click would.
            repository.from("Toolbar") {
                switch command {
                case "fetch": repository.fetch()
                case "push": repository.push()
                case "stash": repository.stash()
                case "pop": repository.popStash()
                case "pull": repository.pull(.merge)
                case "switch": if let name = args.first { repository.switchBranch(name) }
                default: if let name = args.first { repository.createBranch(name) }
                }
            }
        case "dump":
            dump(to: args.first ?? "/tmp/kaern-state.json")
        case "ping":
            // ping <file> — writes the file. Commands run in the order they were sent, so once it's
            // there, every command sent before it has run: a script waits for that, not for a time.
            try? Data("ok".utf8).write(to: URL(filePath: args.first ?? "/tmp/kaern-ping"), options: .atomic)
        case "tooltip":
            DebugTooltip.shared.pinned = args.isEmpty ? nil : args.joined(separator: " ")
        case "snapshotPopover":
            // The + popover lives in a window of its own.
            if let popover = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }),
               let frameView = popover.contentView?.superview ?? popover.contentView,
               let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: args.first ?? "/tmp/kaern-popover.png"))
            }
        case "menus":
            dumpMenus(to: args.first ?? "/tmp/kaern-menus.txt")
        case "key":
            // key <chars> [cmd] [shift] [option] [control] — goes through the main menu's key equivalents.
            if let chars = args.first { key(chars == "tab" ? "\t" : chars, modifiers: Array(args.dropFirst())) }
        case "stripFrames":
            stripFrames(to: args.first ?? "/tmp/kaern-strip.json")
        case "click":
            // click x y [count] — window points, top-left origin; sent through the window like a real click.
            if args.count >= 2, let x = Double(args[0]), let y = Double(args[1]) {
                click(at: CGPoint(x: x, y: y), count: args.count > 2 ? Int(args[2]) ?? 1 : 1)
            }
        case "drag":
            // drag x1 y1 x2 y2
            if args.count == 4, let values = Optional(args.compactMap(Double.init)), values.count == 4 {
                drag(from: CGPoint(x: values[0], y: values[1]), to: CGPoint(x: values[2], y: values[3]))
            }
        case "press":
            // press up|down|return|escape|space [shift] [option] [command] — a key down through the
            // window, to the focused view.
            press(args.first ?? "", modifiers: Array(args.dropFirst()))
        case "front":
            // Makes the window key, so snapshots show the active-window look (traffic lights, checkboxes).
            NSApp.activate()
            controller?.window?.makeKeyAndOrderFront(nil)
        case "quit":
            NSApp.terminate(nil)
        default:
            Self.log.error("unknown debug command \(command, privacy: .public)")
        }
    }

    /// Review, Focus, Search, staging and the composer.
    private func phase2(_ command: String, _ args: [String]) {
        guard let window, let tab = window.activeTab else { return }
        let repository = app.repository(for: tab.path)
        let rest = args.joined(separator: " ")
        switch command {
        case "review":
            // review all | review one [path] | review off
            switch args.first {
            case "off": repository.review = nil
            case "one": repository.review = ReviewState(showsAllFiles: false, path: args.count > 1 ? args[1] : nil)
            default: repository.review = ReviewState(showsAllFiles: true)
            }
        case "focus":
            window.isFocused = args.first != "off"
            if window.isFocused { window.showsDrawer = true; repository.review = nil }
        case "drawer":
            window.showsDrawer = args.first != "off"
        case "drawerFile":
            repository.drawerPath = args.first
        case "search":
            // search off | search <query…>
            if args.first == "off" {
                repository.closeSearch()
            } else {
                repository.openSearch()
                repository.setSearchQuery(rest)
            }
        case "searchScope":
            if let scope = CommitSearchScope(rawValue: args.first ?? "") { repository.setSearchScope(scope) }
        case "searchStep":
            repository.stepSearch(Int(args.first ?? "1") ?? 1)
        case "diff":
            UserDefaults.kaern.set(args.first == "unified" ? "unified" : "split", forKey: DiffPreferences.layoutKey)
        case "whitespace":
            UserDefaults.kaern.set(args.first == "on", forKey: DiffPreferences.ignoreWhitespaceKey)
            repository.reloadDiffs()
        case "tree":
            UserDefaults.kaern.set(args.first == "on", forKey: DiffPreferences.treeKey)
        case "stage":
            repository.stage([rest])
        case "unstage":
            repository.unstage([rest])
        case "stageAll":
            repository.stageAll()
        case "unstageAll":
            repository.unstageAll()
        case "stageHunk", "unstageHunk":
            // stageHunk <hunk id> <path>
            guard args.count >= 2, let hunk = Int(args[0]) else { return }
            let path = args.dropFirst().joined(separator: " ")
            if command == "stageHunk" { repository.stageHunk(path: path, hunk: hunk) } else { repository.unstageHunk(path: path, hunk: hunk) }
        case "summary":
            repository.composer.summary = rest
        case "body":
            repository.composer.body = rest.replacingOccurrences(of: "\\n", with: "\n")
        case "amend":
            repository.setAmend(args.first != "off")
        case "commit":
            repository.commit()
        case "column":
            // column ref|graph|date|sha <width>
            let keys = ["ref": "KaernColumnRef", "graph": "KaernColumnGraph", "date": "KaernColumnDate", "sha": "KaernColumnSHA"]
            if args.count == 2, let key = keys[args[0]], let value = Double(args[1]) { UserDefaults.kaern.set(value, forKey: key) }
        case "scroll":
            // scroll <commit index>
            if let index = args.first.flatMap(Int.init), repository.commits.indices.contains(index) {
                repository.scrollRequest = ScrollRequest(id: repository.commits[index].id)
            }
        default:
            break
        }
    }

    // MARK: Phase 3

    private var openMenu: NSMenu?
    /// `targetFrame`'s answer, for the dump.
    var lastTargetFrame: CGRect?
    /// The first pass of a menu capture, and where its menu was.
    private var menuCapture: NSBitmapImageRep?
    private var menuCaptureFrame: NSRect?

    /// Context menus, picking and compare, ⌘Z, the push flows, line staging, the Command Log.
    private func phase3(_ command: String, _ args: [String]) {
        let rest = args.joined(separator: " ")
        switch command {
        case "commandLog":
            // commandLog [repository path] — opens Window › Command Log.
            CommandLogWindowController.shared.show(repository: window?.activeTab?.path)
            // The board's size, so the two can be compared.
            CommandLogWindowController.shared.window?.setFrame(NSRect(x: 60, y: 40, width: 1440, height: 900), display: true)
            return
        case "commandLogFilter":
            // commandLogFilter all|failed|changes|network [background on|off] [repo on|off]
            let state = CommandLogWindowController.shared.debugState
            if let filter = CommandLogState.Filter(rawValue: args.first ?? "") { state.filter = filter }
            if let index = args.firstIndex(of: "background"), args.count > index + 1 { state.showsBackground = args[index + 1] == "on" }
            if let index = args.firstIndex(of: "repo"), args.count > index + 1 { state.onlyRepository = args[index + 1] == "on" }
            if let index = args.firstIndex(of: "query") { state.query = args.dropFirst(index + 1).joined(separator: " ") }
            return
        case "commandLogSelect":
            // commandLogSelect <text in the command line> — selects the newest entry that has it.
            let state = CommandLogWindowController.shared.debugState
            state.selection = CommandLog.shared.entries.last { $0.record.commandLine.contains(rest) }?.id
            return
        case "snapshotAll":
            snapshotComposite(to: args.first ?? "/tmp/kaern-all.png")
            return
        case "snapshotWindow":
            // snapshotWindow <png> <title…>
            let title = args.dropFirst().joined(separator: " ")
            if args.count >= 2, let target = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) {
                render(target, to: args[0])
            }
            return
        default:
            break
        }
        guard let window, let tab = window.activeTab, let controller else { return }
        let repository = app.repository(for: tab.path)
        func commitID(_ text: String?) -> String? {
            guard let text else { return nil }
            if let index = Int(text), repository.commits.indices.contains(index) { return repository.commits[index].id }
            return repository.commits.first { $0.id.hasPrefix(text) }?.id
        }
        switch command {
        case "menu":
            // menu commit <index> | branch <name> | remote <name> | tag <name> | file <path> [staged] | stash <index>,
            // then <x> <y> (window points, top-left): where the menu's top-left goes, or with `sub <item title…>`
            // where that item goes. `snap <png>` saves the window with the menu (and the item's submenu) open.
            // Distributed notifications don't arrive while a menu tracks the mouse, so the menu takes
            // its own snapshot after a moment and closes again; a submenu is captured in a second
            // pass, opened next to its item.
            var parts = args
            var sub: String?
            var snap: String?
            if let index = parts.firstIndex(of: "sub") {
                sub = parts[(index + 1)...].joined(separator: " ")
                parts = Array(parts[..<index])
            }
            if let index = parts.firstIndex(of: "snap"), parts.count > index + 1 {
                snap = parts[index + 1]
                parts.remove(at: index + 1)
                parts.remove(at: index)
            }
            guard parts.count >= 4, let x = Double(parts[parts.count - 2]), let y = Double(parts[parts.count - 1]) else { return }
            let spec = Array(parts.dropLast(2))
            let target: ContextTarget?
            switch spec[0] {
            case "commit": target = commitID(spec[1]).map { .commit($0) }
            case "branch": target = .branch(spec.dropFirst().joined(separator: " "))
            case "remote": target = .remoteBranch(spec.dropFirst().joined(separator: " "))
            case "tag": target = .tag(spec.dropFirst().joined(separator: " "))
            case "file":
                let staged = spec.last == "staged"
                target = .file(path: spec.dropFirst().dropLast(staged ? 1 : 0).joined(separator: " "), staged: staged)
            case "stash": target = Int(spec[1]).flatMap { repository.stashes.indices.contains($0) ? .stash(repository.stashes[$0].id) : nil }
            default: target = nil
            }
            // `toolbarBranch`: the toolbar branch button's menu (phase 4); `graphScope`: the bar's Graph: menu (phase 6).
            let built = spec[0] == "toolbarBranch"
                ? ContextMenus.toolbarBranchMenu(repository, onNewBranch: {})
                : spec[0] == "graphScope" ? ContextMenus.graphScopeMenu(repository)
                : target.flatMap { ContextMenus.menu(for: $0, repository: repository, window: window) }
            guard let menu = built, let nsWindow = controller.window, let view = nsWindow.contentView else { return }
            let point = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
            let parent = sub.flatMap { title in menu.items.first { $0.title == title } }
            openMenu = menu
            let tracker = controller.contextTracker
            DispatchQueue.main.async {
                self.menuCapture = nil
                self.menuCaptureFrame = nil
                if snap != nil {
                    let timer = Timer(timeInterval: 0.8, repeats: false) { _ in
                        MainActor.assumeIsolated {
                            self.menuCapture = self.compositeRep()
                            self.menuCaptureFrame = NSApp.windows.first {
                                String(describing: type(of: $0)).contains("PopupMenu") && $0.isVisible
                            }?.frame
                            self.openMenu?.cancelTracking()
                        }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                }
                tracker.open = target.flatMap { tracker.view(for: $0) }
                menu.popUp(positioning: parent, at: point, in: view)
                tracker.open = nil
                self.openMenu = nil
                guard let snap, let rep = self.menuCapture else { return }
                guard let parent, let submenu = parent.submenu, let frame = self.menuCaptureFrame else {
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: snap))
                    return
                }
                // Second pass: the submenu, next to its item, drawn onto the first capture.
                let edge = view.convert(nsWindow.convertPoint(fromScreen: NSPoint(x: frame.maxX, y: frame.maxY)), from: nil)
                let subPoint = NSPoint(x: edge.x - 6, y: point.y - (view.isFlipped ? 5 : -5))
                self.openMenu = submenu
                let timer = Timer(timeInterval: 0.8, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        guard let rep = self.menuCapture, let origin = self.controller?.window?.frame.origin else { return }
                        if let window = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("PopupMenu") && $0.isVisible }) {
                            self.drawMenu(window, onto: rep, origin: origin)
                        }
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: snap))
                        self.openMenu?.cancelTracking()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                submenu.popUp(positioning: submenu.items.first, at: subPoint, in: view)
                self.openMenu = nil
            }
        case "menuClose":
            openMenu?.cancelTracking()
        case "rightClick":
            // rightClick x y snap <png> — moves the pointer there (hover), then right-clicks through the
            // window like a real click; the menu that opens is snapshotted and closed.
            guard args.count >= 4, let x = Double(args[0]), let y = Double(args[1]), let nsWindow = controller.window else { return }
            let point = CGPoint(x: x, y: y)
            let snap = args[3]
            let tracker = controller.contextTracker
            Task {
                let timer = Timer(timeInterval: 0.8, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        self.snapshotComposite(to: snap)
                        tracker.openMenu?.cancelTracking()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                let location = NSPoint(x: point.x, y: nsWindow.frame.height - point.y)
                if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: nsWindow.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    nsWindow.sendEvent(event)
                }
            }
        case "pick":
            // pick <index> [<index>…] — the picked commits (2: compare, 3+: the multi-select panel).
            repository.clearPicks()
            let ids = args.compactMap(commitID)
            if ids.count == 1 { repository.selection = .commit(ids[0]) } else { repository.picked = ids }
            repository.pickAnchor = ids.last
        case "clearPicks":
            repository.clearPicks()
        case "branchCompare":
            repository.compare(branch: rest)
        case "swap":
            repository.compareSwapped.toggle()
        case "compareWorking":
            if let id = commitID(args.first) { repository.compareWithWorkingCopy(id) }
        case "undo":
            repository.from("Debug") { repository.undo() }
        case "redo":
            repository.from("Debug") { repository.redo() }
        case "checkout":
            repository.from("Debug") { repository.checkout(branch: rest) }
        case "checkoutCommit":
            if let id = commitID(args.first) { repository.from("Debug") { repository.checkout(commit: id) } }
        case "cherryPick":
            repository.from("Debug") { repository.cherryPick(args.compactMap(commitID)) }
        case "revert":
            repository.from("Debug") { repository.revert(args.compactMap(commitID)) }
        case "reset":
            // reset <index> soft|mixed|hard
            let modes: [String: GitRepository.ResetMode] = ["soft": .soft, "mixed": .mixed, "hard": .hard]
            if args.count == 2, let id = commitID(args[0]), let mode = modes[args[1]] { repository.from("Debug") { repository.reset(to: id, mode: mode) } }
        case "merge":
            repository.from("Debug") { repository.merge(rest) }
        case "rebase":
            repository.from("Debug") { repository.rebase(onto: rest) }
        case "deleteBranch":
            repository.from("Debug") { repository.deleteBranch(rest) }
        case "rename":
            // rename <old> <new>
            if args.count == 2 {
                repository.from("Debug") { repository.renameBranch(args[0], to: args[1], alsoOn: nil) }
            }
        case "tag":
            // tag <index> <name>
            if args.count == 2, let id = commitID(args[0]) {
                repository.from("Debug") { repository.createTag(args[1], at: id, message: nil, push: false) }
            }
        case "discard":
            // discard <path> [unstaged]
            let keep = args.last == "unstaged"
            let path = args.dropLast(keep ? 1 : 0).joined(separator: " ")
            if let entry = repository.status.entries.first(where: { $0.path == path }) {
                repository.from("Debug") { repository.discard([entry], keepingStaged: keep) }
            }
        case "ignore":
            repository.from("Debug") { repository.ignore(pattern: rest) }
        case "apply", "popStash", "drop":
            if let index = Int(args.first ?? ""), repository.stashes.indices.contains(index) {
                let stash = repository.stashes[index]
                repository.from("Debug") {
                    if command == "drop" { repository.dropStash(stash) } else { repository.applyStash(stash, pop: command == "popStash") }
                }
            }
        case "pickLines":
            // pickLines <path> <u|s>:<hunk>:<line>[,…] — picks lines as clicks would (the first plain, the rest with ⌘).
            guard args.count >= 2, let files = repository.reviewFiles, let file = files.first(where: { $0.path == args[0] }) else { return }
            let picks = args[1].split(separator: ",").compactMap { spec -> LinePick? in
                let parts = spec.split(separator: ":")
                guard parts.count == 3, let hunk = Int(parts[1]), let line = Int(parts[2]) else { return nil }
                return LinePick(stage: parts[0] == "s" ? .staged : .unstaged, hunk: hunk, line: line)
            }
            for (index, pick) in picks.enumerated() {
                repository.pickLine(pick, path: file.path, order: file.pickOrder, command: index > 0, shift: false)
            }
        case "stageLines":
            repository.from("Debug") { repository.stagePickedLines() }
        case "discardLines":
            repository.from("Debug") { repository.discardPickedLines() }
        case "clearLines":
            repository.clearLinePicks()
        case "publishDraft":
            // publishDraft — what Push does on a branch without upstream (opens the popover).
            repository.from("Debug") { repository.push() }
        case "publish":
            if let draft = repository.publishDraft { repository.publish(draft) }
        case "confirm":
            if let confirmation = repository.confirmation {
                repository.confirmation = nil
                confirmation.confirm()
            }
        case "dismiss":
            repository.confirmation = nil
            repository.hookFailure = nil
            repository.publishDraft = nil
        case "commitHooks":
            // commitHooks on|off — commit with or without running hooks.
            repository.from("Debug") { repository.commit(runHooks: args.first != "off") }
        case "stopCommit":
            repository.stopCommit()
        case "hookAction":
            // hookAction again|without
            repository.hookFailure = nil
            repository.from("Debug") { repository.commit(runHooks: args.first != "without") }
        case "toast":
            // toast <text…> shows a toast; toast alone puts the one on screen away (as its time running
            // out does), so a picture doesn't show one left from an earlier step.
            if rest.isEmpty { repository.toast = nil } else { repository.showToast(rest, undo: false) }
        default:
            break
        }
    }

    /// Draws the main window and every other visible Kaern window over it (menus, popovers,
    /// the Command Log) at their places, at the screen's scale.
    private func snapshotComposite(to path: String) {
        try? compositeRep()?.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
    }

    private func compositeRep() -> NSBitmapImageRep? {
        guard let main = controller?.window, let frameView = main.contentView?.superview else { return nil }
        frameView.layoutSubtreeIfNeeded()
        let scale = main.backingScaleFactor
        let origin = main.frame.origin
        let size = main.frame.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        // Menus are drawn over a glass backdrop window of their own; it renders blank, so a plain
        // menu-colored plate stands in for it under each menu.
        let others = NSApp.windows
            .filter { $0 !== main && $0.isVisible && $0.frame.intersects(main.frame) && $0.alphaValue > 0 }
            .filter { !String(describing: type(of: $0)).contains("GlassEffect") }
            .sorted { $0.level.rawValue < $1.level.rawValue }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        if let image = image(of: frameView) { image.draw(in: NSRect(origin: .zero, size: size)) }
        NSGraphicsContext.restoreGraphicsState()
        for target in others {
            let kind = String(describing: type(of: target))
            if kind.contains("Menu") {
                drawMenu(target, onto: rep, origin: origin)
            } else if kind.contains("Popover"), let content = target.contentView, let image = image(of: content) {
                // A popover's glass frame renders black: its content goes on a plate in the popover color.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                let frame = target.frame
                let inset = content.convert(content.bounds, to: nil)
                let rect = NSRect(x: frame.minX - origin.x + inset.minX, y: frame.minY - origin.y + inset.minY,
                                  width: inset.width, height: inset.height)
                let plate = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowBlurRadius = 18
                shadow.shadowOffset = NSSize(width: 0, height: -8)
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
                shadow.set()
                (NSApp.effectiveAppearance.isDark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.985, alpha: 1)).setFill()
                plate.fill()
                NSGraphicsContext.restoreGraphicsState()
                NSColor.black.withAlphaComponent(0.12).setStroke()
                plate.lineWidth = 0.5
                plate.stroke()
                image.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
            } else if let view = target.contentView?.superview ?? target.contentView, let image = image(of: view) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                let frame = target.frame
                image.draw(in: NSRect(x: frame.minX - origin.x, y: frame.minY - origin.y, width: frame.width, height: frame.height))
                NSGraphicsContext.restoreGraphicsState()
            }
            Self.log.info("composite \(String(describing: type(of: target)), privacy: .public) \(NSStringFromRect(target.frame), privacy: .public)")
        }
        return rep
    }

    /// A menu window on a plate in the menu color with the menu's shadow.
    private func drawMenu(_ window: NSWindow, onto rep: NSBitmapImageRep, origin: NSPoint) {
        guard let context = NSGraphicsContext(bitmapImageRep: rep), let image = layerImage(of: window, scale: window.backingScaleFactor) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let frame = window.frame
        let rect = NSRect(x: frame.minX - origin.x, y: frame.minY - origin.y, width: frame.width, height: frame.height)
        let plate = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.set()
        (NSApp.effectiveAppearance.isDark ? NSColor(white: 0.19, alpha: 1) : NSColor(white: 0.975, alpha: 1)).setFill()
        plate.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        plate.lineWidth = 0.5
        plate.stroke()
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A window drawn from its frame view's layer tree (`CALayer.render(in:)`).
    private func layerImage(of window: NSWindow, scale: CGFloat) -> NSImage? {
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let layer = view.layer else { return image(of: view) }
        let size = view.bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        if view.isFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: size)
    }

    private func image(of view: NSView) -> NSImage? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    func render(_ target: NSWindow, to path: String) {
        guard let view = target.contentView?.superview else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
    }

    private func dumpMenus(to path: String) {
        var lines: [String] = []
        func walk(_ menu: NSMenu, depth: Int) {
            for item in menu.items {
                if item.isSeparatorItem { lines.append(String(repeating: "  ", count: depth) + "—"); continue }
                var mods = ""
                let flags = item.keyEquivalentModifierMask
                if flags.contains(.control) { mods += "⌃" }
                if flags.contains(.option) { mods += "⌥" }
                if flags.contains(.shift) { mods += "⇧" }
                if flags.contains(.command) { mods += "⌘" }
                let key = item.keyEquivalent == "\t" ? "⇥" : item.keyEquivalent.uppercased()
                let shortcut = item.keyEquivalent.isEmpty ? "" : "  [\(mods)\(key)]"
                lines.append(String(repeating: "  ", count: depth) + item.title + shortcut + (item.isEnabled ? "" : "  (disabled)"))
                if let submenu = item.submenu, depth < 2 { walk(submenu, depth: depth + 1) }
            }
        }
        NSApp.mainMenu?.update()
        if let main = NSApp.mainMenu { walk(main, depth: 0) }
        try? lines.joined(separator: "\n").write(to: URL(filePath: path), atomically: true, encoding: .utf8)
    }

    private func key(_ characters: String, modifiers: [String]) {
        guard let nsWindow = controller?.window else { return }
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains("cmd") { flags.insert(.command) }
        if modifiers.contains("shift") { flags.insert(.shift) }
        if modifiers.contains("option") { flags.insert(.option) }
        if modifiers.contains("control") { flags.insert(.control) }
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: nsWindow.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: characters == "\t" ? 48 : 0
        ) else { return }
        let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
        Self.log.info("key \(characters, privacy: .public) \(modifiers, privacy: .public) handled: \(handled)")
    }

    // MARK: Synthesized input (in-process, through NSWindow.sendEvent)

    private func press(_ name: String, modifiers names: [String] = []) {
        guard let nsWindow = controller?.window else { return }
        let keys: [String: (UInt16, Int)] = [
            "up": (126, NSUpArrowFunctionKey), "down": (125, NSDownArrowFunctionKey),
            "return": (36, 0x0D), "escape": (53, 0x1B), "space": (49, 0x20),
        ]
        guard let (code, scalar) = keys[name], let unicode = UnicodeScalar(scalar) else { return }
        let characters = String(Character(unicode))
        var flags: NSEvent.ModifierFlags = []
        if names.contains("shift") { flags.insert(.shift) }
        if names.contains("option") { flags.insert(.option) }
        if names.contains("command") { flags.insert(.command) }
        // Arrow keys carry the function-key flag, as real ones do.
        if [126, 125].contains(code) { flags.insert([.function, .numericPad]) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: nsWindow.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            ) else { continue }
            nsWindow.sendEvent(event)
        }
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, count: Int = 1) {
        guard let nsWindow = controller?.window else { return }
        let location = NSPoint(x: point.x, y: nsWindow.frame.height - point.y)
        guard let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: nsWindow.windowNumber, context: nil, eventNumber: 0, clickCount: count,
            pressure: type == .leftMouseUp ? 0 : 1
        ) else { return }
        nsWindow.sendEvent(event)
    }

    private func click(at point: CGPoint, count: Int) {
        Task {
            for index in 1...max(1, count) {
                mouse(.leftMouseDown, at: point, count: index)
                try? await Task.sleep(for: .milliseconds(40))
                mouse(.leftMouseUp, at: point, count: index)
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    private func drag(from start: CGPoint, to end: CGPoint) {
        Task {
            mouse(.leftMouseDown, at: start)
            try? await Task.sleep(for: .milliseconds(60))
            let steps = 16
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                mouse(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await Task.sleep(for: .milliseconds(80))
            mouse(.leftMouseUp, at: end)
        }
    }

    /// Where the strip's tabs and chips are, in window points (from the same layout code the
    /// tab bar uses).
    private func stripFrames(to path: String) {
        guard let controller, let nsWindow = controller.window else { return }
        let model = controller.model
        let leading: CGFloat = model.isFullScreen ? 10 : 78
        let available = nsWindow.frame.width - leading - 38
        let layout = StripModel(window: model, app: app, available: available)
        let origin = leading + (layout.overflows ? 28 : 0)
        let units = layout.units.map { unit -> [String: Any] in
            let name: String
            switch unit.kind {
            case .tab(let tab, _, _): name = tab.name
            case .chip(let group, _, _, _): name = "chip:" + group.name
            }
            return ["name": name, "x": origin + unit.x, "width": unit.width, "centerX": origin + unit.x + unit.width / 2]
        }
        let state: [String: Any] = ["overflows": layout.overflows, "units": units]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted]) {
            try? data.write(to: URL(filePath: path))
        }
    }

    /// Draws a window (frame view included, so the traffic lights show) into a PNG at the
    /// screen's scale.
    private func snapshot(to path: String, window index: Int?) {
        let target: NSWindow?
        if let index, app.windows.indices.contains(index) {
            target = app.windows[index].window
        } else {
            target = controller?.window
        }
        guard let nsWindow = target, let frameView = nsWindow.contentView?.superview else { return }
        frameView.layoutSubtreeIfNeeded()
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(filePath: path))
    }

    private func dump(to path: String) {
        var windows: [[String: Any]] = []
        for controller in app.windows {
            let model = controller.model
            windows.append([
                "id": model.id.uuidString,
                "frame": controller.window.map { NSStringFromRect($0.frame) } ?? "",
                "active": model.activeTab?.name ?? "",
                "tabs": model.tabs.map { tab -> [String: Any] in
                    let repository = app.repository(for: tab.path)
                    return [
                        "name": tab.name,
                        "group": tab.group.flatMap { model.group($0)?.name } ?? "",
                        "phase": "\(repository.phase)",
                        "busy": repository.debugIsBusy,
                        "visible": repository.isVisible,
                        "fullLoads": repository.debugFullLoads,
                        "refreshes": repository.debugRefreshes,
                        "lightRefreshes": repository.debugLightRefreshes,
                        "mark": "\(repository.tabMark)",
                        "commits": repository.commits.count,
                        "changes": repository.changeCount,
                        "branch": repository.currentBranch ?? "",
                    ]
                },
                "groups": model.groups.map { ["name": $0.name, "color": $0.color.rawValue, "collapsed": $0.collapsed] },
            ])
        }
        var active: [String: Any] = [:]
        if let window, let tab = window.activeTab {
            let repository = app.repository(for: tab.path)
            let selection: String
            switch repository.selection {
            case .workingCopy: selection = "wip"
            case .commit(let id): selection = repository.commits.firstIndex { $0.id == id }.map { "commit \($0) \(id.prefix(7))" } ?? id
            }
            active = [
                "name": repository.name,
                "selection": selection,
                "focused": window.isFocused,
                "drawer": window.showsDrawer,
                "review": repository.review.map { ["all": $0.showsAllFiles, "path": $0.path ?? ""] as [String: Any] } ?? NSNull(),
                "search": ["open": repository.search.isOpen, "query": repository.search.query, "scope": repository.search.scope.rawValue,
                           "matches": repository.search.matches.compactMap { id in repository.commits.firstIndex { $0.id == id } }],
                "composer": ["summary": repository.composer.summary, "body": repository.composer.body, "amend": repository.composer.amend,
                             "button": repository.commitButtonTitle, "canCommit": repository.canCommit],
                "staged": repository.status.entries.filter(\.hasStagedChanges).map(\.path),
                "unstaged": repository.status.entries.filter(\.hasUnstagedChanges).map(\.path),
                "reviewFiles": (repository.reviewFiles ?? []).map { file -> [String: Any] in
                    ["path": file.path, "letter": file.letter, "hunks": file.hunks.map { "\($0.stage):\($0.hunk.id)" },
                     "add": file.additions, "del": file.deletions, "part": file.partText ?? ""]
                },
                "lanes": repository.graph.map(\.lane),
                "turns": repository.graph.enumerated().flatMap { index, row in
                    row.down.filter { $0.turn != .straight }.map { "\(index):\($0.from)->\($0.to) \($0.turn)" }
                },
                "descriptions": repository.commits.prefix(12).map(\.bodyPreview),
                "activity": repository.activity?.statusText ?? "",
                "head": repository.status.headID.map { String($0.prefix(7)) } ?? "",
                "branch": repository.status.branch ?? "",
                "alert": repository.alert.map { $0.title + " — " + $0.message } ?? "",
                "undo": repository.undoSteps.map(\.label),
                "redo": repository.redoSteps.map(\.label),
                "undoTitle": repository.undoTitle,
                "toast": repository.toast.map { ["message": $0.message, "undo": $0.canUndo] as [String: Any] } ?? NSNull(),
                "picked": repository.picked.compactMap { id in repository.commits.firstIndex { $0.id == id } },
                "branchCompare": repository.branchCompare?.other ?? "",
                "comparison": repository.comparison.map { comparison -> [String: Any] in
                    ["key": comparison.key, "between": comparison.between.map(\.subject), "ours": comparison.oursCount,
                     "theirs": comparison.theirsCount, "files": comparison.files.map(\.path), "linear": comparison.linear,
                     "base": comparison.base.map { String($0.prefix(7)) } ?? ""]
                } ?? NSNull(),
                "linePicks": ["path": repository.linePicks.path ?? "",
                              "lines": repository.linePicks.lines.map { "\($0.stage == .staged ? "s" : "u"):\($0.hunk):\($0.line)" }.sorted()],
                "confirmation": repository.confirmation.map { ["title": $0.title, "lost": $0.lost.map(\.subject)] as [String: Any] } ?? NSNull(),
                "hookRun": repository.hookRun?.command ?? "",
                "hookFailure": repository.hookFailure.map { ["summary": $0.summary, "lines": $0.lines.count] as [String: Any] } ?? NSNull(),
                "publishDraft": repository.publishDraft.map { ["remote": $0.remote, "name": $0.name, "track": $0.track] as [String: Any] } ?? NSNull(),
                "operation": repository.operation.map { "\($0.kind)" } ?? "",
                "stashes": repository.stashes.map(\.message),
                "upstream": repository.status.upstream ?? "",
                "ahead": repository.status.ahead, "behind": repository.status.behind,
                "phase4": phase4Dump(repository),
                "commandLog": CommandLog.shared.entries.suffix(12).map { entry in
                    "\(entry.record.isBackground ? "bg" : "ui") \(entry.record.status.map(String.init) ?? "…") \(entry.record.trigger?.action ?? "-") :: \(entry.record.commandLine)"
                },
            ]
        }
        let state: [String: Any] = [
            "active": active,
            "git": app.git?.url.path(percentEncoded: false) ?? "",
            "gitSource": app.git?.source.rawValue ?? "",
            "gitVersion": app.git?.version ?? "",
            "windows": windows,
            "lastClosedTabs": app.lastClosed?.window.tabs.count ?? 0,
            "recent": app.recent.map(\.name),
            "phase5": phase5Dump(window),
            "phase6": phase6Dump(window),
            // The global git config and credential helpers git sees (TestSession).
            "gitConfigEnvironment": (app.runner?.environment ?? [:]).filter { $0.key.hasPrefix("GIT_CONFIG") },
            // Kaern's settings as this instance reads them: launch arguments over its own store.
            "settings": UserDefaults.kaern.dictionaryRepresentation().filter { $0.key.hasPrefix("Kaern") }.mapValues { "\($0)" },
            "driver": driverDump(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            // In one step, so a script that polls for the file never reads half of it.
            try? data.write(to: URL(filePath: path), options: .atomic)
        }
    }

    /// What a script needs to wait for the app instead of sleeping: whether the shown repository
    /// is in the middle of something, the git commands still running and the newest one (two
    /// dumps with the same one: nothing started in between), whether its file watcher has caught
    /// up, and where typed text goes.
    private func driverDump() -> [String: Any] {
        let entries = CommandLog.shared.entries
        let responder = controller?.window?.firstResponder
        // A text field being edited: its field editor has the keyboard.
        let editor = responder as? NSTextView
        let field = editor?.delegate as? NSTextField
        let shown = window?.activeTab.map { app.repository(for: $0.path) }
        return [
            "channel": Self.channel ?? "",
            "busy": shown?.debugIsBusy ?? false,
            // For a script to know the file watcher has caught up: it writes kaern-debug-sync-<n>
            // into this folder and waits for the name to show as watchMarker.
            "gitDirectory": AppSettings.watchesFiles ? shown?.repository?.gitDirectory.path(percentEncoded: false) ?? "" : "",
            "watchMarker": shown?.debugWatchMarker ?? "",
            "running": entries.filter(\.record.isRunning).map(\.record.commandLine),
            "lastCommand": entries.last?.id.uuidString ?? "",
            "commandCount": entries.count,
            "fetchingAll": AutoFetcher.shared.isFetchingAll,
            // Popovers, menus, Settings, the Command Log…: what is on screen besides the main windows.
            "visibleWindows": NSApp.windows.filter(\.isVisible).map { "\(type(of: $0)) \($0.title)" },
            "firstResponder": responder.map { String(describing: type(of: $0)) } ?? "",
            "typing": editor != nil,
            "fieldText": editor?.string ?? "",
            "fieldPlaceholder": field?.placeholderString ?? field?.placeholderAttributedString?.string ?? "",
            "appearance": NSApp.effectiveAppearance.isDark ? "dark" : "light",
        ]
    }
}
#endif
