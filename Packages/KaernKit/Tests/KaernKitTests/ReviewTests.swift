import Foundation
import Testing
@testable import KaernKit

@Suite("Body preview", .hangGuard)
struct BodyPreviewTests {
    @Test func collapsesWhiteSpaceIntoOneLine() {
        let body = "Write history in batches\nand recover the store\n\n  after a crash.\n"
        #expect(Commit.preview(ofBody: body) == "Write history in batches and recover the store after a crash.")
        #expect(Commit.preview(ofBody: "") == "")
        #expect(Commit.preview(ofBody: "\n\n") == "")
    }

    @Test func cutsLongBodies() {
        let body = String(repeating: "word ", count: 200)
        let preview = Commit.preview(ofBody: body)
        #expect(preview.count <= Commit.bodyPreviewLength + 1 && preview.count > Commit.bodyPreviewLength - 5)
        #expect(preview.hasSuffix("…"))
        #expect(!preview.contains("  "))
    }

    @Test func parsesRecordsWithAndWithoutBodies() {
        let sep = "\u{1F}"
        let withBody = ["a3f9c21aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "", "Minji Park", "minji@example.com", "1790000000",
                        "feat: reorganize settings navigation", "Group the sidebar by task\nand move release settings.\n"]
            .joined(separator: sep)
        let oldFormat = ["7b1e04dbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "", "Han Hyeonjin", "han@example.com", "1789000000", "fix: subject only"]
            .joined(separator: sep)
        let commits = LogParser.parse(Data((withBody + "\0" + oldFormat + "\0").utf8))
        #expect(commits.count == 2)
        #expect(commits[0].bodyPreview == "Group the sidebar by task and move release settings.")
        #expect(commits[0].subject == "feat: reorganize settings navigation")
        #expect(commits[1].bodyPreview.isEmpty)
    }
}

@Suite("Graph turns", .hangGuard)
struct GraphTurnTests {
    private func commit(_ id: String, _ parents: [String]) -> Commit {
        Commit(id: id, parents: parents, author: Signature(name: "A", email: "a@example.com", date: .now), subject: id)
    }

    /// The WindowBase board's history (newest first): three branches off the HEAD branch, three
    /// merged pull requests, a working copy on top.
    private var boardHistory: [Commit] {
        let parents: [Int: [Int]] = [
            0: [4], 1: [2], 2: [5], 3: [6], 4: [5], 5: [6], 6: [7], 7: [8], 8: [9], 9: [12, 10],
            10: [11], 11: [12], 12: [13], 13: [14], 14: [15], 15: [17, 16], 16: [17], 17: [18],
            18: [19], 19: [20], 20: [21], 21: [22], 22: [25, 23], 23: [24], 24: [25], 25: [],
        ]
        return (0...25).map { row in commit("c\(row)", parents[row]!.map { "c\($0)" }) }
    }

    @Test func layoutMatchesTheBoard() {
        var builder = CommitGraphBuilder()
        builder.appendWorkingCopy(head: "c1")
        builder.append(boardHistory)
        let lanes = builder.rows.dropFirst().map(\.lane)
        // The board's `lanes` map: rows 0, 4, 10, 11, 16, 23, 24 on lane 1, row 3 on lane 2.
        let expected = (0...25).map { row -> Int in
            [0, 4, 10, 11, 16, 23, 24].contains(row) ? 1 : (row == 3 ? 2 : 0)
        }
        #expect(Array(lanes) == expected)
    }

    /// Canvas v54: fork and merge lines meet a commit node, never the line between two commits.
    @Test func forksAndMergesMeetACommitNode() {
        var builder = CommitGraphBuilder()
        builder.appendWorkingCopy(head: "c1")
        builder.append(boardHistory)
        let rows = builder.rows
        var leaves = 0
        var joins = 0
        for index in rows.indices.dropLast() {
            let upper = rows[index], lower = rows[index + 1]
            #expect(upper.down == lower.up)
            for edge in upper.down {
                switch edge.turn {
                case .straight:
                    #expect(edge.from == edge.to)
                case .leavesNode:
                    // A merge's line starts at the side of the merge commit…
                    #expect(edge.from == upper.lane)
                    #expect(upper.isMerge)
                    leaves += 1
                case .joinsNode:
                    // …and a branch ends at the side of the commit it grew from.
                    #expect(edge.to == lower.lane)
                    joins += 1
                }
            }
        }
        // Three merges leave a node; five branches (three merged, two open) join one.
        #expect(leaves == 3)
        #expect(joins == 5)
    }

