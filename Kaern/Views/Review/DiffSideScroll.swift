import AppKit
import SwiftUI

/// Settings › Diff › Wrap long lines off: lines stay on one line, and their text scrolls
/// sideways under the line numbers, every line together (as in an editor). A trackpad's
/// sideways swipe or ⇧ with a mouse wheel moves it; a bar at the bottom shows where it is and
/// can be dragged.
@MainActor @Observable
final class DiffSideScroll {
    private(set) var offset: CGFloat = 0
    /// The widest line's text seen so far (lines report theirs as they're drawn).
    private(set) var contentWidth: CGFloat = 0
    /// How much of a line's text shows.
    private(set) var columnWidth: CGFloat = 0
    /// When it last moved: the bar shows for a moment after.
    private(set) var moved = Date.distantPast

    /// Where the diff is in its window (top-left origin), for telling which scrolls are ours.
    @ObservationIgnored var frame: CGRect = .zero
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var monitor: Any?

    var maxOffset: CGFloat { max(0, contentWidth - columnWidth) }

    func noteLine(width: CGFloat) {
        // A few points over, so the last character isn't flush with the edge.
        let needed = (width + 24).rounded(.up)
        if needed > contentWidth { contentWidth = needed }
    }

    func noteColumn(width: CGFloat) {
        guard width != columnWidth, width > 0 else { return }
        columnWidth = width
        clamp()
    }

    func scroll(to value: CGFloat) {
        let next = min(max(0, value), maxOffset)
        moved = .now
        if next != offset { offset = next }
    }

    func scroll(by delta: CGFloat) { scroll(to: offset + delta) }

    /// Other files: back to the left edge, and measure again.
    func reset() {
        offset = 0
        contentWidth = 0
    }

    private func clamp() {
        if offset > maxOffset { offset = maxOffset }
    }

    // MARK: Scroll events

    #if DEBUG
    @ObservationIgnored var lastSeen = ""
    /// The one that last started listening (the debug driver's dump).
    @ObservationIgnored static weak var current: DiffSideScroll?
    #endif

    func startMonitoring() {
        #if DEBUG
        Self.current = self
        #endif
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Local monitors run on the main thread.
            let taken = MainActor.assumeIsolated { self?.takes(event) ?? false }
            return taken ? nil : event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// A sideways scroll over the diff while there's more to see: moves the text, and the
    /// scroll view under it never sees it. Up and down go on to the scroll view.
    private func takes(_ event: NSEvent) -> Bool {
        #if DEBUG
        lastSeen = "window \(event.window?.windowNumber ?? -1) ours \(window?.windowNumber ?? -1) at \(event.locationInWindow) dx \(event.scrollingDeltaX) dy \(event.scrollingDeltaY) frame \(frame)"
        #endif
        guard maxOffset > 0, let window, let content = window.contentView else { return false }
        let location: CGPoint
        if let eventWindow = event.window {
            guard eventWindow === window else { return false }
            location = event.locationInWindow
        } else {
            // Posted events (the debug driver's) carry a screen location and no window.
            guard window.frame.contains(event.locationInWindow) else { return false }
            location = window.convertPoint(fromScreen: event.locationInWindow)
        }
        let point = CGPoint(x: location.x, y: content.bounds.height - location.y)
        guard frame.contains(point) else { return false }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        guard dx != 0, abs(dx) > abs(dy) else { return false }
        scroll(by: -(event.hasPreciseScrollingDeltas ? dx : dx * 10))
        return true
    }
}

extension EnvironmentValues {
    /// Set while lines don't wrap and the diff scrolls sideways.
    @Entry var diffSideScroll: DiffSideScroll? = nil
}

/// Gives the diff under it sideways scrolling while Wrap long lines is off.
private struct DiffSideScrolling: ViewModifier {
    /// Changes when other files show: the text goes back to the left edge.
    let resetKey: String
    @AppStorage(SettingsKey.diffWrap, store: .kaern) private var wraps = true
    @State private var side = DiffSideScroll()

    func body(content: Content) -> some View {
        content
            .environment(\.diffSideScroll, wraps ? nil : side)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { side.frame = $0 }
            .background(WindowReader { side.window = $0 })
            .overlay(alignment: .bottom) {
                if !wraps { SideScrollBar(side: side) }
            }
            .onAppear { if !wraps { side.startMonitoring() } }
            .onDisappear { side.stopMonitoring() }
            .onChange(of: wraps) { _, wraps in
                side.reset()
                if wraps { side.stopMonitoring() } else { side.startMonitoring() }
            }
            .onChange(of: resetKey) { side.reset() }
    }
}

extension View {
    /// Sideways scrolling for the diff rows inside, while Wrap long lines is off.
    func diffSideScrolling(resetKey: String) -> some View {
        modifier(DiffSideScrolling(resetKey: resetKey))
    }
}

/// The overlay scroller at the bottom of the diff: shows while the text moves or the pointer is
/// on it, and can be dragged.
private struct SideScrollBar: View {
    let side: DiffSideScroll
    @State private var shows = false
    @State private var hovering = false
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width - 16
            let knob = max(36, width * min(1, side.columnWidth / max(side.contentWidth, 1)))
            let travel = max(1, width - knob)
            let x = side.maxOffset > 0 ? travel * side.offset / side.maxOffset : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(hovering || dragStart != nil ? 0.08 : 0))
                    .frame(height: z(11))
                Capsule().fill(Color.primary.opacity(hovering || dragStart != nil ? 0.5 : 0.35))
                    .frame(width: knob, height: hovering || dragStart != nil ? z(9) : z(7))
                    .padding(.horizontal, 1)
                    .offset(x: x)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let start = dragStart ?? side.offset
                                if dragStart == nil { dragStart = start }
                                side.scroll(to: start + drag.translation.width * side.maxOffset / travel)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
            .frame(width: width, height: z(13))
            .padding(.horizontal, z(8))
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: z(15))
        .padding(.bottom, z(2))
        .opacity(side.maxOffset > 0 && (shows || hovering || dragStart != nil) ? 1 : 0)
        .allowsHitTesting(side.maxOffset > 0)
        .animation(.easeOut(duration: 0.2), value: shows)
        .onHover { hovering = $0 && side.maxOffset > 0 }
        .task(id: side.moved) {
            guard side.moved > .distantPast else { return }
            shows = true
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled { shows = false }
        }
        .accessibilityHidden(true)
    }
}

/// Reports the window a view is in.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.found = found
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.found = found
    }

    final class ReaderView: NSView {
        var found: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            found?(window)
        }
    }
}
