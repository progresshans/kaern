import Foundation

/// One `git log` that the history reads from as it needs more, instead of a new `git log --skip=N`
/// for every page (which walks the first N commits again each time).
///
/// git writes into a pipe; while nobody reads, the pipe fills and git waits, using no CPU. Each
/// `next(_:)` reads only as far as it needs. `cancel()` ends git (a refresh, a closed tab, a tab
/// in the background); a new stream can start where the old one stopped with `skip`.
///
/// The Command Log shows it as one command that runs until history is read to the end or the
/// stream is stopped, with the number of commits read as its output.
public final class CommitStream: @unchecked Sendable {
    private let runner: GitRunner
    private let directory: URL
    private let arguments: [String]
    private let trigger: GitCommandTrigger?
    private let queue = DispatchQueue(label: "com.progresshans.kaern.commit-stream")
    private let lock = NSLock()

    // Guarded by `lock` (read by `cancel()` from other threads); the rest is only touched on `queue`.
    private var process: Process?
    private var stopped = false
    private var finishedReading = false

    private var reader: FileHandle?
    private var buffer = Data()
    private var delivered = 0
    private var record: GitCommandRecord?
    private var started: ContinuousClock.Instant?
    /// git's standard error, read on the side.
    private let errorOutput = ErrorBox()

    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.withLock { data = value } }
        var value: Data { lock.withLock { data } }
    }

    /// How many commits it was told to skip before the first one it delivers.
    public let skipped: Int

    init(repository: GitRepository, skip: Int, scope: HistoryScope, includeHEAD: Bool) {
        runner = repository.runner
        directory = repository.root
        skipped = skip
        trigger = GitCommandTrigger.current
        var arguments = ["log", "--date-order", "-z", "--format=\(LogParser.format)"]
        if skip > 0 { arguments.append("--skip=\(skip)") }
        arguments += GitRepository.revisionArguments(for: scope, includeHEAD: includeHEAD)
        arguments.append("--")
        self.arguments = arguments
    }

    /// Everything is read, or the stream was stopped.
    public var isFinished: Bool { lock.withLock { finishedReading || stopped } }

    /// How many commits the stream has handed out.
    public var count: Int { queue.sync { delivered } }

    /// The next `count` commits, newest first; fewer at the end of history, none after it.
    public func next(_ count: Int) async throws -> [Commit] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.read(count))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Ends git. Commits already read stay with whoever read them.
    public func cancel() {
        let running: Process? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            return process
        }
        if let running, running.isRunning { running.terminate() }
        queue.async { self.finishRecord(stopped: true) }
    }

    deinit {
        if let process, process.isRunning { process.terminate() }
    }

    // MARK: Reading (on `queue`)

    private func read(_ count: Int) throws -> [Commit] {
        if lock.withLock({ stopped }) { return [] }
        try launchIfNeeded()
        var commits: [Commit] = []
        commits.reserveCapacity(min(count, 4096))
        var reachedEnd = false
        while commits.count < count {
            if let end = buffer.firstIndex(of: 0) {
                let record = buffer[buffer.startIndex ..< end]
                buffer.removeSubrange(buffer.startIndex ... end)
                if let commit = LogParser.parseRecord(String(decoding: record, as: UTF8.self)) { commits.append(commit) }
                continue
            }
            let (atEnd, wasStopped) = lock.withLock { (finishedReading, stopped) }
            if wasStopped {
                // git was ended mid-record: what's left is cut off.
                buffer.removeAll()
                break
            }
            if atEnd {
                // The last record has no NUL after it.
                if !buffer.isEmpty, let commit = LogParser.parseRecord(String(decoding: buffer, as: UTF8.self)) { commits.append(commit) }
                buffer.removeAll()
                break
            }
            let chunk = (try? reader?.read(upToCount: 256 * 1024)) ?? nil
            if let chunk, !chunk.isEmpty {
                buffer.append(chunk)
            } else {
                lock.withLock { finishedReading = true }
                reachedEnd = true
            }
        }
        delivered += commits.count
        // The Command Log hears the end once the last commits are counted.
        if reachedEnd { waitForExit() }
        return commits
    }

    private func launchIfNeeded() throws {
        guard lock.withLock({ process == nil }) else { return }
        let process = Process()
        process.executableURL = runner.executableURL
        process.arguments = GitRunner.baseArguments + arguments
        process.environment = runner.environment
        process.currentDirectoryURL = directory
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            lock.withLock { finishedReading = true }
            throw GitError(arguments: arguments, status: -1,
                           message: "Couldn't run git at \(runner.executableURL.path(percentEncoded: false)): \(error.localizedDescription)")
        }
        lock.withLock { self.process = process }
        reader = output.fileHandleForReading
        started = .now
        // Standard error is small; read it on the side so git never waits on it.
        let errorHandle = errors.fileHandleForReading
        let box = errorOutput
        GitRunner.pipeQueue("log-stderr").async {
            box.set(errorHandle.readDataToEndOfFile())
        }
        if let onCommand = runner.onCommand {
            let record = GitCommandRecord(arguments: GitRedaction.redact(arguments: arguments), directory: directory.path(percentEncoded: false),
                                          trigger: trigger, started: Date())
            self.record = record
            onCommand(.started(record, stop: GitCommandHandle { [weak self] in self?.cancel() }))
        }
    }

    private func waitForExit() {
        guard let process = lock.withLock({ self.process }) else { return }
        process.waitUntilExit()
        finishRecord(stopped: false)
    }

    private func finishRecord(stopped asked: Bool) {
        guard var finished = record, let onCommand = runner.onCommand else { return }
        record = nil
        let (process, stopped) = lock.withLock { (self.process, asked || self.stopped) }
        if stopped, let process, process.isRunning { process.waitUntilExit() }
        finished.status = process.map { $0.isRunning ? 15 : $0.terminationStatus } ?? -1
        if let started { finished.duration = ContinuousClock.now - started }
        finished.output = "\(delivered) commits read" + (stopped ? ", then stopped" : "")
        finished.errorOutput = GitRedaction.redact(String(decoding: errorOutput.value.prefix(GitRunner.recordedOutputLimit / 10), as: UTF8.self))
        finished.wasStopped = stopped
        onCommand(.finished(finished))
    }
}

extension GitRepository {
    /// A stream of the history ``log(skip:limit:includeHEAD:scope:)`` pages through, starting
    /// `skip` commits in.
    public func historyStream(skip: Int = 0, scope: HistoryScope = .all(hidden: []), includeHEAD: Bool = true) -> CommitStream {
        CommitStream(repository: self, skip: skip, scope: scope, includeHEAD: includeHEAD)
    }

    /// The revisions `git log` starts from for a scope.
    static func revisionArguments(for scope: HistoryScope, includeHEAD: Bool) -> [String] {
        var arguments: [String] = []
        switch scope {
        case .all(let hidden):
            // `--exclude` applies to the `--branches` / `--remotes` that follows it, with names
            // relative to refs/heads/ and refs/remotes/.
            for ref in hidden where ref.hasPrefix("refs/heads/") {
                arguments.append("--exclude=" + ref.dropFirst("refs/heads/".count))
            }
            arguments.append("--branches")
            for ref in hidden where ref.hasPrefix("refs/remotes/") {
                arguments.append("--exclude=" + ref.dropFirst("refs/remotes/".count))
            }
            arguments += ["--remotes", "--tags"]
            if includeHEAD { arguments.append("HEAD") }
        case .only(let ref):
            arguments.append(ref)
        }
        return arguments
    }
}
