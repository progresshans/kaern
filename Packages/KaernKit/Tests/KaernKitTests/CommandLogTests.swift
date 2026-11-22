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

    /// `redact` runs a pattern only when one of its telltale words is in the text. Whatever the
    /// text, that must give what every pattern gives.
    @Test func skippingPatternsHidesTheSame() {
        let samples = [
            "", "plain output", "git@github.com:progresshans/powerlens.git", "https://github.com/a/b.git",
            "https://minji:hunter2@git.example.com/team/app.git", "ssh://deploy:pw@host/x", "user@host and http://x/y",
            "Authorization: Bearer abc.def.ghi", "proxy-AUTHORIZATION:   Basic dXNlcg==", "authorization without a colon",
            "PASSWORD=hunter2", "Passwd: x", "pwd = /Users/minji", "api_key=abc apikey: def API-KEY=ghi", "monkey=1 keys: 2",
            "client_secret: abc123", "tokens=5 tokenizer=wordpiece", "oauth_refresh_token=r3fresh&x=1",
            "\u{17F}ecret=abc", "to\u{212A}en=abc", "api_\u{212A}ey: abc", "pa\u{17F}\u{17F}word=abc",
            "ghp_abcdefghijklmnopqrstuvwxyz0123", "ghq_abcdefghijklmnopqrstuvwxyz0123", "gho_short",
            "github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz", "glpat-abcdefghij0123456789", "glpat_abc",
            "ATBBabcdefghijklmnopqrstuvwx", "xoxb-1234567890-abcdefghij", "xoxo",
            "AKIAABCDEFGHIJKLMNOP", "ASIAABCDEFGHIJKLMNOP", "akiaabcdefghijklmnop",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
            "한글 파일.txt | 3 ++-\n README.md | 2 +-", "diff --git a/Token.swift b/Token.swift\n+let token = load()\n-let key: String",
        ]
        for sample in samples {
            #expect(GitRedaction.redact(sample) == GitRedaction.redactWithEveryPattern(sample), "\(sample)")
        }
        // A long diff with nothing to hide, and the same with one secret at its end.
        let line = "+        let rows = commits.map { RowModel(commit: $0, graph: graph[$0.id]) }\n"
        let long = String(repeating: line, count: 800)
        #expect(GitRedaction.redact(long) == long)
        #expect(GitRedaction.redact(long + "password=hunter2") == long + "password=***")
        let clock = ContinuousClock()
        let quick = clock.measure { for _ in 0..<10 { _ = GitRedaction.redact(long) } }
        let every = clock.measure { for _ in 0..<10 { _ = GitRedaction.redactWithEveryPattern(long) } }
        print("redact \(long.utf8.count) bytes, 10 times: \(quick) with the word check, \(every) with every pattern")
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

    /// A command that takes five minutes left alone: git starts a shell, which makes the file `running` in the
    /// repository and becomes `sleep`. A test stops the command once that file is there, so the stop finds git with
    /// what it started. (In the few milliseconds git takes to start it, a stop can end git and miss the shell.)
    private static let longCommand = ["-c", "alias.wait=!touch running && exec sleep 300", "wait"]

    /// Waits until the shell of `longCommand` runs.
    private func waitUntilItRuns(in repository: GitRepository) async throws {
        try await waitUntil { repository.read("running") != nil }
        try #require(repository.read("running") != nil)
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
            try await runner.run(Self.longCommand, in: base.root)
        }
        // Once it runs, stop it from the record's handle.
        try await waitUntilItRuns(in: base)
        let handle = events.list.withLock { events in
            events.compactMap { if case .started(_, let stop) = $0 { stop } else { nil } }.first
        }
        try #require(handle != nil)
        handle?.stop()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        // It was stopped rather than left to end: a stop takes a second or two on a busy Mac, the command five
        // minutes. A minute tells the two apart without timing the stop.
        #expect(clock.now - started < .seconds(60))
        let record = try #require(events.finished.first)
        #expect(record.wasStopped)
    }

    @Test func cancellingTheTaskStopsTheCommand() async throws {
        let base = try await TestRepositories.make()
        defer { TestRepositories.remove(base) }
        let runner = RepositoryTests.runner
        let task = Task {
            try await runner.run(Self.longCommand, in: base.root)
        }
        // Cancel it once it runs: a cancel before git starts is another path, where git doesn't start at all.
        try await waitUntilItRuns(in: base)
        task.cancel()
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        // Stopped rather than left to end, as above.
        #expect(clock.now - start < .seconds(60))
    }
}
