import Foundation
import Testing
@testable import KaernKit

/// The git pieces behind ⌘Z: every step here must leave the repository exactly as it was.
@Suite("Undo plumbing (integration)")
struct UndoTests {
    private func makeRepository() async throws -> GitRepository {
        let repository = try await TestRepositories.make()
        try repository.write("one\ntwo\nthree\n", to: "a.txt")
        try repository.write("x\n", to: "b.txt")
        try await repository.commitAll("base")
        return repository
    }

    @Test func snapshotStashKeepsChangesAndIndexAsTheyWere() async throws {
        let repository = try await makeRepository()
        defer { TestRepositories.remove(repository) }
        try repository.write("one\ntwo\nthree\nfour\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        try repository.write("ONE\ntwo\nthree\nfour\n", to: "a.txt")      // partially staged
        try repository.write("y\n", to: "b.txt")                          // unstaged, not snapshotted
        try repository.write("new\n", to: "[draft].md")                   // untracked, glob-like name
        let before = try await repository.status()

        let object = try await repository.snapshotStash(paths: ["a.txt", "[draft].md"], message: "Before discarding", includeUntracked: true)
        #expect(object != nil)
        let after = try await repository.status()
        #expect(after.entries == before.entries)
        #expect(repository.read("a.txt") == "ONE\ntwo\nthree\nfour\n")
        let stashes = try await repository.stashes()
        #expect(stashes.first?.message.hasSuffix("Before discarding") == true)
        // The stash holds only the snapshotted paths.
        let files = try await repository.git(["stash", "show", "--include-untracked", "--name-only", "stash@{0}"]).text
        #expect(Set(files.split(separator: "\n").map(String.init)) == ["a.txt", "[draft].md"])
    }

    @Test func discardPatchesRoundTrip() async throws {
        let repository = try await makeRepository()
        defer { TestRepositories.remove(repository) }
        try repository.write("one\nTWO\nthree\n", to: "a.txt")
        let unstaged = try await repository.patch(paths: ["a.txt"], staged: false)
        try await repository.discardUnstaged(["a.txt"])
        #expect(repository.read("a.txt") == "one\ntwo\nthree\n")
        try await repository.apply(patchData: unstaged)
        #expect(repository.read("a.txt") == "one\nTWO\nthree\n")

        // A staged-only change comes back to both the index and the working tree.
        try await repository.stage(["a.txt"])
        let staged = try await repository.patch(paths: ["a.txt"], staged: true)
        try await repository.discardAll(["a.txt"])
        let cleaned = try await repository.status()
        #expect(cleaned.isClean)
        try await repository.apply(patchData: staged, index: true)
        let status = try await repository.status()
        #expect(status.entries.first?.stageState == .staged)
    }

    @Test func resetModesAndGoingBack() async throws {
        let repository = try await makeRepository()
        defer { TestRepositories.remove(repository) }
        let base = try #require(await repository.resolve("HEAD"))
        try repository.write("four\n", to: "c.txt")
        let second = try await repository.commitAll("second")
        let count = await repository.countCommits(from: base, to: second)
        let forward = await repository.isAncestor(base, of: second)
        let backward = await repository.isAncestor(second, of: base)
        #expect(count == 1)
        #expect(forward)
        #expect(!backward)

        try await repository.reset(to: base, mode: .soft)
        var status = try await repository.status()
        #expect(status.entries.first?.path == "c.txt")
        #expect(status.entries.first?.stageState == .staged)
        try await repository.reset(to: second, mode: .soft)
        status = try await repository.status()
        #expect(status.isClean)
        #expect(status.headID == second)

        // Hard reset with local changes: stash them first, then everything comes back.
        try repository.write("dirty\n", to: "b.txt")
        let stash = try #require(try await repository.stashAll(message: "Before reset to \(base.prefix(7))", includeUntracked: false))
        try await repository.reset(to: base, mode: .hard)
        #expect(repository.read("c.txt") == nil)
        try await repository.reset(to: second, mode: .hard)
        try await repository.popStash(object: stash)
        #expect(repository.read("b.txt") == "dirty\n")
        #expect(repository.read("c.txt") == "four\n")
    }

    @Test func droppedStashesAndDeletedTagsComeBack() async throws {
        let repository = try await makeRepository()
        defer { TestRepositories.remove(repository) }
        try repository.write("draft\n", to: "b.txt")
        try await repository.stash(message: "work in progress", includeUntracked: false)
        let stash = try #require(try await repository.stashes().first)
        try await repository.dropStash(stash)
        let empty = try await repository.stashes()
        #expect(empty.isEmpty)
        try await repository.storeStash(stash.id, message: stash.message)
        let restored = try await repository.stashes()
        #expect(restored.map(\.id) == [stash.id])
        #expect(restored.first?.message == stash.message)

        let head = try #require(await repository.resolve("HEAD"))
        try await repository.createTag("v1.0.0", at: head, message: "Annotated")
        let object = try #require(await repository.resolve("refs/tags/v1.0.0"))
        #expect(object != head)
        try await repository.deleteTag("v1.0.0")
        try await repository.restoreTag("v1.0.0", object: object)
        let back = await repository.resolve("refs/tags/v1.0.0")
        #expect(back == object)
    }
}
