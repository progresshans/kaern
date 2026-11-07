import Foundation

/// The folder isn't in a Git repository (no `.git` here or in any folder above it).
public struct NotARepositoryError: Error, LocalizedError, Sendable, Equatable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public var errorDescription: String? { "“\(folder.lastPathComponent)” isn't a Git repository." }
}

// MARK: - Creating and cloning

extension GitRepository {
    /// What `create` did, step by step (the Create sheet ticks them off).
    public enum CreationStep: Sendable, Hashable {
        case initialize
        case writeFiles([String])
        case commit
    }

    /// Makes `folder` a repository: `git init -b <branch>` (the folder is created when it isn't
    /// there), writes `files` that don't exist yet (existing ones are never overwritten), and with
    /// a `commitMessage` stages everything and makes the first commit.
    ///
    /// `onStep` hears each step as it starts. Returns the repository and the paths it wrote.
    public static func create(
        at folder: URL,
        defaultBranch: String,
        files: [(path: String, contents: Data)],
        commitMessage: String?,
        runner: GitRunner,
        onStep: (@Sendable (CreationStep) -> Void)? = nil
    ) async throws -> (repository: GitRepository, written: [String]) {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        onStep?(.initialize)
        try await runner.run(["init", "--initial-branch=\(defaultBranch)", "--", folder.path(percentEncoded: false)], in: nil)
        let repository = try await open(folder, runner: runner)
        var written: [String] = []
        let missing = files.filter { !fileManager.fileExists(atPath: repository.root.appending(path: $0.path).path(percentEncoded: false)) }
        if !missing.isEmpty {
            onStep?(.writeFiles(missing.map(\.path)))
            for file in missing {
                let url = repository.root.appending(path: file.path)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.contents.write(to: url, options: .withoutOverwriting)
                written.append(file.path)
            }
        }
        if let commitMessage {
            onStep?(.commit)
            try await repository.stageAll()
            try await repository.commit(message: commitMessage, amend: false)
        }
        return (repository, written)
    }

    /// `init.defaultBranch` from git's config, else "main".
    public static func defaultBranchName(runner: GitRunner) async -> String {
        guard let output = try? await runner.run(["config", "--get", "init.defaultBranch"], in: nil, acceptedStatus: [0, 1]) else {
            return "main"
        }
        let value = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "main" : value
    }

    /// The folder a clone of `remote` gets by default: the last part of the URL or path without
    /// `.git` ("https://github.com/x/kaern.git" → "kaern").
    public static func folderName(forClone remote: String) -> String? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        // scp-like "git@host:owner/name"
        let last = text.split(whereSeparator: { $0 == "/" || $0 == ":" || $0 == "\\" }).last.map(String.init) ?? ""
        let name = last.trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == "." || name == ".." ? nil : name
    }

    /// `git clone --progress` into `destination`. A clone that fails or is stopped leaves nothing
    /// behind: git removes what it made, and so does this when git couldn't (the folder must not
    /// have existed, or been empty, before).
    public static func clone(
        _ remote: String,
        into destination: URL,
        runner: GitRunner,
        onProgress: (@Sendable (GitProgress) -> Void)? = nil
    ) async throws -> GitRepository {
        let fileManager = FileManager.default
        let path = destination.path(percentEncoded: false)
        let existedBefore = fileManager.fileExists(atPath: path)
        if existedBefore, let contents = try? fileManager.contentsOfDirectory(atPath: path), !contents.isEmpty {
            throw GitError(arguments: ["clone"], status: 128,
                           message: "\(destination.lastPathComponent) already exists and isn't empty. Choose another folder.")
        }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        do {
            try await runner.run(["clone", "--progress", "--", remote, path], in: parent, onProgress: { line in
                if let progress = GitProgress.parse(line) { onProgress?(progress) }
            })
        } catch {
            // Never remove a folder that was there with something in it (checked above).
            if fileManager.fileExists(atPath: path) {
                if existedBefore {
                    for item in (try? fileManager.contentsOfDirectory(atPath: path)) ?? [] {
                        try? fileManager.removeItem(at: destination.appending(path: item))
                    }
                } else {
                    try? fileManager.removeItem(at: destination)
                }
            }
            throw error
        }
        return try await open(destination, runner: runner)
    }

    /// Whether `url` is inside a working tree (`git rev-parse --is-inside-work-tree`).
    public static func isInsideWorkTree(_ url: URL, runner: GitRunner) async -> Bool {
        guard let output = try? await runner.run(["rev-parse", "--is-inside-work-tree"], in: url, acceptedStatus: [0, 128]) else {
            return false
        }
        return output.status == 0 && output.text.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }
}
