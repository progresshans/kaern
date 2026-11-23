import Foundation
import Testing
@testable import KaernKit

@Suite("Stashes (integration)", .hangGuard)
struct StashTests {
    @Test func branchNameFromTheMessage() {
        #expect(StashDetails.branch(fromMessage: "On develop: release notes draft") == "develop")
        #expect(StashDetails.branch(fromMessage: "WIP on feature/x: 1d77f5b chore: bump") == "feature/x")
        #expect(StashDetails.branch(fromMessage: "Before reset to c92aa17") == nil)
    }

    @Test func detailsListTrackedAndUntrackedChanges() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("# Changelog\n\n## 1.0\n", to: "docs/CHANGELOG.md")
        let base = try await repository.commitAll("add changelog")
        try repository.write("# Changelog\n\n## Unreleased\n- Fixed\n\n## 1.0\n", to: "docs/CHANGELOG.md")
        try repository.write("notes\n", to: "docs/release-notes/0.9.4.md")
        try await repository.stash(message: "release notes draft", includeUntracked: true)
        let stash = try #require(try await repository.stashes().first)

        let details = try await repository.stashDetails(stash)
        #expect(details.baseID == base)
        #expect(details.branch == "main")
        #expect(details.includesUntracked)
        #expect(details.files.map(\.path) == ["docs/CHANGELOG.md", "docs/release-notes/0.9.4.md"])
        #expect(details.files[0].lineStat == LineStat(additions: 3, deletions: 0))
        #expect(details.files[1].isNewFile)
        #expect(details.untrackedPaths == ["docs/release-notes/0.9.4.md"])
    }

    @Test func undoingAnApplyPutsTheWorkingTreeBack() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("a\n", to: "a.txt")
        try repository.write("b\n", to: "b.txt")
        try await repository.commitAll("first")
        try repository.write("a stashed\n", to: "a.txt")
        try await repository.stash(message: "stashed", includeUntracked: false)
        // Something else was going on in the working tree before applying.
        try repository.write("b edited\n", to: "b.txt")
        try await repository.stage(["b.txt"])
        let before = await repository.stashCreate()
        #expect(before != nil)
        let stash = try #require(try await repository.stashes().first)
        try await repository.applyStash(stash, pop: false)
        #expect(repository.read("a.txt") == "a stashed\n")

        // What ⌘Z does: back to HEAD, then the state from before the apply.
        try await repository.reset(to: "HEAD", mode: .hard)
        try await repository.applyStash(object: try #require(before))
        #expect(repository.read("a.txt") == "a\n")
        #expect(repository.read("b.txt") == "b edited\n")
        let status = try await repository.status()
        #expect(status.entries.first { $0.path == "b.txt" }?.hasStagedChanges == true)
    }

    @Test func branchFromStash() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("a\n", to: "a.txt")
        try await repository.commitAll("first")
        try repository.write("a changed\n", to: "a.txt")
        try await repository.stash(message: "idea", includeUntracked: false)
        let stash = try #require(try await repository.stashes().first)
        try await repository.createBranch("idea", from: stash)
        #expect(try await repository.status().branch == "idea")
        #expect(repository.read("a.txt") == "a changed\n")
        #expect(try await repository.stashes().isEmpty)
    }
}
