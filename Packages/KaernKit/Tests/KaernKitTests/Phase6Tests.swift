import Foundation
import Testing
@testable import KaernKit

/// Phase 6: a failed `git log` is an error, not an empty history.
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
    }
}
