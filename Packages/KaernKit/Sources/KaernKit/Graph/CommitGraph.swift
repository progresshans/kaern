import Foundation

/// A line between the centers of two consecutive rows of the history table.
public struct GraphEdge: Sendable, Hashable {
    /// Lane at the upper row's center.
    public var from: Int
    /// Lane at the lower row's center.
    public var to: Int
    /// Lane whose color the edge uses. Kaern colors by lane position (graph/lane-1…8).
    public var lane: Int
    /// The dashed link between the working-copy row and HEAD.
    public var dashed: Bool

    public init(from: Int, to: Int, lane: Int, dashed: Bool = false) {
        self.from = from
        self.to = to
        self.lane = lane
        self.dashed = dashed
    }

    /// Where an edge that changes lanes makes its turn. Fork and merge lines meet a commit node,
    /// never the line between two commits (GitKraken style).
    public enum Turn: Sendable, Hashable {
        /// Stays in its lane.
        case straight
        /// Leaves the side of the upper row's node and turns down into `to` (a merge's second
        /// parent): the elbow is drawn in the upper row, below the node's center.
        case leavesNode
        /// Comes down lane `from` and turns into the side of the lower row's node (a branch
        /// meeting the commit it grew from): the elbow is drawn in the lower row, above its center.
        case joinsNode
    }

    public var turn: Turn {
        if from == to { return .straight }
        // A merge edge takes its new lane right below the merge (`lane == to`); a lane that ends
        // keeps its own lane until it reaches the node it joins (`lane == from`).
        return lane == to ? .leavesNode : .joinsNode
    }
}

/// Everything needed to draw the graph cell of one row.
public struct GraphRow: Sendable, Hashable {
    /// Lane of the row's node.
    public var lane: Int
    public var isMerge: Bool
    public var isWorkingCopy: Bool
    /// Edges between the previous row and this row (drawn in this row's upper half).
    public var up: [GraphEdge]
    /// Edges between this row and the next row (drawn in this row's lower half).
    public var down: [GraphEdge]

    public init(lane: Int, isMerge: Bool, isWorkingCopy: Bool, up: [GraphEdge] = [], down: [GraphEdge] = []) {
        self.lane = lane
        self.isMerge = isMerge
        self.isWorkingCopy = isWorkingCopy
        self.up = up
        self.down = down
    }

    /// Number of lanes this row touches.
    public var width: Int {
        var result = lane + 1
        for edge in up { result = max(result, edge.from + 1, edge.to + 1) }
        for edge in down { result = max(result, edge.from + 1, edge.to + 1) }
        return result
    }
}

/// Assigns lanes to commits in display order (children before parents, as `git log --date-order`
/// produces) and builds the edges between rows.
///
/// Lanes keep their position until they end, so lines stay straight: a merge's line leaves the
/// side of the merge commit, and a branch comes down its own lane into the side of the commit it
/// grew from (see ``GraphEdge/turn``).
public struct CommitGraphBuilder: Sendable {
    private struct Slot: Sendable {
        var target: String
        var dashed: Bool
    }

    private struct Pending: Sendable {
        var from: Int
        var lane: Int
        var dashed: Bool
    }

    private var lanes: [Slot?] = []
    private var pending: [Pending] = []
    public private(set) var rows: [GraphRow] = []

    public init() {}

    /// Adds the working-copy row. Call before any commit.
    public mutating func appendWorkingCopy(head: String?) {
        append(id: "", parents: head.map { [$0] } ?? [], isWorkingCopy: true)
    }

    public mutating func append(_ commits: some Sequence<Commit>) {
        for commit in commits {
            append(id: commit.id, parents: commit.parents, isWorkingCopy: false)
        }
    }

    public mutating func append(id: String, parents: [String], isWorkingCopy: Bool = false) {
        // 1. The node takes the leftmost lane that was waiting for it, or the first free lane.
        let waiting = lanes.indices.filter { lanes[$0]?.target == id && !id.isEmpty }
        let nodeLane = waiting.first ?? firstFreeLane()

        // 2. Resolve the edges coming from the previous row.
        let up = pending.map { edge -> GraphEdge in
            let converges = lanes.indices.contains(edge.lane) && lanes[edge.lane]?.target == id && !id.isEmpty
            return GraphEdge(from: edge.from, to: converges ? nodeLane : edge.lane, lane: edge.lane, dashed: edge.dashed)
        }
        if !rows.isEmpty {
            rows[rows.count - 1].down = up
        }

        // 3. Lanes that ended at this node are free again.
        for lane in waiting where lane != nodeLane {
            lanes[lane] = nil
        }
        while lanes.count <= nodeLane {
            lanes.append(nil)
        }

        // 4. Continue lanes into the next row.
        var next: [Pending] = []
        for lane in lanes.indices where lane != nodeLane {
            if let slot = lanes[lane] {
                next.append(Pending(from: lane, lane: lane, dashed: slot.dashed))
            }
        }
        if let first = parents.first {
            lanes[nodeLane] = Slot(target: first, dashed: isWorkingCopy)
            next.append(Pending(from: nodeLane, lane: nodeLane, dashed: isWorkingCopy))
        } else {
            lanes[nodeLane] = nil
        }
        for parent in parents.dropFirst() {
            if let existing = lanes.firstIndex(where: { $0?.target == parent }) {
                next.append(Pending(from: nodeLane, lane: existing, dashed: false))
            } else {
                let lane = firstFreeLane()
                while lanes.count <= lane { lanes.append(nil) }
                lanes[lane] = Slot(target: parent, dashed: false)
                next.append(Pending(from: nodeLane, lane: lane, dashed: false))
            }
        }
        while let last = lanes.last, last == nil {
            lanes.removeLast()
        }
        pending = next.sorted { ($0.lane, $0.from) < ($1.lane, $1.from) }

        // Until the next row arrives, lines run straight down (parents may be on a later page).
        let provisional = pending.map { GraphEdge(from: $0.from, to: $0.lane, lane: $0.lane, dashed: $0.dashed) }
        rows.append(GraphRow(
            lane: nodeLane,
            isMerge: parents.count > 1,
            isWorkingCopy: isWorkingCopy,
            up: up,
            down: provisional
        ))
    }

    private func firstFreeLane() -> Int {
        lanes.firstIndex(where: { $0 == nil }) ?? lanes.count
    }
}
