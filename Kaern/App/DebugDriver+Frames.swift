#if DEBUG
import AppKit
import QuartzCore

/// Debug commands that measure how the main thread keeps up with the display while a check
/// scrolls or changes screens:
///
///     frames ghost on|off    the window in front of every other (floating, on every Space), almost
///                            transparent and letting clicks through, and back behind them: a window
///                            that's covered doesn't draw, so what it would cost to draw can't be
///                            measured there, and a window at the normal level goes under whatever
///                            is clicked while a check runs
///     frames start           begins measuring
///     frames stop <file>     writes what was measured since, as JSON (with where the last scrollRun
///                            left its scroll view: `scrollY` of `scrollMax`, 0 of 0 when nothing moved)
///     scrollRun <x> <y> <dy> <count> [per second]
///                            moves the scroll view at the window point (x, y) by `dy` points `count`
///                            times, 120 a second unless said otherwise (negative: down the content).
///                            Of the scroll views there, the innermost one with more content than fits.
///                            It moves the scroll view itself: a posted scroll event doesn't scroll a
///                            SwiftUI list in a window that isn't under the pointer
///
/// Events, SwiftUI updates, layout and the layer commit all happen on the main run loop, so two
/// things are measured there:
/// - turns: how long the run loop works each time it wakes. One that outlasts a refresh (8.3 ms at
///   120 Hz) is a frame the window couldn't draw in time.
/// - frames: a display link's callbacks. A turn that runs past a refresh makes the next callback
///   late or drops it.
extension DebugDriver {
    static let frameCommands: Set<String> = ["frames", "scrollRun"]

    /// The scroll view that shows the window point (x, y) (top-left origin): the innermost one there that has
    /// more content than fits its height (a diff's sideways scroller sits inside the one that scrolls the files),
    /// else the innermost one.
    private func scrollView(atX x: Double, y: Double) -> NSScrollView? {
        guard let nsWindow = controller?.window, let frameView = nsWindow.contentView?.superview else { return nil }
        let point = NSPoint(x: x, y: nsWindow.frame.height - y)
        func scrollsDown(_ scrollView: NSScrollView) -> Bool {
            (scrollView.documentView?.frame.height ?? 0) > scrollView.contentView.bounds.height + 1
        }
        var view = frameView.hitTest(point)
        var innermost: NSScrollView?
        while let current = view {
            if let scrollView = current as? NSScrollView {
                if scrollsDown(scrollView) { return scrollView }
                innermost = innermost ?? scrollView
            }
            view = current.superview
        }
        if let innermost { return innermost }
        // SwiftUI can answer the hit test with a view beside the scroll view: look for the smallest one there.
        var found: NSScrollView?
        func search(_ view: NSView) {
            if let scrollView = view as? NSScrollView, view.convert(view.bounds, to: nil).contains(point),
               found.map({ scrollView.frame.width * scrollView.frame.height < $0.frame.width * $0.frame.height }) ?? true {
                found = scrollView
            }
            view.subviews.forEach(search)
        }
        search(frameView)
        return found
    }

    func frames(_ command: String, _ args: [String]) {
        switch command {
        case "frames":
            if args.first == "start" {
                DebugFrameMeter.shared.start(in: controller?.window)
            } else if args.first == "stop", args.count > 1 {
                DebugFrameMeter.shared.stop(writingTo: args[1])
            } else if args.first == "ghost" {
                DebugFrameMeter.shared.setGhost(args.last != "off", window: controller?.window)
            }
        case "scrollRun":
            let values = args.compactMap(Double.init)
            guard values.count >= 4, values.count == args.count, values[3] >= 1 else { return }
            guard let scrollView = scrollView(atX: values[0], y: values[1]) else { return }
            DebugFrameMeter.shared.scroll(by: values[2], times: Int(values[3]), perSecond: values.count > 4 ? values[4] : 120) { dy in
                // As the wheel does: a negative step moves down the content.
                let clip = scrollView.contentView
                let flipped = scrollView.documentView?.isFlipped ?? true
                let most = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
                var origin = clip.bounds.origin
                origin.y = min(max(0, origin.y + (flipped ? -dy : dy)), most)
                clip.scroll(to: origin)
                scrollView.reflectScrolledClipView(clip)
                DebugFrameMeter.shared.scrolledTo = (origin.y, most)
            }
        default:
            break
        }
    }
}

/// What `frames` measures (see `DebugDriver.frames`).
@MainActor
final class DebugFrameMeter: NSObject {
    static let shared = DebugFrameMeter()

    private var observers: [CFRunLoopObserver] = []
    private var link: CADisplayLink?
    private weak var window: NSWindow?
    /// Keeps App Nap off the instance while it measures: a test window sits in the background.
    private var activity: NSObjectProtocol?
    private var began: CFTimeInterval = 0
    private var wokeAt: CFTimeInterval?
    /// Each turn of the run loop: when it woke (seconds since `began`) and how long it worked.
    private var turns: [(at: Double, length: Double)] = []
    /// Each display-link callback: when it ran and the refresh it was for (seconds since `began`).
    private var ticks: [(ran: Double, due: Double)] = []
    private var refreshInterval: Double = 0
    private var scrollTimer: Timer?
    /// The scroll events `scrollRun` still has to send, how far each goes, and what sends one.
    private(set) var scrollsLeft = 0
    private var scrollStep = 0.0
    private var scrollPost: ((Double) -> Void)?

    var isMeasuring: Bool { !observers.isEmpty }

