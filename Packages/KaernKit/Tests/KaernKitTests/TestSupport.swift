import Foundation
import Testing
@testable import KaernKit

extension Trait where Self == TimeLimitTrait {
    /// On every suite, for each of its tests: one that never ends fails by name after ten minutes, and the others go
    /// on. Without it the whole run waits for CI's limit on the job, and the log doesn't say which test it was.
    /// It says nothing about speed. Ten minutes is twice the five a test takes when the stop it checks ends nothing,
    /// so that test still fails on its own check, and far more than any test takes on a busy CI Mac.
    static var hangGuard: Self { .timeLimit(.minutes(10)) }
}

/// Throwaway repositories for integration tests, isolated from the user's git config.
enum TestRepositories {
    static let runner = RepositoryTests.runner

    static func make() async throws -> GitRepository {
        let url = FileManager.default.temporaryDirectory.appending(path: "kaern-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try await GitRepository.initialize(at: url, defaultBranch: "main", runner: runner)
    }

    static func remove(_ repository: GitRepository) {
        try? FileManager.default.removeItem(at: repository.root)
    }
}

/// Waits until `condition` holds, looking every 20 ms, for something that happens in its own time (git starting, a
/// stopped git exiting). Check the condition afterwards: the limit only keeps a test whose event never comes from
/// hanging. It says nothing about speed, and is far longer than the event takes on a busy CI Mac, where a test
/// takes ten times as long as here.
func waitUntil(limit: Duration = .seconds(60), _ condition: () async throws -> Bool) async throws {
    let clock = ContinuousClock()
    let end = clock.now + limit
    while clock.now < end {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
}

extension GitRepository {
    /// Writes a file relative to the working tree (creating folders).
    func write(_ text: String, to path: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String) -> String? {
        FileManager.default.contents(atPath: root.appending(path: path).path(percentEncoded: false))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// Stages everything and commits.
    @discardableResult
    func commitAll(_ message: String, author: String? = nil) async throws -> String {
        try await stageAll()
        if let author {
            try await git(["commit", "-q", "-m", message, "--author=\(author) <\(author.lowercased())@kaern.invalid>"])
        } else {
            try await commit(message: message, amend: false)
        }
        return try await git(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func headSubject(_ revision: String = "HEAD") async throws -> String {
        try await git(["log", "-1", "--format=%s", revision]).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
