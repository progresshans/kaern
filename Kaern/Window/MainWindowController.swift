import AppKit
import SwiftUI

/// One Kaern window: the tab row sits in the title bar (traffic lights on the left), with the
/// toolbar, sidebar, history, panel and status bar below. Kaern creates these itself from its
/// session file; macOS window restoration is off.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let model: WindowModel
    private weak var app: AppModel?
    private var lights: TrafficLights?
    private let content: WindowContentView
    /// Where this window's rows with context menus are.
    let contextTracker = ContextMenuTracker()

    static let defaultSize = NSSize(width: 1440, height: 900)

    init(model: WindowModel, app: AppModel) {
        self.model = model
        self.app = app
        let window = KaernWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = Self.minimumSize
        window.backgroundColor = NSColor(name: nil) { $0.isDark ? K.hex(0x323232) : K.hex(0xececec) }
        window.isReleasedWhenClosed = false

        let tracker = contextTracker
        let screens = TabScreensHandle()
        let root = WindowRootView(window: model)
            .environment(app)
            .environment(tracker)
            .environment(screens)
            .takesDriverClicksInBackground()
            .zoomed()
        let hosting = KaernHostingView(rootView: root)
        hosting.sizingOptions = []
        // The tabs' screens are views of their own behind this one (`TabScreensView`).
        let content = WindowContentView(chrome: hosting)
        self.content = content
        screens.view = content.screens
        content.screens.make = { [weak app] path, inputs in
            guard let app else { return AnyView(EmptyView()) }
            return AnyView(
                RepositoryScreen(window: model, repository: app.repository(for: path),
                                 showsToolbar: inputs.showsToolbar, showsStatusBar: inputs.showsStatusBar)
                    .environment(\.windowTier, inputs.tier)
                    .environment(\.toolbarFoldsMake, inputs.toolbarFoldsMake)
                    .environment(\.repositorySwitching, inputs.switching)
                    .background(K.win)
                    .environment(app)
                    .environment(tracker)
                    .takesDriverClicksInBackground()
                    .zoomed()
            )
        }
        // A press on the screen's place is the screen's, unless a sheet of the window's covers it.
        hosting.leaves = { [weak screens] point in model.sheet == nil && screens?.takes(point) == true }
        content.open = { [weak app] folders in app?.open(folders, in: model) }
        content.targeted = { model.isDropTarget = $0 }
        window.contentView = content

        super.init(window: window)
        window.delegate = self
        window.closeTab = { [weak self] in self?.closeActiveTab() ?? false }
        window.contextMenu = { [weak self] point in self?.contextMenu(at: point) }
        window.quickLook = { [weak self] in self?.toggleQuickLook() ?? false }
        window.contextTracker = tracker

        lights = TrafficLights(window: window, centerFromTop: KMetric.tabRow / 2)
        hosting.onLayout = { [weak self] in self?.lights?.apply() }

        placeWindow(window)
        updateTitle()
        observeTitle()
        applyChrome()
        // Switching mode and toolbar style move the title bar: the lights follow.
        settingsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.kaern,
                                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyChrome() }
        }
    }

    private var settingsObserver: NSObjectProtocol?

    isolated deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    /// Tabs: the lights sit in the 36 pt tab row. Sidebar and Toolbar: in the toolbar, which is
    /// the title bar (52 pt, 58 with names).
    /// ScreenNarrow's narrowest window, at the zoom.
    static var minimumSize: NSSize { NSSize(width: z(760), height: z(520)) }

    /// The zoom changed (or any setting): the narrowest window follows it, and a window narrower
    /// than that grows to it from its top left.
    private func applyZoom() {
        UIScale.load()
        guard let window, window.minSize != Self.minimumSize else { return }
        let minimum = Self.minimumSize
        window.minSize = minimum
        guard !window.styleMask.contains(.fullScreen),
              window.frame.width < minimum.width || window.frame.height < minimum.height else { return }
        var frame = window.frame
        let top = frame.maxY
        frame.size = NSSize(width: max(frame.width, minimum.width), height: max(frame.height, minimum.height))
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true)
    }

    private func applyChrome() {
        applyZoom()
        let style = ToolbarStyle(rawValue: UserDefaults.kaern.string(forKey: SettingsKey.toolbarStyle) ?? "") ?? .iconOnly
        let tabs = AppSettings.repositorySwitching == .tabs
        let center = tabs ? KMetric.tabRow / 2 : style.titleBarHeight / 2
        (window as? KaernWindow)?.chromeHeight = tabs ? KMetric.tabRow + style.height : style.titleBarHeight
        guard lights?.centerFromTop != center else { return }
        lights?.centerFromTop = center
        lights?.apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func placeWindow(_ window: NSWindow) {
        #if DEBUG
        // A test window is as large as its session says, whatever the screen, and beside the screen when the
        // session's launcher asks for that (see `AppWindow`).
        if TestSession.stem != nil, let saved = model.frame {
            window.setFrame(window.constrainFrameRect(saved, to: nil), display: false)
            return
        }
        #endif
        if let saved = model.frame, let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(saved) }) {
            // Keep it on a screen that's still attached, and no bigger than that screen.
            var frame = saved
            let visible = screen.visibleFrame
            frame.size.width = min(max(frame.width, window.minSize.width), visible.width)
            frame.size.height = min(max(frame.height, window.minSize.height), visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            window.setFrame(frame, display: false)
        } else if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = NSSize(width: min(Self.defaultSize.width, visible.width - 40),
                              height: min(Self.defaultSize.height, visible.height - 40))
            window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                   width: size.width, height: size.height), display: false)
            // Cascade new windows from the front one.
            if let front = app?.windows.last(where: { $0 !== self })?.window {
                window.setFrameTopLeftPoint(NSPoint(x: front.frame.minX + 28, y: front.frame.maxY - 28))
            }
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if model.isFullScreen, let window, !window.styleMask.contains(.fullScreen) {
            DispatchQueue.main.async { window.toggleFullScreen(nil) }
        }
    }

    /// ⌘W closes the selected tab; with no tab left it closes the window.
    private func closeActiveTab() -> Bool {
        guard let active = model.activeTabID else { return false }
        app?.close([active], in: model)
        return true
    }

    /// Space: Quick Look of the file Review shows; Space again closes it.
    func toggleQuickLook() -> Bool {
        guard let tab = model.activeTab, let app, window?.attachedSheet == nil else { return false }
        let repository = app.repository(for: tab.path)
        if repository.showsQuickLook {
            repository.closeQuickLook()
            return true
        }
        guard let file = repository.quickLookFile else { return false }
        repository.quickLook(file)
        return true
    }

    /// The menu for the row at `point` (a commit, label, sidebar row, file or stash), in window
    /// coordinates with the origin at the top left.
    private func contextMenu(at point: CGPoint) -> (NSMenu, UUID)? {
        guard let tab = model.activeTab, let app, let hit = contextTracker.hit(at: point) else { return nil }
        contextTracker.lastTarget = hit.target
        let repository = app.repository(for: tab.path)
        return ContextMenus.menu(for: hit.target, repository: repository, window: model).map { ($0, hit.view) }
    }

    // MARK: Title (Window menu, Mission Control)

    private func observeTitle() {
        withObservationTracking {
            _ = model.activeTab
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updateTitle()
                self?.observeTitle()
            }
        }
    }

    private func updateTitle() {
        window?.title = model.activeTab.map { "Kaern — \($0.name)" } ?? "Kaern"
        if let path = model.activeTab?.path {
            window?.representedURL = URL(filePath: path, directoryHint: .isDirectory)
        } else {
            window?.representedURL = nil
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        app?.windowBecameKey(self)
    }

    func windowWillClose(_ notification: Notification) {
        content.screens.removeAll()
        app?.windowWillClose(self)
    }

    /// The folders whose screens are kept, the shown one last (the debug dump).
    var keptScreens: [String] { content.screens.keptPaths }

    func windowDidMove(_ notification: Notification) { rememberFrame() }
    func windowDidResize(_ notification: Notification) { rememberFrame() }

    func windowWillEnterFullScreen(_ notification: Notification) {
        model.isFullScreen = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        model.isFullScreen = false
        lights?.apply()
        rememberFrame()
    }

    private func rememberFrame() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        model.frame = window.frame
    }
}

