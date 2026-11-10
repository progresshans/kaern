import Foundation
import Testing
@testable import KaernKit

/// What Reset Hard puts aside before `git reset --hard`: git writes over (or deletes) untracked and
/// ignored files where the target commit has files, so they go into the stash with the changes.
@Suite("Reset Hard keeps what git would write over", .serialized)
struct ResetHardTests {
    /// A commit with notes.md, .env, the file `cache` and the folder `docs/`, and the next commit
    /// that removes them (and ignores .env): then they are made again by hand, the other way round
    /// for `cache` and `docs` (a folder where a file was, a file where a folder was).
    static func filesInTheWayOfTheCommitBefore() async throws -> (GitRepository, target: String) {
        let repository = try await TestRepositories.make()
        try repository.write("one\n", to: "a.txt")
        try repository.write("staged before\n", to: "s.txt")
        try repository.write("committed notes\n", to: "notes.md")
        try repository.write("TOKEN=committed\n", to: ".env")
        try repository.write("committed cache\n", to: "cache")
        try repository.write("committed doc\n", to: "docs/x.md")
        let target = try await repository.commitAll("everything")
        try await repository.git(["rm", "-q", "--cached", ".env"])
        try await repository.git(["rm", "-q", "-r", "notes.md", "cache", "docs"])
        try repository.write(".env\nnode_modules/\n", to: ".gitignore")
        try await repository.commitAll("remove them")
        // By hand, after that commit:
        try repository.write("TOKEN=my secret\n", to: ".env")                    // ignored, where the target has .env
        try repository.write("my notes\n", to: "notes.md")                       // untracked, where the target has notes.md
        try repository.write("in a folder\n", to: "cache/mine.txt")              // a folder where the target has a file
        try repository.write("a file\n", to: "docs")                             // a file where the target needs a folder
        try repository.write("not in the way\n", to: "scratch.txt")              // untracked, nothing in the target there
        try repository.write("dependency\n", to: "node_modules/x.js")            // ignored, nothing in the target there
        try repository.write("staged now\n", to: "s.txt")
        try await repository.stage(["s.txt"])
        try repository.write("one\nunstaged\n", to: "a.txt")
        return (repository, target)
    }

    @Test func untrackedAndIgnoredFilesInTheWayGoIntoTheStashAndComeBack() async throws {
        let (repository, target) = try await Self.filesInTheWayOfTheCommitBefore()
        defer { TestRepositories.remove(repository) }
        let head = try #require(await repository.resolve("HEAD"))
        #expect(try await repository.untrackedInTheWay(of: target) == [".env", "cache", "docs", "notes.md"])

        let stash = try #require(try await repository.stashBeforeHardReset(to: target, message: "Before reset"))
        // What isn't in the way stays.
        #expect(repository.read("scratch.txt") == "not in the way\n" && repository.read("node_modules/x.js") == "dependency\n")
        try await repository.reset(to: target, mode: .hard)
        #expect(repository.read(".env") == "TOKEN=committed\n" && repository.read("docs/x.md") == "committed doc\n")

        // ⌘Z: back to where the branch was, then the stash.
        try await repository.resetKeepingStaged(to: head)
        try await repository.popStash(object: stash)
        #expect(repository.read(".env") == "TOKEN=my secret\n")
        #expect(repository.read("notes.md") == "my notes\n")
        #expect(repository.read("cache/mine.txt") == "in a folder\n")
        #expect(repository.read("docs") == "a file\n")
        #expect(repository.read("a.txt") == "one\nunstaged\n")
        #expect(try await repository.git(["diff", "--cached", "--name-only"]).text.trimmingCharacters(in: .whitespacesAndNewlines) == "s.txt")
        #expect(try await repository.stashes().isEmpty)
    }

    @Test func withNothingInTheWayItStashesTheChangesAsBefore() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("one\n", to: "a.txt")
        let target = try await repository.commitAll("one")
        try repository.write("two\n", to: "a.txt")
        try await repository.commitAll("two")
        try repository.write("untracked\n", to: "u.txt")
        #expect(try await repository.untrackedInTheWay(of: target).isEmpty)
        #expect(try await repository.stashBeforeHardReset(to: target, message: "Before reset") == nil)
        try repository.write("three\n", to: "a.txt")
        let stash = try #require(try await repository.stashBeforeHardReset(to: target, message: "Before reset"))
        #expect(repository.read("a.txt") == "two\n" && repository.read("u.txt") == "untracked\n")
        #expect(try await repository.stashes().first?.id == stash)
    }
}
