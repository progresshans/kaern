import Testing
@testable import KaernKit

@Suite("Commit search")
struct CommitSearchTests {
    @Test func prefixesPickTheScope() {
        #expect(CommitSearchScope.parsePrefix("author:Minji")! == (.author, "Minji"))
        #expect(CommitSearchScope.parsePrefix("Path: script/")! == (.path, "script/"))
        #expect(CommitSearchScope.parsePrefix("sha:c92a")! == (.sha, "c92a"))
        #expect(CommitSearchScope.parsePrefix("release") == nil)
    }

    @Test func loadedCommitsMatchByScope() {
        let commit = Commit(
            id: "c92aa17f00000000000000000000000000000000", parents: [],
            author: Signature(name: "Minji Park", email: "minji@example.com", date: .now),
            subject: "fix: restore automatic alpha releases"
        )
        #expect(CommitSearchScope.all.matchesLoaded(commit, query: "Restore"))
        #expect(CommitSearchScope.all.matchesLoaded(commit, query: "minji"))
        #expect(CommitSearchScope.all.matchesLoaded(commit, query: "c92a"))
        #expect(!CommitSearchScope.all.matchesLoaded(commit, query: "c92"))   // too short for a SHA
        #expect(!CommitSearchScope.message.matchesLoaded(commit, query: "minji"))
        #expect(CommitSearchScope.author.matchesLoaded(commit, query: "example.com"))
        #expect(!CommitSearchScope.sha.matchesLoaded(commit, query: "restore"))
        #expect(!CommitSearchScope.path.matchesLoaded(commit, query: "restore"))
    }
}

@Suite("Commit search (integration)")
struct HistorySearchTests {
    @Test func searchesTheWholeHistoryByScope() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("echo release", to: "script/release.sh")
        let script = try await repository.commitAll("feat: add a release script", author: "Minji")
        try repository.write("# Kaern", to: "docs/README.md")
        let readme = try await repository.commitAll("fix: typo\n\nMentioned in the release notes.", author: "Han")
        try repository.write("let version = 1", to: "Sources/Release/Version.swift")
        let version = try await repository.commitAll("chore: bump", author: "Han")

        let message = try await repository.searchHistory("RELEASE", scope: .message, includeHEAD: true)
        #expect(Set(message.matches) == [script, readme])
        #expect(message.total == 3)

        let author = try await repository.searchHistory("minji", scope: .author, includeHEAD: true)
        #expect(author.matches == [script])

        let path = try await repository.searchHistory("release", scope: .path, includeHEAD: true)
        #expect(Set(path.matches) == [script, version])

        let sha = try await repository.searchHistory(String(version.prefix(6)), scope: .sha, includeHEAD: true)
        #expect(sha.matches == [version])

        let all = try await repository.searchHistory("han", scope: .all, includeHEAD: true)
        #expect(Set(all.matches) == [readme, version])

        let literal = try await repository.searchHistory("rel*se", scope: .path, includeHEAD: true)
        #expect(literal.matches.isEmpty)
    }
}
