import AppKit
import SwiftUI

/// The start window (the Welcome board): the app, the last session to reopen, Open, Clone and Create, and the recent
/// repositories, in a 900 × 572 window of its own. Kaern shows it when no main window is open: at launch with nothing
/// to reopen, after the last tab closes, from the Dock icon and from File › New Window (`AppModel.showWelcome`).
///
/// It holds a window model that hasn't become a window yet. What opens in it (a repository, a clone, a new one, the
/// last session) makes that model a main window, and this window closes (`AppModel.adopt`).
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    let model: WindowModel
    private weak var app: AppModel?
    private var lights: TrafficLights?

    static var size: NSSize { NSSize(width: z(900), height: z(572)) }

    init(model: WindowModel, app: AppModel) {
        self.model = model
        self.app = app
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Kaern"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(name: nil) { $0.isDark ? K.hex(0x1e1e1e) : K.hex(0xffffff) }

        let hosting = NSHostingView(rootView: WelcomeRootView(window: model).environment(app).zoomed())
        hosting.sizingOptions = []
        window.contentView = hosting

        super.init(window: window)
        window.delegate = self
        // The board's lights sit in the left column, 22 pt from the top.
        lights = TrafficLights(window: window, centerFromTop: 22)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        app?.welcomeWillClose(self)
    }
}

/// The start window's content: the Welcome board, the Clone and Create sheets over it, and a folder dropped anywhere
/// opens.
private struct WelcomeRootView: View {
    let window: WindowModel
    @Environment(AppModel.self) private var app
    @State private var isDropTarget = false

    var body: some View {
        ZStack(alignment: .top) {
            WelcomeView(window: window)
            WindowSheetHost(window: window, topInset: 0)
        }
        .animation(.easeOut(duration: 0.15), value: window.sheet?.id)
        .frame(width: WelcomeWindowController.size.width, height: WelcomeWindowController.size.height)
        .ignoresSafeArea()
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: z(10), style: .continuous)
                    .strokeBorder(K.accent, lineWidth: 3)
                    .padding(z(4))
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) && isDirectory.boolValue
            }
            guard !folders.isEmpty else { return false }
            app.open(folders, in: window)
            return true
        } isTargeted: { isDropTarget = $0 }
    }
}
