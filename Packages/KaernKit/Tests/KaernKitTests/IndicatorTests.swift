import Foundation
import Testing
@testable import KaernKit

@Suite("Submodules, worktrees, LFS and signatures", .hangGuard)
struct IndicatorTests {
    @Test func parsesSubmoduleStatusLines() {
        let up = Submodule.parse(" a41c9e2a41c9e2a41c9e2a41c9e2a41c9e2a41c9 Vendor/Sparkle (2.6.4)")
        #expect(up?.path == "Vendor/Sparkle")
        #expect(up?.state == .upToDate)
        #expect(Submodule.parse("-9f8e7d69f8e7d69f8e7d69f8e7d69f8e7d69f8e7 Vendor/SwiftCharts")?.state == .notInitialized)
        #expect(Submodule.parse("+9f8e7d69f8e7d69f8e7d69f8e7d69f8e7d69f8e7 Vendor/Sparkle (2.6.4-3-g9f8e7d6)")?.state == .moved)
    }

    @Test func parsesSignatures() {
        let ssh = CommitSignature.parse("G\u{1F}Han Hyeonjin\u{1F}SHA256:abc\u{1F}Good \"git\" signature with ED25519 key SHA256:abc")
        #expect(ssh?.status == .verified)
        #expect(ssh?.format == "SSH")
        #expect(CommitSignature.parse("U\u{1F}Han\u{1F}ABCDEF\u{1F}gpg: Good signature")?.status == .unverified)
        #expect(CommitSignature.parse("N\u{1F}\u{1F}\u{1F}") == nil)
    }

    @Test func recognizesLFSPointers() {
        func line(_ kind: DiffLine.Kind, _ text: String, _ id: Int) -> DiffLine { DiffLine(id: id, kind: kind, text: text, oldNumber: nil, newNumber: nil) }
        let hunk = DiffHunk(id: 0, oldStart: 1, oldCount: 3, newStart: 1, newCount: 3, section: "", lines: [
            line(.context, "version https://git-lfs.github.com/spec/v1", 0),
            line(.deletion, "oid sha256:aaa", 1),
            line(.deletion, "size 48200000", 2),
            line(.addition, "oid sha256:bbb", 3),
            line(.addition, "size 51000000", 4),
        ])
        let change = FileDiff(path: "Assets/Onboarding.mov", hunks: [hunk]).lfsChange
        #expect(change?.old?.size == 48_200_000)
        #expect(change?.new?.size == 51_000_000)
        #expect(FileDiff(path: "a.txt", hunks: []).lfsChange == nil)
    }

    @Test func listsWorktrees() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("a\n", to: "a.txt")
        try await repository.commitAll("first")
        let other = FileManager.default.temporaryDirectory.appending(path: "kaern-worktree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: other) }
        try await repository.git(["worktree", "add", "-q", "-b", "hotfix", other.path(percentEncoded: false)])
        let worktrees = await repository.worktrees()
        #expect(worktrees.count == 2)
        #expect(worktrees.last?.branch == "hotfix")
        #expect(worktrees.first?.branch == "main")
    }
}

@Suite("Ignored paths (integration)", .hangGuard)
struct IgnoredPathTests {
    @Test func filtersOutIgnoredFolders() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("build/\n*.log\n", to: ".gitignore")
        try await repository.commitAll("ignore build output")
        let root = repository.root.path(percentEncoded: false).trimmingSuffix("/")
        let kept = await repository.notIgnored([
            "\(root)/build/Debug/Kaern.app/Contents/MacOS/Kaern",
            "\(root)/Sources/App.swift",
            "\(root)/trace.log",
            "/somewhere/else.txt",
        ])
        #expect(kept == ["Sources/App.swift"])
    }
}
