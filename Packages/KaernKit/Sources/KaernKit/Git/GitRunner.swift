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

    /// Removes progress noise, empty lines and the `error:`/`fatal:` prefixes git puts on every line.
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
        return settingAdviceApart(lines).joined(separator: "\n")
    }

    /// When a remote can't be read, git ends with advice it sends on two lines, after an empty one. The advice
    /// goes on one line, so it wraps at the width it is shown in, and keeps the empty line above it.
    private static func settingAdviceApart(_ lines: [String]) -> [String] {
        guard let first = lines.firstIndex(of: "Please make sure you have the correct access rights"),
              lines.indices.contains(first + 1), lines[first + 1] == "and the repository exists." else { return lines }
        var result = lines
        result.replaceSubrange(first...first + 1, with: (first > 0 ? [""] : []) + [lines[first] + " " + lines[first + 1]])
        return result
    }
}

/// Runs the git command-line tool. Kaern never links libgit2; everything goes through the CLI so
/// behaviour (hooks, signing, credential helpers, config) matches what the user gets in Terminal.
public struct GitRunner: Sendable {
    public var executableURL: URL
    public var environment: [String: String]
    /// Told when a command starts, prints progress and ends (the Command Log). Arguments and
    /// output arrive with their secrets masked.
    public var onCommand: (@Sendable (GitCommandEvent) -> Void)?
    /// Whether `git-lfs` is on the PATH git runs with.
    ///
    /// Without it, the Git LFS filters `git lfs install` put in ~/.gitconfig
    /// (`filter.lfs.required = true`) make `git status` and `git diff` fail in any repository
    /// that stores files in LFS. Commands then run with those filters off: the files on disk are
    /// pointers, and git compares them as they are. `git add` keeps the filters, so staging a
    /// real file at an LFS path fails rather than putting the file into git itself.
    public let isLFSInstalled: Bool
    /// How long a stopped git and what it started get to end by themselves, before they are ended by force.
    /// Long enough for a busy Mac and for a hook that tidies up; short enough for a command that will never end.
    var stopGrace: Duration = .seconds(10)

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

    /// The variables Kaern sets for every command (the Command Log shows them).
    public static let kaernEnvironmentKeys = [
        "LC_ALL", "GIT_TERMINAL_PROMPT", "GIT_OPTIONAL_LOCKS", "GIT_MERGE_AUTOEDIT", "GIT_EDITOR", "GIT_PAGER", "TERM",
    ]

    /// How much of a command's output a record keeps (user actions; background commands keep a
    /// tenth of it).
    public static let recordedOutputLimit = 64 * 1024

    /// The subcommand of `arguments` (after any `-c key=value` and `-C dir` options).
    static func subcommand(of arguments: [String]) -> String? {
        subcommandIndex(of: arguments).map { arguments[$0] }
    }

