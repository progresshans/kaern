import Foundation
import Testing
@testable import KaernKit

/// Picked lines across several hunks: staged, unstaged and discarded with one patch each.
@Suite("Line staging (integration)", .hangGuard)
struct LineStagingTests {
    /// 30 lines; the edit changes lines 3, 4 and 25, adds two after 12 and deletes 20.
    private static let base = (1...30).map { "line \($0)" }

    private static var edited: [String] {
        var lines = base
        lines[2] = "LINE 3"
        lines[3] = "LINE 4"
        lines[24] = "LINE 25"
        lines.remove(at: 19)                       // line 20
        lines.insert(contentsOf: ["new a", "new b"], at: 12)   // after line 12
        return lines
    }

    private func text(_ lines: [String]) -> String { lines.joined(separator: "\n") + "\n" }

    private func makeRepository() async throws -> GitRepository {
        let repository = try await TestRepositories.make()
        try repository.write(text(Self.base), to: "file.txt")
        try await repository.commitAll("base")
        try repository.write(text(Self.edited), to: "file.txt")
        return repository
    }

    /// Line ids of the changes whose text is in `texts`, per hunk.
    private func pick(_ diff: FileDiff, _ texts: Set<String>) -> [Int: Set<Int>] {
        var selection: [Int: Set<Int>] = [:]
        for hunk in diff.hunks {
            for line in hunk.lines where line.isChange && texts.contains(line.text) {
                selection[hunk.id, default: []].insert(line.id)
            }
        }
        return selection
    }

    private func indexText(_ repository: GitRepository) async throws -> String {
        try await repository.git(["show", ":file.txt"]).text
    }

    @Test func stagesPickedLinesFromSeveralHunks() async throws {
        let repository = try await makeRepository()
        defer { TestRepositories.remove(repository) }
        let diff = try #require(try await repository.workingDiff(path: "file.txt", staged: false))
        #expect(diff.hunks.count >= 2)
        // From the first hunk only the change of line 3; from a later one the new lines and line 25.
        let selection = pick(diff, ["line 3", "LINE 3", "new a", "new b", "line 25", "LINE 25"])
        #expect(selection.count >= 2)
        try await repository.stage(lines: selection, of: diff)

        var expected = Self.base
        expected[2] = "LINE 3"
        expected[24] = "LINE 25"
        expected.insert(contentsOf: ["new a", "new b"], at: 12)
        #expect(try await indexText(repository) == text(expected))
        // The working tree keeps every edit.
        #expect(repository.read("file.txt") == text(Self.edited))
    }

    @Test func unstagesPickedLinesOfTheStagedDiff() async throws {
        let repository = try await makeRepository()
        defer { TestRepositories.remove(repository) }
        try await repository.stage(["file.txt"])
        let staged = try #require(try await repository.workingDiff(path: "file.txt", staged: true))
        try await repository.unstage(lines: pick(staged, ["line 4", "LINE 4", "line 20", "new b"]), of: staged)

        var expected = Self.edited
        expected[3] = "line 4"                     // back to the old line 4
        expected.remove(at: 13)                    // "new b" leaves the index
        // Line 20 is back in the index, after line 19 (indices shift by the one new line kept).
        let at = try #require(expected.firstIndex(of: "line 19"))
        expected.insert("line 20", at: at + 1)
        #expect(try await indexText(repository) == text(expected))
        #expect(repository.read("file.txt") == text(Self.edited))
    }

    @Test func discardsPickedLinesAndPutsThemBack() async throws {
        let repository = try await makeRepository()
        defer { TestRepositories.remove(repository) }
        let diff = try #require(try await repository.workingDiff(path: "file.txt", staged: false))
        let result = try #require(try await repository.discardLines(pick(diff, ["line 3", "LINE 3", "line 20", "new a"]),
                                                                    of: diff, message: "Before discarding 3 lines"))
        var expected = Self.edited
        expected[2] = "line 3"
        expected.remove(at: 12)                    // "new a"
        let at = try #require(expected.firstIndex(of: "line 19"))
        expected.insert("line 20", at: at + 1)
        #expect(repository.read("file.txt") == text(expected))
        // A copy of the file's changes went to the stash list first.
        #expect(result.stash != nil)
        let stashes = try await repository.stashes()
        #expect(stashes.first?.message.hasSuffix("Before discarding 3 lines") == true)

        try await repository.restoreDiscardedLines(result.patch)
        #expect(repository.read("file.txt") == text(Self.edited))
    }

    @Test func refusesFilesThatOnlyStageWhole() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("a\n", to: "a.txt")
        try await repository.commitAll("base")
        try repository.write("new\n", to: "b.txt")
        try await repository.stage(["b.txt"])
        let diff = try #require(try await repository.workingDiff(path: "b.txt", staged: true))
        #expect(diff.stagesWholeFile)
        await #expect(throws: GitError.self) {
            try await repository.unstage(lines: [0: [0]], of: diff)
        }
    }

    @Test func patchNumbersFollowEarlierHunks() {
        // Two hunks; only additions are picked, so the second hunk's new start moves by two.
        let first = DiffHunk(id: 0, oldStart: 1, oldCount: 2, newStart: 1, newCount: 4, section: "", lines: [
            DiffLine(id: 0, kind: .context, text: "a", oldNumber: 1, newNumber: 1),
            DiffLine(id: 1, kind: .addition, text: "x", oldNumber: nil, newNumber: 2),
            DiffLine(id: 2, kind: .addition, text: "y", oldNumber: nil, newNumber: 3),
            DiffLine(id: 3, kind: .context, text: "b", oldNumber: 2, newNumber: 4),
        ])
        let second = DiffHunk(id: 1, oldStart: 10, oldCount: 2, newStart: 12, newCount: 1, section: "", lines: [
            DiffLine(id: 0, kind: .context, text: "c", oldNumber: 10, newNumber: 12),
            DiffLine(id: 1, kind: .deletion, text: "d", oldNumber: 11, newNumber: nil),
        ])
        let diff = FileDiff(path: "f", header: ["diff --git a/f b/f", "--- a/f", "+++ b/f"], hunks: [first, second])
        let patch = diff.patch(picking: [0: [1, 2], 1: [1]])
        #expect(patch == """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,2 +1,4 @@
         a
        +x
        +y
         b
        @@ -10,2 +12,1 @@
         c
        -d

        """)
        // Picking only the second hunk keeps its numbers unshifted.
        #expect(diff.patch(picking: [1: [1]])?.contains("@@ -10,2 +10,1 @@") == true)
        #expect(diff.patch(picking: [0: [], 1: []]) == nil)
    }
}
