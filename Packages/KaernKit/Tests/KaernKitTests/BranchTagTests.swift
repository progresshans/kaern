import Foundation
import Testing
@testable import KaernKit

@Suite("Branches and tags (integration)")
struct BranchTagTests {
    @Test func renamesBranchesAndRemembersRecentOnes() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("a\n", to: "a.txt")
        try await repository.commitAll("base")
        try await repository.createBranch("topic", startPoint: nil, checkout: true)
        try await repository.switchBranch("main")
        try await repository.createBranch("other", startPoint: nil, checkout: true)

        let recent = await repository.recentlyCheckedOut()
        #expect(Array(recent.prefix(3)) == ["other", "main", "topic"])

        try await repository.renameBranch("topic", to: "feature/topic")
        let refs = try await repository.refs()
        #expect(refs.localBranches.map(\.name).sorted() == ["feature/topic", "main", "other"])
    }

    @Test func createsLightweightAndAnnotatedTags() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("a\n", to: "a.txt")
        let head = try await repository.commitAll("base")

        #expect(await repository.isValidTagName("v1.0.0"))
        #expect(!(await repository.isValidTagName("bad name")))
        try await repository.createTag("v1.0.0", at: head, message: nil)
        try await repository.createTag("v1.0.1", at: head, message: "First patch")
        let type = try await repository.git(["cat-file", "-t", "v1.0.1"]).text
        #expect(type.trimmingCharacters(in: .whitespacesAndNewlines) == "tag")
        let refs = try await repository.refs()
        #expect(Set(refs.tags.map(\.name)) == ["v1.0.0", "v1.0.1"])
        // Annotated tags are peeled to the commit.
        #expect(refs.tags.allSatisfy { $0.target == head })

        try await repository.deleteTag("v1.0.0")
        let after = try await repository.refs()
        #expect(after.tags.map(\.name) == ["v1.0.1"])
    }

    @Test func suggestsTheNextVersionTag() {
        #expect(TagNaming.suggestion(after: []) == nil)
        #expect(TagNaming.suggestion(after: ["nightly", "latest"]) == nil)
        #expect(TagNaming.suggestion(after: ["v0.9.2", "v0.9.3-alpha.6", "v0.9.3-alpha.7"]) == "v0.9.3-alpha.8")
        #expect(TagNaming.suggestion(after: ["v0.9.3-alpha.7", "v0.9.3"]) == "v0.9.4-alpha.1")
        #expect(TagNaming.suggestion(after: ["1.2.3", "1.10.0"]) == "1.10.1")
        #expect(TagNaming.suggestion(after: ["v2.0.0-rc.1", "v2.0.0-beta.3"]) == "v2.0.0-rc.2")
    }
}