    static func subcommandIndex(of arguments: [String]) -> Int? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-c" || argument == "-C" {
                index += 2
            } else if argument.hasPrefix("-") {
                index += 1
            } else {
                return index
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
        onCommand: (@Sendable (GitCommandEvent) -> Void)? = nil
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
        environment extra: [String: String] = [:],
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> GitOutput {
        let start = ContinuousClock.now
        let lfsArguments = isLFSInstalled || GitRunner.subcommand(of: arguments) == "add" ? [] : GitRunner.lfsFiltersOff
        let onCommand = onCommand
        var record = onCommand.map { _ in
            GitCommandRecord(
                arguments: GitRedaction.redact(arguments: arguments),
                directory: directory?.path(percentEncoded: false) ?? "",
                trigger: GitCommandTrigger.current,
                started: Date(),
                hasInput: input != nil
            )
        }
        // A task that asked for progress (Activity's bars) hears every progress line too.
        var onProgress = onProgress
        if let reporter = GitProgressReporter.current {
            let given = onProgress
            onProgress = { line in
                given?(line)
                if let progress = GitProgress.parse(line) { reporter(progress) }
            }
        }
        let progress: (@Sendable (String) -> Void)?
        if let onProgress, let onCommand, let id = record?.id {
            progress = { line in
                onProgress(line)
                onCommand(.progress(id, GitRedaction.redact(line)))
            }
        } else {
            progress = onProgress
        }
        let launched = record
        let result = try await GitRunner.execute(
            executableURL: executableURL,
            arguments: GitRunner.baseArguments + lfsArguments + arguments,
            directory: directory,
            environment: extra.isEmpty ? environment : environment.merging(extra) { _, new in new },
            input: input,
            stopGrace: stopGrace,
            onProgress: progress,
            onLaunch: { stop in
                if let onCommand, let launched { onCommand(.started(launched, stop: GitCommandHandle(stop))) }
            }
        )
        let output = result.output
        if let onCommand, var finished = record {
            let limit = finished.isBackground ? GitRunner.recordedOutputLimit / 10 : GitRunner.recordedOutputLimit
            finished.status = output.status
            finished.duration = ContinuousClock.now - start
            // A credential helper's answer is the secret itself (and fields masking can't know,
            // like a refresh token): the Command Log never keeps it.
            finished.output = GitRunner.subcommand(of: arguments) == "credential"
                ? (output.stdout.isEmpty ? "" : "(not kept: a credential helper’s answer)")
                : GitRedaction.redact(String(decoding: output.stdout.prefix(limit), as: UTF8.self))
            finished.errorOutput = GitRedaction.redact(String(decoding: output.stderr.prefix(limit), as: UTF8.self))
            finished.isOutputCut = output.stdout.count > limit || output.stderr.count > limit
            finished.wasStopped = result.wasStopped
            record = finished
            onCommand(.finished(finished))
        }
        if result.wasStopped {
            throw CancellationError()
        }
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
        private let grace: Duration
        private let stopped = Mutex(false)
        /// git's process group, once a stop has signalled it. Foundation starts git as the leader of a group
        /// of its own, and what git starts stays in that group unless it leaves it.
        private let group = Mutex<pid_t?>(nil)
        private let forceIsDue = Mutex(false)
        init(_ process: Process, grace: Duration) {
            self.process = process
            self.grace = grace
        }
        var wasStopped: Bool { stopped.withLock { $0 } }

        /// Ends git and everything it started (a hook and the tools it runs), so the pipes close. It asks them
        /// to end (SIGTERM); what is still there after `grace` is ended by force (SIGKILL).
        func terminate() {
            stopped.withLock { $0 = true }
            guard process.isRunning else { return }
            send(SIGTERM)
            guard forceIsDue.withLock({ due in defer { due = true }; return !due }) else { return }
            let (seconds, attoseconds) = grace.components
            let wait = Double(seconds) + Double(attoseconds) * 1e-18
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + wait) {
                // A hook may refuse to end, and so can git: a SIGTERM that arrives just as git 2.54 sets up
                // to pass signals on to what it started leaves it spinning, without end.
                if self.process.isRunning {
                    self.send(SIGKILL)
                } else {
                    self.endWhatIsLeft(with: SIGKILL)
                }
            }
        }

        /// Signals git, while it runs, and everything it started.
        private func send(_ signal: Int32) {
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            // A git that runs has an ID above 1. Checked all the same, since the signals below go by it: as a
            // process ID, 0 stands for this app's own group, and what's under 0 or 1 is everything on the Mac.
            guard pid > 1 else { return }
            // One signal for git's group reaches everything in it at once. Listing what git started and
            // signalling each misses what git starts in between.
            if getpgid(pid) == pid {
                group.withLock { $0 = pid }
                kill(-pid, signal)
            }
            // What left the group but is still under git. And everything, should git ever not lead a group
            // of its own: its group would then be this app's, which a stop must never signal.
            for child in ProcessBox.descendants(of: pid) {
                kill(child, signal)
            }
            kill(pid, signal)
        }

        /// Once a stopped git has exited: ends what it was starting when the stop came. A signal that reaches
        /// git while it starts a child ends git only after that, and the child, born after the signal, never
        /// got it. It is in git's group all the same.
        func endWhatIsLeftAfterExit() {
            endWhatIsLeft(with: SIGTERM)
            // And again, twice. What was only just born can miss a signal: a shell's child still has the
            // shell's trap for a moment, and takes the signal as the shell would.
            for delay in [0.2, 1.0] {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
                    self.endWhatIsLeft(with: SIGTERM)
                }
            }
        }

        /// Signals what is still in the group of a git that has exited.
        private func endWhatIsLeft(with signal: Int32) {
            guard let group = group.withLock({ $0 }) else { return }
            var buffer = [pid_t](repeating: 0, count: 256)
            let count = buffer.withUnsafeMutableBytes { bytes in
                proc_listpgrppids(group, bytes.baseAddress, Int32(bytes.count))
            }
            let members = buffer.prefix(max(0, Int(count))).filter { $0 > 0 }
            // With nothing left the group is gone, and its number is free for another from here on. And git
            // has exited, so a process with its ID is another one, given the ID since: that group is its own.
            guard !members.isEmpty, !members.contains(group) else {
                self.group.withLock { $0 = nil }
                return
            }
            for member in members {
                kill(member, signal)
            }
        }

        private static func descendants(of pid: pid_t) -> [pid_t] {
            var result: [pid_t] = []
            var queue = [pid]
            while let parent = queue.popLast(), result.count < 512 {
                var buffer = [pid_t](repeating: 0, count: 256)
                let count = buffer.withUnsafeMutableBytes { bytes in
                    proc_listchildpids(parent, bytes.baseAddress, Int32(bytes.count))
                }
                guard count > 0 else { continue }
                for child in buffer.prefix(Int(count)) where child > 0 {
                    result.append(child)
                    queue.append(child)
                }
            }
            return result
        }
    }

    private struct Execution: Sendable {
        let output: GitOutput
        /// Ended by `terminate()` (Stop, or the task was cancelled), not on its own.
        let wasStopped: Bool
    }

    private static func execute(
        executableURL: URL,
        arguments: [String],
        directory: URL?,
        environment: [String: String],
        input: Data?,
        stopGrace: Duration,
        onProgress: (@Sendable (String) -> Void)?,
        onLaunch: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void
    ) async throws -> Execution {
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

        let box = ProcessBox(process, grace: stopGrace)
        let collector = Collector()
        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        let inHandle = stdinPipe?.fileHandleForWriting

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Execution, any Error>) in
                let group = DispatchGroup()
                group.enter()
                group.enter()
                let resumed = Mutex(false)
                process.terminationHandler = { finished in
                    let status = finished.terminationStatus
                    if box.wasStopped { box.endWhatIsLeftAfterExit() }
                    let finish: @Sendable () -> Void = {
                        guard resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                        let out = collector.stdout.withLock { $0 }
                        let err = collector.stderr.withLock { $0 }
                        continuation.resume(returning: Execution(
                            output: GitOutput(status: status, stdout: out, stderr: err),
                            wasStopped: box.wasStopped
                        ))
                    }
                    group.notify(queue: .global(qos: .userInitiated), execute: finish)
                    if box.wasStopped {
                        // Something that ignored the stop may still hold the pipes open.
                        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1, execute: finish)
                    }
                }

                // Stopped before git started (the task was cancelled already, so the stop came
                // first and found nothing to end): git doesn't start at all. Started anyway, it
                // would run to its end and only then report the stop, its work done.
                if box.wasStopped {
                    group.leave()
                    group.leave()
                    continuation.resume(returning: Execution(output: GitOutput(status: -1, stdout: Data(), stderr: Data()), wasStopped: true))
                    return
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
                // A stop that came while git was starting found nothing running yet: end it now.
                if box.wasStopped { box.terminate() }
                onLaunch { box.terminate() }

                GitRunner.pipeQueue("stdout").async {
                    let data = outHandle.readDataToEndOfFile()
                    collector.stdout.withLock { $0 = data }
                    group.leave()
                }
                GitRunner.pipeQueue("stderr").async {
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
                    GitRunner.pipeQueue("stdin").async {
                        try? inHandle.write(contentsOf: input)
                        try? inHandle.close()
                    }
                }
            }
        } onCancel: {
            box.terminate()
        }
    }

    /// A queue for one pipe of one git process. Reading a pipe blocks until git closes it; a
    /// serial queue of its own gets its own thread, so many git processes at once (the test
    /// suite, Fetch All) can't use up the shared pool and leave a git waiting on a full pipe
    /// that nobody reads.
    static func pipeQueue(_ name: String) -> DispatchQueue {
        DispatchQueue(label: "com.progresshans.kaern.git-\(name)", qos: .userInitiated)
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
