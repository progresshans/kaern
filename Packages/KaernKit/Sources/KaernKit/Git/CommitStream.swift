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
///
/// The end of git's output is the end of history only when git exits with 0. Anything else (a
/// ref pointing at a missing object, a corrupt pack) throws ``GitError`` with git's message, so
/// nobody mistakes a failed read for an empty or shorter history.
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
    /// How git exited (set by its termination handler). The one place that says git has exited:
    /// `read` and the Command Log's record both go by it, so the record ends in the step that
    /// reads the end of history.
    private var termination: (status: Int32, reason: Process.TerminationReason)?
    /// Signalled once git has exited, from its termination handler: after the end of git's
    /// output, `read` waits on this for the exit status. (Never `waitUntilExit()` on `queue`:
    /// it waits on a run loop that thread doesn't run.)
    private let exitSignal = DispatchSemaphore(value: 0)
    /// git's standard error has been read to its end.
    private let errorsRead = DispatchGroup()
    /// git failed: every read after that throws this.
    private var failure: GitError?

    private var reader: FileHandle?
    private var buffer = Data()
    private var delivered = 0
    private var record: GitCommandRecord?
    private var started: ContinuousClock.Instant?
    /// The last commit was read.
    private var readToEnd = false
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
        arguments += GitRepository.revisionArguments(for: scope, head: includeHEAD ? repository.headState() : .leftOut)
        arguments.append("--")
        self.arguments = arguments
    }

    /// History was read to its end. A stopped stream isn't finished: there may be more, and a new
    /// stream can read it.
    public var isFinished: Bool { lock.withLock { finishedReading && !stopped } }

    /// How many commits the stream has handed out.
    public var count: Int { queue.sync { delivered } }

    /// The next `count` commits, newest first; fewer at the end of history, none after it.
    /// Throws `CancellationError` when the stream was stopped before it got them: a read that
    /// was cut short gives nothing, so nobody mistakes part of the history for all of it.
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
        queue.async { self.finishIfDone() }
    }

    deinit {
        if let process, process.isRunning { process.terminate() }
        // Released before git's exit was heard: the Command Log record ends here, or it would
        // show git running forever.
        if record != nil { finishRecord(stopped: !readToEnd) }
    }

    // MARK: Reading (on `queue`)

    private func read(_ count: Int) throws -> [Commit] {
        if lock.withLock({ stopped }) { throw CancellationError() }
        if let failure { throw failure }
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
                // git was ended before this read had what it asked for.
                buffer.removeAll()
                throw CancellationError()
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
                // `cancel()` marks the stream stopped before it ends git, so an end of output
                // after that is the cut, not the end of history.
                if lock.withLock({ stopped }) {
                    buffer.removeAll()
                    throw CancellationError()
                }
                // Otherwise it's the end of history if git exits with 0.
                let exit = waitForExit()
                let cut = lock.withLock { () -> Bool in
                    if stopped { return true }
                    if exit.map({ $0.status == 0 && $0.reason == .exit }) ?? true { finishedReading = true }
                    return false
                }
                if cut {
                    buffer.removeAll()
                    throw CancellationError()
                }
                if let exit, exit.status != 0 || exit.reason != .exit {
                    // git failed partway or before the first commit: what this read collected
                    // isn't all there is, so it gives nothing.
                    buffer.removeAll()
                    _ = errorsRead.wait(timeout: .now() + 5)
                    let message = String(decoding: errorOutput.value, as: UTF8.self)
                    let error = GitError(arguments: arguments, status: exit.status,
                                         message: exit.reason == .uncaughtSignal && message.isEmpty
                                             ? "git log was ended by signal \(exit.status)." : message)
                    failure = error
                    finishIfDone()
                    throw error
                }
                reachedEnd = true
            }
        }
        delivered += commits.count
        // The Command Log hears the end once the last commits are counted and git has exited.
        if reachedEnd {
            readToEnd = true
            finishIfDone()
        }
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
        // Never `waitUntilExit()` on this queue: it waits on a run loop the queue's thread doesn't run.
        // The handler runs on Foundation's own queue, so `read` can wait on `exitSignal` meanwhile.
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let exit = (status: process.terminationStatus, reason: process.terminationReason)
            self.lock.withLock { self.termination = exit }
            self.exitSignal.signal()
            // A stream that was stopped before git exited ends its record here, and so does one
            // whose read stopped waiting for git's exit.
            self.queue.async { self.finishIfDone() }
        }
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
        let group = errorsRead
        group.enter()
        GitRunner.pipeQueue("log-stderr").async {
            box.set(errorHandle.readDataToEndOfFile())
            group.leave()
        }
        if let onCommand = runner.onCommand {
            let record = GitCommandRecord(arguments: GitRedaction.redact(arguments: arguments), directory: directory.path(percentEncoded: false),
                                          trigger: trigger, started: Date())
            self.record = record
            onCommand(.started(record, stop: GitCommandHandle { [weak self] in self?.cancel() }))
        }
    }

    /// After the end of git's output, how git exited: `nil` when it didn't within 10 s (read as
    /// the end of history, as before git's status was checked).
    private func waitForExit() -> (status: Int32, reason: Process.TerminationReason)? {
        if let known = lock.withLock({ termination }) { return known }
        guard lock.withLock({ process != nil }) else { return nil }
        guard exitSignal.wait(timeout: .now() + 10) == .success else { return nil }
        exitSignal.signal()   // stays signalled for any later wait
        return lock.withLock { termination }
    }

    /// Ends the Command Log record once git has exited and the stream was read to the end,
    /// stopped or failed (on `queue`).
    private func finishIfDone() {
        guard record != nil else { return }
        let (exited, stopped) = lock.withLock { (termination != nil, self.stopped) }
        guard exited, readToEnd || stopped || failure != nil else { return }
        finishRecord(stopped: stopped)
    }

    private func finishRecord(stopped: Bool) {
        guard var finished = record, let onCommand = runner.onCommand else { return }
        record = nil
        let process = lock.withLock { self.process }
        finished.status = process.map { $0.isRunning ? 15 : $0.terminationStatus } ?? -1
        if let started { finished.duration = ContinuousClock.now - started }
        finished.output = "\(delivered) commits read" + (stopped ? ", then stopped" : failure != nil ? ", then git failed" : "")
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

    /// Where HEAD is, for what `git log` needs to name besides the branches.
    enum HeadState: Sendable, Hashable {
        /// The caller doesn't want HEAD's commits (unless a branch brings them).
        case leftOut
        /// On a branch (`ref: refs/heads/<name>`), born or not.
        case attached
        /// At a commit no branch may hold.
        case detached
        /// HEAD's file doesn't say (reftable keeps HEAD elsewhere).
        case unknown
    }

    /// Reads `HEAD` in the repository's git directory (a linked worktree has its own).
    func headState() -> HeadState {
        let file = gitDirectory.appending(path: "HEAD").path(percentEncoded: false)
        guard let data = FileManager.default.contents(atPath: file) else { return .unknown }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // reftable leaves "ref: refs/heads/.invalid" in the file and keeps the real HEAD in its table.
        if text == "ref: refs/heads/.invalid" { return .unknown }
        if text.hasPrefix("ref: refs/heads/") { return .attached }
        if text.hasPrefix("ref:") { return .unknown }
        return .detached
    }

    /// The revisions `git log` starts from for a scope.
    ///
    /// HEAD is named only when it adds commits the branches don't have: when it's detached, or
    /// when the scope may leave out the branch it's on. HEAD on an unborn branch (a repository
    /// without commits yet) is never named bare: git would fail with "bad revision 'HEAD'".
    /// `--ignore-missing` covers that where git can't be told otherwise; it isn't used next to
    /// `--branches`, where it would also skip a branch that points at a missing object instead
    /// of failing.
    static func revisionArguments(for scope: HistoryScope, head: HeadState) -> [String] {
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
            switch head {
            case .leftOut: break
            case .detached: arguments.append("HEAD")
            // A hidden branch may be the one HEAD is on: HEAD brings it back.
            case .attached where hidden.isEmpty: break
            case .attached, .unknown: arguments = ["--ignore-missing"] + arguments + ["HEAD"]
            }
        case .only(let ref):
            arguments.append(ref)
        case .local(let remoteBranches):
            arguments.append("--branches")
            // Each remote branch by a pattern that matches only its own name, so a branch a fetch
            // pruned meanwhile is left out instead of failing the whole read.
            arguments += remoteBranches.map { "--glob=" + exactRemoteGlob($0) }
            switch head {
            case .detached: arguments.append("HEAD")
            case .unknown: arguments = ["--ignore-missing"] + arguments + ["HEAD"]
            case .leftOut, .attached: break
            }
        case .current:
            // HEAD is the only revision, so --ignore-missing only lets an unborn branch read as empty.
            arguments += ["--ignore-missing", "HEAD"]
        }
        return arguments
    }

    /// A ref pattern that matches the remote branch `name` ("origin/main") alone, and nothing
    /// when a fetch pruned it (where naming it would fail the whole read). git appends `/*` to a
    /// pattern without `*`, `?` or `[` (so `origin/main` would mean the branches under it), so one
    /// character is bracketed: the `s` of `refs/remotes/`. A character of the name itself won't
    /// do: a bracket matches one byte (not `é` or `글`), and `[!]` isn't a valid bracket. Branch
    /// names can't contain `*`, `?`, `[` or a backslash, so the rest matches as written.
    static func exactRemoteGlob(_ name: String) -> String {
        "refs/remote[s]/" + name
    }
}