    @Test func mergeIntoAFreeLaneOnTheLeftStillLeavesTheNode() {
        // Lane 0 ends at the root q before m (on lane 1) needs a lane for its second parent, so
        // the merge turns left into lane 0.
        var builder = CommitGraphBuilder()
        builder.append([
            commit("p", ["q"]),        // lane 0
            commit("k", ["m"]),        // lane 1
            commit("q", []),           // lane 0 ends here
            commit("m", ["y", "z"]),   // lane 1; z takes the free lane 0
            commit("z", ["y"]),
            commit("y", []),
        ])
        let rows = builder.rows
        #expect(rows.map(\.lane) == [0, 1, 0, 1, 0, 0])
        let mergeEdges = rows[3].down.filter { $0.turn == .leavesNode }
        #expect(mergeEdges == [GraphEdge(from: 1, to: 0, lane: 0)])
        for index in rows.indices.dropLast() {
            for edge in rows[index].down where edge.turn == .joinsNode {
                #expect(edge.to == rows[index + 1].lane)
            }
            for edge in rows[index].down where edge.turn == .leavesNode {
                #expect(edge.from == rows[index].lane)
            }
        }
    }

    @Test func pageEndKeepsTheMergeTurn() {
        // The second parent isn't loaded yet: the provisional edge still leaves the merge node.
        var builder = CommitGraphBuilder()
        builder.append([commit("m", ["a", "b"])])
        #expect(builder.rows[0].down.contains(GraphEdge(from: 0, to: 1, lane: 1)))
        #expect(builder.rows[0].down.first { $0.lane == 1 }?.turn == .leavesNode)
    }
}

@Suite("Diff segments", .hangGuard)
struct DiffSegmentTests {
    @Test func marksOnlyTheFileThatIsNotUTF8AsLossy() {
        var data = Data("""
        diff --git a/a.txt b/a.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -old
        +new
        diff --git a/b.txt b/b.txt
        index 3333333..4444444 100644
        --- a/b.txt
        +++ b/b.txt
        @@ -1 +1 @@
        -caf
        """.utf8)
        data.append(contentsOf: [0x65, 0xE9, 0x0A]) // "eé" in Latin-1: not valid UTF-8
        data.append(contentsOf: Array("+cafe\n".utf8))
        let files = DiffParser.parse(data)
        #expect(files.map(\.path) == ["a.txt", "b.txt"])
        #expect(files[0].isLossy == false)
        #expect(files[0].supportsPartialPatches)
        #expect(files[1].isLossy)
        #expect(files[0].hunks.first?.lines.map(\.text) == ["old", "new"])
    }
}

/// Real git against throwaway repositories, isolated from the user's config.
@Suite("Review diffs and hunk staging (integration)", .hangGuard)
struct ReviewIntegrationTests {
    private func makeRepository() async throws -> GitRepository {
        try await TestRepositories.make()
    }

    private let twoHunks = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"

    @Test func logCarriesTheBodyPreview() async throws {
        let repository = try await makeRepository()
        defer { TestRepositories.remove(repository) }
        try repository.write("a\n", to: "a.txt")
        try await repository.stageAll()
        try await repository.commit(message: "feat: subject\n\nFirst line of the body\nsecond line.", amend: false)
        let log = try await repository.log(skip: 0, limit: 10, includeHEAD: true)
        #expect(log.first?.subject == "feat: subject")
        #expect(log.first?.bodyPreview == "First line of the body second line.")
    }