/// A window of Kaern's. macOS keeps a window's top on the screen and makes it no taller than the screen. A test
/// session's windows are left out of that:
/// - They are as large as their check asks. On a small screen, such as GitHub's Mac has, a 900-point window came
///   out 680 tall, and what a check measured or clicked was somewhere else.
/// - With `-KaernDebugWindowsAside` they are beside the screen, all moved to the right by the same distance, so
///   they keep their places among themselves and cover nothing of yours while checks run. They are drawn there
///   as on the screen.
/// Anywhere else, nothing changes.
class AppWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        #if DEBUG
        if TestSession.stem != nil {
            var frame = frameRect
            // Once: a window already over there has its left edge past half the distance.
            if let aside = TestSession.windowsAside, frame.minX < aside / 2 { frame.origin.x += aside }
            return frame
        }
        #endif
        return super.constrainFrameRect(frameRect, to: screen)
    }
}

/// The window. ⌘W ("Close") closes the selected tab first, like a browser; the close button
/// and Close Window (⇧⌘W) always close the window.
final class KaernWindow: AppWindow {
    var closeTab: (() -> Bool)?
    /// Space that nothing else took: Quick Look of the file Review shows (ScreenMarks).
    var quickLook: (() -> Bool)?
    /// The context menu for the row at a point (window coordinates, top-left origin), `nil`
    /// where Kaern has none (the tab bar's own menus and text fields then get the click).
    var contextMenu: ((CGPoint) -> (NSMenu, UUID)?)?
    var contextTracker: ContextMenuTracker?
    /// The tab row and toolbar (or the toolbar alone as the title bar): their own menus stay theirs.
    var chromeHeight: CGFloat = KMetric.tabRow + KMetric.toolbar
    private var closingWindow = false

