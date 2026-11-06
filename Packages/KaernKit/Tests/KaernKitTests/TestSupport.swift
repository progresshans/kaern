import Foundation
@testable import KaernKit

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
