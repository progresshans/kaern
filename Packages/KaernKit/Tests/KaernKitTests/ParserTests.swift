import Foundation
import Testing
@testable import KaernKit

private func nulJoined(_ records: [String]) -> Data {
    Data((records.joined(separator: "\u{0}") + "\u{0}").utf8)
}

@Suite("Status parser")
struct StatusParserTests {
    @Test func parsesBranchHeadersAndEntries() {
        let data = nulJoined([
            "# branch.oid 7b1e04d3a7c1f00e9b1c2d3e4f5a6b7c8d9e0f11",
            "# branch.head feature/restore-automatic-alpha",
            "# branch.upstream origin/feature/restore-automatic-alpha",
            "# branch.ab +2 -3",
            "# stash 1",
            "1 M. N... 100644 100644 100644 aaaaaaa bbbbbbb .github/workflows/ci.yml",
            "1 MM N... 100644 100644 100644 aaaaaaa bbbbbbb .github/workflows/release.yml",
            "1 .D N... 100644 100644 000000 aaaaaaa aaaaaaa script/legacy_publish.sh",
            "2 R. N... 100644 100644 100644 aaaaaaa aaaaaaa R100 docs/new name.md",
            "docs/old name.md",
            "u UU N... 100644 100644 100644 100644 a b c Package.resolved",
            "? script/publish_github_release.sh",
        ])
        let status = StatusParser.parse(data)
        #expect(status.headID == "7b1e04d3a7c1f00e9b1c2d3e4f5a6b7c8d9e0f11")
        #expect(status.branch == "feature/restore-automatic-alpha")
        #expect(status.upstream == "origin/feature/restore-automatic-alpha")
        #expect(status.ahead == 2)
        #expect(status.behind == 3)
        #expect(status.stashCount == 1)
        #expect(status.entries.count == 6)

        let ci = status.entries[0]
        #expect(ci.stageState == .staged)
        #expect(ci.kind == .modified)

        let release = status.entries[1]
        #expect(release.stageState == .partial)

        let deleted = status.entries[2]
        #expect(deleted.stageState == .unstaged)
        #expect(deleted.kind == .deleted)

        let renamed = status.entries[3]
        #expect(renamed.path == "docs/new name.md")
        #expect(renamed.originalPath == "docs/old name.md")
        #expect(renamed.kind == .renamed)

        let conflict = status.entries[4]
        #expect(conflict.isConflicted)
        #expect(conflict.kind == .conflicted)

        let untracked = status.entries[5]
        #expect(untracked.isUntracked)
        #expect(untracked.kind == .untracked)
        #expect(untracked.stageState == .unstaged)
        #expect(status.stagedCount == 3)
    }

    @Test func parsesUnbornAndDetachedHeads() {
        let unborn = StatusParser.parse(nulJoined(["# branch.oid (initial)", "# branch.head main"]))
        #expect(unborn.head == .unborn("main"))

        let detached = StatusParser.parse(nulJoined(["# branch.oid abcdef1234567", "# branch.head (detached)"]))
        #expect(detached.head == .detached("abcdef1234567"))
    }
}

@Suite("Log and ref parsers")
struct LogAndRefParserTests {
    @Test func parsesLogRecords() {
        let sep = "\u{1F}"
        let data = nulJoined([
            ["a3f9c21aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "7b1e04dbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "Minji Park", "minji@example.com", "1790000000", "feat: reorganize settings navigation"].joined(separator: sep),
            ["2a6c74eccccccccccccccccccccccccccccccccc", "1111111111111111111111111111111111111111 2222222222222222222222222222222222222222", "Han Hyeonjin", "han@example.com", "1789000000", "Merge pull request #10 from feature/charge-limit-awareness"].joined(separator: sep),
        ])
        let commits = LogParser.parse(data)
        #expect(commits.count == 2)
        #expect(commits[0].shortID == "a3f9c21")
        #expect(commits[0].parents == ["7b1e04dbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"])
        #expect(commits[0].author.name == "Minji Park")
        #expect(commits[0].author.initials == "MP")
        #expect(commits[1].isMerge)
        #expect(commits[1].subject.hasPrefix("Merge pull request #10"))
    }

    @Test func parsesRefsAndTracking() {
        let sep = "\u{1F}"
        let text = [
            ["refs/heads/main", "aaa", "", "origin/main", "behind 3", "", " "],
            ["refs/heads/feature/x", "bbb", "", "origin/feature/x", "ahead 2, behind 1", "", "*"],
            ["refs/heads/old", "ccc", "", "origin/old", "gone", "", " "],
            ["refs/remotes/origin/HEAD", "aaa", "", "", "", "refs/remotes/origin/main", " "],
            ["refs/remotes/origin/feature/x", "bbb", "", "", "", "", " "],
            ["refs/tags/v0.9.1", "ddd", "eee", "", "", "", " "],
        ].map { $0.joined(separator: sep) }.joined(separator: "\n")
        let snapshot = RefSnapshot(refs: RefParser.parse(text))
        #expect(snapshot.localBranches.count == 3)
        #expect(snapshot.headBranch?.name == "feature/x")
        #expect(snapshot.headBranch?.ahead == 2)
        #expect(snapshot.headBranch?.behind == 1)
        #expect(snapshot.localBranch(named: "old")?.upstreamGone == true)
        #expect(snapshot.remoteBranches.count == 1)
        #expect(snapshot.remoteBranches.first?.remoteName == "origin")
        #expect(snapshot.remoteBranches.first?.branchName == "feature/x")
        #expect(snapshot.tags.first?.target == "eee")
        #expect(snapshot.refs(at: "bbb").count == 2)
        #expect(snapshot.remoteNames == ["origin"])
    }

