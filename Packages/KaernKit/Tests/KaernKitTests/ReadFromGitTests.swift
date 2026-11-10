import Foundation
import Testing
@testable import KaernKit

/// What the app read earlier (a stash list, a branch name) can be older than the repository by the
/// time an action runs. These act on what git has then.
@Suite("Read from git when acting", .serialized)
struct ReadFromGitTests {
    /// One stash ("first", changing a.txt) read into a list, then a second one made after the list
    /// was read ("second", changing b.txt): the first is stash@{1} by now, while the list read
    /// earlier still calls it stash@{0}.
    static func secondStashMadeAfterTheListWasRead() async throws -> (GitRepository, seen: Stash) {
        let repository = try await TestRepositories.make()
        try repository.write("a\n", to: "a.txt")
        try repository.write("b\n", to: "b.txt")
        try await repository.commitAll("base")
        try repository.write("a first\n", to: "a.txt")
        try await repository.stash(message: "first", includeUntracked: false)
        let seen = try #require(try await repository.stashes().first)
        try repository.write("b second\n", to: "b.txt")
        try await repository.stash(message: "second", includeUntracked: false)
        return (repository, seen)
    }

    static func messages(_ repository: GitRepository) async throws -> [String] {
        try await repository.stashes().map(\.message)
    }

    @Test func dropTakesThePickedStashNotTheOneNowAtItsNumber() async throws {
        let (repository, seen) = try await Self.secondStashMadeAfterTheListWasRead()
        defer { TestRepositories.remove(repository) }
        #expect(seen.reference == "stash@{0}")
        try await repository.dropStash(seen)
        let left = try await Self.messages(repository)
        #expect(left.count == 1 && left[0].hasSuffix("second"), "\(left)")
    }

    @Test func popTakesThePickedStash() async throws {
        let (repository, seen) = try await Self.secondStashMadeAfterTheListWasRead()
        defer { TestRepositories.remove(repository) }
        try await repository.applyStash(seen, pop: true)
        #expect(repository.read("a.txt") == "a first\n" && repository.read("b.txt") == "b\n")
        let left = try await Self.messages(repository)
        #expect(left.count == 1 && left[0].hasSuffix("second"), "\(left)")
    }

    @Test func branchFromStashTakesThePickedStash() async throws {
        let (repository, seen) = try await Self.secondStashMadeAfterTheListWasRead()
        defer { TestRepositories.remove(repository) }
        try await repository.createBranch("from-first", from: seen)
        #expect(await repository.currentBranchName() == "from-first")
        #expect(repository.read("a.txt") == "a first\n" && repository.read("b.txt") == "b\n")
        let left = try await Self.messages(repository)
        #expect(left.count == 1 && left[0].hasSuffix("second"), "\(left)")
    }

    @Test func aStashThatIsGoneIsNotReplacedByAnother() async throws {
        let (repository, seen) = try await Self.secondStashMadeAfterTheListWasRead()
        defer { TestRepositories.remove(repository) }
        // The picked one is dropped elsewhere (Terminal): what is stash@{0} now must stay.
        try await repository.git(["stash", "drop", "-q", "stash@{1}"])
        await #expect(throws: GitError.self) { try await repository.dropStash(seen) }
        await #expect(throws: GitError.self) { try await repository.applyStash(seen, pop: true) }
        let left = try await Self.messages(repository)
        #expect(left.count == 1 && left[0].hasSuffix("second"), "\(left)")
        #expect(repository.read("b.txt") == "b\n")
    }

    @Test func anInteractiveRebaseKeepsACommitMadeAfterItsListWasRead() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("a\n", to: "a.txt")
        let base = try await repository.commitAll("base")
        try repository.write("b\n", to: "b.txt")
        try await repository.commitAll("second")
        let steps = try await repository.commitsToRebase(onto: base).map { RebaseStep(commit: $0) }
        try repository.write("c\n", to: "c.txt")
        let made = try await repository.commitAll("made after the list was read")
        // git would drop the commit the list doesn't have: nothing is rebased.
        await #expect(throws: GitError.self) { _ = try await repository.interactiveRebase(onto: base, steps: steps, autostash: false) }
        #expect(await repository.resolve("HEAD") == made)
        #expect(repository.operationState() == nil)
        // With the list read again it goes ahead.
        let again = try await repository.commitsToRebase(onto: base).map { RebaseStep(commit: $0) }
        #expect(try await repository.interactiveRebase(onto: base, steps: again, autostash: false) == .finished)
        #expect(repository.read("c.txt") == "c\n")
    }

    @Test func theBranchNameIsTheBranchsWhenATagHasTheSameName() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("a\n", to: "a.txt")
        try await repository.commitAll("base")
        try await repository.git(["switch", "-q", "-c", "release/1.2"])
        // git shortens the branch to "heads/release/1.2" when a tag has its name; git status
        // (and so the app) calls it "release/1.2".
        try await repository.git(["tag", "release/1.2"])
        #expect(await repository.currentBranchName() == "release/1.2")
        #expect(try await repository.status().branch == "release/1.2")
        try await repository.git(["switch", "-q", "--detach", "HEAD"])
        #expect(await repository.currentBranchName() == nil)
    }
}
