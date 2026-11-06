#if DEBUG
import AppKit
import KaernKit
import OSLog

/// Debug builds only: lets scripts drive Kaern and render its windows to PNG files, so the
/// frame can be checked without controlling the screen.
///
/// Post a distributed notification named `com.progresshans.kaern.debug` whose object is a
/// command line, e.g. `snapshot /tmp/a.png`, `activate 3`, `toggleGroup godj`,
/// `moveBlock 0 2`, `appearance dark`, `dump /tmp/state.json`, `quit`.
@MainActor
final class DebugDriver {
    static let shared = DebugDriver()
    private static let log = Logger(subsystem: "com.progresshans.kaern", category: "debug")
    private var observer: NSObjectProtocol?

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.progresshans.kaern.debug"), object: nil, queue: .main
        ) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { DebugDriver.shared.run(command) }
        }
    }

    private var app: AppModel { AppModel.shared }
    private var controller: MainWindowController? { app.activeWindow ?? app.windows.last }
    private var window: WindowModel? { controller?.model }

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
            switch command {
            case "fetch": repository.fetch()
            case "push": repository.push()
            case "stash": repository.stash()
            case "pop": repository.popStash()
            case "pull": repository.pull(.merge)
            case "switch": if let name = args.first { repository.switchBranch(name) }
            default: if let name = args.first { repository.createBranch(name) }
            }
        case "dump":
            dump(to: args.first ?? "/tmp/kaern-state.json")
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
            // press up|down|return|escape — a key down through the window, to the focused view.
            press(args.first ?? "")
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
            UserDefaults.standard.set(args.first == "unified" ? "unified" : "split", forKey: DiffPreferences.layoutKey)
        case "whitespace":
            UserDefaults.standard.set(args.first == "on", forKey: DiffPreferences.ignoreWhitespaceKey)
            repository.reloadDiffs()
        case "tree":
            UserDefaults.standard.set(args.first == "on", forKey: DiffPreferences.treeKey)
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
            if args.count == 2, let key = keys[args[0]], let value = Double(args[1]) { UserDefaults.standard.set(value, forKey: key) }
        case "scroll":
            // scroll <commit index>
            if let index = args.first.flatMap(Int.init), repository.commits.indices.contains(index) {
                repository.scrollRequest = ScrollRequest(id: repository.commits[index].id)
            }
        default:
            break
        }
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

    private func press(_ name: String) {
        guard let nsWindow = controller?.window else { return }
        let keys: [String: (UInt16, Int)] = [
            "up": (126, NSUpArrowFunctionKey), "down": (125, NSDownArrowFunctionKey),
            "return": (36, 0x0D), "escape": (53, 0x1B),
        ]
        guard let (code, scalar) = keys[name], let unicode = UnicodeScalar(scalar) else { return }
        let characters = String(Character(unicode))
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
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
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(filePath: path))
        }
    }
}
#endif
