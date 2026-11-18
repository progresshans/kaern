import Foundation
import Testing
@testable import KaernKit

@Suite("Settings engine")
struct SettingsEngineTests {
    @Test func contextLinesWidenHunks() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        let lines = (1...30).map { "line \($0)" }
        try repository.write(lines.joined(separator: "\n") + "\n", to: "a.txt")
        try await repository.commitAll("one")
        var changed = lines
        changed[14] = "line fifteen"
        try repository.write(changed.joined(separator: "\n") + "\n", to: "a.txt")

        func contextCount(_ context: Int) async throws -> Int {
            let diff = try #require(try await repository.workingDiffs(staged: false, contextLines: context).first)
            return diff.hunks[0].lines.count { $0.kind == .context }
        }
        #expect(try await contextCount(3) == 6)
        #expect(try await contextCount(1) == 2)
        #expect(try await contextCount(10) == 20)
        // Commit diffs take the same option.
        try await repository.commitAll("two")
        let head = try await repository.commit("HEAD")
        let commitDiff = try #require(try await repository.diffs(of: head, contextLines: 5).first)
        #expect(commitDiff.hunks[0].lines.count { $0.kind == .context } == 10)
        #expect(GitRepository.contextArguments(3).isEmpty)
        #expect(GitRepository.contextArguments(5) == ["-U5"])
    }

    @Test func globalConfigRoundTrip() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "kaern-global-\(UUID().uuidString).gitconfig")
        FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: Data())
        defer { try? FileManager.default.removeItem(at: file) }
        let runner = GitRunner(extraEnvironment: ["GIT_CONFIG_GLOBAL": file.path(percentEncoded: false), "GIT_CONFIG_NOSYSTEM": "1"])
        #expect(await runner.globalConfig("user.name") == nil)
        try await runner.setGlobalConfig("user.name", "Han Hyeonjin")
        try await runner.setGlobalConfig("init.defaultBranch", "main")
        #expect(await runner.globalConfig("user.name") == "Han Hyeonjin")
        #expect(await runner.globalConfig("init.defaultBranch") == "main")
        try await runner.setGlobalConfig("user.name", nil)
        #expect(await runner.globalConfig("user.name") == nil)
        // Removing a key that isn't there is fine.
        try await runner.setGlobalConfig("user.name", nil)
    }
}

@Suite("Conflicts and stashes")
struct ConflictStashTests {
    /// main has `a.txt` changed one way; a stash made on the parent commit changes it another way.
    private func conflictingStash() async throws -> GitRepository {
        let repository = try await TestRepositories.make()
        try repository.write("one\ntwo\nthree\n", to: "a.txt")
        try await repository.commitAll("base")
        try repository.write("one\nTWO (stash)\nthree\n", to: "a.txt")
        try repository.write("kept\n", to: "new.txt")
        try await repository.git(["add", "new.txt"])
        try await repository.git(["stash", "push", "-q", "-m", "work in progress"])
        try repository.write("one\nTWO (main)\nthree\n", to: "a.txt")
        try await repository.commitAll("main changes two")
        return repository
    }

    @Test func popThatConflictsIsReported() async throws {
        let repository = try await conflictingStash()
        defer { TestRepositories.remove(repository) }
        let stash = try #require(try await repository.stashes().first)
        do {
            _ = try await repository.applyStashReportingConflicts(stash, pop: true)
            Issue.record("expected a conflict")
        } catch let conflict as StashApplyConflict {
            #expect(conflict.conflicted == ["a.txt"])
            #expect(conflict.wasPop)
            #expect(Set(conflict.tracked) == ["a.txt", "new.txt"])
        }
        #expect(await repository.unmergedPaths() == ["a.txt"])
        // git keeps the stash after a pop that stopped.
        #expect(try await repository.stashes().count == 1)
    }

    @Test func undoPopPutsTheFilesBack() async throws {
        let repository = try await conflictingStash()
        defer { TestRepositories.remove(repository) }
        let stash = try #require(try await repository.stashes().first)
        var caught: StashApplyConflict?
        do { _ = try await repository.applyStashReportingConflicts(stash, pop: true) } catch let conflict as StashApplyConflict { caught = conflict }
        let conflict = try #require(caught)
        try await repository.takeBack(conflict)
        #expect(await repository.unmergedPaths().isEmpty)
        #expect(repository.read("a.txt") == "one\nTWO (main)\nthree\n")
        #expect(repository.read("new.txt") == nil)
        #expect(try await repository.status().isClean)
        #expect(try await repository.stashes().count == 1)
    }

