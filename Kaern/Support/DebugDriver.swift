#if DEBUG
import AppKit
import KaernKit
import SwiftUI

/// Debug builds only: drives the app from a script through distributed notifications, for
/// checking the UI without the window server (a locked screen, CI). Snapshots come from the
/// views' own drawing, so materials and glass show up flat.
///
///     com.progresshans.kaern.debug  { id, command, args }  →  com.progresshans.kaern.debug.reply  { id, result }
@MainActor
final class DebugDriver: NSObject {
    static let shared = DebugDriver()

    private var models: [WeakModel] = []

    private struct WeakModel {
        weak var model: RepositoryModel?
    }

    /// Per bundle identifier, so a test build (another bundle ID) never takes commands meant for
    /// the copy someone is using, and the other way round.
    private static let name = (Bundle.main.bundleIdentifier ?? "com.progresshans.kaern") + ".debug"

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(received(_:)), name: Notification.Name(Self.name), object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    func register(_ model: RepositoryModel) {
        models.removeAll { $0.model == nil || $0.model === model }
        models.append(WeakModel(model: model))
    }

    private var model: RepositoryModel? {
        if let window = targetWindow, let match = models.compactMap(\.model).last(where: { window.title == $0.displayName }) {
            return match
        }
        return models.compactMap(\.model).last
    }

