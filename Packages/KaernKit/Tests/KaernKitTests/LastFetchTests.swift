import Foundation
import Testing
@testable import KaernKit

/// When a repository's remotes were last fetched: the status bar's "Fetched from origin …" and
/// the Repositories window's Fetched column.
@Suite("Last fetch", .hangGuard)
struct LastFetchTests {
    static let runner = RepositoryTests.runner

    private static func scratchFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "kaern-fetched-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func hasFetchHead(_ repository: GitRepository) -> Bool {
        FileManager.default.fileExists(atPath: repository.gitDirectory.appending(path: "FETCH_HEAD").path(percentEncoded: false))
    }

    /// `git clone` writes no FETCH_HEAD: until the first fetch, the clone is the last fetch. The
    /// working trees share the remote branches, so a fetch in one counts in another that hasn't
    /// fetched itself.
    @Test func aCloneCountsAsFetchedWhenItWasMade() async throws {
        let source = try await TestRepositories.make()
        defer { TestRepositories.remove(source) }
        try source.write("hello\n", to: "a.txt")
        try await source.commitAll("Base")
        let parent = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: parent) }

        // A reflog keeps whole seconds.
        let before = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
        let clone = try await GitRepository.clone("file://" + source.root.path(percentEncoded: false),
                                                  into: parent.appending(path: "copy"), runner: Self.runner)
        let after = Date.now
        #expect(!Self.hasFetchHead(clone))
        let cloned = try #require(clone.lastFetchDate)
        #expect(cloned >= before && cloned <= after)

        var linked: [GitRepository] = []
        for name in ["one", "two"] {
            try await clone.addWorktree(at: parent.appending(path: name), branch: name, newBranchFrom: "HEAD")
            linked.append(try await GitRepository.open(parent.appending(path: name), runner: Self.runner))
        }
        #expect(linked.map(\.lastFetchDate) == [cloned, cloned])

        // Each working tree's fetch writes a FETCH_HEAD of its own.
        try await clone.fetch()
        let fetched = try #require(clone.lastFetchDate)
        #expect(fetched >= cloned)
        #expect(linked.map(\.lastFetchDate) == [fetched, fetched])
        try await linked[0].fetch()
        #expect(Self.hasFetchHead(linked[0]) && !Self.hasFetchHead(linked[1]))
        let fetchedInOne = try #require(linked[0].lastFetchDate)
        #expect(fetchedInOne >= fetched)
        #expect(linked[1].lastFetchDate == fetchedInOne)
    }

    /// A remote that was added, even one pushed to, hasn't been fetched until a fetch.
    @Test func aRemoteThatWasNeverFetchedHasNoFetchDate() async throws {
        let parent = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let bare = parent.appending(path: "origin.git")
        try await Self.runner.run(["init", "-q", "--bare", "-b", "main", bare.path(percentEncoded: false)], in: nil)
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("hello\n", to: "a.txt")
        try await repository.commitAll("Base")
        #expect(repository.lastFetchDate == nil)
        try await repository.addRemote("origin", url: bare.path(percentEncoded: false))
        #expect(repository.lastFetchDate == nil)

        // Publishing writes origin/main without fetching.
        try await repository.git(["push", "-q", "-u", "origin", "main"])
        #expect(try await repository.git(["rev-parse", "--verify", "-q", "refs/remotes/origin/main"]).status == 0)
        #expect(repository.lastFetchDate == nil)

        try await repository.fetch()
        #expect(repository.lastFetchDate != nil)
    }

    @Test func readsTheLastCloneOrFetchInAReflog() {
        let zero = String(repeating: "0", count: 40), a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40)
        let reflog = """
            \(zero) \(a) Jane Q Doe <jane@kaern.invalid> 1700000000 +0900\tclone: from https://example.invalid/r.git
            \(a) \(b) Jane Q Doe <jane@kaern.invalid> 1700000500 +0900\tfetch --progress --prune --all: fast-forward
            \(b) \(a) Jane Q Doe <jane@kaern.invalid> 1700000900 -0500\tupdate by push

            """
        #expect(GitRepository.newestFetch(inReflog: reflog) == Date(timeIntervalSince1970: 1_700_000_500))
        let pulled = reflog + "\(a) \(b) Jane <jane@kaern.invalid> 1700001000 +0000\tpull --progress: fast-forward\n"
        #expect(GitRepository.newestFetch(inReflog: pulled) == Date(timeIntervalSince1970: 1_700_001_000))
        let setHead = "\(zero) \(a) Jane <jane@kaern.invalid> 1700000000 +0900\tclone: from /tmp/r.git\n"
            + "\(a) \(a) Jane <jane@kaern.invalid> 1700002000 +0900\tremote set-head\n"
        #expect(GitRepository.newestFetch(inReflog: setHead) == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(GitRepository.newestFetch(inReflog: "\(zero) \(a) Jane <jane@kaern.invalid> 1700000000 +0900\tupdate by push\n") == nil)
        #expect(GitRepository.newestFetch(inReflog: "") == nil)
    }
}
