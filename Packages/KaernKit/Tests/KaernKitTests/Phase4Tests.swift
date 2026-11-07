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
