import SwiftUI

/// Lists stacked in one column, each scrolling on its own under a header that stays: the sidebar's sections, and the
/// panel's Unstaged and Staged files. GitKraken's left panel works this way.
///
/// While all their rows fit, each list is as tall as its rows and what's left of the column is under the last one:
/// nothing scrolls, as when the column was one list. When they don't fit, each list first gets its least (a row, or
/// all of it when it has less), and they share the rest by weight: a list that needs less than its share has just
/// what it needs, and what it leaves goes to the others.
///
/// The edge between two lists can be dragged: the lists above it grow and the ones below it shrink, nearest first, a
/// list growing up to all its rows and shrinking down to its least. The heights it leaves are kept as weights, so the
/// lists keep them while the column is that tall, and their proportions when it's taller or shorter.
nonisolated enum StackedLists {
    struct Item: Equatable {
        /// How tall all its rows are.
        var content: CGFloat
        /// The least it's squeezed to: a row, or all of it when it has less.
        var least: CGFloat
        /// Its share of the room above the lists' leasts when every list has more rows than fit, in points (nil:
        /// none kept).
        var weight: CGFloat?

        init(content: CGFloat, row: CGFloat, weight: CGFloat?) {
            self.content = max(0, content)
            least = min(max(0, row), self.content)
            self.weight = weight
        }
    }

    /// The lists don't all fit in a column `room` points tall: some scroll.
    static func overflows(_ items: [Item], room: CGFloat) -> Bool {
        items.reduce(0) { $0 + $1.content } > max(0, room) + 0.5
    }

    /// The lists' heights in a column `room` points tall (their headers not counted).
    static func heights(_ items: [Item], room: CGFloat) -> [CGFloat] {
        let room = max(0, room)
        guard overflows(items, room: room) else { return items.map(\.content) }
        let leastTotal = items.reduce(0) { $0 + $1.least }
        // Too short even for every list's least: each gets its part of the column.
        guard leastTotal < room else {
            return items.map { leastTotal > 0 ? ($0.least * room / leastTotal).rounded(.down) : 0 }
        }
        // The rest is shared by weight, each list taking no more than all of its rows.
        let weights = weights(of: items, room: room)
        var extras = [CGFloat?](repeating: nil, count: items.count)
        var left = room - leastTotal
        var scrolling: [Int] = []
        while true {
            let open = items.indices.filter { extras[$0] == nil }
            guard !open.isEmpty else { break }
            let total = open.reduce(0) { $0 + weights[$1] }
            // Within a point of all its rows: all of them, rather than a list that scrolls by a point.
            let fit = open.filter { items[$0].content - items[$0].least <= left * weights[$0] / total + 1 }
            guard fit.isEmpty else {
                for i in fit {
                    extras[i] = items[i].content - items[i].least
                    left -= items[i].content - items[i].least
                }
                continue
            }
            // Whole points, so rows sit on pixels; what rounding leaves goes to the first list that scrolls.
            for i in open { extras[i] = (left * weights[i] / total).rounded(.down) }
            scrolling = open
            break
        }
        if let first = scrolling.first {
            let used = items.indices.reduce(CGFloat(0)) { $0 + items[$1].least + max(0, extras[$1] ?? 0) }
            extras[first] = (extras[first] ?? 0) + max(0, (room - used).rounded(.down))
        }
        return items.indices.map { items[$0].least + max(0, extras[$0] ?? 0) }
    }

    /// Each list's weight: the kept one; a list with none weighs the mean of the kept ones, or an equal share of the
    /// room above the leasts when none is kept.
    static func weights(of items: [Item], room: CGFloat) -> [CGFloat] {
        let kept = items.compactMap(\.weight).filter { $0 > 0 }
        let leastTotal = items.reduce(0) { $0 + $1.least }
        let fallback = kept.isEmpty ? max(1, (room - leastTotal) / CGFloat(max(1, items.count))) : kept.reduce(0, +) / CGFloat(kept.count)
        return items.map { item in item.weight.flatMap { $0 > 0 ? $0 : nil } ?? fallback }
    }

    /// The heights after the edge above list `below` was dragged `delta` points down (up when negative) from where it
    /// was at `start`: the lists on the side it moves toward shrink and the ones on the other side grow, nearest first.
    static func dragged(_ start: [CGFloat], items: [Item], edgeAbove below: Int, by delta: CGFloat) -> [CGFloat] {
        guard start.count == items.count, below > 0, below < items.count, delta != 0 else { return start }
        let above = Array((0..<below).reversed())
        let under = Array(below..<items.count)
        let (growing, shrinking) = delta > 0 ? (above, under) : (under, above)
        func canGrow(_ i: Int) -> CGFloat { max(0, items[i].content - start[i]) }
        func canShrink(_ i: Int) -> CGFloat { max(0, start[i] - items[i].least) }
        let moved = min(abs(delta), growing.reduce(0) { $0 + canGrow($1) }, shrinking.reduce(0) { $0 + canShrink($1) })
        var heights = start
        var grow = moved, shrink = moved
        for i in growing where grow > 0 {
            let step = min(grow, canGrow(i))
            heights[i] += step
            grow -= step
        }
        for i in shrinking where shrink > 0 {
            let step = min(shrink, canShrink(i))
            heights[i] -= step
            shrink -= step
        }
        return heights
    }

    /// The weights that give `heights` again in a column `room` tall: a list that scrolls weighs what it has above its
    /// least, and one that shows all its rows keeps its weight, or that when it's more (so it still shows them all).
    static func weights(keeping heights: [CGFloat], items: [Item], room: CGFloat) -> [CGFloat] {
        let current = weights(of: items, room: room)
        return items.indices.map { i in
            let extra = max(0, heights[i] - items[i].least)
            let showsAll = heights[i] >= items[i].content - 0.5
            // Never 0: a list at its least still gets a little of a taller column.
            return max(1, showsAll ? max(current[i], extra) : extra)
        }
    }

    /// Which ways the edge above list `below` can go now: up when a list above it can shrink and one below it can
    /// grow, down the other way round.
    static func ways(_ heights: [CGFloat], items: [Item], edgeAbove below: Int) -> (up: Bool, down: Bool) {
        guard heights.count == items.count, below > 0, below < items.count else { return (false, false) }
        func grows(_ i: Int) -> Bool { heights[i] < items[i].content - 0.5 }
        func shrinks(_ i: Int) -> Bool { heights[i] > items[i].least + 0.5 }
        let above = 0..<below, under = below..<items.count
        return (up: above.contains(where: shrinks) && under.contains(where: grows),
                down: above.contains(where: grows) && under.contains(where: shrinks))
    }
}