    @Test func loadsEveryFileOfACommitAndOfTheWorkingCopy() async throws {
        let repository = try await makeRepository()
        defer { TestRepositories.remove(repository) }
        try repository.write("a\n", to: "a.txt")
        try repository.write("b\n", to: "dir/b.txt")
        let root = try await repository.commitAll("root")
        try repository.write("a2\n", to: "a.txt")
        try repository.write("c\n", to: "c.txt")
        let second = try await repository.commitAll("second")

        let rootCommit = try await repository.commit(root)
        let rootDiffs = try await repository.diffs(of: rootCommit)
        #expect(Set(rootDiffs.map(\.path)) == ["a.txt", "dir/b.txt"])
        #expect(rootDiffs.allSatisfy { $0.isNewFile })

        let secondDiffs = try await repository.diffs(of: try await repository.commit(second))
        #expect(secondDiffs.map(\.path) == ["a.txt", "c.txt"])
        #expect(secondDiffs[0].additions == 1 && secondDiffs[0].deletions == 1)

        try repository.write("a3\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        try repository.write("b2\n", to: "dir/b.txt")
        try repository.write("new\nfile", to: "new.txt")
        let staged = try await repository.workingDiffs(staged: true)
        let unstaged = try await repository.workingDiffs(staged: false)
        #expect(staged.map(\.path) == ["a.txt"])
        #expect(unstaged.map(\.path) == ["dir/b.txt"])

        let untracked = repository.untrackedFileDiff(path: "new.txt")
        #expect(untracked.isNewFile)
        #expect(untracked.hunks.first?.lines.filter { $0.kind == .addition }.map(\.text) == ["new", "file"])
        #expect(untracked.hunks.first?.lines.last?.kind == .noNewline)
    }

    @Test func stagesAndUnstagesOneHunk() async throws {
        let repository = try await makeRepository()
        defer { TestRepositories.remove(repository) }
        try repository.write(twoHunks, to: "f.txt")
        try await repository.commitAll("base")
        let edited = twoHunks.replacingOccurrences(of: "line 2\n", with: "line two\n")
            .replacingOccurrences(of: "line 28\n", with: "line twenty-eight\n")
        try repository.write(edited, to: "f.txt")

        let unstaged = try #require(try await repository.workingDiffs(staged: false).first)
        #expect(unstaged.hunks.count == 2)
        try await repository.stage(hunk: unstaged.hunks[1].id, of: unstaged)

        let staged = try #require(try await repository.workingDiffs(staged: true).first)
        #expect(staged.hunks.count == 1)
        #expect(staged.hunks[0].lines.contains { $0.text == "line twenty-eight" && $0.kind == .addition })
        let rest = try #require(try await repository.workingDiffs(staged: false).first)
        #expect(rest.hunks.count == 1)
        #expect(rest.hunks[0].lines.contains { $0.text == "line two" && $0.kind == .addition })

        try await repository.unstage(hunk: staged.hunks[0].id, of: staged, hasHead: true)
        #expect(try await repository.workingDiffs(staged: true).isEmpty)
        #expect(try await repository.workingDiffs(staged: false).first?.hunks.count == 2)
    }

    @Test func stagesNewAndDeletedFilesWhole() async throws {
        let repository = try await makeRepository()
        defer { TestRepositories.remove(repository) }
        try repository.write("keep\n", to: "old.txt")
        try await repository.commitAll("base")
        try FileManager.default.removeItem(at: repository.root.appending(path: "old.txt"))
        try repository.write("one\ntwo\n", to: "new.txt")

        let untracked = repository.untrackedFileDiff(path: "new.txt")
        #expect(untracked.stagesWholeFile)
        try await repository.stage(hunk: 0, of: untracked)
        let deleted = try #require(try await repository.workingDiffs(staged: false).first { $0.path == "old.txt" })
        #expect(deleted.isDeletedFile)
        try await repository.stage(hunk: 0, of: deleted)

        let status = try await repository.status()
        #expect(status.entries.first { $0.path == "new.txt" }?.stageState == .staged)
        #expect(status.entries.first { $0.path == "old.txt" }?.stageState == .staged)

        let staged = try await repository.workingDiffs(staged: true)
        for diff in staged {
            try await repository.unstage(hunk: 0, of: diff, hasHead: true)
        }
        #expect(try await repository.status().stagedCount == 0)
    }
}

@Suite("Line stats (integration)", .hangGuard)
struct LineStatTests {
    @Test func keepsStagedAndUnstagedApart() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write((1...20).map { "line \($0)" }.joined(separator: "\n") + "\n", to: "f.txt")
        try await repository.commitAll("base")
        try repository.write((1...20).map { $0 == 2 ? "two" : "line \($0)" }.joined(separator: "\n") + "\n", to: "f.txt")
        try await repository.stage(["f.txt"])
        try repository.write((1...20).map { $0 == 2 ? "two" : ($0 == 19 ? "nineteen\nextra" : "line \($0)") }.joined(separator: "\n") + "\n", to: "f.txt")
        try repository.write("a\nb\nc\n", to: "new.txt")
        let stats = await repository.stagedAndUnstagedLineStats(untracked: ["new.txt"])
        #expect(stats.staged["f.txt"] == LineStat(additions: 1, deletions: 1))
        #expect(stats.unstaged["f.txt"] == LineStat(additions: 2, deletions: 1))
        #expect(stats.unstaged["new.txt"] == LineStat(additions: 3, deletions: 0))
        #expect(stats.staged["new.txt"] == nil)
    }
}
