import Foundation
import Testing
@testable import KaernKit

@Suite("Operations (integration)")
struct OperationTests {
    /// main and feature both change line 2 of f.txt; feature has a second, clean commit.
    private func makeDivergedRepository() async throws -> (GitRepository, featureFirst: String) {
        let repository = try await TestRepositories.make()
        try repository.write("a\nb\nc\n", to: "f.txt")
        try await repository.commitAll("base")
        try await repository.createBranch("feature", startPoint: nil, checkout: true)
        try repository.write("a\nFEATURE\nc\n", to: "f.txt")
        let first = try await repository.commitAll("feat: change b", author: "Original")
        try repository.write("x\n", to: "g.txt")
        try await repository.commitAll("feat: add g", author: "Original")
        try await repository.switchBranch("main")
        try repository.write("a\nMAIN\nc\n", to: "f.txt")
        try repository.write("n\n", to: "notes.md")
        try await repository.commitAll("main: change b")
        return (repository, first)
    }

    @Test func rebaseStopsOnConflictAndContinuesWithEditedMessage() async throws {
        let (repository, featureFirst) = try await makeDivergedRepository()
        defer { TestRepositories.remove(repository) }
        try await repository.switchBranch("feature")

        let outcome = try await repository.rebase(onto: "main")
        #expect(outcome == .stopped)
        let state = try #require(repository.operationState())
        #expect(state.kind == .rebase)
        #expect(state.branch == "feature")
        #expect(state.step == 1)
        #expect(state.total == 2)
        #expect(state.incoming == featureFirst)
        #expect(state.message == "feat: change b")
        let status = try await repository.status()
        #expect(status.conflictCount == 1)
        #expect(status.branch == nil)

        let document = try #require(repository.conflictDocument("f.txt"))
        #expect(document.conflictCount == 1)
        #expect(document.blocks[0].ours == ["MAIN"])
        #expect(document.blocks[0].theirs == ["FEATURE"])
        try await repository.writeResolution(document.resolvingAll(with: .both).text, to: "f.txt")
        #expect(repository.read("f.txt") == "a\nMAIN\nFEATURE\nc\n")

        let finished = try await repository.continueOperation(state, message: "feat: change b, reworded")
        #expect(finished == .finished)
        #expect(repository.operationState() == nil)
        let after = try await repository.status()
        #expect(after.branch == "feature")
        let reworded = try await repository.headSubject("HEAD~1")
        #expect(reworded == "feat: change b, reworded")
        let author = try await repository.git(["log", "-1", "--format=%an", "HEAD~1"]).text
        #expect(author.trimmingCharacters(in: .whitespacesAndNewlines) == "Original")
    }

    @Test func continuingWithConflictsLeftThrows() async throws {
        let (repository, _) = try await makeDivergedRepository()
        defer { TestRepositories.remove(repository) }
        try await repository.switchBranch("feature")
        _ = try await repository.rebase(onto: "main")
        let state = try #require(repository.operationState())
        await #expect(throws: GitError.self) {
            _ = try await repository.continueOperation(state)
        }
        #expect(repository.operationState() != nil)
    }

    @Test func abortRestoresTheBranch() async throws {
        let (repository, _) = try await makeDivergedRepository()
        defer { TestRepositories.remove(repository) }
        try await repository.switchBranch("feature")
        let before = try await repository.status().headID
        _ = try await repository.rebase(onto: "main")
        try await repository.abortOperation(.rebase)
        #expect(repository.operationState() == nil)
        let status = try await repository.status()
        #expect(status.branch == "feature")
        #expect(status.headID == before)
        #expect(status.isClean)
    }

    @Test func skipDropsTheConflictingCommit() async throws {
        let (repository, _) = try await makeDivergedRepository()
        defer { TestRepositories.remove(repository) }
        try await repository.switchBranch("feature")
        _ = try await repository.rebase(onto: "main")
        let outcome = try await repository.skipOperationStep(.rebase)
        #expect(outcome == .finished)
        let head = try await repository.headSubject()
        let parent = try await repository.headSubject("HEAD~1")
        #expect(head == "feat: add g")
        #expect(parent == "main: change b")
    }

    @Test func mergeConflictTakesTheirsAndCommits() async throws {
        let (repository, _) = try await makeDivergedRepository()
        defer { TestRepositories.remove(repository) }

        let outcome = try await repository.merge("feature")
        #expect(outcome == .stopped)
        let state = try #require(repository.operationState())
        #expect(state.kind == .merge)
        #expect(state.incomingName == "feature")
        #expect(state.message == "Merge branch 'feature'")
        let status = try await repository.status()
        // g.txt merged cleanly and is staged; f.txt conflicts.
        #expect(status.entries.first { $0.path == "g.txt" }?.hasStagedChanges == true)
        #expect(status.entries.first { $0.path == "f.txt" }?.isConflicted == true)

        try await repository.resolveConflict("f.txt", taking: .theirs)
        #expect(repository.read("f.txt") == "a\nFEATURE\nc\n")
        let finished = try await repository.continueOperation(state)
        #expect(finished == .finished)
        let parents = try await repository.git(["log", "-1", "--format=%P"]).text.split(separator: " ")
        #expect(parents.count == 2)
        let message = try await repository.git(["log", "-1", "--format=%B"]).text
        #expect(message.trimmingCharacters(in: .whitespacesAndNewlines) == "Merge branch 'feature'")
    }

    @Test func takingTheSideThatDeletedAFileRemovesIt() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("one\n", to: "doc.txt")
        try await repository.commitAll("base")
        try await repository.createBranch("cleanup", startPoint: nil, checkout: true)
        try await repository.git(["rm", "-q", "doc.txt"])
        try await repository.commit(message: "remove doc", amend: false)
        try await repository.switchBranch("main")
        try repository.write("one\ntwo\n", to: "doc.txt")
        try await repository.commitAll("edit doc")

        let outcome = try await repository.merge("cleanup")
        #expect(outcome == .stopped)
        let stages = try await repository.conflictStages("doc.txt")
        #expect(stages == [1, 2])
        try await repository.resolveConflict("doc.txt", taking: .theirs)
        #expect(repository.read("doc.txt") == nil)
        let status = try await repository.status()
        #expect(status.conflictCount == 0)
    }

    @Test func cleanMergeFinishes() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("one\n", to: "a.txt")
        try await repository.commitAll("base")
        try await repository.createBranch("topic", startPoint: nil, checkout: true)
        try repository.write("two\n", to: "b.txt")
        try await repository.commitAll("topic")
        try await repository.switchBranch("main")
        let outcome = try await repository.merge("topic", fastForward: .never)
        #expect(outcome == .finished)
        #expect(repository.operationState() == nil)
        let subject = try await repository.headSubject()
        #expect(subject == "Merge branch 'topic'")
    }

    @Test func failedMergeThrowsInsteadOfStopping() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("one\n", to: "a.txt")
        try await repository.commitAll("base")
        await #expect(throws: GitError.self) {
            _ = try await repository.merge("no-such-branch")
        }
    }
}

