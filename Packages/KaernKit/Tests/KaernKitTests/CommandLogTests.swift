import Foundation
import Synchronization
import Testing
@testable import KaernKit

@Suite("Command log: redaction")
struct RedactionTests {
    @Test func masksCredentialsInURLs() {
        #expect(GitRedaction.redact("https://x-access-token:ghp_abcdefghijklmnopqrstuvwxyz0123@github.com/o/r.git")
                == "https://***@github.com/o/r.git")
        #expect(GitRedaction.redact("fatal: unable to access 'https://minji:hunter2@git.example.com/team/app.git/'")
                == "fatal: unable to access 'https://***@git.example.com/team/app.git/'")
        // An address without credentials and an SSH remote stay as they are.
        #expect(GitRedaction.redact("https://github.com/progresshans/powerlens.git") == "https://github.com/progresshans/powerlens.git")
        #expect(GitRedaction.redact("git@github.com:progresshans/powerlens.git") == "git@github.com:progresshans/powerlens.git")
    }

    @Test func masksKnownTokensAndHeaders() {
        #expect(GitRedaction.redact("token ghp_abcdefghijklmnopqrstuvwxyz0123 expired") == "token *** expired")
        #expect(GitRedaction.redact("github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz") == "***")
        #expect(GitRedaction.redact("glpat-abcdefghij0123456789") == "***")
        #expect(GitRedaction.redact("http.extraHeader=Authorization: Bearer abc.def.ghi")
                == "http.extraHeader=Authorization: ***")
        #expect(GitRedaction.redact("AUTHORIZATION: basic dXNlcjpwYXNz") == "AUTHORIZATION: ***")
        #expect(GitRedaction.redact("protocol=https\nhost=github.com\nusername=minji\npassword=s3cret\n")
                == "protocol=https\nhost=github.com\nusername=minji\npassword=***\n")
        #expect(GitRedaction.redact("https://example.com/repo.git?private_token=abc123&ref=main")
                == "https://example.com/repo.git?private_token=***&ref=main")
        #expect(GitRedaction.redact("AKIAABCDEFGHIJKLMNOP") == "***")
    }

    @Test func leavesOrdinaryOutputAlone() {
        let output = """
        To github.com:progresshans/powerlens.git
         + 5d0e6a1...7b1e04d feature/restore-automatic-alpha -> feature/restore-automatic-alpha (forced update)
        """
        #expect(GitRedaction.redact(output) == output)
        #expect(GitRedaction.redact(arguments: ["push", "--force-with-lease=refs/heads/x:5d0e6a1", "origin"])
                == ["push", "--force-with-lease=refs/heads/x:5d0e6a1", "origin"])
    }
}

@Suite("Command log: kinds")
struct CommandKindTests {
    @Test func sortsCommandsByWhatTheyDo() {
        #expect(GitCommandKinds.of(["fetch", "--prune", "origin"]) == .network)
        #expect(GitCommandKinds.of(["push", "--progress", "origin", "HEAD"]) == [.network, .changes])
        #expect(GitCommandKinds.of(["-c", "x=y", "commit", "--file=-"]) == .changes)
        #expect(GitCommandKinds.of(["status", "--porcelain=v2"]) == [])
        #expect(GitCommandKinds.of(["log", "--format=%H"]) == [])
        #expect(GitCommandKinds.of(["stash", "list"]) == [])
        #expect(GitCommandKinds.of(["stash", "push", "-m", "x"]) == .changes)
        #expect(GitCommandKinds.of(["stash"]) == .changes)
        #expect(GitCommandKinds.of(["branch", "--format=%(refname:short)", "--contains", "abc"]) == [])
        #expect(GitCommandKinds.of(["branch", "-D", "old"]) == .changes)
        #expect(GitCommandKinds.of(["branch", "feature/x", "abc"]) == .changes)
        #expect(GitCommandKinds.of(["tag", "v1.0", "abc"]) == .changes)
        #expect(GitCommandKinds.of(["tag", "--list"]) == [])
        #expect(GitCommandKinds.of(["config", "--get", "user.name"]) == [])
        #expect(GitCommandKinds.of(["config", "--local", "core.hooksPath", "x"]) == .changes)
        #expect(GitCommandKinds.of(["apply", "--cached", "-"]) == .changes)
        #expect(GitCommandKinds.of(["apply", "--check", "-"]) == [])
        #expect(GitCommandKinds.of(["remote", "-v"]) == [])
        #expect(GitCommandKinds.of(["remote", "add", "origin", "x"]) == .changes)
        #expect(GitCommandKinds.of(["worktree", "list"]) == [])
    }