/// The weights a column's lists were dragged to, by list, at actual size (as the panes keep their sizes, so a list
/// keeps its share at any zoom). In `UserDefaults.kaern` for every window, as "local=210.0,remote=480.0".
nonisolated struct StackedWeights: RawRepresentable, Equatable {
    static let sidebarKey = "KaernSidebarSections"
    static let changesKey = "KaernChangeLists"

    var values: [String: Double]

    init(_ values: [String: Double] = [:]) {
        self.values = values
    }

    init?(rawValue: String) {
        var values: [String: Double] = [:]
        for pair in rawValue.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, let value = Double(parts[1]), value > 0 { values[String(parts[0])] = value }
        }
        self.values = values
    }

    var rawValue: String {
        values.keys.sorted().map { "\($0)=\(values[$0] ?? 0)" }.joined(separator: ",")
    }

    /// A list's weight in points at the zoom now.
    func weight(_ id: String) -> CGFloat? {
        values[id].map { CGFloat($0) * UIScale.value }
    }

    /// `weights` (points at the zoom now) kept for the lists `ids`; the others keep theirs.
    func keeping(_ weights: [CGFloat], for ids: [String]) -> StackedWeights {
        var values = values
        for (id, weight) in zip(ids, weights) { values[id] = Double(weight / UIScale.value) }
        return StackedWeights(values)
    }
}

/// A column of stacked lists as laid out now, for its views and its edges.
struct StackedColumn {
    /// The lists shown with their rows, top to bottom.
    let ids: [String]
    let items: [StackedLists.Item]
    /// The column's height less the lists' headers.
    let room: CGFloat
    let heights: [CGFloat]

    init(ids: [String], items: [StackedLists.Item], room: CGFloat) {
        self.ids = ids
        self.items = items
        self.room = room
        heights = StackedLists.heights(items, room: room)
    }

    var overflows: Bool { StackedLists.overflows(items, room: room) }

