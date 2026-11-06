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
            // select <commit index>
            if let index = args.first.flatMap(Int.init), let tab = window?.activeTab {
                let repository = app.repository(for: tab.path)
                if repository.commits.indices.contains(index) { repository.selection = .commit(repository.commits[index].id) }
            }
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
        case "fetch":
            if let tab = window?.activeTab { app.repository(for: tab.path).fetch() }
        case "dump":
            dump(to: args.first ?? "/tmp/kaern-state.json")
        case "quit":
            NSApp.terminate(nil)
        default:
            Self.log.error("unknown debug command \(command, privacy: .public)")
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
        let state: [String: Any] = [
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
