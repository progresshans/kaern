import Foundation
import Testing
@testable import KaernKit

/// What the review of the stale-status branch found: a git command started after a stop ran to
/// its end, Reset Hard let git delete a repository of its own in the way, and the changes put
/// aside before an operation came back with conflict markers when they clashed with it.
@Suite("Stops, Reset Hard and kept changes", .serialized, .hangGuard)
struct StopAndResetTests {
    static let runner = RepositoryTests.runner

    /// Runs `work` on `repository` and stops it as soon as a git command whose command line
    /// contains `match` has finished. Returns the error the work ended with (`nil`: none).
    static func run(stoppingAfter match: String, in repository: GitRepository,
                    _ work: @escaping @Sendable (GitRepository) async throws -> Void) async throws -> (any Error)? {
        let stopper = StopAfter(match)
        var runner = Self.runner
        runner.onCommand = { stopper.notice($0) }
        let watched = try await GitRepository.open(repository.root, runner: runner)
        // The task is known to the stopper before its first git command.
        let (gate, open) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in gate { break }
            try await work(watched)
        }
        stopper.watch(task)
        open.yield()
        open.finish()
        do {
            try await task.value
            return nil
        } catch {
            return error
        }
    }

    final class StopAfter: @unchecked Sendable {
        private let lock = NSLock()
        private let match: String
        private var task: Task<Void, any Error>?
        private var stopped = false
        init(_ match: String) { self.match = match }
        func watch(_ task: Task<Void, any Error>) { lock.withLock { self.task = task } }
        func notice(_ event: GitCommandEvent) {
            guard case .finished(let record) = event, record.commandLine.contains(match) else { return }
            lock.withLock {
                guard !stopped else { return }
                stopped = true
                task?.cancel()
            }
        }
    }

    @Test func aGitCommandInAStoppedTaskDoesntStart() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("a\n", to: "a.txt")
        try await repository.commitAll("one")
        let stopped = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await repository.git(["tag", "made-after-the-stop"])
        }
        await #expect(throws: CancellationError.self) { _ = try await stopped.value }
        #expect(await repository.resolve("refs/tags/made-after-the-stop") == nil)
        // What puts things back after a stop still runs.
        let back = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await GitRepository.uncancelled { try await repository.git(["tag", "put-back"]) }
        }
        _ = try await back.value
        #expect(await repository.resolve("refs/tags/put-back") != nil)
    }

    @Test func aRepositoryOfItsOwnInTheWayStopsTheResetBeforeAnythingChanges() async throws {
        // Where the target has a file: the repository itself, a file inside it, a folder holding one.
        for (committed, nestedAt) in [("vendor", "vendor"), ("vendor/lib.txt", "vendor"), ("cache", "cache/tool")] {
            let repository = try await TestRepositories.make()
            defer { TestRepositories.remove(repository) }
            try repository.write("one\n", to: "a.txt")
            try repository.write("committed\n", to: committed)
            let target = try await repository.commitAll("with \(committed)")
            try await repository.git(["rm", "-q", "-r", String(committed.split(separator: "/")[0])])
            try await repository.commitAll("without it")
            let head = try #require(await repository.resolve("HEAD"))
            // A clone kept in the folder, with work of its own.
            let nested = repository.root.appending(path: nestedAt, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try await Self.runner.run(["init", "-q"], in: nested)
            try repository.write("its own\n", to: "\(nestedAt)/lib.txt")
            try repository.write("work in progress\n", to: "\(nestedAt)/wip.txt")
            try repository.write("one\nchanged\n", to: "a.txt")

            let error = await #expect(throws: GitError.self) { _ = try await repository.resetHard(to: target, message: "Before reset") }
            #expect(error?.message.hasPrefix("\(nestedAt) is a git repository of its own") == true, "\(error?.message ?? "")")
            #expect(await repository.resolve("HEAD") == head)
            #expect(try await repository.stashes().isEmpty)
            #expect(repository.read("\(nestedAt)/lib.txt") == "its own\n" && repository.read("\(nestedAt)/wip.txt") == "work in progress\n")
            #expect(FileManager.default.fileExists(atPath: nested.appending(path: ".git").path(percentEncoded: false)))
            #expect(repository.read("a.txt") == "one\nchanged\n")
        }
    }

    @Test func aResetThatDoesntHappenPutsTheChangesBack() async throws {
        let (repository, target) = try await ResetHardTests.filesInTheWayOfTheCommitBefore()
        defer { TestRepositories.remove(repository) }
        let head = try #require(await repository.resolve("HEAD"))
        // Stopped once the changes are in the stash list: the reset never starts.
        let error = try await Self.run(stoppingAfter: "stash push", in: repository) { repository in
            _ = try await repository.resetHard(to: target, message: "Before reset")
        }
        #expect(error is CancellationError, "\(String(describing: error))")
        #expect(await repository.resolve("HEAD") == head)
        #expect(try await repository.stashes().isEmpty)
        #expect(repository.read(".env") == "TOKEN=my secret\n" && repository.read("notes.md") == "my notes\n")
        #expect(repository.read("cache/mine.txt") == "in a folder\n" && repository.read("docs") == "a file\n")
        #expect(repository.read("a.txt") == "one\nunstaged\n")
        #expect(try await repository.git(["diff", "--cached", "--name-only"]).text.trimmingCharacters(in: .whitespacesAndNewlines) == "s.txt")
    }

    @Test func aStopRightAfterTheChangesWentAsideBringsThemBack() async throws {
        // Around an operation (Merge, Rebase, Cherry-pick, Revert, Pull).
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("one\n", to: "a.txt")
        try await repository.commitAll("one")
        try repository.write("one\nmine\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let error = try await Self.run(stoppingAfter: "stash push", in: repository) { repository in
            _ = try await repository.withChangesStashed(message: "Before Test") {
                _ = try await repository.git(["rev-parse", "HEAD"])
                return .finished
            }
        }
        #expect(error is CancellationError, "\(String(describing: error))")
        #expect(try await repository.stashes().isEmpty)
        #expect(repository.read("a.txt") == "one\nmine\n")
        #expect(try await repository.git(["diff", "--cached", "--name-only"]).text.contains("a.txt"))

        // Remove… of a worktree.
        let (main, folder) = try await Phase6ReviewTests.repositoryWithWorktree()
        defer { TestRepositories.remove(main); try? FileManager.default.removeItem(at: folder) }
        let worktree = try await GitRepository.open(folder, runner: Self.runner)
        try worktree.write("one\nchanged\n", to: "a.txt")
        let stopped = try await Self.run(stoppingAfter: "stash push", in: main) { main in
            _ = try await main.removeWorktree(folder.path(percentEncoded: false), keepingChangesAs: "Worktree test")
        }
        #expect(stopped is CancellationError, "\(String(describing: stopped))")
        #expect(try await main.stashes().isEmpty)
        #expect(worktree.read("a.txt") == "one\nchanged\n")
    }

    /// A runner whose `git stash push` is still running after it made the entry: it writes the file `made` into
    /// `folder` then, and stays for two more seconds. The real one is in that state for a few milliseconds, between
    /// writing the entry and taking the changes out of the files.
    static func runner(stayingInStashPush folder: URL) throws -> GitRunner {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let git = Self.runner.executableURL.path(percentEncoded: false)
        let file = folder.appending(path: "git.sh")
        try Data("""
            #!/bin/sh
            case " $* " in
            *" stash push "*)
                "\(git)" "$@"
                status=$?
                touch "\(folder.appending(path: "made").path(percentEncoded: false))"
                sleep 2
                exit $status ;;
            esac
            exec "\(git)" "$@"

            """.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        var runner = Self.runner
        runner.executableURL = file
        return runner
    }

    /// Runs `work` on `repository` with that runner and stops it while `git stash push` is still running, the
    /// entry made. Returns the error the work ended with (`nil`: none).
    static func run(stoppingInStashPushOf repository: GitRepository,
                    _ work: @escaping @Sendable (GitRepository) async throws -> Void) async throws -> (any Error)? {
        let folder = FileManager.default.temporaryDirectory.appending(path: "kaern-tests-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let slow = try await GitRepository.open(repository.root, runner: runner(stayingInStashPush: folder))
        let made = folder.appending(path: "made").path(percentEncoded: false)
        let task = Task { try await work(slow) }
        try await waitUntil { FileManager.default.fileExists(atPath: made) }
        try #require(FileManager.default.fileExists(atPath: made), "git stash push never got to its entry")
        task.cancel()
        do {
            try await task.value
            return nil
        } catch {
            return error
        }
    }

    /// A stop can also reach `git stash push` itself. git writes the entry first and takes the changes out of the
    /// files after that; ended in between, it left them in the stash list, and whole or in part in the files, and
    /// nothing put them back. A stop waits for git there, and then they come back.
    @Test func aStopWhileTheChangesGoAsideBringsThemBack() async throws {
        // Around an operation (Merge, Rebase, Cherry-pick, Revert, Pull).
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("one\n", to: "a.txt")
        try await repository.commitAll("one")
        try repository.write("one\nmine\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let error = try await Self.run(stoppingInStashPushOf: repository) { repository in
            _ = try await repository.withChangesStashed(message: "Before Test") {
                _ = try await repository.git(["rev-parse", "HEAD"])
                return .finished
            }
        }
        #expect(error is CancellationError, "\(String(describing: error))")
        #expect(try await repository.stashes().isEmpty)
        #expect(repository.read("a.txt") == "one\nmine\n")
        #expect(try await repository.git(["diff", "--cached", "--name-only"]).text.contains("a.txt"))

        // Remove… of a worktree.
        let (main, folder) = try await Phase6ReviewTests.repositoryWithWorktree()
        defer { TestRepositories.remove(main); try? FileManager.default.removeItem(at: folder) }
        let worktree = try await GitRepository.open(folder, runner: Self.runner)
        try worktree.write("one\nchanged\n", to: "a.txt")
        let stopped = try await Self.run(stoppingInStashPushOf: main) { main in
            _ = try await main.removeWorktree(folder.path(percentEncoded: false), keepingChangesAs: "Worktree test")
        }
        #expect(stopped is CancellationError, "\(String(describing: stopped))")
        #expect(try await main.stashes().isEmpty)
        #expect(worktree.read("a.txt") == "one\nchanged\n")
    }

    /// The same for Reset Hard, whose entry also takes the untracked files in the way.
    @Test func aResetStoppedWhileTheChangesGoAsidePutsThemBack() async throws {
        let (repository, target) = try await ResetHardTests.filesInTheWayOfTheCommitBefore()
        defer { TestRepositories.remove(repository) }
        let head = try #require(await repository.resolve("HEAD"))
        let error = try await Self.run(stoppingInStashPushOf: repository) { repository in
            _ = try await repository.resetHard(to: target, message: "Before reset")
        }
        #expect(error is CancellationError, "\(String(describing: error))")
        #expect(await repository.resolve("HEAD") == head)
        #expect(try await repository.stashes().isEmpty)
        #expect(repository.read(".env") == "TOKEN=my secret\n" && repository.read("notes.md") == "my notes\n")
        #expect(repository.read("cache/mine.txt") == "in a folder\n" && repository.read("docs") == "a file\n")
        #expect(repository.read("a.txt") == "one\nunstaged\n")
        #expect(try await repository.git(["diff", "--cached", "--name-only"]).text.trimmingCharacters(in: .whitespacesAndNewlines) == "s.txt")
    }

    @Test func aRenameStoppedHalfwayPutsTheStashesBack() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("a\n", to: "a.txt")
        try await repository.commitAll("one")
        for name in ["oldest", "middle", "newest"] {
            try repository.write("a \(name)\n", to: "a.txt")
            try await repository.stash(message: name, includeUntracked: false)
        }
        let before = try await repository.stashes()
        let oldest = try #require(before.last)
        // Stopped after the first entry was dropped: the next command doesn't start.
        let error = try await Self.run(stoppingAfter: "stash drop", in: repository) { repository in
            try await repository.renameStash(oldest, to: "renamed")
        }
        #expect(error is CancellationError, "\(String(describing: error))")
        let after = try await repository.stashes()
        #expect(after.map(\.id) == before.map(\.id))
        #expect(after.map(\.message) == before.map(\.message))
    }

    @Test func keptChangesComeBackUnlessTheyClash() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("one\n", to: "a.txt")
        try repository.write("one\n", to: "b.txt")
        let start = try await repository.commitAll("one")
        try repository.write("one\nmine\n", to: "b.txt")
        let kept = try #require(try await repository.stashAll(message: "Before Test", includeUntracked: false))

        // What happened since changed a.txt only: b.txt comes back.
        try repository.write("one\ntheirs\n", to: "a.txt")
        try await repository.commitAll("a.txt")
        #expect(try await repository.popKeptChanges(kept, since: start))
        #expect(repository.read("b.txt") == "one\nmine\n")
        #expect(try await repository.stashes().isEmpty)

        // Now it changed b.txt as well: the changes stay in the stash list, and no markers are written.
        let again = try #require(try await repository.stashAll(message: "Before Test", includeUntracked: false))
        let middle = try #require(await repository.resolve("HEAD"))
        try repository.write("one\ntheirs too\n", to: "b.txt")
        try await repository.commitAll("b.txt")
        #expect(try await repository.popKeptChanges(again, since: middle) == false)
        #expect(repository.read("b.txt") == "one\ntheirs too\n")
        #expect(try await repository.stashes().map(\.id) == [again])
        // Ended where it began: nothing to clash with.
        try await repository.reset(to: middle, mode: .hard)
        #expect(try await repository.popKeptChanges(again, since: middle))
        #expect(repository.read("b.txt") == "one\nmine\n")
    }
}
