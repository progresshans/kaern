import AppKit
import SwiftUI

/// What a tab's screen is made with besides its repository: a kept screen gets a new root only
/// when one of these changed (a window being resized changes none until it crosses a width).
struct ScreenInputs: Equatable {
    var showsToolbar = true
    var showsStatusBar = true
    var tier = NarrowTier(width: 0)
    var toolbarFoldsMake = false
    var switching = RepositorySwitching.tabs
}

/// The repository screens of a window's tabs, each in a hosting view of its own. The one of the
/// tab that shows is in the window; the others are kept out of it, as they were left.
///
/// A screen made anew for every switch cost a tenth of a second or more (the sidebar, forty
/// history rows, the panel: about a billion instructions), which is what switching tabs felt
/// like. A kept one comes back in a fraction of that, with its scroll positions and open folders.
///
/// The screens sit beside the window's own hosting view (the tab row and what's around the
/// screen), behind it, not inside it: a hosting view inside another's SwiftUI takes no press in a
/// window that isn't key. The window's view leaves the screen's place clear and passes the
/// presses there on (`KaernHostingView.leaves`).
///
/// A screen that isn't in the window is not on screen for SwiftUI either: its views get
/// `onDisappear` (they stop their event monitors and take their right-click frames back) and
/// `onAppear` when the tab shows again, it isn't laid out when the window is resized, and no key
/// or click reaches it. It still reads its repository, so it is current when it comes back.
final class TabScreensView: NSView {
    /// How many screens are kept, the shown one included. Each holds its views in memory and
    /// follows its repository, so not every tab of a window with thirty: the ones used last.
    static let limit: Int = {
        #if DEBUG
        // -KaernKeptScreens 1 keeps none but the shown one: what a measurement compares with.
        let asked = UserDefaults.kaern.integer(forKey: "KaernKeptScreens")
        if asked > 0 { return asked }
        #endif
        return 5
    }()

    private struct Kept {
        let host: KaernHostingView<AnyView>
        var inputs: ScreenInputs
    }

    private var kept: [String: Kept] = [:]
    /// The kept folders, the one shown last at the end.
    private var recent: [String] = []
    private(set) var shown: String?
    /// Makes a screen's root view for a folder (the window controller knows the app and the window).
    var make: ((String, ScreenInputs) -> AnyView)?

    override var isFlipped: Bool { true }

    /// Shows `path`'s screen, making it if it isn't kept (none for `nil`), and lets go of the
    /// screens of closed tabs.
    func show(_ path: String?, open: Set<String>, inputs: ScreenInputs) {
        for gone in kept.keys where !open.contains(gone) { remove(gone) }
        guard let path, let make else {
            leave()
            return
        }
        let host: KaernHostingView<AnyView>
        if var screen = kept[path] {
            host = screen.host
            if screen.inputs != inputs {
                host.rootView = make(path, inputs)
                screen.inputs = inputs
                kept[path] = screen
            }
        } else {
            host = KaernHostingView(rootView: make(path, inputs))
            host.sizingOptions = []
            // Like the window's own view: the tab row is in the title bar.
            host.safeAreaRegions = []
            host.autoresizingMask = [.width, .height]
            kept[path] = Kept(host: host, inputs: inputs)
        }
        recent.removeAll { $0 == path }
        recent.append(path)
        if shown != path {
            leave()
            host.frame = bounds
            addSubview(host)
            shown = path
        }
        while recent.count > Self.limit, let oldest = recent.first { remove(oldest) }
    }

    /// Takes the shown screen out of the window, kept.
    private func leave() {
        guard let shown, let old = kept[shown]?.host else { return }
        // What had the keyboard in the tab that leaves doesn't keep it from outside the window.
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: old) {
            window?.makeFirstResponder(nil)
        }
        old.removeFromSuperview()
        self.shown = nil
    }

    func removeAll() {
        for path in Array(kept.keys) { remove(path) }
    }

    private func remove(_ path: String) {
        kept[path]?.host.removeFromSuperview()
        kept[path] = nil
        recent.removeAll { $0 == path }
        if shown == path { shown = nil }
    }

    /// The folders whose screens are kept, the shown one last.
    var keptPaths: [String] { recent }
}

/// What the window's root view tells the window about the tab's screen: which one shows and where.
@MainActor @Observable
final class TabScreensHandle {
    @ObservationIgnored weak var view: TabScreensView?
    /// Where the screen is, in the window's points from its top left.
    @ObservationIgnored private(set) var frame = CGRect.zero
    /// How far something of the window's own view reaches over the screen's leading edge and
    /// keeps the presses there (the repository list's resize handle).
    @ObservationIgnored var coveredLeading: CGFloat = 0

    func place(_ frame: CGRect) {
        self.frame = frame
        view?.frame = frame
    }

    func show(_ path: String?, open: [String], inputs: ScreenInputs) {
        view?.show(path, open: Set(open), inputs: inputs)
    }

    /// A press at `point` is the screen's, not the window's own view's.
    func takes(_ point: CGPoint) -> Bool {
        view?.shown != nil && frame.contains(point) && point.x >= frame.minX + coveredLeading
    }
}

/// The place the window's root view leaves for the tab's screen. It draws nothing there (the
/// window's color while no tab shows): the screen is a view behind this one (`TabScreensView`).
struct ScreenSlot: View {
    let window: WindowModel
    var showsToolbar = true
    var showsStatusBar = true
    /// See `TabScreensHandle.coveredLeading`.
    var coveredLeading: CGFloat = 0
    @Environment(TabScreensHandle.self) private var screens: TabScreensHandle?
    @Environment(\.windowTier) private var tier
    @Environment(\.toolbarFoldsMake) private var toolbarFoldsMake
    @Environment(\.repositorySwitching) private var switching

    private struct Request: Equatable {
        var path: String?
        var open: [String]
        var inputs: ScreenInputs
    }

    var body: some View {
        let request = Request(path: window.activeTab?.path, open: window.tabs.map(\.path),
                              inputs: ScreenInputs(showsToolbar: showsToolbar, showsStatusBar: showsStatusBar, tier: tier,
                                                   toolbarFoldsMake: toolbarFoldsMake, switching: switching))
        Group {
            if request.path == nil { K.win } else { Color.clear }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { screens?.place($0) }
        .onChange(of: request, initial: true) { screens?.show(request.path, open: request.open, inputs: request.inputs) }
        .onChange(of: coveredLeading, initial: true) { screens?.coveredLeading = coveredLeading }
    }
}

/// The window's content view: the tabs' screens, and over them the window's own hosting view,
/// which leaves the screen's place clear. Folders dropped anywhere on the window open in it.
final class WindowContentView: NSView {
    let screens = TabScreensView()
    private let chrome: NSView
    /// Folders were dropped on the window.
    var open: (([URL]) -> Void)?
    /// A drag with folders is over the window, or left it.
    var targeted: ((Bool) -> Void)?

    init(chrome: NSView) {
        self.chrome = chrome
        super.init(frame: .zero)
        addSubview(screens)
        addSubview(chrome)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        chrome.frame = bounds
    }

    override func layout() {
        super.layout()
        if chrome.frame != bounds { chrome.frame = bounds }
    }

    private func folders(_ sender: any NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !folders(sender).isEmpty else { return [] }
        targeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        folders(sender).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { targeted?(false) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { targeted?(false) }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let folders = folders(sender)
        targeted?(false)
        guard !folders.isEmpty else { return false }
        open?(folders)
        return true
    }
}