@Suite("Conflict document")
struct ConflictDocumentTests {
    let sample = """
    struct AlphaVersion {
    <<<<<<< HEAD
        let published = releases.filter { $0.channel == .alpha }
    =======
        let sameVersion = releases.filter { $0.marketing == marketing }
    >>>>>>> 7b1e04d (fix: reset alpha numbering per version)
    }
    <<<<<<< HEAD
    // ours
    ||||||| base
    // base
    =======
    // theirs
    >>>>>>> 7b1e04d (fix: reset alpha numbering per version)

    """

    @Test func parsesBlocksAndLabels() {
        let document = ConflictDocument(text: sample)
        #expect(document.conflictCount == 2)
        #expect(document.endsWithNewline)
        let first = document.blocks[0]
        #expect(first.oursLabel == "HEAD")
        #expect(first.theirsLabel == "7b1e04d (fix: reset alpha numbering per version)")
        #expect(first.ours == ["    let published = releases.filter { $0.channel == .alpha }"])
        #expect(first.base == nil)
        #expect(document.blocks[1].base == ["// base"])
    }

    @Test func roundTripsUnresolvedBlocks() {
        #expect(ConflictDocument(text: sample).text == sample)
    }

    @Test func resolvesBlocks() {
        let document = ConflictDocument(text: sample)
        let one = document.resolving(0, with: .theirs)
        #expect(one.conflictCount == 1)
        let all = one.resolving(0, with: .both)
        #expect(!all.hasConflicts)
        #expect(all.text == """
        struct AlphaVersion {
            let sameVersion = releases.filter { $0.marketing == marketing }
        }
        // ours
        // theirs

        """)
    }

    @Test func sideLinesMarkTheirBlock() {
        let lines = ConflictDocument(text: sample).lines(for: .ours)
        #expect(lines.map(\.text) == [
            "struct AlphaVersion {",
            "    let published = releases.filter { $0.channel == .alpha }",
            "}",
            "// ours",
        ])
        #expect(lines.map(\.conflict) == [nil, 0, nil, 1])
    }

    @Test func appliesPickedLinesByBlockIndex() {
        let document = ConflictDocument(text: sample)
        // Block 1 only: its first side's line, then nothing from block 0 yet.
        let partial = document.applying([1: ["// theirs", "// ours"]])
        #expect(partial.conflictCount == 1)
        #expect(partial.blocks[0].ours == document.blocks[0].ours)
        let done = document.applying([0: [], 1: ["// theirs"]])
        #expect(!done.hasConflicts)
        #expect(done.text == "struct AlphaVersion {\n}\n// theirs\n")
    }

    @Test func keepsUnterminatedMarkersAsText() {
        let text = "a\n<<<<<<< HEAD\nb\n=======\nc\n"
        let document = ConflictDocument(text: text)
        #expect(!document.hasConflicts)
        #expect(document.text == text)
    }

    @Test func keepsCarriageReturns() {
        let text = "a\r\n<<<<<<< HEAD\r\nb\r\n=======\r\nc\r\n>>>>>>> x\r\nd\r\n"
        let document = ConflictDocument(text: text)
        #expect(document.conflictCount == 1)
        #expect(document.text == text)
        #expect(document.resolvingAll(with: .ours).text == "a\r\nb\r\nd\r\n")
    }

    @Test func cleansPreparedMessages() {
        let raw = "Merge branch 'develop' into feature\n\n# Conflicts:\n#\tf.txt\n"
        #expect(OperationState.cleanMessage(raw) == "Merge branch 'develop' into feature")
        #expect(OperationState.mergeSource(fromMessage: raw) == "develop")
        #expect(OperationState.mergeSource(fromMessage: "Merge remote-tracking branch 'origin/main'") == "origin/main")
        #expect(OperationState.mergeSource(fromMessage: "Merge commit") == nil)
    }
}
