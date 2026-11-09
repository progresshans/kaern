import Foundation
import Testing
@testable import KaernKit

/// Phase 6: a failed `git log` is an error (not an empty history), the graph's scopes, and Pull
/// with rebase over uncommitted changes.
@Suite("Phase 6")
struct Phase6Tests {
    static let runner = RepositoryTests.runner

    private static func breakRef(_ name: String, in repository: GitRepository) throws {
        let file = repository.gitDirectory.appending(path: "refs/heads/\(name)")
        try Data("1234567890123456789012345678901234567890\n".utf8).write(to: file)
    }

    // MARK: A failed git log

    @Test func aFailedLogThrowsGitsMessageAndStaysFailed() async throws {
        let repository = try await BigRepositoryTests.repository(commits: 5)
        defer { TestRepositories.remove(repository) }
        try Self.breakRef("broken", in: repository)

        let events = EventLog()
        let runner = GitRunner(executableURL: repository.runner.executableURL, extraEnvironment: [
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        ], onCommand: { events.append($0) })
        let watched = GitRepository(root: repository.root, gitDirectory: repository.gitDirectory, runner: runner)
        let stream = watched.historyStream()
        do {
            _ = try await stream.next(10)
            Issue.record("a failed git log read as history")
        } catch let error as GitError {
            #expect(error.status == 128)
            #expect(error.message.contains("broken"))
        }
        #expect(!stream.isFinished)
        // Every read after that fails the same way; none gives part of the history.
        await #expect(throws: GitError.self) { _ = try await stream.next(10) }
        // The Command Log record ends, saying git failed.
        for _ in 0 ..< 150 where events.finished < 1 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(events.started == 1 && events.finished == 1)
        #expect(events.lastOutput.contains("git failed"))

        // Paging with `log` fails too, rather than returning an empty page.
        await #expect(throws: GitError.self) { _ = try await repository.log(skip: 0, limit: 10, includeHEAD: true) }

        // Without the broken ref, history reads again.
        try FileManager.default.removeItem(at: repository.gitDirectory.appending(path: "refs/heads/broken"))
        #expect(try await repository.historyStream().next(10).count == 5)
    }

