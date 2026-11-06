import Foundation
import Testing
@testable import KaernKit

/// Discard keeps a copy in the stash list first, and ⌘Z puts everything back.
@Suite("Discard with a kept copy (integration)")
struct DiscardTests {
    private func makeRepository() async throws -> GitRepository {
        let repository = try await TestRepositories.make()
        try repository.write("one\ntwo\nthree\n", to: "a.txt")
        try repository.write("x\n", to: "b.txt")
        try repository.write("keep\n", to: "c.txt")
        try await repository.commitAll("base")
        return repository
    }

    @Test func discardsTrackedAndUntrackedFilesAndRestoresThem() async throws {
        let repository = try await makeRepository()
        defer { TestRepositories.remove(repository) }
        try repository.write("one\nTWO\nthree\n", to: "a.txt")            // unstaged
        try repository.write("y\n", to: "b.txt")
        try await repository.stage(["b.txt"])                              // staged
        try repository.write("draft\n", to: "notes/[draft].md")             // untracked, glob-like name
        try repository.write("other\n", to: "c.txt")                       // not discarded
        let before = try await repository.status()

        let record = try await repository.discard(paths: ["a.txt", "b.txt", "notes/[draft].md"], untracked: ["notes/[draft].md"],
                                                  keepingStaged: false, message: "Before discarding 3 files")
        #expect(record.stash != nil)
        #expect(repository.read("a.txt") == "one\ntwo\nthree\n")
        #expect(repository.read("b.txt") == "x\n")
        #expect(repository.read("notes/[draft].md") == nil)
        #expect(repository.read("c.txt") == "other\n")
        let stashes = try await repository.stashes()
        #expect(stashes.first?.message.hasSuffix("Before discarding 3 files") == true)
        let middle = try await repository.status()
        #expect(middle.entries.map(\.path) == ["c.txt"])

        try await repository.restore(record)
        let after = try await repository.status()
        #expect(after.entries == before.entries)
        #expect(repository.read("a.txt") == "one\nTWO\nthree\n")
        #expect(repository.read("notes/[draft].md") == "draft\n")
        // The copy Discard kept is dropped again.
        let left = try await repository.stashes()
        #expect(left.isEmpty)
    }

    @Test func discardUnstagedKeepsWhatIsStaged() async throws {
        let repository = try await makeRepository()
        defer { TestRepositories.remove(repository) }
        try repository.write("one\ntwo\nthree\nfour\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        try repository.write("ONE\ntwo\nthree\nfour\n", to: "a.txt")      // partially staged
        let before = try await repository.status()

        let record = try await repository.discard(paths: ["a.txt"], untracked: [], keepingStaged: true, message: "Before discarding a.txt")
        #expect(repository.read("a.txt") == "one\ntwo\nthree\nfour\n")
        let middle = try await repository.status()
        #expect(middle.entries.first?.stageState == .staged)

        try await repository.restore(record)
        #expect(repository.read("a.txt") == "ONE\ntwo\nthree\nfour\n")
        let after = try await repository.status()
        #expect(after.entries == before.entries)

        // Discard again after ⌘Z (redo).
        _ = try await repository.discardAgain(record, message: "Before discarding a.txt")
        #expect(repository.read("a.txt") == "one\ntwo\nthree\nfour\n")
    }

    @Test func refusesToRestoreOverANewFile() async throws {
        let repository = try await makeRepository()
        defer { TestRepositories.remove(repository) }
        try repository.write("draft\n", to: "new.txt")
        let record = try await repository.discard(paths: ["new.txt"], untracked: ["new.txt"], keepingStaged: false, message: "Before discarding new.txt")
        try repository.write("something else\n", to: "new.txt")
        await #expect(throws: GitError.self) {
            try await repository.restore(record)
        }
        #expect(repository.read("new.txt") == "something else\n")
    }
}

@Suite("Ignore")
struct IgnoreTests {
    @Test func patternsForAPath() {
        let nested = IgnorePatterns(path: ".github/workflows/ci.yml")
        #expect(nested.file == ".github/workflows/ci.yml")
        #expect(nested.fileExtension == "*.yml")
        #expect(nested.folder == ".github/workflows/")
        let top = IgnorePatterns(path: "notes.txt")
        #expect(top.file == "/notes.txt")
        #expect(top.folder == nil)
        let folder = IgnorePatterns(path: "build/out.log")
        #expect(folder.folder == "/build/")
        let special = IgnorePatterns(path: "docs/[draft]*.md")
        #expect(special.file == "docs/\\[draft]\\*.md")
        #expect(IgnorePatterns(path: "Makefile").fileExtension == nil)
        #expect(IgnorePatterns(path: "#notes").file == "/\\#notes")
    }

    @Test func addsAPatternAndPutsTheFileBack() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("base\n", to: "a.txt")
        try await repository.commitAll("base")
        try repository.write("log\n", to: "build/out.log")
        try repository.write("note\n", to: "todo.txt")

        let first = try repository.addIgnorePattern("/build/")
        #expect(first.previous == nil)
        #expect(repository.read(".gitignore") == "/build/\n")
        var status = try await repository.status()
        #expect(Set(status.entries.map(\.path)) == [".gitignore", "todo.txt"])

        // Appends on a new line even when the file has no final newline.
        try Data("*.tmp".utf8).write(to: repository.root.appending(path: ".gitignore"))
        let second = try repository.addIgnorePattern("/todo.txt")
        #expect(repository.read(".gitignore") == "*.tmp\n/todo.txt\n")
        status = try await repository.status()
        #expect(status.entries.map(\.path).contains("todo.txt") == false)

        try repository.restoreIgnoreFile(second)
        #expect(repository.read(".gitignore") == "*.tmp")
        try repository.restoreIgnoreFile(first)
        #expect(repository.read(".gitignore") == nil)
    }
}