    /// The modifier keys of the last mouse press or release a Kaern window took: those of the click a
    /// view is handling, which reads its ⌘ and ⇧ here. `NSEvent.modifierFlags` is the keyboard as it is
    /// at that moment, for every app: in a test instance, a key held on the real keyboard for another app.
    private(set) static var clickModifiers: NSEvent.ModifierFlags = []

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if event.keyCode == 49, modifiers.isEmpty, quickLook?() == true { return }
        super.keyDown(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            Self.clickModifiers = event.modifierFlags
        default:
            break
        }
        let isContextClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        let point = CGPoint(x: event.locationInWindow.x, y: frame.height - event.locationInWindow.y)
        // Below the tab row and toolbar only: their own menus stay theirs.
        if isContextClick, point.y > chromeHeight,
           let (menu, row) = contextMenu?(point), let view = contentView {
            showContextMenu(menu, for: row, event: event, in: view)
            return
        }
        super.sendEvent(event)
    }

    /// Shows a context menu with the ring around its row while it's open.
    func showContextMenu(_ menu: NSMenu, for row: UUID?, event: NSEvent, in view: NSView) {
        contextTracker?.open = row
        contextTracker?.openMenu = menu
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        contextTracker?.open = nil
    }

    override func performClose(_ sender: Any?) {
        let fromKeyboard = NSApp.currentEvent?.type == .keyDown
        if !closingWindow, fromKeyboard, closeTab?() == true { return }
        super.performClose(sender)
    }

    func performCloseWindow() {
        closingWindow = true
        defer { closingWindow = false }
        super.performClose(nil)
    }
}

/// Hosts the SwiftUI window content. The title-bar part of the content handles its own
/// clicks and drags (tabs reorder by dragging); empty areas move the window through
/// `WindowDragGesture`.
final class KaernHostingView<Content: View>: NSHostingView<Content> {
    var onLayout: (() -> Void)?
    /// Says where a press isn't this view's (in its own points): there the view behind gets it.
    var leaves: ((CGPoint) -> Bool)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let leaves, leaves(convert(point, from: superview)) { return nil }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

extension View {
    /// A test instance stays in the background, where a window's views ignore the press that would
    /// bring it forward: there they take the debug driver's clicks and drags as they come
    /// (`DebugDriver.mouse`). Anywhere else, nothing changes.
    func takesDriverClicksInBackground() -> some View {
        #if DEBUG
        allowsWindowActivationEvents(TestSession.stem != nil ? true : nil)
        #else
        self
        #endif
    }
}

/// Keeps the traffic lights vertically centered in Kaern's 36 pt tab row. macOS centers them in
/// a 32 pt title bar; Kaern makes the title-bar container 36 pt tall and moves the buttons to
/// its middle, again after anything that makes AppKit lay them out (resize, full screen,
/// appearance changes).
final class TrafficLights {
    private weak var window: NSWindow?
    var centerFromTop: CGFloat
    private var observers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?
    private var isApplying = false

    init(window: NSWindow, centerFromTop: CGFloat) {
        self.window = window
        self.centerFromTop = centerFromTop
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification, NSWindow.didExitFullScreenNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            })
        }
        appearanceObservation = window.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.apply() }
        }
        apply()
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func apply() {
        guard !isApplying, let window, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview, let container = titlebar.superview else { return }
        isApplying = true
        defer { isApplying = false }
        let height = centerFromTop * 2
        if container.frame.height != height {
            var frame = container.frame
            frame.origin.y = window.frame.height - height
            frame.size.height = height
            container.frame = frame
        }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            let y = titlebar.isFlipped
                ? centerFromTop - button.frame.height / 2
                : titlebar.bounds.height - centerFromTop - button.frame.height / 2
            if button.frame.origin.y != y { button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y)) }
        }
    }
}
