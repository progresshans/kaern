import Foundation
import Synchronization

/// Raw result of one `git` invocation.
public struct GitOutput: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public init(status: Int32, stdout: Data, stderr: Data) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    /// Standard output decoded as UTF-8 (invalid bytes are replaced).
    public var text: String { String(decoding: stdout, as: UTF8.self) }
    /// Standard error decoded as UTF-8 (invalid bytes are replaced).
    public var errorText: String { String(decoding: stderr, as: UTF8.self) }
}

/// A failed git command. `message` is what git printed, so it can be shown to the user as-is.
public struct GitError: Error, LocalizedError, Sendable, Equatable {
    public let arguments: [String]
    public let status: Int32
    public let message: String

    public init(arguments: [String], status: Int32, message: String) {
        self.arguments = arguments
        self.status = status
        self.message = message
    }

    public var errorDescription: String? {
        let trimmed = GitError.clean(message)
        if trimmed.isEmpty {
            return "git \(arguments.first ?? "") failed (exit code \(status))."
        }
        return trimmed
    }

    /// Removes progress noise and the `error:`/`fatal:` prefixes git puts on every line.
    static func clean(_ message: String) -> String {
        let lines = message
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { line -> String in
                var text = String(line)
                for prefix in ["fatal: ", "error: "] where text.hasPrefix(prefix) {
                    text.removeFirst(prefix.count)
                }
                return text.trimmingCharacters(in: .whitespaces)
            }
            .filter { line in
                !line.isEmpty
                    && !line.hasPrefix("hint:")
                    && !line.contains("% (")
                    && !line.hasPrefix("remote: Counting")
                    && !line.hasPrefix("remote: Compressing")
                    && !line.hasPrefix("remote: Enumerating")
                    && !line.hasPrefix("remote: Total")
            }
        return lines.joined(separator: "\n")
    }
}

/// One entry of the command log (Settings › Advanced).
public struct GitCommandRecord: Sendable, Identifiable {
    public let id = UUID()
    public let arguments: [String]
    public let directory: String
    public let status: Int32
    public let duration: Duration
    public let date: Date
}

/// Runs the git command-line tool. Kaern never links libgit2; everything goes through the CLI so
/// behaviour (hooks, signing, credential helpers, config) matches what the user gets in Terminal.
public struct GitRunner: Sendable {
    public var executableURL: URL
    public var environment: [String: String]
    public var onCommand: (@Sendable (GitCommandRecord) -> Void)?
    /// Whether `git-lfs` is on the PATH git runs with.
    ///
    /// Without it, the Git LFS filters `git lfs install` put in ~/.gitconfig
    /// (`filter.lfs.required = true`) make `git status` and `git diff` fail in any repository
    /// that stores files in LFS. Commands then run with those filters off: the files on disk are
    /// pointers, and git compares them as they are. `git add` keeps the filters, so staging a
    /// real file at an LFS path fails rather than putting the file into git itself.
    public let isLFSInstalled: Bool

    public static let defaultExecutableURL = URL(filePath: "/usr/bin/git")

    /// Options applied to every command so output stays machine-readable regardless of user config.
    static let baseArguments = [
        "--no-pager",
        "-c", "core.quotepath=false",
        "-c", "color.ui=false",
        "-c", "color.diff=false",
        "-c", "log.showSignature=false",
        "-c", "diff.noprefix=false",
        "-c", "diff.mnemonicPrefix=false",
    ]

    /// See ``isLFSInstalled``.
    static let lfsFiltersOff = [
        "-c", "filter.lfs.process=",
        "-c", "filter.lfs.clean=",
        "-c", "filter.lfs.smudge=",
        "-c", "filter.lfs.required=false",
    ]

