import Foundation

/// The repository window's column rules: sidebar | history | inspector.
///
/// Narrow windows (minimum 800pt) collapse the inspector first, then the history's Commit
/// column; the sidebar never collapses on its own. Dragging a divider stops where the history
/// would get narrower than its minimum, and dragging well past a pane's minimum hides the pane.
public struct PaneLayout: Equatable, Sendable {
    public static let minimumTableWidth: Double = 520
    /// Below this window width the search field becomes a magnifier button.
    public static let compactSearchWidth: Double = 1240
    public static let commitColumnWidth: Double = 600
    public static let defaultSidebarWidth: Double = 210
    public static let defaultInspectorWidth: Double = 320
    public static let sidebarLimits: ClosedRange<Double> = 180 ... 480
    public static let inspectorLimits: ClosedRange<Double> = 280 ... 560
    /// How far past its minimum a divider is dragged before the pane hides.
    public static let collapseDistance: Double = 70

    public var sidebarWidth: Double
    public var inspectorWidth: Double
    /// The inspector fits next to the history; otherwise it's shown as an overlay on request.
    public var fitsInspector: Bool
    public var showsCommitColumn: Bool
    /// How far each divider can go at this window width.
    public var sidebarRange: ClosedRange<Double>
    public var inspectorRange: ClosedRange<Double>

    public init(width: Double, showSidebar: Bool, showInspector: Bool, sidebarWidth: Double, inspectorWidth: Double) {
        let sidebarWidth = Self.clamp(sidebarWidth, to: Self.sidebarLimits)
        let inspectorWidth = Self.clamp(inspectorWidth, to: Self.inspectorLimits)
        self.sidebarWidth = sidebarWidth
        self.inspectorWidth = inspectorWidth
        // Each divider is 1pt.
        let sidebar = showSidebar ? sidebarWidth + 1 : 0
        fitsInspector = width - sidebar - inspectorWidth - 1 >= Self.minimumTableWidth
        let inspector = showInspector && fitsInspector ? inspectorWidth + 1 : 0
        showsCommitColumn = width - sidebar - inspector >= Self.commitColumnWidth
        sidebarRange = Self.range(Self.sidebarLimits, room: width - inspector - 1)
        inspectorRange = Self.range(Self.inspectorLimits, room: width - sidebar - 1)
    }

    public enum DragResult: Equatable, Sendable {
        case width(Double)
        case collapse
    }

    /// Where a divider drag that started at `start` lands after moving `delta` toward the
    /// pane's growing side.
    public static func drag(from start: Double, by delta: Double, in range: ClosedRange<Double>) -> DragResult {
        let proposed = start + delta
        if proposed < range.lowerBound - collapseDistance {
            return .collapse
        }
        return .width(clamp(proposed, to: range))
    }

    public static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// The pane's limits, capped so the history keeps its minimum width in `room`.
    private static func range(_ limits: ClosedRange<Double>, room: Double) -> ClosedRange<Double> {
        let upper = min(limits.upperBound, room - minimumTableWidth)
        return limits.lowerBound ... max(limits.lowerBound, upper)
    }
}