    @Test func resolvingAConflictWithTheDocument() async throws {
        let repository = try await conflictingStash()
        defer { TestRepositories.remove(repository) }
        let stash = try #require(try await repository.stashes().first)
        _ = try? await repository.applyStashReportingConflicts(stash, pop: false)
        let document = try #require(repository.conflictDocument("a.txt"))
        #expect(document.conflictCount == 1)
        let resolved = document.resolving(0, with: .theirs)
        #expect(!resolved.hasConflicts)
        try await repository.writeResolution(resolved.text, to: "a.txt")
        #expect(await repository.unmergedPaths().isEmpty)
        #expect(repository.read("a.txt") == "one\nTWO (stash)\nthree\n")
    }

    @Test func renameKeepsThePlaceInTheList() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("a\n", to: "a.txt")
        try await repository.commitAll("base")
        for name in ["first", "second", "third"] {
            try repository.write("\(name)\n", to: "a.txt")
            try await repository.git(["stash", "push", "-q", "-m", name])
        }
        let before = try await repository.stashes()
        #expect(before.map(\.message) == ["On main: third", "On main: second", "On main: first"])
        try await repository.renameStash(before[1], to: "On main: second, renamed")
        let after = try await repository.stashes()
        #expect(after.map(\.message) == ["On main: third", "On main: second, renamed", "On main: first"])
        #expect(after.map(\.id) == before.map(\.id))
        #expect(after.map(\.date) == before.map(\.date))
    }

    @Test func undoPopKeepsStagedAndUnstagedWork() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("one\ntwo\nthree\n", to: "a.txt")
        try repository.write("c\n", to: "c.txt")
        try await repository.commitAll("base")
        try repository.write("one\nTWO (stash)\nthree\n", to: "a.txt")
        try repository.write("C\n", to: "c.txt")
        try await repository.git(["stash", "push", "-q", "-m", "work in progress"])
        // Staged work in the file the stash changes: git still pops and stops on the conflict.
        try repository.write("one\nTWO (staged)\nthree\n", to: "a.txt")
        // The stash's change to c.txt staged as well, plus more not staged: git pops without touching it.
        try repository.write("C\n", to: "c.txt")
        try await repository.git(["add", "a.txt", "c.txt"])
        try repository.write("C, not staged\n", to: "c.txt")
        let stash = try #require(try await repository.stashes().first)
        var caught: StashApplyConflict?
        do { _ = try await repository.applyStashReportingConflicts(stash, pop: true) } catch let conflict as StashApplyConflict { caught = conflict }
        let conflict = try #require(caught)
        #expect(conflict.conflicted == ["a.txt"])
        try await repository.takeBack(conflict)
        #expect(await repository.unmergedPaths().isEmpty)
        #expect(repository.read("a.txt") == "one\nTWO (staged)\nthree\n")
        #expect(try await repository.git(["show", ":a.txt"]).text == "one\nTWO (staged)\nthree\n")
        #expect(repository.read("c.txt") == "C, not staged\n")
        #expect(try await repository.git(["show", ":c.txt"]).text == "C\n")
        #expect(try await repository.stashes().count == 1)
    }

    @Test func aRenameThatStopsHalfwayPutsTheStashesBack() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("a\n", to: "a.txt")
        try await repository.commitAll("base")
        for name in ["first", "second", "third"] {
            try repository.write("\(name)\n", to: "a.txt")
            try await repository.git(["stash", "push", "-q", "-m", name])
        }
        let before = try await repository.stashes()
        // git dropped the top two entries, then failed.
        try await repository.git(["stash", "drop", "-q", "stash@{0}"])
        try await repository.git(["stash", "drop", "-q", "stash@{0}"])
        await repository.restoreMissingStashes(Array(before[...1]))
        let after = try await repository.stashes()
        #expect(after.map(\.id) == before.map(\.id))
        #expect(after.map(\.message) == before.map(\.message))
    }

    @Test func remoteAddressCanChange() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try await repository.addRemote("origin", url: "https://example.com/a.git")
        try await repository.setRemoteURL("origin", url: "https://example.com/b.git")
        #expect(await repository.remoteInfos().first?.fetchURL == "https://example.com/b.git")
    }

    @Test func interactiveRebaseSquashesAndRewords() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("0\n", to: "a.txt")
        let base = try await repository.commitAll("base")
        for index in 1...3 {
            try repository.write("\(index)\n", to: "f\(index).txt")
            try await repository.commitAll("commit \(index)")
        }
        let commits = try await repository.commitsToRebase(onto: base)
        #expect(commits.map(\.subject) == ["commit 1", "commit 2", "commit 3"])
        let steps = [
            RebaseStep(commit: commits[0], action: .reword, message: "first, reworded"),
            RebaseStep(commit: commits[1], action: .fixup),
            RebaseStep(commit: commits[2]),
        ]
        let outcome = try await repository.interactiveRebase(onto: base, steps: steps, autostash: false)
        #expect(outcome == .finished)
        let subjects = try await repository.git(["log", "--format=%s", "\(base)..HEAD"]).text
            .split(separator: "\n").map(String.init)
        #expect(subjects == ["commit 3", "first, reworded"])
        #expect(repository.read("f2.txt") == "2\n")
    }
}