    @Test func anEmptyRepositoryHasNoHistoryAndNoError() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        let stream = repository.historyStream()
        #expect(try await stream.next(10).isEmpty)
        #expect(stream.isFinished)
        #expect(try await repository.log(skip: 0, limit: 10, includeHEAD: true).isEmpty)
        #expect(try await repository.commitCount(in: .all(hidden: [])) == 0)
        #expect(try await repository.commitCount(in: .current) == 0)
        #expect(try await repository.searchHistory("anything", scope: .all, includeHEAD: true).matches.isEmpty)
    }

    @Test func aDetachedHEADOnNoBranchIsInTheHistory() async throws {
        let repository = try await BigRepositoryTests.repository(commits: 3)
        defer { TestRepositories.remove(repository) }
        try await repository.git(["checkout", "-q", "--detach"])
        try repository.write("detached\n", to: "d.txt")
        let detached = try await repository.commitAll("on no branch")
        #expect(repository.headState() == .detached)
        let ids = try await repository.historyStream().next(10).map(\.id)
        #expect(ids.first == detached && ids.count == 4)
    }

    @Test func headIsNamedOnlyWhenItAddsCommits() {
        let all = HistoryScope.all(hidden: [])
        #expect(GitRepository.revisionArguments(for: all, head: .attached) == ["--branches", "--remotes", "--tags"])
        #expect(GitRepository.revisionArguments(for: all, head: .detached) == ["--branches", "--remotes", "--tags", "HEAD"])
        #expect(GitRepository.revisionArguments(for: all, head: .leftOut) == ["--branches", "--remotes", "--tags"])
        #expect(GitRepository.revisionArguments(for: .current, head: .attached) == ["--ignore-missing", "HEAD"])
        #expect(GitRepository.revisionArguments(for: .local(remoteBranches: ["origin/main"]), head: .attached)
            == ["--branches", "--remotes=origin/mai[n]"])
        #expect(GitRepository.exactPattern("origin/release/2026.11") == "origin/release/2026.1[1]")
    }

    // MARK: Graph scopes

    @Test func localScopeDrawsLocalBranchesAndOnlyTheNamedRemoteBranches() async throws {
        let repository = try await BigRepositoryTests.repository(commits: 3)
        defer { TestRepositories.remove(repository) }
        let main = try await repository.git(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tree = try await repository.git(["rev-parse", "HEAD^{tree}"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        func remoteOnly(_ branch: String, _ subject: String) async throws -> String {
            let id = try await repository.git(["commit-tree", tree, "-p", main, "-m", subject]).text.trimmingCharacters(in: .whitespacesAndNewlines)
            try await repository.git(["update-ref", "refs/remotes/origin/\(branch)", id])
            return id
        }
        try await repository.git(["update-ref", "refs/remotes/origin/main", main])
        let x = try await remoteOnly("feature/x", "only on x")
        let xy = try await remoteOnly("feature/xy", "only on xy")
        try await repository.git(["update-ref", "refs/tags/v1", xy])

        func ids(_ scope: HistoryScope) async throws -> Set<String> {
            Set(try await repository.historyStream(scope: scope).next(100).map(\.id))
        }
        let all = try await ids(.all(hidden: []))
        #expect(all.contains(x) && all.contains(xy) && all.count == 5)
        let local = try await ids(.local(remoteBranches: ["origin/main"]))
        #expect(!local.contains(x) && !local.contains(xy) && local.count == 3)
        // The name matches that branch alone, not origin/feature/xy and not the tag's commit.
        let picked = try await ids(.local(remoteBranches: ["origin/main", "origin/feature/x"]))
        #expect(picked.contains(x) && !picked.contains(xy) && picked.count == 4)
        // A remote branch that's gone (a fetch pruned it) is left out instead of failing the read.
        #expect(try await ids(.local(remoteBranches: ["origin/gone"])).count == 3)
        #expect(try await ids(.current).count == 3)
        #expect(try await repository.commitCount(in: .local(remoteBranches: ["origin/feature/x"])) == 4)
        let found = try await repository.searchHistory("only on", scope: .message, includeHEAD: true,
                                                      history: .local(remoteBranches: ["origin/feature/x"]))
        #expect(found.matches == [x])
    }

    @Test func refsKeepWhatASymbolicRefPointsAt() async throws {
        let repository = try await BigRepositoryTests.repository(commits: 1)
        defer { TestRepositories.remove(repository) }
        try await repository.git(["update-ref", "refs/remotes/origin/trunk", "HEAD"])
        try await repository.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk"])
        let refs = try await repository.refs()
        let head = refs.refs.first { $0.fullName == "refs/remotes/origin/HEAD" }
        #expect(head?.isSymbolic == true && head?.symbolicTarget == "refs/remotes/origin/trunk")
        #expect(!refs.remoteBranches.contains { $0.fullName == "refs/remotes/origin/HEAD" })
    }

    // MARK: Pull with rebase over uncommitted changes

    /// A repository with an origin, a local commit the origin doesn't have, and a second clone
    /// that pushes `incoming` (path: contents) to main.
    private static func pullSetup(incoming: [String: String]) async throws -> (local: GitRepository, folders: [URL]) {
        let bare = FileManager.default.temporaryDirectory.appending(path: "kaern-pull-\(UUID().uuidString).git")
        try await runner.run(["init", "-q", "--bare", "-b", "main", bare.path(percentEncoded: false)], in: nil)
        let local = try await TestRepositories.make()
        try local.write("shared\n", to: "shared.txt")
        try local.write("staged\n", to: "s.txt")
        try local.write("unstaged\n", to: "u.txt")
        try await local.commitAll("base")
        try await local.addRemote("origin", url: bare.path(percentEncoded: false))
        try await local.git(["push", "-q", "-u", "origin", "main"])
        let otherFolder = FileManager.default.temporaryDirectory.appending(path: "kaern-pull-other-\(UUID().uuidString)")
        try await runner.run(["clone", "-q", bare.path(percentEncoded: false), otherFolder.path(percentEncoded: false)], in: nil)
        let other = try await GitRepository.open(otherFolder, runner: runner)
        for (path, text) in incoming { try other.write(text, to: path) }
        try await other.commitAll("incoming")
        try await other.git(["push", "-q", "origin", "main"])
        // Local: a commit of its own, then a staged change and an unstaged one.
        try local.write("shared\nmine\n", to: "shared.txt")
        try await local.commitAll("mine")
        try local.write("staged\nmore\n", to: "s.txt")
        try await local.git(["add", "s.txt"])
        try local.write("unstaged\nmore\n", to: "u.txt")
        return (local, [bare, otherFolder])
    }

    @Test func pullWithRebaseOverUncommittedChangesKeepsWhatWasStaged() async throws {
        let (local, folders) = try await Self.pullSetup(incoming: ["theirs.txt": "theirs\n"])
        defer { TestRepositories.remove(local); folders.forEach { try? FileManager.default.removeItem(at: $0) } }
        // Plain git refuses.
        await #expect(throws: GitError.self) { _ = try await local.pull(strategy: .rebase) }

        let result = try await local.withChangesStashed(message: "Before Pull") {
            try await local.pull(strategy: .rebase)
        }
        #expect(result.outcome == .finished && result.kept == nil)
        #expect(try await local.headSubject() == "mine")
        #expect(try await local.headSubject("HEAD~1") == "incoming")
        let staged = try await local.git(["diff", "--cached", "--name-only"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let unstaged = try await local.git(["diff", "--name-only"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(staged == "s.txt" && unstaged == "u.txt")
        #expect(try await local.stashes().isEmpty)
    }

    @Test func pullWithRebaseThatStopsKeepsTheChangesInTheStashList() async throws {
        let (local, folders) = try await Self.pullSetup(incoming: ["shared.txt": "shared\ntheirs\n"])
        defer { TestRepositories.remove(local); folders.forEach { try? FileManager.default.removeItem(at: $0) } }
        let result = try await local.withChangesStashed(message: "Before Pull") {
            try await local.pull(strategy: .rebase)
        }
        #expect(result.outcome == .stopped && result.kept != nil)
        #expect(local.operationState()?.kind == .rebase)
        #expect(try await local.stashes().first?.message.contains("Before Pull") == true)
        // A merge pull that conflicts stops the same way instead of throwing.
        try await local.abortOperation(.rebase)
        try await local.popStash(object: result.kept!)
        let merge = try await local.withChangesStashed(message: "Before Pull") {
            try await local.pull(strategy: .merge)
        }
        #expect(merge.outcome == .stopped && local.operationState()?.kind == .merge)
    }
}