    func start(in window: NSWindow?) {
        end()
        self.window = window
        turns = []
        ticks = []
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Measuring frames")
        began = CACurrentMediaTime()
        // The command that starts the measuring runs in a turn of its own: that one isn't counted.
        wokeAt = nil
        let woke = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { _, _ in
            MainActor.assumeIsolated { DebugFrameMeter.shared.wokeAt = CACurrentMediaTime() }
        }
        // Last of the observers: after AppKit's display cycle and Core Animation's commit.
        let sleeps = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated { DebugFrameMeter.shared.turnEnded() }
        }
        for observer in [woke, sleeps].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
        let link = (window?.screen ?? NSScreen.main)?.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
        self.link = link
    }

    private func turnEnded() {
        guard let wokeAt else { return }
        turns.append((wokeAt - began, CACurrentMediaTime() - wokeAt))
        self.wokeAt = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        ticks.append((CACurrentMediaTime() - began, link.timestamp - began))
        refreshInterval = link.targetTimestamp - link.timestamp
    }

    private func end() {
        for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observers = []
        link?.invalidate()
        link = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    func stop(writingTo path: String) {
        let seconds = CACurrentMediaTime() - began
        end()
        let lengths = turns.map(\.length).sorted()
        func percentile(_ p: Double) -> Double {
            lengths.isEmpty ? 0 : lengths[min(lengths.count - 1, Int(Double(lengths.count) * p))]
        }
        func milliseconds(_ value: Double) -> Double { (value * 100_000).rounded() / 100 }
        let interval = refreshInterval > 0 ? refreshInterval : 1.0 / 120
        // Refreshes that got no callback at all: the main thread was busy through them.
        var dropped = 0
        var longestGap = 0.0
        for (previous, tick) in zip(ticks, ticks.dropFirst()) {
            dropped += max(0, Int(((tick.due - previous.due) / interval).rounded()) - 1)
            longestGap = max(longestGap, tick.ran - previous.ran)
        }
        let late = ticks.count { $0.ran - $0.due > interval / 2 }
        let result: [String: Any] = [
            "seconds": (seconds * 1000).rounded() / 1000,
            "visible": window?.occlusionState.contains(.visible) ?? false,
            // Where the last `scrollRun` left its scroll view, and how far it can go (-1: none ran).
            "scrollY": scrolledTo.y, "scrollMax": scrolledTo.most,
            "active": NSApp.isActive,
            "refresh": (1 / interval * 10).rounded() / 10,
            "turns": [
                "count": turns.count,
                "busyMs": milliseconds(lengths.reduce(0, +)),
                "over4": lengths.count { $0 > 0.004 },
                "over8": lengths.count { $0 > 0.0083 },
                "over16": lengths.count { $0 > 0.0167 },
                "over33": lengths.count { $0 > 0.0333 },
                "p50Ms": milliseconds(percentile(0.5)),
                "p90Ms": milliseconds(percentile(0.9)),
                "p99Ms": milliseconds(percentile(0.99)),
                "maxMs": milliseconds(lengths.last ?? 0),
            ],
            "frames": [
                "count": ticks.count,
                "dropped": dropped,
                "late": late,
                "longestGapMs": milliseconds(longestGap),
            ],
            // The longest turns, in the order they happened: [when (s), how long (ms)].
            "longest": turns.sorted { $0.length > $1.length }.prefix(24).sorted { $0.at < $1.at }
                .map { [($0.at * 1000).rounded() / 1000, milliseconds($0.length)] },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(filePath: path), options: .atomic)
        }
    }

    /// What the window was before `frames ghost on`.
    private var beforeGhost: (alpha: CGFloat, ignoresMouse: Bool)?
    private var beforeGhostSpaces: NSWindow.CollectionBehavior?
    private var beforeGhostLevel: NSWindow.Level?
    /// Where `scrollRun` last put its scroll view (see `stop`).
    var scrolledTo: (y: Double, most: Double) = (-1, -1)

    /// In front of every window, where the window server has it drawn, but nearly invisible and out
    /// of the pointer's way: a test instance mustn't cover what you're working in. Off puts it back
    /// behind the other windows.
    func setGhost(_ on: Bool, window: NSWindow?) {
        guard let window else { return }
        if on, beforeGhost == nil {
            beforeGhost = (window.alphaValue, window.ignoresMouseEvents)
            beforeGhostSpaces = window.collectionBehavior
            window.alphaValue = 0.01
            window.ignoresMouseEvents = true
            beforeGhostLevel = window.level
            // On whichever Space is in front, and above the windows of the app in use: a window on another
            // Space or under a window clicked meanwhile doesn't draw.
            window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.level = .floating
            window.orderFrontRegardless()
        } else if !on, let before = beforeGhost {
            window.orderBack(nil)
            window.alphaValue = before.alpha
            window.ignoresMouseEvents = before.ignoresMouse
            if let spaces = beforeGhostSpaces { window.collectionBehavior = spaces }
            if let level = beforeGhostLevel { window.level = level }
            beforeGhostSpaces = nil
            beforeGhostLevel = nil
            beforeGhost = nil
        }
    }

    /// `times` scroll events of `dy` points, `perSecond` a second.
    func scroll(by dy: Double, times: Int, perSecond: Double, post: @escaping (Double) -> Void) {
        scrollTimer?.invalidate()
        scrollsLeft = times
        scrollStep = dy
        scrollPost = post
        let timer = Timer(timeInterval: 1 / max(1, perSecond), repeats: true) { _ in
            MainActor.assumeIsolated { DebugFrameMeter.shared.scrollTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollTimer = timer
    }

    private func scrollTick() {
        guard scrollsLeft > 0, let scrollPost else {
            scrollTimer?.invalidate()
            scrollTimer = nil
            scrollPost = nil
            return
        }
        scrollsLeft -= 1
        scrollPost(scrollStep)
    }
}
#endif