    /// The subcommand of `arguments` (after any `-c key=value` and `-C dir` options).
    static func subcommand(of arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-c" || argument == "-C" {
                index += 2
            } else if argument.hasPrefix("-") {
                index += 1
            } else {
                return argument
            }
        }
        return nil
    }

    private static let ignoreSIGPIPE: Void = {
        // Writing a patch to a git process that exits early must not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }()

    /// `removedEnvironment`: variables git shouldn't see (`SSH_AUTH_SOCK` when Settings ›
    /// Advanced › Use the SSH agent is off).
    public init(
        executableURL: URL = GitRunner.defaultExecutableURL,
        extraEnvironment: [String: String] = [:],
        removedEnvironment: [String] = [],
        onCommand: (@Sendable (GitCommandRecord) -> Void)? = nil
    ) {
        _ = GitRunner.ignoreSIGPIPE
        self.executableURL = executableURL
        self.onCommand = onCommand

        var env = ProcessInfo.processInfo.environment
        // Apps launched from Finder get a minimal PATH. Make Homebrew helpers (gpg, git-lfs,
        // credential helpers) reachable the same way they are in a login shell.
        var path = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init)
        for extra in ["/opt/homebrew/bin", "/usr/local/bin"] where !path.contains(extra) {
            path.append(extra)
        }
        env["PATH"] = path.joined(separator: ":")
        // English messages, so errors match the UI and can be recognized (paths are unaffected).
        env["LC_ALL"] = "en_US.UTF-8"
        env["GIT_TERMINAL_PROMPT"] = "0"   // never hang waiting for a password on a tty we don't have
        env["GIT_OPTIONAL_LOCKS"] = "0"    // background `git status` must not rewrite the index
        env["GIT_MERGE_AUTOEDIT"] = "no"
        // Give up on a remote that stops answering (under 1 KB/s for 30 s) instead of hanging.
        env["GIT_HTTP_LOW_SPEED_LIMIT"] = env["GIT_HTTP_LOW_SPEED_LIMIT"] ?? "1000"
        env["GIT_HTTP_LOW_SPEED_TIME"] = env["GIT_HTTP_LOW_SPEED_TIME"] ?? "30"
        env["GIT_EDITOR"] = "true"
        env["GIT_PAGER"] = "cat"
        env["TERM"] = "dumb"
        for (key, value) in extraEnvironment {
            env[key] = value
        }
        for key in removedEnvironment {
            env[key] = nil
        }
        self.environment = env
        isLFSInstalled = (env["PATH"] ?? "").split(separator: ":").contains { directory in
            FileManager.default.isExecutableFile(atPath: "\(directory)/git-lfs")
        }
    }

    /// Runs `git <arguments>` in `directory`.
    ///
    /// - Parameters:
    ///   - input: Bytes written to the process' standard input (for example a patch or a commit message).
    ///   - acceptedStatus: Exit codes that count as success. Anything else throws ``GitError``.
    ///   - onProgress: When set, standard error is read incrementally and every progress line
    ///     (split on `\r` and `\n`) is reported as it arrives.
    @discardableResult
    public func run(
        _ arguments: [String],
        in directory: URL?,
        input: Data? = nil,
        acceptedStatus: Set<Int32> = [0],
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> GitOutput {
        let start = ContinuousClock.now
        let lfsArguments = isLFSInstalled || GitRunner.subcommand(of: arguments) == "add" ? [] : GitRunner.lfsFiltersOff
        let output = try await GitRunner.execute(
            executableURL: executableURL,
            arguments: GitRunner.baseArguments + lfsArguments + arguments,
            directory: directory,
            environment: environment,
            input: input,
            onProgress: onProgress
        )
        onCommand?(GitCommandRecord(
            arguments: arguments,
            directory: directory?.path(percentEncoded: false) ?? "",
            status: output.status,
            duration: ContinuousClock.now - start,
            date: Date()
        ))
        guard acceptedStatus.contains(output.status) else {
            let message = output.errorText.isEmpty ? output.text : output.errorText
            throw GitError(arguments: arguments, status: output.status, message: message)
        }
        return output
    }

    /// `git --version`, e.g. "2.54.0 (Apple Git-157)".
    public func version() async -> String? {
        guard let output = try? await run(["--version"], in: nil) else { return nil }
        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("git version ") ? String(text.dropFirst("git version ".count)) : text
    }

    // MARK: - Process plumbing

    private final class Collector: Sendable {
        let stdout = Mutex(Data())
        let stderr = Mutex(Data())
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
        func terminate() {
            if process.isRunning { process.terminate() }
        }
    }

    private static func execute(
        executableURL: URL,
        arguments: [String],
        directory: URL?,
        environment: [String: String],
        input: Data?,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> GitOutput {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        if let directory {
            process.currentDirectoryURL = directory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe: Pipe? = input == nil ? nil : Pipe()
        if let stdinPipe {
            process.standardInput = stdinPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let box = ProcessBox(process)
        let collector = Collector()
        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        let inHandle = stdinPipe?.fileHandleForWriting

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GitOutput, any Error>) in
                let group = DispatchGroup()
                group.enter()
                group.enter()
                process.terminationHandler = { finished in
                    let status = finished.terminationStatus
                    group.notify(queue: .global(qos: .userInitiated)) {
                        let out = collector.stdout.withLock { $0 }
                        let err = collector.stderr.withLock { $0 }
                        continuation.resume(returning: GitOutput(status: status, stdout: out, stderr: err))
                    }
                }

                do {
                    try process.run()
                } catch {
                    group.leave()
                    group.leave()
                    continuation.resume(throwing: GitError(
                        arguments: arguments,
                        status: -1,
                        message: "Couldn't run git at \(executableURL.path(percentEncoded: false)): \(error.localizedDescription)"
                    ))
                    return
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    let data = outHandle.readDataToEndOfFile()
                    collector.stdout.withLock { $0 = data }
                    group.leave()
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let data: Data
                    if let onProgress {
                        data = readIncrementally(errHandle, onLine: onProgress)
                    } else {
                        data = errHandle.readDataToEndOfFile()
                    }
                    collector.stderr.withLock { $0 = data }
                    group.leave()
                }
                if let inHandle, let input {
                    DispatchQueue.global(qos: .userInitiated).async {
                        try? inHandle.write(contentsOf: input)
                        try? inHandle.close()
                    }
                }
            }
        } onCancel: {
            box.terminate()
        }
    }

    /// Reads a stream to the end, reporting each `\r`/`\n` separated line along the way.
    private static func readIncrementally(_ handle: FileHandle, onLine: @Sendable (String) -> Void) -> Data {
        var all = Data()
        var pending: [UInt8] = []
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            all.append(chunk)
            for byte in chunk {
                if byte == 0x0A || byte == 0x0D {
                    if !pending.isEmpty {
                        onLine(String(decoding: pending, as: UTF8.self))
                        pending.removeAll(keepingCapacity: true)
                    }
                } else {
                    pending.append(byte)
                }
            }
        }
        if !pending.isEmpty {
            onLine(String(decoding: pending, as: UTF8.self))
        }
        return all
    }
}
