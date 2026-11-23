import SwiftUI

/// The sizes the side columns and Focus's drawer were dragged to. Like the history's columns,
/// they're kept in `UserDefaults.kaern` for every window; 0 is the pane's size from the boards.
nonisolated enum PaneSizes {
    static let sidebarKey = "KaernSidebarWidth"
    /// The right panel, whatever it shows (details, a stash, Explore, Resolve Conflicts).
    static let panelKey = "KaernPanelWidth"
    static let drawerKey = "KaernDrawerHeight"
    /// Sidebar switching: the repository list.
    static let listKey = "KaernRepositoryListWidth"

    /// The least each pane can be dragged to. None has a most of its own: a column grows until the
    /// middle has `middleMin` left (the list, until the repository beside it has `screenLeast`),
    /// the drawer until the graph has `graphMin`.
    static var sidebarMin: CGFloat { z(180) }
    static var panelMin: CGFloat { z(280) }
    static var listMin: CGFloat { z(180) }
    static var drawerMin: CGFloat { z(180) }
    /// What the middle (the graph, Review, a stash, Explore) keeps when the columns beside it grow.
    static var middleMin: CGFloat { z(400) }
    /// What the graph keeps above Focus's drawer.
    static var graphMin: CGFloat { z(150) }
    /// What an open sidebar or panel leaves of the graph when it's over it (a narrow window).
    static var overlayGap: CGFloat { z(120) }
    /// What the repository beside the list needs: its sidebar, panel and middle at their least.
    static var screenLeast: CGFloat { sidebarMin + panelMin + middleMin }

    /// The stored size, or `board` when there's none, within `range`. What's stored is the size at
    /// actual size (`kept`), so a pane keeps its share of the window at any zoom.
    static func size(_ stored: Double, board: CGFloat, in range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(stored > 0 ? z(CGFloat(stored)) : board, range.lowerBound), range.upperBound)
    }

    /// A size a pane was dragged to, as it's stored: at actual size.
    static func kept(_ size: CGFloat) -> Double { Double(size / UIScale.value) }

    /// `lower` up to `upper`, or just `lower` when there's no room above it.
    static func range(_ lower: CGFloat, _ upper: CGFloat) -> ClosedRange<CGFloat> {
        lower...max(lower, upper)
    }
}

/// The sidebar and the right panel beside the middle of a row `width` wide. They keep their
/// sizes while the middle has `PaneSizes.middleMin`; past that they narrow together, each in
/// proportion to what it has above its least width, and a wider window gives their sizes back.
/// A drag stops where the middle would get less.
struct SideColumns: Equatable {
    var sidebar: CGFloat
    var panel: CGFloat
    /// What each may be dragged to now.
    var sidebarRange: ClosedRange<CGFloat>
    var panelRange: ClosedRange<CGFloat>

    /// `sidebar` and `panel`: their sizes, `nil` when not beside the middle. `fixed`: the rest
    /// of the row's columns (the sidebar's rail).
    init(width: CGFloat, sidebar: CGFloat?, panel: CGFloat?, fixed: CGFloat = 0) {
        let sidebarLeast = PaneSizes.sidebarMin
        let panelLeast = PaneSizes.panelMin
        var shownSidebar = sidebar ?? 0
        var shownPanel = panel ?? 0
        guard width > 0 else {
            self.sidebar = shownSidebar
            self.panel = shownPanel
            sidebarRange = PaneSizes.range(sidebarLeast, .infinity)
            panelRange = PaneSizes.range(panelLeast, .infinity)
            return
        }
        let room = width - PaneSizes.middleMin - fixed
        let over = shownSidebar + shownPanel - room
        let sidebarSlack = sidebar == nil ? 0 : max(0, shownSidebar - sidebarLeast)
        let panelSlack = panel == nil ? 0 : max(0, shownPanel - panelLeast)
        if over > 0, sidebarSlack + panelSlack > 0 {
            let cut = min(over, sidebarSlack + panelSlack)
            shownSidebar = (shownSidebar - cut * sidebarSlack / (sidebarSlack + panelSlack)).rounded()
            shownPanel = (shownPanel - cut * panelSlack / (sidebarSlack + panelSlack)).rounded()
        }
        self.sidebar = shownSidebar
        self.panel = shownPanel
        sidebarRange = PaneSizes.range(sidebarLeast, room - shownPanel)
        panelRange = PaneSizes.range(panelLeast, room - shownSidebar)
    }
}