    @Test func parsesStashList() {
        let text = "stash@{0}\u{1F}abc123\u{1F}On develop: release notes draft\u{1F}1790000000\nstash@{1}\u{1F}def456\u{1F}WIP on main: 1234567 fix\u{1F}1780000000\n"
        let stashes = StashParser.parse(text)
        #expect(stashes.count == 2)
        #expect(stashes[0].message == "On develop: release notes draft")
        #expect(stashes[1].index == 1)
        #expect(stashes[1].reference == "stash@{1}")
    }

    @Test func parsesNumstatAndNameStatus() {
        let numstat = nulJoined(["4\t1\t.github/workflows/ci.yml", "-\t-\tassets/logo.png", "3\t0\t", "old.txt", "new.txt"])
        let stats = ChangeListParser.parseNumstat(numstat)
        #expect(stats[".github/workflows/ci.yml"] == LineStat(additions: 4, deletions: 1))
        #expect(stats["assets/logo.png"]?.isBinary == true)
        #expect(stats["new.txt"] == LineStat(additions: 3, deletions: 0))

        let names = ChangeListParser.parseNameStatus(nulJoined(["M", "a.swift", "R087", "old.txt", "new.txt", "A", "b.swift"]))
        #expect(names.count == 3)
        #expect(names[1].kind == .renamed)
        #expect(names[1].oldPath == "old.txt")
        #expect(names[1].path == "new.txt")
        #expect(names[2].kind == .added)
    }
}

@Suite("Diff parser")
struct DiffParserTests {
    static let sample = """
    diff --git a/.github/workflows/release.yml b/.github/workflows/release.yml
    index 1111111..2222222 100644
    --- a/.github/workflows/release.yml
    +++ b/.github/workflows/release.yml
    @@ -12,7 +12,9 @@ on:
       workflow_dispatch:
         inputs:
           channel:
    -        description: 'stable or beta'
    +        description: 'stable, beta or alpha'
    +        type: choice
    +        options: [stable, beta, alpha]
             required: true
       push:
         tags: ['v*']
    @@ -41,6 +43,8 @@ jobs:
       release:
         runs-on: macos-15
    +    environment: release
    +    concurrency: release-${{ inputs.channel }}
         steps:
           - uses: actions/checkout@v4
           - name: Build and notarize
    \\ No newline at end of file

    """

    @Test func parsesHunksAndLineNumbers() throws {
        let diffs = DiffParser.parse(Data(Self.sample.utf8))
        let diff = try #require(diffs.first)
        #expect(diff.path == ".github/workflows/release.yml")
        #expect(diff.oldPath == nil)
        #expect(diff.hunks.count == 2)
        #expect(diff.header.count == 4)
        #expect(diff.additions == 5)
        #expect(diff.deletions == 1)

        let first = diff.hunks[0]
        #expect(first.oldStart == 12)
        #expect(first.newCount == 9)
        #expect(first.section == "on:")
        let removed = try #require(first.lines.first { $0.kind == .deletion })
        #expect(removed.oldNumber == 15)
        #expect(removed.newNumber == nil)
        let added = first.lines.filter { $0.kind == .addition }
        #expect(added.map(\.newNumber) == [15, 16, 17])

        let second = diff.hunks[1]
        #expect(second.lines.last?.kind == .noNewline)
    }

    @Test func buildsWholeAndPartialPatches() throws {
        let diff = try #require(DiffParser.parse(Data(Self.sample.utf8)).first)
        let whole = try #require(diff.patch(hunk: 0))
        #expect(whole.contains("@@ -12,7 +12,9 @@"))

        // Keep only the first added line: the deletion becomes context, the other additions drop out.
        let firstAddition = try #require(diff.hunks[0].lines.first { $0.kind == .addition })
        let partial = try #require(diff.patch(hunk: 0, selectedLines: [firstAddition.id]))
        #expect(partial.contains("@@ -12,7 +12,8 @@"))
        #expect(partial.contains("\n         description: 'stable or beta'\n"))
        #expect(!partial.contains("type: choice"))

        // Reverse (unstage) of the same line: other additions become context, the deletion drops out.
        let reverse = try #require(diff.patch(hunk: 0, selectedLines: [firstAddition.id], reverse: true))
        #expect(reverse.contains("@@ -12,8 +12,9 @@"))
        #expect(!reverse.contains("-        description: 'stable or beta'"))
        #expect(reverse.contains("\n         type: choice\n"))

        #expect(diff.patch(hunk: 0, selectedLines: []) == nil)
    }

    @Test func readsPathsOfRenamesAndBinaryFiles() throws {
        let text = """
        diff --git a/old name.txt b/new name.txt
        similarity index 90%
        rename from old name.txt
        rename to new name.txt
        diff --git a/logo.png b/logo.png
        index 1111111..2222222 100644
        Binary files a/logo.png and b/logo.png differ

        """
        let diffs = DiffParser.parse(Data(text.utf8))
        #expect(diffs.count == 2)
        #expect(diffs[0].path == "new name.txt")
        #expect(diffs[0].oldPath == "old name.txt")
        #expect(diffs[1].path == "logo.png")
        #expect(diffs[1].isBinary)
        #expect(!diffs[1].supportsPartialPatches)
    }
}