    func height(_ id: String) -> CGFloat {
        ids.firstIndex(of: id).map { heights[$0] } ?? 0
    }

    /// The edge above list `below` (an index in `ids`), dragged `translation` points from where a drag that began at
    /// `start` found the lists: the weights that keep where it is now.
    func weights(dragging below: Int, from start: [CGFloat], by translation: CGFloat) -> [CGFloat] {
        let heights = StackedLists.dragged(start, items: items, edgeAbove: below, by: translation.rounded())
        return StackedLists.weights(keeping: heights, items: items, room: room)
    }
}

/// Where a drag of a column's edge began, and the lists' heights then. A press of its own starts over, even after a
/// drag that was cut short without ending.
@MainActor
final class StackedDrag {
    var start: (point: CGPoint, heights: [CGFloat])?

    /// The heights the drag that began at `point` started from.
    func heights(from point: CGPoint, now heights: [CGFloat]) -> [CGFloat] {
        if start?.point != point || start?.heights.count != heights.count { start = (point, heights) }
        return start?.heights ?? heights
    }
}

/// The edge between two stacked lists: 9 pt over the line between them, dragged up or down while there's room to
/// move (`StackedLists.ways`). A double-click puts the column's lists back to equal shares.
struct StackedEdge: View {
    /// The drag's start and how far it has gone down (up when negative).
    struct Change {
        let start: CGPoint
        let translation: CGFloat
    }

    let ways: (up: Bool, down: Bool)
    /// For VoiceOver ("Height of Local").
    let label: String
    /// Debug builds: whose edge it is (the repository's folder), for `DebugStacks.frames`.
    var scope = ""
    /// A drag's change, and nil when it ends.
    let drag: (Change?) -> Void
    let reset: () -> Void

    var body: some View {
        let active = ways.up || ways.down
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: z(9))
            .contentShape(Rectangle())
            .pointerStyle(active ? .rowResize(directions: ways.up && ways.down ? .all : ways.up ? .up : .down) : nil)
            .gesture(
                // Global: the edge moves with the lists while it's dragged.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag(Change(start: $0.startLocation, translation: $0.translation.height)) }
                    .onEnded { _ in drag(nil) }
            )
            .onTapGesture(count: 2, perform: reset)
            // Nothing to move: the line is just a line, and the rows under the band take the pointer.
            .allowsHitTesting(active)
            // Where it is after the offset below, which centers it on the line.
            .debugStackFrame("\(scope) edge \(label)")
            .offset(y: -z(4.5))
            .accessibilityHidden(!active)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAdjustableAction { direction in
                // Down makes the list above the edge taller.
                drag(Change(start: CGPoint(x: -1, y: -1), translation: direction == .increment ? 28 : -28))
                drag(nil)
            }
    }
}

#if DEBUG
/// Debug builds: the stacked lists as last laid out ("sidebar <folder>", "changes <folder>"), and where their scroll
/// views and edges are ("<folder> sidebar Local", window points, top-left origin), for the driver's dump. By the
/// repository's folder: a tab that isn't shown keeps its views, and they're laid out too.
@MainActor
enum DebugStacks {
    static var columns: [String: [[String: Any]]] = [:]
    static var frames: [String: CGRect] = [:]

    /// The frames of one repository's columns, without its folder in their names.
    static func frames(of folder: String) -> [String: [CGFloat]] {
        let prefix = folder + " "
        return frames.reduce(into: [:]) { result, item in
            if item.key.hasPrefix(prefix) {
                result[String(item.key.dropFirst(prefix.count))] = [item.value.minX, item.value.minY, item.value.width, item.value.height]
            }
        }
    }

    static func record(_ name: String, _ column: StackedColumn, shown: [String]) {
        columns[name] = shown.map { id in
            let index = column.ids.firstIndex(of: id)
            return ["name": id, "open": index != nil, "height": index.map { column.heights[$0] } ?? 0,
                    "content": index.map { column.items[$0].content } ?? 0, "room": column.room]
        }
    }
}

extension View {
    /// Debug builds: tells the driver where this part of a stacked column is (`DebugStacks.frames`).
    func debugStackFrame(_ key: String) -> some View {
        modifier(DebugFrameReport(key: "stack:\(key)") { DebugStacks.frames[key] = $0 })
    }
}
#else
extension View {
    func debugStackFrame(_ key: String) -> some View { self }
}
#endif
