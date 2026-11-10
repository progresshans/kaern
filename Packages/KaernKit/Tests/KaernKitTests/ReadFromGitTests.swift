import Foundation
import Testing
@testable import KaernKit

/// What the app read earlier (a branch name) can be older than the repository, or named another way,
/// by the time an action runs. These act on what git has then.
@Suite("Read from git when acting", .serialized)
struct ReadFromGitTests {
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
