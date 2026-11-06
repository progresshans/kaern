import Foundation
import KaernKit
import OSLog

/// Finds the git Kaern runs, once per launch. Calling the real binary directly skips the
/// `/usr/bin/git` shim, which costs ~5 ms per command (measured 10.2 ms vs 5.0 ms for
/// `git --version`).
///
/// Order: the path chosen in Settings › Git (`KaernGitPath`), then `xcrun --find git` (only
/// when Xcode or the Command Line Tools are installed, so the installer never pops up), then
/// `/usr/bin/git`.
nonisolated enum GitLocator {
    static let userPathKey = "KaernGitPath"
    private static let log = Logger(subsystem: "com.progresshans.kaern", category: "git")

    struct Resolution: Sendable {
        var url: URL
        var source: Source
        var version: String?
    }

    enum Source: String, Sendable {
        case userChoice = "Settings"
        case xcrun = "xcrun"
        case fallback = "/usr/bin/git"
    }

    @concurrent
    static func resolve(userPath: String?) async -> Resolution {
        let start = ContinuousClock.now
        defer { log.info("Resolved git in \(ContinuousClock.now - start, privacy: .public)") }

        if let userPath, !userPath.isEmpty, FileManager.default.isExecutableFile(atPath: userPath) {
            let url = URL(filePath: userPath)
            return Resolution(url: url, source: .userChoice, version: await GitRunner(executableURL: url).version())
        }
        if await GitRunner.developerToolsInstalled(), let found = await run("/usr/bin/xcrun", ["--find", "git"]),
           FileManager.default.isExecutableFile(atPath: found) {
            let url = URL(filePath: found)
            return Resolution(url: url, source: .xcrun, version: await GitRunner(executableURL: url).version())
        }
        let fallback = GitRunner.defaultExecutableURL
        return Resolution(url: fallback, source: .fallback, version: await GitRunner.availableVersion(at: fallback))
    }

    /// Runs a tool and returns its trimmed standard output (`nil` on failure).
    private static func run(_ path: String, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: finished.terminationStatus == 0 && !text.isEmpty ? text : nil)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
