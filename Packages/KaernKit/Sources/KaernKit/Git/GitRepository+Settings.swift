import Foundation

/// A remote as Repository Settings lists it.
public struct RemoteInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var fetchURL: String
    /// Set when pushes go somewhere else (`remote.<name>.pushurl`).
    public var pushURL: String?

    public var id: String { name }

    public init(name: String, fetchURL: String, pushURL: String? = nil) {
        self.name = name
        self.fetchURL = fetchURL
        self.pushURL = pushURL
    }
}

/// A git hook that runs when committing, with the first command it runs.
public struct HookInfo: Sendable, Hashable, Identifiable {
    public var name: String
    /// The first command in the script, `nil` when there's no hook (or it isn't executable).
    public var summary: String?

    public var id: String { name }
    public var isInstalled: Bool { summary != nil }
}

// MARK: - Repository Settings

extension GitRepository {
    /// `git remote -v`, one entry per remote.
    public func remoteInfos() async -> [RemoteInfo] {
        guard let output = try? await git(["remote", "-v"]) else { return [] }
        var order: [String] = []
        var fetch: [String: String] = [:]
        var push: [String: String] = [:]
        for line in output.text.split(separator: "\n") {
            // origin\thttps://… (fetch)
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = String(parts[0])
            let rest = parts[1]
            guard let space = rest.lastIndex(of: " ") else { continue }
            let url = String(rest[..<space])
            if !order.contains(name) { order.append(name) }
            if rest.hasSuffix("(push)") { push[name] = url } else { fetch[name] = url }
        }
        return order.map { name in
            let fetchURL = fetch[name] ?? push[name] ?? ""
            let pushURL = push[name].flatMap { $0 == fetchURL ? nil : $0 }
            return RemoteInfo(name: name, fetchURL: fetchURL, pushURL: pushURL)
        }
    }

    public func addRemote(_ name: String, url: String) async throws {
        try await git(["remote", "add", name, url])
    }

    public func renameRemote(_ name: String, to newName: String) async throws {
        try await git(["remote", "rename", name, newName])
    }

    /// `git remote set-url`: a new fetch (and push) address.
    public func setRemoteURL(_ name: String, url: String) async throws {
        try await git(["remote", "set-url", name, url])
    }

    /// `git remote remove`: also drops its remote branches and the upstream settings that use it.
    public func removeRemote(_ name: String) async throws {
        try await git(["remote", "remove", name])
    }

    public func isValidRemoteName(_ name: String) async -> Bool {
        guard !name.isEmpty, !name.contains(" ") else { return false }
        return (try? await git(["check-ref-format", "refs/remotes/\(name)/x"])) != nil
    }

    /// A value from this repository's own `.git/config` only.
    public func localConfig(_ key: String) async -> String? {
        guard let output = try? await git(["config", "--local", "--get", key], accepted: [0, 1]), output.status == 0 else { return nil }
        let value = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Writes `key` to `.git/config`, or removes it when `value` is `nil`.
    public func setLocalConfig(_ key: String, _ value: String?) async throws {
        if let value {
            try await git(["config", "--local", key, value])
        } else {
            // Exit status 5: the key wasn't set.
            try await git(["config", "--local", "--unset-all", key], accepted: [0, 5])
        }
    }

    /// The hooks that run when committing (`pre-commit`, `commit-msg`) plus any other installed
    /// commit or push hook, from the hooks folder git uses (`core.hooksPath` included).
    public func commitHooks() async -> [HookInfo] {
        guard let output = try? await git(["rev-parse", "--git-path", "hooks"]) else { return [] }
        var path = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.hasPrefix("/") { path = root.appending(path: path).path(percentEncoded: false) }
        let folder = URL(filePath: path, directoryHint: .isDirectory)
        var hooks: [HookInfo] = []
        for name in ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit", "pre-push"] {
            let summary = Self.hookSummary(folder.appending(path: name))
            if summary != nil || name == "pre-commit" || name == "commit-msg" {
                hooks.append(HookInfo(name: name, summary: summary))
            }
        }
        return hooks
    }

    /// The first line of an executable hook that isn't the shebang, a comment or blank.
    static func hookSummary(_ url: URL) -> String? {
        let path = url.path(percentEncoded: false)
        guard FileManager.default.isExecutableFile(atPath: path),
              let data = FileManager.default.contents(atPath: path) else { return nil }
        let text = String(decoding: data.prefix(8192), as: UTF8.self)
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed == "set -e" || trimmed.hasPrefix("set -") { continue }
            return trimmed.count > 80 ? String(trimmed.prefix(79)) + "…" : trimmed
        }
        return String(localized: "script")
    }
}

extension GitRunner {
    /// A value from the user's `~/.gitconfig` (or XDG config) only.
    public func globalConfig(_ key: String) async -> String? {
        guard let output = try? await run(["config", "--global", "--get", key], in: nil, acceptedStatus: [0, 1]),
              output.status == 0 else { return nil }
        let value = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Writes `key` to the user's global config (`git config --global`), or removes it when
    /// `value` is `nil` (Settings › Git).
    public func setGlobalConfig(_ key: String, _ value: String?) async throws {
        if let value {
            try await run(["config", "--global", key, value], in: nil)
        } else {
            // Exit status 5: the key wasn't set.
            try await run(["config", "--global", "--unset-all", key], in: nil, acceptedStatus: [0, 5])
        }
    }
}
