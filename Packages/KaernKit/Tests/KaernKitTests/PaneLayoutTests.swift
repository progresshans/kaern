import Testing
@testable import KaernKit

@Suite("Window columns", .hangGuard)
struct PaneLayoutTests {
    @Test func defaultWindowFitsEverything() {
        let layout = PaneLayout(width: 1440, showSidebar: true, showInspector: true, sidebarWidth: 210, inspectorWidth: 320)
        #expect(layout.fitsInspector)
        #expect(layout.showsCommitColumn)
        // 1440 − inspector 321 − divider 1 − history 520 leaves 598, more than the 480 limit.
        #expect(layout.sidebarRange == 180 ... 480)
        #expect(layout.inspectorRange == 280 ... 560)
    }

    @Test func dividersStopBeforeTheHistoryGetsTooNarrow() {
        let layout = PaneLayout(width: 1100, showSidebar: true, showInspector: true, sidebarWidth: 210, inspectorWidth: 320)
        #expect(layout.fitsInspector)
        // 1100 − 321 − 1 − 520
        #expect(layout.sidebarRange == 180 ... 258)
        // 1100 − 211 − 1 − 520
        #expect(layout.inspectorRange == 280 ... 368)
        #expect(!layout.showsCommitColumn)
    }

    @Test func narrowWindowDropsTheInspectorFirst() {
        let layout = PaneLayout(width: 1000, showSidebar: true, showInspector: true, sidebarWidth: 300, inspectorWidth: 320)
        #expect(!layout.fitsInspector)
        // Without the inspector the sidebar can use the room: 1000 − 1 − 520.
        #expect(layout.sidebarRange == 180 ... 479)
        #expect(layout.sidebarWidth == 300)
    }

    @Test func storedWidthsAreKeptWithinLimits() {
        let layout = PaneLayout(width: 1440, showSidebar: true, showInspector: true, sidebarWidth: 40, inspectorWidth: 2000)
        #expect(layout.sidebarWidth == 180)
        #expect(layout.inspectorWidth == 560)
    }

    @Test func draggingPastTheMinimumHidesThePane() {
        let range: ClosedRange<Double> = 180 ... 480
        #expect(PaneLayout.drag(from: 210, by: 90, in: range) == .width(300))
        #expect(PaneLayout.drag(from: 210, by: 400, in: range) == .width(480))
        // A little past the minimum stops there…
        #expect(PaneLayout.drag(from: 210, by: -60, in: range) == .width(180))
        #expect(PaneLayout.drag(from: 210, by: -100, in: range) == .width(180))
        // …well past it hides the pane.
        #expect(PaneLayout.drag(from: 210, by: -101, in: range) == .collapse)
    }
}