    @Test func quotesForTheShell() {
        let record = GitCommandRecord(arguments: ["commit", "-m", "it's done", "--", "a b.txt"], directory: "/", trigger: nil, started: .now)
        #expect(record.commandLine == "git commit -m 'it'\\''s done' -- 'a b.txt'")
    }
}

@Suite("Command log: records (integration)")
struct CommandRecordTests {
    final class Events: Sendable {
        let list = Mutex<[GitCommandEvent]>([])
        func add(_ event: GitCommandEvent) { list.withLock { $0.append(event) } }
        var finished: [GitCommandRecord] {
            list.withLock { events in events.compactMap { if case .finished(let record) = $0 { record } else { nil } } }
        }
        var started: [GitCommandRecord] {
            list.withLock { events in events.compactMap { if case .started(let record, _) = $0 { record } else { nil } } }
        }
    }

    private func runner(_ events: Events) -> GitRunner {
        var runner = RepositoryTests.runner
        runner.onCommand = { events.add($0) }
        return runner
    }

    @Test func recordsTriggerOutputAndMasksSecrets() async throws {
        let base = try await TestRepositories.make()
        defer { TestRepositories.remove(base) }
        let events = Events()
        let repository = GitRepository(root: base.root, gitDirectory: base.gitDirectory, runner: runner(events))
        let token = "ghp_abcdefghijklmnopqrstuvwxyz0123"
        try await GitCommandTrigger.$current.withValue(GitCommandTrigger("Repository Settings › Add Remote")) {
            try await repository.addRemote("origin", url: "https://x-access-token:\(token)@github.com/o/r.git")
            _ = await repository.remoteURL("origin")
        }
        _ = try await repository.status()

        let records = events.finished
        #expect(records.count == 3)
        let add = try #require(records.first)
        #expect(add.trigger?.action == "Repository Settings › Add Remote")
        #expect(add.isBackground == false)
        #expect(add.kinds == .changes)
        #expect(add.status == 0)
        #expect(add.arguments == ["remote", "add", "origin", "https://***@github.com/o/r.git"])
        #expect(!add.commandLine.contains(token))
        let url = records[1]
        #expect(url.output.trimmingCharacters(in: .whitespacesAndNewlines) == "https://***@github.com/o/r.git")
        // No trigger: background work.
        #expect(records[2].trigger == nil)
        #expect(records[2].isBackground)
        #expect(events.started.count == 3)
        #expect(events.started.allSatisfy { $0.status == nil })
    }

    @Test func recordsFailuresWithTheirErrorOutput() async throws {
        let base = try await TestRepositories.make()
        defer { TestRepositories.remove(base) }
        let events = Events()
        let repository = GitRepository(root: base.root, gitDirectory: base.gitDirectory, runner: runner(events))
        await #expect(throws: GitError.self) {
            try await repository.switchBranch("no-such-branch")
        }
        let record = try #require(events.finished.first)
        #expect(record.failed)
        #expect(record.status == 128)
        #expect(record.errorOutput.contains("no-such-branch"))
    }

    @Test func stopEndsTheCommandAndWhatItStarted() async throws {
        let base = try await TestRepositories.make()
        defer { TestRepositories.remove(base) }
        let events = Events()
        let runner = runner(events)
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task {
            try await runner.run(["-c", "alias.wait=!sleep 30", "wait"], in: base.root)
        }
        // Wait for the start, then stop it from the record's handle.
        var handle: GitCommandHandle?
        for _ in 0..<200 where handle == nil {
            try await Task.sleep(for: .milliseconds(20))
            handle = events.list.withLock { events in
                events.compactMap { if case .started(_, let stop) = $0 { stop } else { nil } }.first
            }
        }
        try #require(handle != nil)
        handle?.stop()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(clock.now - started < .seconds(10))
        let record = try #require(events.finished.first)
        #expect(record.wasStopped)
    }

    @Test func cancellingTheTaskStopsTheCommand() async throws {
        let base = try await TestRepositories.make()
        defer { TestRepositories.remove(base) }
        let runner = RepositoryTests.runner
        let task = Task {
            try await runner.run(["-c", "alias.wait=!sleep 30", "wait"], in: base.root)
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(clock.now - start < .seconds(5))
    }
}
