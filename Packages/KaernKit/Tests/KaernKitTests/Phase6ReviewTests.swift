import Foundation
import Testing
@testable import KaernKit

/// The problems the phase-6 review found: Remove… losing ignored files or acting on the wrong
/// folder, changes left in the stash list after a stop, index undo after folder staging, remote
/// branches with names a bracket pattern can't match, and long signature reads.
@Suite("Phase 6 review", .serialized, .hangGuard)
struct Phase6ReviewTests {
    static let runner = RepositoryTests.runner

    static func repositoryWithWorktree() async throws -> (GitRepository, URL) {
        let repository = try await TestRepositories.make()
        try repository.write("*.env\nbuild/\n", to: ".gitignore")
        try repository.write("one\n", to: "a.txt")
        try await repository.commitAll("one")
        try await repository.createBranch("hotfix", startPoint: nil, checkout: false)
        let folder = FileManager.default.temporaryDirectory.appending(path: "kaern-wt-\(UUID().uuidString)", directoryHint: .isDirectory)
        try await repository.addWorktree(at: folder, branch: "hotfix", newBranchFrom: nil)
        return (repository, folder)
    }

    @Test func removingAWorktreePutsItsIgnoredFilesInTheTrashAndUndoBringsThemBack() async throws {
        let (repository, folder) = try await Self.repositoryWithWorktree()
        defer { TestRepositories.remove(repository); try? FileManager.default.removeItem(at: folder) }
        let worktree = try await GitRepository.open(folder, runner: Self.runner)
        try worktree.write("SECRET=1\n", to: "local.env")
        try worktree.write("artifact\n", to: "build/out.bin")
        try worktree.write("one\nchanged\n", to: "a.txt")
        #expect(Set(await worktree.ignoredItems()) == ["local.env", "build"])

        let path = folder.path(percentEncoded: false)
        let removed = try await repository.removeWorktree(path, keepingChangesAs: "Worktree test")
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(removed.stash != nil && removed.branch == "hotfix")
        #expect(Set(removed.trashed.map(\.path)) == ["local.env", "build"])
        #expect(removed.trashed.allSatisfy { FileManager.default.fileExists(atPath: $0.trashURL.path(percentEncoded: false)) })

        // ⌘Z: the worktree, its change and its ignored files come back (and leave the Trash).
        try await repository.addWorktree(at: folder, branch: "hotfix", newBranchFrom: nil)
        let back = try await GitRepository.open(folder, runner: Self.runner)
        #expect(GitRepository.putBack(removed.trashed, into: back.root) == 0)
        try await back.popStash(object: try #require(removed.stash))
        #expect(back.read("local.env") == "SECRET=1\n" && back.read("build/out.bin") == "artifact\n")
        #expect(back.read("a.txt") == "one\nchanged\n")
    }

    @Test func removalRefusesTheMainTreeAFolderInsideAndCommitsOnNoBranch() async throws {
        let (repository, folder) = try await Self.repositoryWithWorktree()
        defer { TestRepositories.remove(repository); try? FileManager.default.removeItem(at: folder) }
        let main = repository.root.path(percentEncoded: false)
        await #expect(throws: WorktreeRefusal.self) { _ = try await repository.removeWorktree(main, keepingChangesAs: "x") }
        // Seen from the linked tree, the main one is still refused.
        let linked = try await GitRepository.open(folder, runner: Self.runner)
        await #expect(throws: WorktreeRefusal.self) { _ = try await linked.removeWorktree(main, keepingChangesAs: "x") }
        // A folder inside a working tree isn't one.
        try linked.write("x\n", to: "docs/x.txt")
        await #expect(throws: WorktreeRefusal.self) {
            _ = try await repository.removeWorktree(folder.appending(path: "docs").path(percentEncoded: false), keepingChangesAs: "x")
        }
        try FileManager.default.removeItem(at: folder.appending(path: "docs"))
        // A detached HEAD with a commit no branch holds.
        try await linked.git(["switch", "-q", "--detach"])
        try linked.write("detached\n", to: "a.txt")
        _ = try await linked.commitAll("on no branch")
        await #expect(throws: WorktreeRefusal.self) {
            _ = try await repository.removeWorktree(folder.path(percentEncoded: false), keepingChangesAs: "x")
        }
        // Nothing changed: no stash, the worktree is still there.
        #expect(try await repository.stashes().isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "a.txt").path(percentEncoded: false)))
        #expect(await repository.worktrees().first?.isMain == true)
        #expect(await repository.worktrees().dropFirst().allSatisfy { !$0.isMain })
    }

    @Test func aLockedWorktreeStaysUntilItIsUnlocked() async throws {
        let (repository, folder) = try await Self.repositoryWithWorktree()
        defer { TestRepositories.remove(repository); try? FileManager.default.removeItem(at: folder) }
        let path = folder.path(percentEncoded: false)
        try await repository.lockWorktree(path)
        #expect(await repository.worktrees().last?.isLocked == true)
        // git leaves it alone, and Remove… loses nothing on the way.
        await #expect(throws: (any Error).self) { _ = try await repository.removeWorktree(path, keepingChangesAs: "x") }
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try await repository.stashes().isEmpty)
        // The main working tree can't be locked.
        await #expect(throws: (any Error).self) { try await repository.lockWorktree(repository.root.path(percentEncoded: false)) }
        try await repository.unlockWorktree(path)
        #expect(await repository.worktrees().last?.isLocked == false)
        _ = try await repository.removeWorktree(path, keepingChangesAs: "x")
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func aStopPutsTheChangesBackOrKeepsThemForTheOperation() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("one\n", to: "a.txt")
        try await repository.commitAll("one")
        try repository.write("one\nmine\n", to: "a.txt")
        try await repository.stage(["a.txt"])

        // The work is stopped (Cancel): the changes come back staged, though the task is cancelled.
        let task = Task {
            try await repository.withChangesStashed(message: "Before Test") {
                // Long work: left alone it takes five minutes, so the stop below always comes first.
                try await Task.sleep(for: .seconds(300))
                return .finished
            }
        }
        // Wait until the changes are in the stash list (the work is sleeping), then stop it.
        try await waitUntil { (try? await repository.stashes())?.isEmpty == false }
        #expect(try await repository.stashes().count == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await repository.stashes().isEmpty)
        #expect(repository.read("a.txt") == "one\nmine\n")
        #expect(try await repository.git(["diff", "--cached", "--name-only"]).text.contains("a.txt"))
    }

    @Test func folderUndoRestoresEverythingTheCommandChanged() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("a\n", to: "src/a.txt")
        try await repository.commitAll("one")
        // A rename out of the folder is staged; a nested repository sits untracked in tools/.
        try FileManager.default.createDirectory(at: repository.root.appending(path: "lib"), withIntermediateDirectories: true)
        try await repository.git(["mv", "src/a.txt", "lib/a.txt"])
        let nested = repository.root.appending(path: "tools/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try await Self.runner.run(["init", "-q"], in: nested)
        try "x\n".write(to: nested.appending(path: "x.txt"), atomically: true, encoding: .utf8)
        try await Self.runner.run(["add", "x.txt"], in: nested)
        try await Self.runner.run(["-c", "user.name=T", "-c", "user.email=t@t.invalid", "commit", "-q", "-m", "x"], in: nested)

        for (folder, work) in [("src/", ["reset", "-q", "--", "src/"]), ("tools/", ["add", "--", "tools/"])] {
            let before = try #require(await repository.writeIndexTree())
            _ = try await repository.git(work)
            let after = try #require(await repository.writeIndexTree())
            #expect(before != after)
            try await repository.restoreIndex(paths: [folder], from: before)
            #expect(await repository.writeIndexTree() == before, "⌘Z of \(folder) restores the index")
            #expect(await repository.indexMatches(before, paths: [folder]))
            try await repository.restoreIndex(paths: [folder], from: after)
            #expect(await repository.writeIndexTree() == after, "⇧⌘Z of \(folder) does it again")
            try await repository.restoreIndex(paths: [folder], from: before)
        }
    }

    @Test func ignoreEditsKnowWhatTheyWrote() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        let edit = try repository.addIgnorePattern("charts/vendor/")
        #expect(repository.ignoreFileContents() == edit.written)
        try repository.write("charts/vendor/\n.env\n", to: ".gitignore")
        #expect(repository.ignoreFileContents() != edit.written)
    }

    @Test func remoteBranchesWithAnyNameReadExactly() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("a\n", to: "a.txt")
        try await repository.commitAll("base")
        var expected: [String: String] = [:]
        for name in ["기능/한글", "café", "ends!", "main", "main-other"] {
            try repository.write("\(name)\n", to: "a.txt")
            let id = try await repository.commitAll("on \(name)")
            try await repository.git(["update-ref", "refs/remotes/origin/\(name)", id])
            expected[name] = id
        }
        for name in ["기능/한글", "café", "ends!", "main"] {
            let arguments = ["log", "--format=%H"] + GitRepository.revisionArguments(for: .local(remoteBranches: ["origin/\(name)"]), head: .leftOut)
                .filter { $0 != "--branches" } + ["--"]
            let ids = try await repository.git(arguments).text.split(separator: "\n").map(String.init)
            #expect(ids.first == expected[name], "origin/\(name) is read, and only it")
        }
        // One a fetch pruned reads as nothing instead of failing.
        let gone = ["log", "--format=%H"] + ["--glob=" + GitRepository.exactRemoteGlob("origin/gone"), "--"]
        #expect(try await repository.git(gone).text.isEmpty)
    }

    @Test func readsSignaturesForMoreCommitsThanACommandLineHolds() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("a\n", to: "a.txt")
        let id = try await repository.commitAll("one")
        let codes = await repository.signatureCodes(of: Array(repeating: id, count: 40_000))
        #expect(codes[id] == "N")
    }
}
