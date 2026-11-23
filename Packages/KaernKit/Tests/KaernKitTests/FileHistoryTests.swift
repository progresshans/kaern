import Foundation
import Testing
@testable import KaernKit

@Suite("File history and blame", .hangGuard)
struct FileHistoryParsingTests {
    @Test func blameGroupsLinesByCommitAndRanksAges() {
        let old = String(repeating: "a", count: 40)
        let new = String(repeating: "b", count: 40)
        let none = String(repeating: "0", count: 40)
        let porcelain = """
        \(old) 1 1 2
        author Sungho Lee
        author-mail <sungho@example.com>
        author-time 1000
        author-tz +0900
        summary feat: add AlphaVersion
        filename Version.swift
        \timport Foundation
        \(old) 2 2
        \t
        \(new) 3 3 1
        author Han
        author-mail <han@example.com>
        author-time 2000
        summary fix: tag parsing
        previous \(old) Version.swift
        filename Version.swift
        \tstruct AlphaVersion {
        \(none) 4 4 1
        author Not Committed Yet
        author-mail <not.committed.yet>
        author-time 3000
        summary Version of Version.swift from Version.swift
        filename Version.swift
        \t    let number: Int
        \(old) 3 5 1
        \t}
        """
        let blame = BlameParser.parse(Data(porcelain.utf8))
        #expect(blame.lines.map(\.number) == [1, 2, 3, 4, 5])
        #expect(blame.lines[1].text == "")
        #expect(blame.chunks.map(\.lines) == [0 ..< 2, 2 ..< 3, 3 ..< 4, 4 ..< 5])
        #expect(blame.commits[old]?.author == "Sungho Lee")
        #expect(blame.commits[old]?.authorEmail == "sungho@example.com")
        #expect(blame.commits[new]?.previousID == old)
        #expect(blame.commits[new]?.previousPath == "Version.swift")
        #expect(blame.commits[none]?.isUncommitted == true)
        #expect(blame.ageLevels[old] == 0)
        #expect(blame.ageLevels[new] == 3)
        #expect(blame.ageLevels[none] == nil)
    }

    @Test func historyFollowsRenames() {
        let a = String(repeating: "1", count: 40), b = String(repeating: "2", count: 40), c = String(repeating: "3", count: 40)
        func header(_ id: String, _ subject: String) -> String { "\u{1E}\(id)\u{1F}\u{1F}T\u{1F}t@t\u{1F}100\u{1F}\(subject)\0" }
        let text = header(a, "edit new") + "\n1\t0\tnew.txt\0" + header(b, "rename") + "\n0\t0\t\0old.txt\0new.txt\0"
            + header(c, "add old") + "\n3\t0\told.txt\0"
        let entries = FileHistoryParser.parse(Data(text.utf8), path: "new.txt")
        #expect(entries.map(\.commit.subject) == ["edit new", "rename", "add old"])
        #expect(entries.map(\.path) == ["new.txt", "new.txt", "old.txt"])
        #expect(entries[1].oldPath == "old.txt")
        #expect(entries[0].stat == LineStat(additions: 1, deletions: 0))
    }

    @Test func remotePagesForCommits() throws {
        let github = try #require(RemoteURL("git@github.com:progresshans/powerlens.git"))
        #expect(github.commitPage("c92aa17")?.absoluteString == "https://github.com/progresshans/powerlens/commit/c92aa17")
        #expect(github.hostName == "GitHub")
        let gitlab = try #require(RemoteURL("https://gitlab.com/team/app"))
        #expect(gitlab.commitPage("abc")?.absoluteString == "https://gitlab.com/team/app/-/commit/abc")
    }
}

@Suite("File history and blame (integration)", .hangGuard)
struct FileHistoryTests {
    @Test func historyAndBlameOfARenamedFile() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("a\nb\nc\n", to: "old.txt")
        let added = try await repository.commitAll("add old", author: "Minji")
        try repository.write("a\nb2\nc\n", to: "old.txt")
        let edited = try await repository.commitAll("edit old", author: "Han")
        try await repository.git(["mv", "old.txt", "new.txt"])
        let renamed = try await repository.commitAll("rename")
        try repository.write("x\n", to: "other.txt")
        try await repository.commitAll("unrelated")

        let history = try await repository.fileHistory("new.txt")
        #expect(history.map(\.commit.id) == [renamed, edited, added])
        #expect(history.map(\.path) == ["new.txt", "old.txt", "old.txt"])
        #expect(history[0].oldPath == "old.txt")
        #expect(history[1].stat == LineStat(additions: 1, deletions: 1))

        // The working copy: one line changed and not committed yet.
        try repository.write("a\nb2\nc3\n", to: "new.txt")
        let blame = try await repository.blame("new.txt", at: nil, ignoreWhitespace: false, detectMoves: false)
        #expect(blame.lines.map(\.text) == ["a", "b2", "c3"])
        #expect(blame.lines.map(\.commitID) == [added, edited, String(repeating: "0", count: 40)])

        // Blame Before This Commit: the edited line as it was before "edit old", under the old name.
        let editedCommit = try #require(blame.commits[edited])
        #expect(editedCommit.previousID == added)
        #expect(editedCommit.previousPath == "old.txt")
        let before = try await repository.blame("old.txt", at: added, ignoreWhitespace: false, detectMoves: false)
        #expect(before.lines.map(\.text) == ["a", "b", "c"])
        #expect(Set(before.lines.map(\.commitID)) == [added])

        let commit = try await repository.commit(edited)
        #expect(commit.subject == "edit old")
        #expect(commit.parents == [added])
    }
}
