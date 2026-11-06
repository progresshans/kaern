import AppKit
import SwiftUI

/// One Kaern window: the tab row sits in the title bar (traffic lights on the left), with the
/// toolbar, sidebar, history, panel and status bar below. Kaern creates these itself from its
/// session file; macOS window restoration is off.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let model: WindowModel
    private weak var app: AppModel?
    private var lights: TrafficLights?

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
        window.minSize = NSSize(width: 820, height: 520)
        window.backgroundColor = NSColor(name: nil) { $0.isDark ? K.hex(0x323232) : K.hex(0xececec) }
        window.isReleasedWhenClosed = false

        let root = WindowRootView(window: model)
            .environment(app)
        let hosting = KaernHostingView(rootView: root)
        hosting.sizingOptions = []
        window.contentView = hosting

        super.init(window: window)
        window.delegate = self
        window.closeTab = { [weak self] in self?.closeActiveTab() ?? false }

        lights = TrafficLights(window: window, centerFromTop: KMetric.tabRow / 2)
        hosting.onLayout = { [weak self] in self?.lights?.apply() }

        placeWindow(window)
        updateTitle()
        observeTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func placeWindow(_ window: NSWindow) {
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
        app?.windowWillClose(self)
    }

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

/// The window. ⌘W ("Close") closes the selected tab first, like a browser; the close button
/// and Close Window (⇧⌘W) always close the window.
final class KaernWindow: NSWindow {
    var closeTab: (() -> Bool)?
    private var closingWindow = false

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

    override func layout() {
        super.layout()
        onLayout?()
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

/// Keeps the traffic lights vertically centered in Kaern's 36 pt tab row. macOS centers them in
/// a 32 pt title bar; Kaern makes the title-bar container 36 pt tall and moves the buttons to
/// its middle, again after anything that makes AppKit lay them out (resize, full screen,
/// appearance changes).
final class TrafficLights {
    private weak var window: NSWindow?
    private let centerFromTop: CGFloat
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

    /// Where the tab strip may start: right of the zoom button.
    static func leadingInset(for window: NSWindow?) -> CGFloat {
        guard let zoom = window?.standardWindowButton(.zoomButton) else { return 78 }
        return zoom.convert(zoom.bounds, to: nil).maxX + 9
    }
}
