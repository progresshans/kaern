import Foundation
import Testing
@testable import KaernKit

@Suite("Compare, pick and push (integration)", .hangGuard)
struct CompareAndPushTests {
    /// main: base → m1 → m2; topic (from base): t1 → t2.
    private func makeBranches() async throws -> (GitRepository, [String: String]) {
        let repository = try await TestRepositories.make()
        var ids: [String: String] = [:]
        try repository.write("base\n", to: "base.txt")
        ids["base"] = try await repository.commitAll("base")
        try await repository.createBranch("topic", startPoint: nil, checkout: false)
        try repository.write("m1\n", to: "main.txt")
        ids["m1"] = try await repository.commitAll("m1")
        try repository.write("m1\nm2\n", to: "main.txt")
        ids["m2"] = try await repository.commitAll("m2")
        try await repository.switchBranch("topic")
        try repository.write("t1\n", to: "topic.txt")
        ids["t1"] = try await repository.commitAll("t1")
        try repository.write("t1\nt2\n", to: "topic.txt")
        ids["t2"] = try await repository.commitAll("t2")
        try await repository.switchBranch("main")
        return (repository, ids)
    }

    private func makeRemote(for repository: GitRepository) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "kaern-remote-\(UUID().uuidString).git")
        try await RepositoryTests.runner.run(["init", "-q", "--bare", "-b", "main", url.path(percentEncoded: false)], in: nil)
        try await repository.addRemote("origin", url: url.path(percentEncoded: false))
        return url
    }

    @Test func comparesBranchesAndRanges() async throws {
        let (repository, ids) = try await makeBranches()
        defer { TestRepositories.remove(repository) }
        let comparison = try await repository.compare("main", with: "topic")
        #expect(comparison.ours == [ids["m2"]!, ids["m1"]!])
        #expect(comparison.theirs == [ids["t2"]!, ids["t1"]!])
        #expect(comparison.base == ids["base"])

        let range = try await repository.commitIDs(from: ids["m1"]!, to: ids["t2"]!)
        #expect(range == [ids["t2"]!, ids["t1"]!])
        let base = await repository.mergeBase(ids["m1"]!, ids["t2"]!)
        #expect(base == ids["base"])
        let summaries = try await repository.summaries(["\(ids["base"]!)..main"])
        #expect(summaries.map(\.subject) == ["m2", "m1"])

        try repository.write("m1\nm2\nlocal\n", to: "main.txt")
        let files = try await repository.changedFilesToWorkingTree(from: ids["m1"]!)
        #expect(files.map(\.path) == ["main.txt"])
        #expect(files.first?.stat == LineStat(additions: 2, deletions: 0))
        let diffs = try await repository.diffsToWorkingTree(from: ids["m1"]!)
        #expect(diffs.first?.additions == 2)
    }

    @Test func cherryPicksAndRevertsSeveralCommits() async throws {
        let (repository, ids) = try await makeBranches()
        defer { TestRepositories.remove(repository) }
        let commits = try await repository.log(skip: 0, limit: 20, includeHEAD: true)
        func commit(_ name: String) -> Commit { commits.first { $0.id == ids[name] }! }

        // Oldest first.
        let picked = try await repository.cherryPick([commit("t1"), commit("t2")])
        #expect(picked == .finished)
        #expect(repository.read("topic.txt") == "t1\nt2\n")
        #expect(try await repository.headSubject() == "t2")

        // Newest first: m2 then m1.
        let reverted = try await repository.revert([commit("m2"), commit("m1")])
        #expect(reverted == .finished)
        #expect(repository.read("main.txt") == nil)
        #expect(try await repository.headSubject() == "Revert \"m1\"")
        let branch = await repository.currentBranchName()
        #expect(branch == "main")
    }

    @Test func picksWithStagedChangesPutAsideAndBack() async throws {
        let (repository, ids) = try await makeBranches()
        defer { TestRepositories.remove(repository) }
        let commits = try await repository.log(skip: 0, limit: 20, includeHEAD: true)
        let t1 = try #require(commits.first { $0.id == ids["t1"] })
        // A staged change and an unstaged one in files the pick doesn't touch.
        try repository.write("base\nstaged\n", to: "base.txt")
        try await repository.stage(["base.txt"])
        try repository.write("m1\nm2\nlocal\n", to: "main.txt")
        // git alone refuses: the index isn't clean.
        await #expect(throws: GitError.self) {
            _ = try await repository.cherryPick([t1])
        }
        let result = try await repository.withChangesStashed(message: "Before cherry-pick") {
            try await repository.cherryPick([t1])
        }
        #expect(result.outcome == .finished)
        #expect(result.kept == nil)
        #expect(try await repository.headSubject() == "t1")
        #expect(repository.read("topic.txt") == "t1\n")
        let status = try await repository.status()
        #expect(status.entries.first { $0.path == "base.txt" }?.stageState == .staged)
        #expect(status.entries.first { $0.path == "main.txt" }?.hasUnstagedChanges == true)
        #expect(try await repository.stashes().isEmpty)
    }

    /// ⌘Z of a pick moves the branch back and leaves staged files staged (a plain `reset --keep`
    /// unstages them, and a staged new file would turn untracked).
    @Test func movingBackKeepsWhatIsStaged() async throws {
        let (repository, ids) = try await makeBranches()
        defer { TestRepositories.remove(repository) }
        let before = try #require(await repository.resolve("HEAD"))
        try repository.write("base\nstaged\n", to: "base.txt")
        try repository.write("new\n", to: "new.txt")
        try await repository.stage(["base.txt", "new.txt"])
        try repository.write("m1\nm2\nlocal\n", to: "main.txt")
        let statusBefore = try await repository.status()
        let commits = try await repository.log(skip: 0, limit: 20, includeHEAD: true)
        let t1 = try #require(commits.first { $0.id == ids["t1"] })
        _ = try await repository.withChangesStashed(message: "Before cherry-pick") {
            try await repository.cherryPick([t1])
        }
        let picked = try #require(await repository.resolve("HEAD"))
        try await repository.resetKeepingStaged(to: before)
        #expect(await repository.resolve("HEAD") == before)
        let statusAfter = try await repository.status()
        #expect(statusAfter.entries == statusBefore.entries)
        // And forward again (⇧⌘Z).
        try await repository.resetKeepingStaged(to: picked)
        let redone = try await repository.status()
        #expect(redone.entries.first { $0.path == "new.txt" }?.stageState == .staged)
        #expect(repository.read("topic.txt") == "t1\n")
    }

    /// A revert that changes a file the uncommitted changes touch: it finishes, and the changes
    /// stay in the stash list instead of coming back with conflict markers.
    @Test func changesTouchingTheResultStayInTheStashList() async throws {
        let (repository, ids) = try await makeBranches()
        defer { TestRepositories.remove(repository) }
        try repository.write("m1\nm2\nmine\n", to: "main.txt")      // m2 touched main.txt
        let commits = try await repository.log(skip: 0, limit: 20, includeHEAD: true)
        let m2 = try #require(commits.first { $0.id == ids["m2"] })
        let result = try await repository.withChangesStashed(message: "Before revert") {
            try await repository.revert([m2])
        }
        #expect(result.outcome == .finished)
        let kept = try #require(result.kept)
        #expect(try await repository.headSubject() == "Revert \"m2\"")
        #expect(repository.read("main.txt") == "m1\n")
        // Moving back and popping restores the starting point exactly.
        try await repository.resetKeepingStaged(to: ids["m2"]!)
        try await repository.popStash(object: kept)
        #expect(repository.read("main.txt") == "m1\nm2\nmine\n")
    }

    @Test func aPickThatStopsKeepsTheChangesInTheStashList() async throws {
        let (repository, ids) = try await makeBranches()
        defer { TestRepositories.remove(repository) }
        // topic.txt on main conflicts with t1's.
        try repository.write("main's own\n", to: "topic.txt")
        _ = try await repository.commitAll("main adds topic.txt")
        try repository.write("base\nlocal\n", to: "base.txt")
        let commits = try await repository.log(skip: 0, limit: 20, includeHEAD: true)
        let t1 = try #require(commits.first { $0.id == ids["t1"] })
        let result = try await repository.withChangesStashed(message: "Before cherry-pick") {
            try await repository.cherryPick([t1])
        }
        #expect(result.outcome == .stopped)
        let kept = try #require(result.kept)
        let stash = await repository.stash(withObject: kept)
        #expect(stash?.message.hasSuffix("Before cherry-pick") == true)
        try await repository.abortOperation(.cherryPick)
        try await repository.popStash(object: kept)
        #expect(repository.read("base.txt") == "base\nlocal\n")
    }

    @Test func publishesTracksAndPushesBranches() async throws {
        let (repository, _) = try await makeBranches()
        defer { TestRepositories.remove(repository) }
        let remote = try await makeRemote(for: repository)
        defer { try? FileManager.default.removeItem(at: remote) }

        let noRemoteBranches = await repository.unpublishedCount()
        #expect(noRemoteBranches == nil)
        try await repository.publish(to: "origin", as: "main", track: true)
        var status = try await repository.status()
        #expect(status.upstream == "origin/main")
        let published = await repository.unpublishedCount()
        #expect(published == 0)

        // Push once without tracking, under another name.
        try await repository.switchBranch("topic")
        let unpublished = await repository.unpublishedCount()
        #expect(unpublished == 2)
        try await repository.publish(to: "origin", as: "review/topic", track: false)
        status = try await repository.status()
        #expect(status.upstream == nil)
        let remoteTopic = try await RepositoryTests.runner.run(["rev-parse", "refs/heads/review/topic"], in: remote)
        #expect(remoteTopic.text.trimmingCharacters(in: .whitespacesAndNewlines) == (await repository.resolve("topic")))

        // A branch that isn't checked out.
        try await repository.push(branch: "main", to: "origin", as: "copy-of-main")
        let copy = try await RepositoryTests.runner.run(["rev-parse", "refs/heads/copy-of-main"], in: remote)
        #expect(copy.text.trimmingCharacters(in: .whitespacesAndNewlines) == (await repository.resolve("main")))
    }

    @Test func forcePushNeedsTheLeaseToMatch() async throws {
        let (repository, _) = try await makeBranches()
        defer { TestRepositories.remove(repository) }
        let remote = try await makeRemote(for: repository)
        defer { try? FileManager.default.removeItem(at: remote) }
        try await repository.publish(to: "origin", as: "main", track: true)
        let published = try #require(await repository.resolve("origin/main"))

        // Rewrite the last commit: the remote has a commit this branch replaced.
        try repository.write("m1\nm2 amended\n", to: "main.txt")
        try await repository.stage(["main.txt"])
        try await repository.commit(message: "m2 amended", amend: true)
        let rewritten = await repository.branchHadCommit("main", commit: published)
        #expect(rewritten)
        let lost = try await repository.summaries(["HEAD..origin/main"])
        #expect(lost.map(\.subject) == ["m2"])

        // A wrong lease is refused; the right one replaces the remote branch.
        await #expect(throws: GitError.self) {
            try await repository.forcePush(to: "origin", branch: "main", expected: String(repeating: "1", count: 40))
        }
        try await repository.forcePush(to: "origin", branch: "main", expected: published)
        try await repository.fetch(remote: "origin")
        #expect(await repository.resolve("origin/main") == (await repository.resolve("HEAD")))

        // A commit the branch never had: someone else pushed.
        let other = try #require(await repository.resolve("topic"))
        let neverHad = await repository.branchHadCommit("main", commit: other)
        #expect(!neverHad)
    }

    @Test func fastForwardsABranchThatIsNotCheckedOut() async throws {
        let (repository, _) = try await makeBranches()
        defer { TestRepositories.remove(repository) }
        let remote = try await makeRemote(for: repository)
        defer { try? FileManager.default.removeItem(at: remote) }
        try await repository.publish(to: "origin", as: "main", track: true)
        try await repository.git(["branch", "-q", "behind", "HEAD~1"])
        try await repository.fastForward(branch: "behind", from: "origin", remoteBranch: "main")
        #expect(await repository.resolve("behind") == (await repository.resolve("main")))
        // Not a fast-forward: refused.
        await #expect(throws: GitError.self) {
            try await repository.fastForward(branch: "topic", from: "origin", remoteBranch: "main")
        }
    }

    @Test func pullRequestPages() {
        let github = RemoteURL("git@github.com:progresshans/powerlens.git")
        #expect(github?.pullRequestPage(branch: "feature/x")?.absoluteString
                == "https://github.com/progresshans/powerlens/compare/feature/x?expand=1")
        #expect(github?.newReleasePage(tag: "v1.0")?.absoluteString == "https://github.com/progresshans/powerlens/releases/new?tag=v1.0")
        let gitlab = RemoteURL("https://gitlab.com/team/app.git")
        #expect(gitlab?.pullRequestPage(branch: "fix")?.absoluteString
                == "https://gitlab.com/team/app/-/merge_requests/new?merge_request%5Bsource_branch%5D=fix")
    }
}