    /// The window commands go to: the key window, else the frontmost titled one.
    private var targetWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.orderedWindows.first { $0.isVisible && $0.styleMask.contains(.titled) }
    }

    @objc private func received(_ notification: Notification) {
        let info = notification.userInfo ?? [:]
        let id = info["id"] as? String ?? ""
        let command = info["command"] as? String ?? ""
        let args = info["args"] as? [String] ?? []
        Task { @MainActor in
            let result = await self.run(command, args)
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(Self.name + ".reply"), object: nil,
                userInfo: ["id": id, "result": result], deliverImmediately: true
            )
        }
    }

    private func run(_ command: String, _ args: [String]) async -> String {
        switch command {
        case "windows":
            return NSApp.windows.filter(\.isVisible).map { "\($0.windowNumber) \($0.title) \(Int($0.frame.width))x\(Int($0.frame.height))\($0.isKeyWindow ? " key" : "") tabs=\($0.tabGroup?.windows.count ?? 0) tabBar=\($0.tabGroup?.isTabBarVisible ?? false)" }
                .joined(separator: "\n")
        case "focus":
            // focus <title>: make a window key.
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title.localizedCaseInsensitiveContains(args.first ?? "") }) else { return "no window" }
            window.makeKeyAndOrderFront(nil)
            return "focused \(window.title)"
        case "snapshot":
            return snapshot(to: args.first ?? "/tmp/kaern-snapshot.png", crop: args.count >= 5 ? args[1...4].compactMap { Double($0) } : nil)
        case "size":
            guard let window = targetWindow, args.count == 2, let width = Double(args[0]), let height = Double(args[1]) else { return "usage: size w h" }
            var frame = window.frame
            frame.origin.y += frame.height - height
            frame.size = CGSize(width: width, height: height)
            window.setFrame(frame, display: true)
            return "sized"
        case "key":
            return key(args)
        case "type":
            guard let window = targetWindow else { return "no window" }
            if let editor = window.firstResponder as? NSTextView {
                editor.insertText(args.joined(separator: " "), replacementRange: editor.selectedRange())
                return "typed"
            }
            return "no text field is focused (\(String(describing: window.firstResponder)))"
        case "click":
            return click(args, count: 1)
        case "doubleclick":
            return click(args, count: 2)
        case "rightclick":
            return click(args, count: 1, right: true)
        case "drag":
            return drag(args)
        case "find":
            return find(args.joined(separator: " "))
        case "tree":
            guard let window = targetWindow else { return "no window" }
            var lines: [String] = []
            dump(window, depth: 0, into: &lines, maxDepth: Int(args.first ?? "") ?? 30)
            return lines.joined(separator: "\n")
        case "responder":
            guard let window = targetWindow else { return "no window" }
            var text = String(describing: window.firstResponder.map { type(of: $0) })
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
                text += " editing \(type(of: field)) inContent=\(window.contentView.map { field.isDescendant(of: $0) } ?? false)"
            }
            return text
        case "account":
            // account add github <host> <token> · account remove <host> · account list
            switch args.first {
            case "add":
                guard args.count == 4 else { return "usage: account add github|gitlab host token" }
                do {
                    let account = try await AppModel.shared.addAccount(kind: args[1] == "gitlab" ? .gitlab : .github, host: args[2], token: args[3])
                    return "added \(account.login)@\(account.host)"
                } catch {
                    return "failed: \(error.localizedDescription)"
                }
            case "remove":
                guard let account = AppModel.shared.accounts.first(where: { $0.host == args.dropFirst().first }) else { return "no account" }
                await AppModel.shared.signOut(account)
                return "removed"
            default:
                return AppModel.shared.accounts.map(\.id).joined(separator: "\n")
            }
        case "open":
            AppModel.shared.open(URL(filePath: args.joined(separator: " "), directoryHint: .isDirectory))
            try? await Task.sleep(for: .milliseconds(1500))
            return "opened"
        case "defaults":
            return args.map { "\($0)=\(String(describing: UserDefaults.standard.object(forKey: $0)))" }.joined(separator: " ")
        case "views":
            // views [maxY]: the window's NSView tree (class, frame in window coordinates from the top-left).
            guard let window = targetWindow, let frameView = window.contentView?.superview else { return "no window" }
            let limit = Double(args.first ?? "") ?? .infinity
            var lines: [String] = []
            func walk(_ view: NSView, depth: Int) {
                let rect = view.convert(view.bounds, to: nil)
                let top = frameView.bounds.height - rect.maxY
                if top <= limit {
                    lines.append(String(repeating: "  ", count: depth)
                        + "\(type(of: view)) [\(Int(rect.minX)),\(Int(top)),\(Int(rect.width)),\(Int(rect.height))]\(view.isHidden ? " hidden" : "")")
                }
                for subview in view.subviews { walk(subview, depth: depth + 1) }
            }
            walk(frameView, depth: 0)
            return lines.joined(separator: "\n")
        case "press":
            // press <label> [n]: accessibilityPerformPress on the n-th matching element.
            let matches = elements(matching: args.first ?? "")
            let index = args.count > 1 ? Int(args[1]) ?? 0 : 0
            guard index < matches.count else { return "no match (\(matches.count))" }
            let element = matches[index]
            return element.accessibilityPerformPress() ? "pressed \(describe(element))" : "press failed on \(describe(element))"
        case "menu":
            // menu <Menu> <Item>
            guard args.count >= 2, let menu = NSApp.mainMenu?.items.first(where: { $0.title == args[0] })?.submenu else { return "no menu" }
            menu.update()
            guard let item = find(item: args[1...].joined(separator: " "), in: menu) else { return "no item" }
            guard item.isEnabled, let menu = item.menu else { return "disabled: \(item.title)" }
            menu.performActionForItem(at: menu.index(of: item))
            return "chose \(item.title)"
        case "model":
            return await modelCommand(args)
        default:
            return "unknown command \(command)"
        }
    }

    // MARK: Model shortcuts

    private func modelCommand(_ args: [String]) async -> String {
        guard let model else { return "no repository window" }
        switch args.first {
        case "switcher":
            model.showQuickSwitcher(query: args.dropFirst().joined(separator: " "))
        case "select":
            guard let prefix = args.dropFirst().first, let commit = model.commits.first(where: { $0.id.hasPrefix(prefix) }) else { return "no commit" }
            model.selectedFile = nil
            model.selection = .commit(commit.id)
        case "wip":
            model.selection = .workingCopy
        case "file":
            model.selection = .workingCopy
            model.selectedFile = .working(args.dropFirst().joined(separator: " "))
        case "cfile":
            // cfile <path>: a file of the selected commit.
            guard case .commit(let id) = model.selection else { return "no commit selected" }
            model.selectedFile = .commit(commitID: id, path: args.dropFirst().joined(separator: " "))
        case "sidebar":
            model.showSidebar.toggle()
        case "inspector":
            model.toggleInspector()
        case "refresh":
            await model.refreshEverything()
        case "search":
            // search <scope> <text…>
            model.searchScope = CommitSearchScope(rawValue: args.dropFirst().first ?? "all") ?? .all
            model.searchText = args.dropFirst(2).joined(separator: " ")
            try? await Task.sleep(for: .milliseconds(900))
            return "matches=\(model.searchMatchCount) summary=\(model.searchSummary ?? "nil")"
        case "next":
            model.selectNextSearchMatch(backwards: args.dropFirst().first == "back")
        case "filehistory":
            // filehistory <path> [blame]
            guard args.count >= 2 else { return "usage: model filehistory path [blame]" }
            model.showFileHistory(args[1], mode: args.count > 2 && args[2] == "blame" ? .blame : .history)
            try? await Task.sleep(for: .milliseconds(800))
            let state = model.fileHistory
            return "entries=\(state?.entries?.count ?? -1) selected=\(state?.selectedID?.prefix(7) ?? "nil") blameLines=\(state?.blame?.lines.count ?? -1) chunks=\(state?.blame?.chunks.count ?? -1) error=\(state?.error ?? state?.blameError ?? "nil") file=\(String(describing: model.selectedFile))"
        case "chunk":
            guard let blame = model.fileHistory?.blame, let index = Int(args.dropFirst().first ?? ""), index < blame.chunks.count else { return "no chunk" }
            model.selectBlameChunk(blame.chunks[index])
        case "blamebefore":
            guard let blame = model.fileHistory?.blame, let index = Int(args.dropFirst().first ?? ""), index < blame.chunks.count else { return "no chunk" }
            model.blameBefore(blame.chunks[index].commitID)
            try? await Task.sleep(for: .milliseconds(800))
            let state = model.fileHistory
            return "revision=\(String(describing: state?.blameRevision)) path=\(state?.blamePath ?? "") lines=\(state?.blame?.lines.count ?? -1) error=\(state?.blameError ?? "nil")"
        case "stash":
            guard let index = Int(args.dropFirst().first ?? ""), index < model.stashes.count else { return "no stash" }
            model.showStash(model.stashes[index])
            try? await Task.sleep(for: .milliseconds(700))
            return "files=\(model.stashView?.details?.files.map(\.path) ?? []) error=\(model.stashView?.error ?? "nil")"
        case "blamemode":
            model.setFileHistoryMode(args.dropFirst().first == "history" ? .history : .blame)
            try? await Task.sleep(for: .milliseconds(600))
        case "fitsidebar":
            return "fitting sidebar width \(SidebarView.fittingWidth(for: model))"
        case "state":
            break
        case "compare":
            // compare <sha prefix> <sha prefix>
            let ids = args.dropFirst().compactMap { prefix in model.commits.first(where: { $0.id.hasPrefix(prefix) })?.id }
            guard ids.count == 2 else { return "need two commits" }
            model.compare(ids[0], ids[1])
            try? await Task.sleep(for: .milliseconds(900))
            return "base=\(model.comparisonBase?.prefix(7) ?? "nil") selection=\(model.selection) files=\(model.detailFiles.map(\.path)) distance=\(String(describing: model.comparisonDistance))"
        case "endcompare":
            model.endComparison()
        case "hide", "solo":
            // hide|solo <branch name>
            let name = args.dropFirst().joined(separator: " ")
            guard let ref = model.refs.refs.first(where: { $0.name == name }) else { return "no ref \(name)" }
            if args[0] == "hide" { model.setHiddenInGraph(ref, true) } else { model.showOnlyInGraph(ref) }
            try? await Task.sleep(for: .milliseconds(900))
            return "commits=\(model.commits.map(\.subject))"
        case "showall":
            model.showAllBranchesInGraph()
            try? await Task.sleep(for: .milliseconds(900))
            return "commits=\(model.commits.map(\.subject))"
        case "undo":
            // undo: the window's undo manager takes the last step back (as Edit › Undo would).
            guard let manager = model.undoManager, manager.canUndo else { return "nothing to undo" }
            manager.undo()
            try? await Task.sleep(for: .milliseconds(1500))
        default:
            return "unknown model command"
        }
        try? await Task.sleep(for: .milliseconds(150))
        return "selection=\(model.selection) file=\(String(describing: model.selectedFile)) switcher=\(model.quickSwitcherQuery ?? "nil") sidebar=\(model.showSidebar) inspector=\(model.isInspectorVisible) sheet=\(model.sheet?.id ?? "nil") confirmation=\(model.confirmation?.id ?? "nil") alert=\(model.alert?.title ?? "nil") activity=\(model.activity?.title ?? "nil") undo=\(model.undoManager.map { $0.canUndo ? $0.undoActionName : "empty" } ?? "no manager")"
    }

    // MARK: Snapshots

    private func snapshot(to path: String, crop: [Double]?) -> String {
        guard let window = targetWindow, let frameView = window.contentView?.superview else { return "no window" }
        var rect = frameView.bounds
        if let crop, crop.count == 4 {
            // x y w h from the window's top-left, in points.
            rect = CGRect(x: crop[0], y: frameView.bounds.height - crop[1] - crop[3], width: crop[2], height: crop[3])
        }
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: rect) else { return "no bitmap" }
        frameView.cacheDisplay(in: rect, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return "no png" }
        do {
            try data.write(to: URL(filePath: path))
        } catch {
            return error.localizedDescription
        }
        return "\(path) \(rep.pixelsWide)x\(rep.pixelsHigh)"
    }

    // MARK: Events

    private func point(_ x: String, _ y: String, in window: NSWindow) -> NSPoint? {
        guard let x = Double(x), let y = Double(y), let height = window.contentView?.superview?.bounds.height else { return nil }
        return NSPoint(x: x, y: height - y)
    }

    private func mouse(_ type: NSEvent.EventType, at location: NSPoint, in window: NSWindow, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1
        ) else { return }
        window.sendEvent(event)
    }

    private func click(_ args: [String], count: Int, right: Bool = false) -> String {
        guard let window = targetWindow, args.count >= 2, let location = point(args[0], args[1], in: window) else { return "usage: click x y" }
        let flags = modifierFlags(args.dropFirst(2).joined())
        for click in 1 ... count {
            mouse(right ? .rightMouseDown : .leftMouseDown, at: location, in: window, clicks: click, flags: flags)
            mouse(right ? .rightMouseUp : .leftMouseUp, at: location, in: window, clicks: click, flags: flags)
        }
        return "clicked \(args[0]),\(args[1])"
    }

    private func drag(_ args: [String]) -> String {
        guard let window = targetWindow, args.count >= 4,
              let start = point(args[0], args[1], in: window), let end = point(args[2], args[3], in: window) else { return "usage: drag x1 y1 x2 y2" }
        mouse(.mouseMoved, at: start, in: window)
        mouse(.leftMouseDown, at: start, in: window)
        for step in 1 ... 10 {
            let t = CGFloat(step) / 10
            mouse(.leftMouseDragged, at: NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t), in: window)
        }
        mouse(.leftMouseUp, at: end, in: window)
        return "dragged"
    }

    private func modifierFlags(_ text: String) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if text.contains("cmd") { flags.insert(.command) }
        if text.contains("opt") { flags.insert(.option) }
        if text.contains("shift") { flags.insert(.shift) }
        if text.contains("ctrl") { flags.insert(.control) }
        return flags
    }

    /// key <name> [modifiers]: return, esc, down, up, left, right, tab, delete, space, or a character.
    private func key(_ args: [String]) -> String {
        guard let window = targetWindow, let name = args.first else { return "usage: key name [cmd,opt,shift,ctrl]" }
        let flags = modifierFlags(args.dropFirst().joined())
        let keys: [String: (UInt16, String)] = [
            "return": (36, "\r"), "esc": (53, "\u{1b}"), "down": (125, "\u{F701}"), "up": (126, "\u{F700}"),
            "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "tab": (48, "\t"), "delete": (51, "\u{7f}"), "space": (49, " "),
        ]
        let (code, characters) = keys[name] ?? (0, name)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            ) else { continue }
            if type == .keyDown, flags.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                return "key equivalent \(name)"
            }
            if type == .keyDown, window.performKeyEquivalent(with: event) {
                return "window key equivalent \(name)"
            }
            window.sendEvent(event)
        }
        return "key \(name) → \(String(describing: window.firstResponder.map { type(of: $0) }))"
    }

    // MARK: Accessibility (in-process)

    private typealias Element = NSAccessibilityProtocol

    private func describe(_ element: Element) -> String {
        let role = (element.accessibilityRole()?.rawValue ?? "?")
        var parts = [role]
        if let label = element.accessibilityLabel(), !label.isEmpty { parts.append("label=\"\(label.prefix(80))\"") }
        if let title = element.accessibilityTitle(), !title.isEmpty { parts.append("title=\"\(title.prefix(80))\"") }
        if let value = element.accessibilityValue() { parts.append("value=\"\(String(describing: value).prefix(60))\"") }
        if let identifier = element.accessibilityIdentifier(), !identifier.isEmpty { parts.append("id=\(identifier)") }
        let frame = element.accessibilityFrame()
        if let window = targetWindow, frame != .zero {
            let local = window.convertFromScreen(frame)
            let height = window.contentView?.superview?.bounds.height ?? 0
            parts.append("[\(Int(local.minX)),\(Int(height - local.maxY)),\(Int(local.width)),\(Int(local.height))]")
        }
        if !element.isAccessibilityEnabled() { parts.append("disabled") }
        if element.isAccessibilitySelected() { parts.append("selected") }
        return parts.joined(separator: " ")
    }

    private func children(of element: Element) -> [Element] {
        (element.accessibilityChildren() ?? []).compactMap { $0 as? Element }
    }

    private func dump(_ element: Element, depth: Int, into lines: inout [String], maxDepth: Int) {
        guard depth <= maxDepth else { return }
        lines.append(String(repeating: "  ", count: depth) + describe(element))
        for child in children(of: element) {
            dump(child, depth: depth + 1, into: &lines, maxDepth: maxDepth)
        }
    }

    private func elements(matching text: String) -> [Element] {
        guard let window = targetWindow else { return [] }
        var found: [Element] = []
        func walk(_ element: Element, depth: Int) {
            guard depth < 40 else { return }
            let texts = [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String].compactMap { $0 }
            if texts.contains(where: { $0.localizedCaseInsensitiveContains(text) }) { found.append(element) }
            for child in children(of: element) { walk(child, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return found
    }

    private func find(_ text: String) -> String {
        elements(matching: text).map { describe($0) }.joined(separator: "\n")
    }

    private func find(item title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let submenu = item.submenu {
                submenu.update()
                if let found = find(item: title, in: submenu) { return found }
            }
        }
        return nil
    }
}
#endif
