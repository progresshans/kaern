import Foundation
import Synchronization
import Testing
@testable import KaernKit

/// Runs real git commands against throwaway repositories in the temporary directory.
@Suite("Repository (integration)")
struct RepositoryTests {
    /// Isolated from the user's global config (signing, hooks, aliases) so results are predictable.
    static let runner = GitRunner(extraEnvironment: [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "Kaern Tests",
        "GIT_AUTHOR_EMAIL": "tests@kaern.invalid",
        "GIT_COMMITTER_NAME": "Kaern Tests",
        "GIT_COMMITTER_EMAIL": "tests@kaern.invalid",
    ])

    private func makeRepository() async throws -> GitRepository {
        let url = FileManager.default.temporaryDirectory.appending(path: "kaern-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try await GitRepository.initialize(at: url, defaultBranch: "main", runner: Self.runner)
    }

    private func write(_ text: String, to path: String, in repository: GitRepository) throws {
        let url = repository.root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func cleanUp(_ repository: GitRepository) {
        try? FileManager.default.removeItem(at: repository.root)
    }

    @Test func emptyRepositoryHasUnbornHead() async throws {
        let repository = try await makeRepository()
        defer { cleanUp(repository) }
        let status = try await repository.status()
        #expect(status.head == .unborn("main"))
        #expect(status.isClean)
        let refs = try await repository.refs()
        #expect(refs.refs.isEmpty)
    }

    @Test func stageCommitBranchAndLog() async throws {
        let repository = try await makeRepository()
        defer { cleanUp(repository) }

        try write("one\ntwo\nthree\n", to: "notes.txt", in: repository)
        try write("print(1)\n", to: "Sources/App.swift", in: repository)
        var status = try await repository.status()
        #expect(status.entries.map(\.path).sorted() == ["Sources/App.swift", "notes.txt"])
        let allUntracked = status.entries.allSatisfy { $0.isUntracked }
        #expect(allUntracked)

        let stats = await repository.workingTreeLineStats(untracked: status.entries.map(\.path))
        #expect(stats["notes.txt"] == LineStat(additions: 3, deletions: 0))

        try await repository.stageAll()
        try await repository.commit(message: "Initial commit\n\nWith a body.", amend: false)
        status = try await repository.status()
        #expect(status.isClean)
        #expect(status.head == .branch("main"))

        try await repository.createBranch("feature/x", startPoint: nil, checkout: true)
        try write("one\ntwo\nthree\nfour\n", to: "notes.txt", in: repository)
        try await repository.stage(["notes.txt"])
        try await repository.commit(message: "Add four", amend: false)
        try await repository.switchBranch("main")
        try write("print(2)\n", to: "Sources/App.swift", in: repository)
        try await repository.stageAll()
        try await repository.commit(message: "Change app", amend: false)

        let refs = try await repository.refs()
        #expect(refs.localBranches.map(\.name).sorted() == ["feature/x", "main"])
        #expect(refs.headBranch?.name == "main")

        let commits = try await repository.log(skip: 0, limit: 100, includeHEAD: true)
        #expect(commits.count == 3)
        #expect(Set(commits.prefix(2).map(\.subject)) == ["Add four", "Change app"])
        #expect(commits.last?.subject == "Initial commit")

        let details = try await repository.commitDetails(try #require(commits.last).id)
        #expect(details.body == "With a body.")
        #expect(details.commit.author.name == "Kaern Tests")

        let root = try #require(commits.last)
        let rootFiles = try await repository.changedFiles(in: root)
        #expect(rootFiles.map(\.path).sorted() == ["Sources/App.swift", "notes.txt"])
        let allAdded = rootFiles.allSatisfy { $0.kind == .added }
        #expect(allAdded)

        let feature = try #require(commits.first { $0.subject == "Add four" })
        let files = try await repository.changedFiles(in: feature)
        #expect(files == [FileChange(path: "notes.txt", kind: .modified, stat: LineStat(additions: 1, deletions: 0))])
        let diff = try await repository.diff(of: files[0], in: feature)
        #expect(diff.hunks.count == 1)
        #expect(diff.additions == 1)

        var graph = CommitGraphBuilder()
        graph.appendWorkingCopy(head: status.headID)
        graph.append(commits)
        #expect(graph.rows.count == 4)
        let count = try await repository.commitCount()
        #expect(count == 2)
    }

    @Test func stagesAndUnstagesSingleLines() async throws {
        let repository = try await makeRepository()
        defer { cleanUp(repository) }
        let original = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try write(original, to: "file.txt", in: repository)
        try await repository.stageAll()
        try await repository.commit(message: "Base", amend: false)

        var lines = (1...20).map { "line \($0)" }
        lines[1] = "line 2 changed"
        lines[17] = "line 18 changed"
        try write(lines.joined(separator: "\n") + "\n", to: "file.txt", in: repository)

        let unstaged = try #require(try await repository.workingDiff(path: "file.txt", staged: false))
        #expect(unstaged.hunks.count == 2)
        #expect(unstaged.supportsPartialPatches)

        // Stage only the first hunk.
        try await repository.apply(patch: try #require(unstaged.patch(hunk: 0)), cached: true, reverse: false)
        var status = try await repository.status()
        #expect(status.entries.first?.stageState == .partial)
        let staged = try #require(try await repository.workingDiff(path: "file.txt", staged: true))
        #expect(staged.hunks.count == 1)
        #expect(staged.hunks[0].lines.contains { $0.text == "line 2 changed" })

        // Unstage just the added line of that hunk: the index goes back to HEAD.
        let added = try #require(staged.hunks[0].lines.first { $0.kind == .addition })
        let deleted = try #require(staged.hunks[0].lines.first { $0.kind == .deletion })
        let reverse = try #require(staged.patch(hunk: 0, selectedLines: [added.id, deleted.id], reverse: true))
        try await repository.apply(patch: reverse, cached: true, reverse: true)
        status = try await repository.status()
        #expect(status.entries.first?.stageState == .unstaged)

        // Discard the second hunk from the working tree.
        let current = try #require(try await repository.workingDiff(path: "file.txt", staged: false))
        try await repository.apply(patch: try #require(current.patch(hunk: 1)), cached: false, reverse: true)
        let remaining = try #require(try await repository.workingDiff(path: "file.txt", staged: false))
        #expect(remaining.hunks.count == 1)
        #expect(remaining.hunks[0].lines.contains { $0.text == "line 2 changed" })
    }

    @Test func stashRoundTrip() async throws {
        let repository = try await makeRepository()
        defer { cleanUp(repository) }
        try write("a\n", to: "a.txt", in: repository)
        try await repository.stageAll()
        try await repository.commit(message: "Base", amend: false)

        try write("b\n", to: "b.txt", in: repository)
        try await repository.stash(message: "release notes draft", includeUntracked: true)
        let afterStash = try await repository.status()
        #expect(afterStash.isClean)
        #expect(afterStash.stashCount == 1)
        let stashes = try await repository.stashes()
        #expect(stashes.count == 1)
        #expect(stashes[0].message == "On main: release notes draft")

        try await repository.applyStash(stashes[0], pop: true)
        let remaining = try await repository.stashes()
        #expect(remaining.isEmpty)
        let afterPop = try await repository.status()
        #expect(afterPop.entries.map(\.path) == ["b.txt"])
    }

    @Test func clonesAndReportsProgress() async throws {
        let source = try await makeRepository()
        defer { cleanUp(source) }
        try write("hello\n", to: "a.txt", in: source)
        try await source.stageAll()
        try await source.commit(message: "Base", amend: false)

        let destination = FileManager.default.temporaryDirectory.appending(path: "kaern-clone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let lines = LockedLines()
        let clone = try await GitRepository.clone(source.root.path(percentEncoded: false), to: destination, runner: Self.runner) { line in
            lines.append(line)
        }
        let status = try await clone.status()
        #expect(status.head == .branch("main"))
        #expect(status.upstream == "origin/main")
        let remotes = try await clone.remotes()
        #expect(remotes == ["origin"])
        #expect(lines.count > 0)
    }

    @Test func classifiesFileSystemEvents() async throws {
        let repository = try await makeRepository()
        defer { cleanUp(repository) }
        func git(_ path: String) -> String { repository.gitDirectory.appending(path: path).path(percentEncoded: false) }
        func work(_ path: String) -> String { repository.root.appending(path: path).path(percentEncoded: false) }
        #expect(repository.classify([work("Sources/App.swift")]) == .workTree)
        #expect(repository.classify([git("index")]) == .index)
        #expect(repository.classify([git("refs/heads/main"), git("objects/ab/cdef")]) == .refs)
        #expect(repository.classify([git("index.lock"), git("logs/HEAD")]) == [])
        #expect(repository.workTreePaths([work("Sources/App.swift"), git("index"), git("objects/ab/cdef")]) == [work("Sources/App.swift")])
    }

    /// A linked working tree has its HEAD and index in a git directory of its own and its branches
    /// in the one it shares: a branch moved there (a commit made in Terminal) is a change of refs,
    /// and nothing else in the shared directory is this working tree's.
    @Test func classifiesALinkedWorktreesSharedFiles() async throws {
        let (repository, folder) = try await Phase6ReviewTests.repositoryWithWorktree()
        defer {
            TestRepositories.remove(repository)
            try? FileManager.default.removeItem(at: folder)
        }
        let worktree = try await repository.linkedWorktree(at: folder.path(percentEncoded: false))
        func shared(_ path: String) -> String { repository.gitDirectory.appending(path: path).path(percentEncoded: false) }
        func own(_ path: String) -> String { worktree.gitDirectory.appending(path: path).path(percentEncoded: false) }
        let file = worktree.root.appending(path: "a.txt").path(percentEncoded: false)
        #expect(worktree.classify([shared("refs/heads/hotfix")]) == .refs)
        #expect(worktree.classify([shared("packed-refs")]) == .refs)
        #expect(worktree.classify([shared("index"), shared("HEAD"), shared("objects/ab/cdef"), shared("refs/heads/hotfix.lock")]) == [])
        #expect(worktree.classify([own("index")]) == .index)
        #expect(worktree.classify([own("HEAD")]) == .refs)
        #expect(worktree.classify([file]) == .workTree)
        #expect(worktree.workTreePaths([shared("refs/heads/hotfix"), own("index"), file]) == [file])
    }

    @Test func rejectsFoldersThatArentRepositories() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "kaern-not-a-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        // Phase 5: a plain folder opens as a tab that offers Create Repository Here.
        await #expect(throws: NotARepositoryError.self) {
            _ = try await GitRepository.open(url, runner: Self.runner)
        }
    }
}


/// Collects progress lines from git's standard error.
final class LockedLines: Sendable {
    private let lines = Mutex<[String]>([])
    func append(_ line: String) { lines.withLock { $0.append(line) } }
    var count: Int { lines.withLock { $0.count } }
}
