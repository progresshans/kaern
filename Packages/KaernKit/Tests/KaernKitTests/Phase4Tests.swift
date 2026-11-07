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