@Suite("Why a command failed")
struct GitFailureTests {
    @Test func signInExpired() {
        let error = """
        remote: Invalid username or token. Password authentication is not supported for Git operations.
        fatal: Authentication failed for 'https://github.com/***/recipe-box.git/'
        """
        #expect(GitFailure.explain(arguments: ["fetch", "--prune", "origin"], errorOutput: error, status: 128) == .signIn(host: "github.com"))
        let prompt = "fatal: could not read Username for 'https://gitlab.com': terminal prompts disabled"
        #expect(GitFailure.explain(arguments: ["push"], errorOutput: prompt, status: 128) == .signIn(host: "gitlab.com"))
    }

    @Test func sshAndNetwork() {
        let ssh = "git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository."
        #expect(GitFailure.explain(arguments: ["fetch"], errorOutput: ssh, status: 128) == .sshKey(host: "github.com"))
        let dns = "fatal: unable to access 'https://github.com/kaern/app.git/': Could not resolve host: github.com"
        #expect(GitFailure.explain(arguments: ["fetch"], errorOutput: dns, status: 128) == .network(host: "github.com"))
        let port = "ssh: connect to host gitlab.example.com port 22: Operation timed out"
        #expect(GitFailure.explain(arguments: ["pull"], errorOutput: port, status: 128) == .network(host: "gitlab.example.com"))
    }

    @Test func pushRejectedConflictsAndLocks() {
        let rejected = """
        To github.com:kaern/app.git
         ! [rejected]        main -> main (fetch first)
        error: failed to push some refs to 'github.com:kaern/app.git'
        """
        #expect(GitFailure.explain(arguments: ["push", "origin", "main"], errorOutput: rejected, status: 1) == .pushRejected(remote: "origin"))
        let conflict = "CONFLICT (content): Merge conflict in a.txt\nCONFLICT (content): Merge conflict in b.txt\nAutomatic merge failed; fix conflicts and then commit the result."
        #expect(GitFailure.explain(arguments: ["merge", "develop"], errorOutput: "", output: conflict, status: 1) == .conflicts(files: 2))
        let lock = "fatal: Unable to create '/Users/me/app/.git/index.lock': File exists.\n\nAnother git process seems to be running"
        #expect(GitFailure.explain(arguments: ["commit"], errorOutput: lock, status: 128) == .locked(path: "/Users/me/app/.git/index.lock"))
        let local = """
        error: Your local changes to the following files would be overwritten by checkout:
        \tSources/App.swift
        \tREADME.md
        Please commit your changes or stash them before you switch branches.
        """
        #expect(GitFailure.explain(arguments: ["switch", "develop"], errorOutput: local, status: 1) == .localChanges(files: ["Sources/App.swift", "README.md"]))
        #expect(GitFailure.explain(arguments: ["status"], errorOutput: "", status: 0) == nil)
        #expect(GitFailure.explain(arguments: ["log"], errorOutput: "fatal: something else", status: 128) == nil)
    }
}

@Suite("What a failed command says")
struct GitErrorTextTests {
    private func text(_ output: String) -> String? {
        GitError(arguments: ["push"], status: 128, message: output).errorDescription
    }

    @Test func setsGitsAdviceApartOnOneLine() {
        let ssh = """
        git@github.com: Permission denied (publickey).
        fatal: Could not read from remote repository.

        Please make sure you have the correct access rights
        and the repository exists.
        """
        #expect(text(ssh) == """
        git@github.com: Permission denied (publickey).
        Could not read from remote repository.

        Please make sure you have the correct access rights and the repository exists.
        """)
        // Nothing above it: no empty line to open with.
        #expect(text("Please make sure you have the correct access rights\nand the repository exists.")
                == "Please make sure you have the correct access rights and the repository exists.")
    }

    @Test func keepsEveryOtherLineApart() {
        let paths = """
        error: pathspec 'a.txt' did not match any file(s) known to git
        error: pathspec 'b.txt' did not match any file(s) known to git
        """
        #expect(text(paths) == """
        pathspec 'a.txt' did not match any file(s) known to git
        pathspec 'b.txt' did not match any file(s) known to git
        """)
        let local = """
        error: Your local changes to the following files would be overwritten by checkout:
        \tSources/App.swift
        \treadme.md
        Please commit your changes or stash them before you switch branches.
        Aborting
        """
        #expect(text(local) == """
        Your local changes to the following files would be overwritten by checkout:
        Sources/App.swift
        readme.md
        Please commit your changes or stash them before you switch branches.
        Aborting
        """)
    }
}
