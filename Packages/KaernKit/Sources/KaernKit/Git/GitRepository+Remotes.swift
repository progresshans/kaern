import Foundation

// MARK: - Remote URLs and credentials

extension GitRepository {
    /// `git remote get-url <remote>`
    public func remoteURL(_ remote: String) async -> String? {
        guard let output = try? await git(["remote", "get-url", remote]) else { return nil }
        let url = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    /// The URL as written in `.git/config`, before `insteadOf` rewriting: it names the hosting
    /// service even when fetches go somewhere else.
    public func configuredRemoteURL(_ remote: String) async -> String? {
        guard let output = try? await git(["config", "--get", "remote.\(remote).url"], accepted: [0, 1]), output.status == 0 else { return nil }
        let url = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    /// `git remote set-url <remote> <url>`
    public func setRemoteURL(_ remote: String, to url: String) async throws {
        try await git(["remote", "set-url", remote, url])
    }

    /// The credential helpers git is configured with (`osxkeychain`, `manager`, …).
    public func credentialHelpers() async -> [String] {
        guard let output = try? await git(["config", "--get-all", "credential.helper"], accepted: [0, 1]) else { return [] }
        return output.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Hands a username and token to git's credential helpers (`git credential approve`), the same
    /// Keychain item Terminal's git uses. Kaern keeps no copy. Without a configured helper the
    /// osxkeychain helper is used for this one call.
    public func approveCredential(host: String, username: String, secret: String) async throws {
        let input = "protocol=https\nhost=\(host)\nusername=\(username)\npassword=\(secret)\n\n"
        var arguments: [String] = []
        if await credentialHelpers().isEmpty {
            arguments = ["-c", "credential.helper=osxkeychain"]
        }
        try await git(arguments + ["credential", "approve"], input: Data(input.utf8))
    }

    /// Removes a stored credential (`git credential reject`).
    public func rejectCredential(host: String, username: String?) async {
        var input = "protocol=https\nhost=\(host)\n"
        if let username { input += "username=\(username)\n" }
        input += "\n"
        _ = try? await git(["credential", "reject"], input: Data(input.utf8))
    }
}

extension GitRunner {
    /// The git version when `executableURL` can run, `nil` when git isn't there. `/usr/bin/git`
    /// is only a shim that needs Xcode or the Command Line Tools; it's not run without them,
    /// because that pops up the installer.
    public static func availableVersion(at executableURL: URL) async -> String? {
        let path = executableURL.path(percentEncoded: false)
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        if path == "/usr/bin/git" {
            guard await developerToolsInstalled() else { return nil }
        }
        return await GitRunner(executableURL: executableURL).version()
    }

    /// `xcode-select -p` succeeds when Xcode or the Command Line Tools are installed.
    public static func developerToolsInstalled() async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/xcode-select")
            process.arguments = ["-p"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}
