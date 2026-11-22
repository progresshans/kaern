import Foundation
import Testing
@testable import KaernKit

/// The problems the phase-5 review found: a cut history read, LFS pointers naming files
/// elsewhere, secrets in the Command Log, and Update to Recorded leaving commits behind.
@Suite("Phase 5 review")
struct Phase5ReviewTests {
    static let runner = RepositoryTests.runner

    @Test func aStoppedStreamGivesNothingAndIsNotTheEndOfHistory() async throws {
        let repository = try await BigRepositoryTests.repository(commits: 20)
        defer { TestRepositories.remove(repository) }
        let events = EventLog()
        let runner = GitRunner(executableURL: repository.runner.executableURL, extraEnvironment: [
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        ], onCommand: { events.append($0) })
        let watched = GitRepository(root: repository.root, gitDirectory: repository.gitDirectory, runner: runner)

        let stream = watched.historyStream()
        #expect(try await stream.next(5).count == 5)
        stream.cancel()
        // A read after the stop gives nothing rather than part of the history, and there's more.
        #expect(!stream.isFinished)
        await #expect(throws: CancellationError.self) { _ = try await stream.next(5) }

        // A stream let go of right after its stop still ends its Command Log record.
        do {
            let other = watched.historyStream(skip: 10)
            _ = try await other.next(2)
            other.cancel()
        }
        // A stopped stream's record ends when its git has exited, which takes git its own time.
        try await waitUntil { events.finished >= 2 }
        #expect(events.started == 2 && events.finished == 2)

        // A new stream reads on from where the first one stopped.
        #expect(try await repository.historyStream(skip: 5).next(100).count == 15)
    }

    @Test func anLFSPointerCannotNameAFileOutsideItsObjects() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("not for you\n", to: "outside.txt")
        // .git/lfs/objects is there, as after any download.
        let objects = repository.root.appending(path: ".git/lfs/objects")
        try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true)
        // Put together the way git-lfs places objects, this oid would land on outside.txt.
        #expect(repository.lfsObjectURL("sha256:../../outside.txt") == nil)
        try repository.write("*.png filter=lfs diff=lfs merge=lfs -text\n", to: ".gitattributes")
        try repository.write("version https://git-lfs.github.com/spec/v1\noid sha256:../../outside.txt\nsize 12\n", to: "art/logo.png")
        let contents = await repository.contents(of: "art/logo.png", at: .workTree)
        #expect(contents?.data != Data("not for you\n".utf8))

        // A real oid still finds its object.
        let hex = String(repeating: "ab", count: 32)
        let object = objects.appending(path: "ab/ab/\(hex)")
        try FileManager.default.createDirectory(at: object.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: object)
        #expect(repository.lfsObjectURL("sha256:" + hex) != nil)
        #expect(repository.lfsObjectURL("sha256:" + hex.uppercased()) == nil)
    }

    @Test func masksAnyKeyThatEndsInTokenOrSecret() {
        #expect(GitRedaction.redact("protocol=https\nhost=gitlab.com\npassword=s3cret\noauth_refresh_token=r3fresh\n")
                == "protocol=https\nhost=gitlab.com\npassword=***\noauth_refresh_token=***\n")
        #expect(GitRedaction.redact("client_secret: abc123") == "client_secret: ***")
        #expect(GitRedaction.redact("tokens=5 tokenizer=wordpiece") == "tokens=5 tokenizer=wordpiece")
    }

    @Test func neverKeepsACredentialHelpersAnswer() async throws {
        let events = EventLog()
        let runner = GitRunner(executableURL: Self.runner.executableURL, extraEnvironment: [
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        ], onCommand: { events.append($0) })
        let helper = "!f() { echo username=minji; echo password=s3cret; echo oauth_refresh_token=r3fresh; }; f"
        let output = try await runner.run(["-c", "credential.helper=" + helper, "credential", "fill"], in: nil,
                                          input: Data("protocol=https\nhost=example.com\n\n".utf8))
        // The caller gets the answer; the Command Log doesn't keep it.
        #expect(output.text.contains("password=s3cret"))
        #expect(events.finished == 1)
        #expect(events.lastOutput == "(not kept: a credential helper’s answer)")
    }

    @Test func updateToRecordedSeesCommitsOnNoBranchAndWinsOverUpdateNone() async throws {
        let library = try await TestRepositories.make()
        defer { TestRepositories.remove(library) }
        try library.write("1\n", to: "VERSION")
        let recorded = try await library.commitAll("Release 1")
        try library.write("2\n", to: "VERSION")
        let newer = try await library.commitAll("Release 2")

        let app = try await TestRepositories.make()
        defer { TestRepositories.remove(app) }
        try app.write("app\n", to: "README.md")
        try await app.commitAll("Start")
        try await app.git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", library.root.path(percentEncoded: false), "Vendor/Lib"])
        let folder = app.root.appending(path: "Vendor/Lib")
        try await Self.runner.run(["checkout", "-q", recorded], in: folder)
        try await app.commitAll("Add Lib at release 1")

        // On a commit its branches hold: nothing would be left behind.
        try await Self.runner.run(["checkout", "-q", newer], in: folder)
        #expect(await app.submoduleCommitsOnNoBranch("Vendor/Lib").isEmpty)

        // A commit made there on a detached HEAD: no branch holds it.
        try app.write("local\n", to: "Vendor/Lib/LOCAL")
        try await Self.runner.run(["add", "LOCAL"], in: folder)
        try await Self.runner.run(["-c", "user.name=T", "-c", "user.email=t@t.invalid", "commit", "-q", "-m", "Local fix"], in: folder)
        let behind = await app.submoduleCommitsOnNoBranch("Vendor/Lib")
        #expect(behind.map(\.subject) == ["Local fix"])
        let position = try #require(await app.submodulePosition("Vendor/Lib"))
        #expect(position.branch == nil && position.commit == behind.first?.id)

        // `update = none` would leave it where it is; Update to Recorded checks out the recorded commit.
        try await app.git(["config", "submodule.Vendor/Lib.update", "none"])
        try await app.checkOutRecordedSubmodule("Vendor/Lib")
        #expect(await app.submoduleHead("Vendor/Lib") == recorded)

        // ⌘Z works in the submodule as a repository of its own: the commit comes back.
        let submodule = try await app.submodule(at: "Vendor/Lib")
        #expect(await submodule.resolve("HEAD") == recorded)
        try await submodule.detach(at: position.commit)
        #expect(await app.submoduleHead("Vendor/Lib") == position.commit)
        await #expect(throws: NotARepositoryError.self) { _ = try await app.submodule(at: "Vendor/Missing") }
    }
}
