import Foundation
import Testing
@testable import KaernKit

@Suite("Commit graph", .hangGuard)
struct GraphTests {
    private func commit(_ id: String, _ parents: [String]) -> Commit {
        Commit(id: id, parents: parents, author: Signature(name: "A", email: "a@example.com", date: .now), subject: id)
    }

    @Test func linearHistoryStaysInOneLane() {
        var builder = CommitGraphBuilder()
        builder.append([commit("c", ["b"]), commit("b", ["a"]), commit("a", [])])
        #expect(builder.rows.map(\.lane) == [0, 0, 0])
        #expect(builder.rows[0].up.isEmpty)
        #expect(builder.rows[0].down == [GraphEdge(from: 0, to: 0, lane: 0)])
        #expect(builder.rows[1].up == builder.rows[0].down)
        #expect(builder.rows[2].down.isEmpty)
    }

    @Test func mergeCurvesOutBelowAndForkCurvesInAbove() {
        // m merges f into main:  m(b, f) · f(a) · b(a) · a
        var builder = CommitGraphBuilder()
        builder.append([commit("m", ["b", "f"]), commit("f", ["a"]), commit("b", ["a"]), commit("a", [])])
        let rows = builder.rows
        #expect(rows.map(\.lane) == [0, 1, 0, 0])
        #expect(rows[0].isMerge)
        // Below the merge: main continues in lane 0, the second parent curves out to lane 1.
        #expect(rows[0].down.contains(GraphEdge(from: 0, to: 0, lane: 0)))
        #expect(rows[0].down.contains(GraphEdge(from: 0, to: 1, lane: 1)))
        // Above the fork point: lane 1 curves back into lane 0 with its own color.
        #expect(rows[3].up.contains(GraphEdge(from: 1, to: 0, lane: 1)))
        #expect(rows[3].up.contains(GraphEdge(from: 0, to: 0, lane: 0)))
        #expect(rows.map(\.width).max() == 2)
    }

    @Test func workingCopyLinksToHeadWithDashedLine() {
        // A newer commit on another branch sits between the working copy and HEAD.
        var builder = CommitGraphBuilder()
        builder.appendWorkingCopy(head: "h")
        builder.append([commit("x", ["h"]), commit("h", ["a"]), commit("a", [])])
        let rows = builder.rows
        #expect(rows[0].isWorkingCopy)
        #expect(rows[0].lane == 0)
        #expect(rows[1].lane == 1)
        #expect(rows[0].down == [GraphEdge(from: 0, to: 0, lane: 0, dashed: true)])
        #expect(rows[2].lane == 0)
        #expect(rows[2].up.contains(GraphEdge(from: 0, to: 0, lane: 0, dashed: true)))
        #expect(rows[2].up.contains(GraphEdge(from: 1, to: 0, lane: 1)))
        #expect(rows[2].down == [GraphEdge(from: 0, to: 0, lane: 0)])
    }

    @Test func pagesContinueTheLayout() {
        var whole = CommitGraphBuilder()
        let commits = [commit("d", ["c"]), commit("c", ["b"]), commit("b", ["a"]), commit("a", [])]
        whole.append(commits)

        var paged = CommitGraphBuilder()
        paged.append(commits.prefix(2))
        #expect(paged.rows.last?.down == [GraphEdge(from: 0, to: 0, lane: 0)])
        paged.append(commits.dropFirst(2))
        #expect(paged.rows == whole.rows)
    }
}
