import Foundation
import Testing
@testable import KaernKit

@Suite("Branches and tags (integration)", .hangGuard)
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

    @Test func listsTagsNewestFirstWithDates() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("a\n", to: "a.txt")
        let first = try await repository.commitAll("first")
        try await repository.git(["tag", "v1.0"], input: nil)
        try repository.write("b\n", to: "a.txt")
        let second = try await repository.commitAll("second")
        // An annotated tag made "later" than the lightweight one, on the newer commit.
        try await repository.git(["-c", "user.name=T", "-c", "user.email=t@kaern.invalid", "tag", "-a", "v2.0", "-m", "Two"])
        try await repository.git(["update-ref", "refs/tags/v0.9", first])

        let tags = try await repository.tags()
        #expect(Set(tags.map(\.name)) == ["v0.9", "v1.0", "v2.0"])
        #expect(tags.first { $0.name == "v2.0" }?.target == second)
        #expect(tags.first { $0.name == "v1.0" }?.target == first)
        #expect(tags.allSatisfy { $0.date != nil })
        // Sorted by date, newest first.
        let dates = tags.compactMap(\.date)
        #expect(dates == dates.sorted(by: >))
    }

    @Test func lightStatusFoldsUntrackedFolders() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("a\n", to: "a.txt")
        try await repository.commitAll("base")
        try repository.write("x\n", to: "new/one.txt")
        try repository.write("y\n", to: "new/two.txt")

        let full = try await repository.status()
        let light = try await repository.status(untrackedFiles: .normal)
        #expect(full.entries.map(\.path).sorted() == ["new/one.txt", "new/two.txt"])
        #expect(light.entries.map(\.path) == ["new/"])
        #expect(!light.isClean)
    }

    @Test func suggestsTheNextVersionTag() {
        #expect(TagNaming.suggestion(after: []) == nil)
        #expect(TagNaming.suggestion(after: ["nightly", "latest"]) == nil)
        #expect(TagNaming.suggestion(after: ["v0.9.2", "v0.9.3-alpha.6", "v0.9.3-alpha.7"]) == "v0.9.3-alpha.8")
        #expect(TagNaming.suggestion(after: ["v0.9.3-alpha.7", "v0.9.3"]) == "v0.9.4-alpha.1")
        #expect(TagNaming.suggestion(after: ["1.2.3", "1.10.0"]) == "1.10.1")
        #expect(TagNaming.suggestion(after: ["v2.0.0-rc.1", "v2.0.0-beta.3"]) == "v2.0.0-rc.2")
        // Tags with nothing after the prefix used to end the app.
        #expect(TagNaming.suggestion(after: ["v", "V", "-", "v-", "v-beta"]) == nil)
        #expect(TagNaming.suggestion(after: ["v", "v1.0.0", "v-"]) == "v1.0.1")
    }
}