@Suite("Undo plumbing, phase 3 (integration)", .hangGuard)
struct UndoPlumbingTests {
    @Test func indexEntriesGoBackAndForth() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("one\n", to: "a.txt")
        try await repository.commitAll("base")
        try repository.write("one\ntwo\n", to: "a.txt")
        try repository.write("new\n", to: "new [1].txt")
        let before = try #require(await repository.writeIndexTree())

        try await repository.stage(["a.txt", "new [1].txt"])
        let after = try #require(await repository.writeIndexTree())
        #expect(before != after)
        let matchesAfter = await repository.indexMatches(after, paths: ["a.txt", "new [1].txt"])
        #expect(matchesAfter)

        // Undo: both files leave the index (the new one becomes untracked again).
        try await repository.restoreIndex(paths: ["a.txt", "new [1].txt"], from: before)
        var status = try await repository.status()
        #expect(status.stagedCount == 0)
        #expect(status.entries.first { $0.path == "new [1].txt" }?.isUntracked == true)
        let matchesBefore = await repository.indexMatches(before, paths: ["a.txt", "new [1].txt"])
        #expect(matchesBefore)

        // Redo.
        try await repository.restoreIndex(paths: ["a.txt", "new [1].txt"], from: after)
        status = try await repository.status()
        #expect(status.stagedCount == 2)
        #expect(repository.read("a.txt") == "one\ntwo\n")
    }

    @Test func poppedStashGoesBackIntoTheList() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("one\n", to: "a.txt")
        try await repository.commitAll("base")
        try repository.write("one\nchanged\n", to: "a.txt")
        try repository.write("fresh\n", to: "fresh.txt")
        try await repository.stash(message: "work", includeUntracked: true)
        let stash = try #require(try await repository.stashes().first)

        let applied = try #require(try await repository.applyStashUndoably(stash, pop: true))
        #expect(applied.tracked == ["a.txt"])
        #expect(applied.untracked == ["fresh.txt"])
        #expect(try await repository.stashes().isEmpty)
        #expect(repository.read("fresh.txt") == "fresh\n")

        try await repository.unapply(applied)
        let status = try await repository.status()
        #expect(status.isClean)
        let back = try await repository.stashes()
        #expect(back.map(\.id) == [stash.id])

        // Edited after the pop: ⌘Z refuses instead of losing the edit.
        let again = try #require(try await repository.applyStashUndoably(back[0], pop: false))
        try repository.write("one\nchanged\nmore\n", to: "a.txt")
        await #expect(throws: GitError.self) {
            try await repository.unapply(again)
        }
        #expect(repository.read("a.txt") == "one\nchanged\nmore\n")
    }

    @Test func localChangesElsewhereDontBlockUndo() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("one\n", to: "a.txt")
        try repository.write("x\n", to: "b.txt")
        try await repository.commitAll("base")
        try repository.write("one\nstashed\n", to: "a.txt")
        try await repository.stash(message: "work", includeUntracked: false)
        let stash = try #require(try await repository.stashes().first)
        try repository.write("x\nlocal\n", to: "b.txt")            // a different file: apply works
        let applied = try await repository.applyStashUndoably(stash, pop: false)
        #expect(applied != nil)
        #expect(repository.read("a.txt") == "one\nstashed\n")
    }
}
