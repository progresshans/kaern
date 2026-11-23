import Foundation
import Testing
@testable import KaernKit

@Suite("Interactive rebase (integration)", .hangGuard)
struct InteractiveRebaseTests {
    @Test func reordersRewordsFixesUpAndDrops() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("base\n", to: "a.txt")
        let base = try await repository.commitAll("base")
        try repository.write("one\n", to: "one.txt")
        try await repository.commitAll("feat: one")
        try repository.write("two\n", to: "two.txt")
        try await repository.commitAll("feat: two")
        try repository.write("one fixed\n", to: "one.txt")
        try await repository.commitAll("fixup one")
        try repository.write("junk\n", to: "junk.txt")
        try await repository.commitAll("wip: junk")

        let commits = try await repository.commitsToRebase(onto: base)
        #expect(commits.map(\.subject) == ["feat: one", "feat: two", "fixup one", "wip: junk"])
        // two first, then one with its fixup, reworded; junk dropped.
        let steps = [
            RebaseStep(commit: commits[1]),
            RebaseStep(commit: commits[0], action: .reword, message: "feat: one, done right\n\nWith a body."),
            RebaseStep(commit: commits[2], action: .fixup),
            RebaseStep(commit: commits[3], action: .drop),
        ]
        let outcome = try await repository.interactiveRebase(onto: base, steps: steps, autostash: false)
        #expect(outcome == .finished)
        let log = try await repository.git(["log", "--format=%s", "\(base)..HEAD"]).text
            .split(separator: "\n").map(String.init)
        #expect(log == ["feat: one, done right", "feat: two"])
        #expect(repository.read("one.txt") == "one fixed\n")
        #expect(repository.read("junk.txt") == nil)
        let body = try await repository.git(["log", "-1", "--format=%b"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(body == "With a body.")
    }

    @Test func editStopsForAmending() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("base\n", to: "a.txt")
        let base = try await repository.commitAll("base")
        try repository.write("one\n", to: "one.txt")
        try await repository.commitAll("feat: one")
        let commits = try await repository.commitsToRebase(onto: base)
        let outcome = try await repository.interactiveRebase(onto: base, steps: [RebaseStep(commit: commits[0], action: .edit)], autostash: false)
        #expect(outcome == .stopped)
        #expect(repository.operationState()?.kind == .rebase)
        _ = try await repository.continueOperation(try #require(repository.operationState()))
        #expect(repository.operationState() == nil)
    }
}