/// The edge of a pane that can be dragged: 9 pt over its separator, half outside the pane (put
/// the pane above its neighbor). The pane follows the pointer within `range`; a double-click puts
/// it back to its size from the boards. The pointer shows only the ways it can still go.
struct PaneResizeHandle: View {
    /// The pane's side the handle is on.
    enum Side { case leading, trailing, top }

    let side: Side
    /// The pane's width (or the drawer's height) now.
    let size: CGFloat
    let range: ClosedRange<CGFloat>
    /// For VoiceOver ("Sidebar width").
    let label: String
    let resize: (CGFloat) -> Void
    let reset: () -> Void

    /// Where the drag began and the pane's size then. A press of its own starts over, even after a
    /// drag that was cut short without ending.
    @State private var start: (point: CGPoint, size: CGFloat)?

    var body: some View {
        let across = side == .top
        Color.clear
            .frame(width: across ? nil : z(9), height: across ? z(9) : nil)
            .frame(maxWidth: across ? .infinity : nil, maxHeight: across ? nil : .infinity)
            .contentShape(Rectangle())
            .pointerStyle(pointer)
            .gesture(
                // Global: the handle moves with the edge while it's dragged.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        if start?.point != drag.startLocation { start = (drag.startLocation, size) }
                        let moved = switch side {
                        case .trailing: drag.translation.width
                        case .leading: -drag.translation.width
                        case .top: -drag.translation.height
                        }
                        let value = clamped(((start?.size ?? size) + moved).rounded())
                        resize(value)
                        #if DEBUG
                        DebugDriver.shared.didDragPane(label, to: value)
                        #endif
                    }
                    .onEnded { _ in start = nil }
            )
            .onTapGesture(count: 2, perform: reset)
            .offset(x: side == .trailing ? z(4.5) : side == .leading ? -z(4.5) : 0, y: across ? -z(4.5) : 0)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("\(Int(size.rounded())) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: resize(clamped(size + 20))
                case .decrement: resize(clamped(size - 20))
                @unknown default: break
                }
            }
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private var pointer: PointerStyle {
        let least = size <= range.lowerBound + 0.5
        let most = size >= range.upperBound - 0.5
        switch side {
        case .top:
            let ways: VerticalDirection.Set = least == most ? .all : least ? .up : .down
            return .rowResize(directions: ways)
        case .leading, .trailing:
            // Toward the pane's middle makes it smaller.
            let grows: HorizontalDirection.Set = side == .trailing ? .trailing : .leading
            let shrinks: HorizontalDirection.Set = side == .trailing ? .leading : .trailing
            return .columnResize(directions: least == most ? .all : least ? grows : shrinks)
        }
    }
}

#if DEBUG
/// Debug builds: where each pane is (window points, top-left origin) in each window, for the
/// driver's dump.
@MainActor
enum PaneFrames {
    static var frames: [UUID: [String: CGRect]] = [:]
}

extension View {
    /// Debug builds: tells the driver where this pane is (`dump` › `phase5.layout.panes`).
    func debugPaneFrame(_ name: String, window: UUID) -> some View {
        modifier(DebugFrameReport(key: "pane:\(window):\(name)") { frame in
            if let frame { PaneFrames.frames[window, default: [:]][name] = frame } else { PaneFrames.frames[window]?[name] = nil }
        })
    }
}

/// Debug builds: where a view is in the window, told when it moves and when it comes back on
/// screen unmoved (its tab shows again), and `nil` when it leaves. `key` names what the frame is
/// told for: a view made anew (the zoom changed) takes it over, and the one it replaces, which
/// leaves a moment later, then says nothing.
struct DebugFrameReport: ViewModifier {
    let key: String
    let report: (CGRect?) -> Void
    @State private var place = FramePlace()
    private static var tellers: [String: ObjectIdentifier] = [:]

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                place.frame = frame
                Self.tellers[key] = ObjectIdentifier(place)
                report(frame)
            }
            .onAppear {
                guard let frame = place.frame else { return }
                Self.tellers[key] = ObjectIdentifier(place)
                report(frame)
            }
            .onDisappear {
                guard Self.tellers[key] == ObjectIdentifier(place) else { return }
                Self.tellers[key] = nil
                report(nil)
            }
    }
}
#else
extension View {
    func debugPaneFrame(_ name: String, window: UUID) -> some View { self }
}
#endif
