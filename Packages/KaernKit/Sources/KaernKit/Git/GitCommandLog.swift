import Foundation

// MARK: - Why a command ran

/// The UI action a git command runs for ("Commit menu › Cherry-pick 3e71b0c"), or background
/// work ("File watcher"). Set it around the work with
/// `GitCommandTrigger.$current.withValue(…) { … }`: every command run in that task, and in the
/// tasks it starts, is recorded with it.
public struct GitCommandTrigger: Sendable, Hashable {
    public var action: String
    /// Kaern ran it on its own (refreshing after file changes, loading history). The Command
    /// Log hides these unless asked.
    public var isBackground: Bool

    public init(_ action: String, background: Bool = false) {
        self.action = action
        self.isBackground = background
    }

    public static func background(_ action: String) -> GitCommandTrigger {
        GitCommandTrigger(action, background: true)
    }

    /// The trigger of the commands the current task runs.
    @TaskLocal public static var current: GitCommandTrigger?
}

// MARK: - Records

/// What a command does, for the Command Log's filters.
public struct GitCommandKinds: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Writes the repository: commits, refs, the index, the working tree, the stash or config.
    public static let changes = GitCommandKinds(rawValue: 1 << 0)
    /// Talks to a remote.
    public static let network = GitCommandKinds(rawValue: 1 << 1)
}

/// One git command as the Command Log shows it. Arguments and output have secrets replaced by
/// `***` (see ``GitRedaction``); what went to standard input isn't kept.
public struct GitCommandRecord: Sendable, Identifiable {
    public let id: UUID
    /// The arguments after `git`, without the `-c` options Kaern adds to every command.
    public let arguments: [String]
    public let directory: String
    public let trigger: GitCommandTrigger?
    public let started: Date
    /// Something was written to standard input (a commit message, a patch).
    public let hasInput: Bool
    public let kinds: GitCommandKinds
    /// The exit code, `nil` while the command runs.
    public var status: Int32?
    public var duration: Duration?
    /// Standard output and error, cut at ``GitRunner/recordedOutputLimit``.
    public var output: String
    public var errorOutput: String
    public var isOutputCut: Bool
    /// Stopped by Kaern (Stop in the Command Log or the hook HUD, or a cancelled task).
    public var wasStopped: Bool

    public init(
        id: UUID = UUID(), arguments: [String], directory: String, trigger: GitCommandTrigger?, started: Date,
        hasInput: Bool = false, status: Int32? = nil, duration: Duration? = nil,
        output: String = "", errorOutput: String = "", isOutputCut: Bool = false, wasStopped: Bool = false
    ) {
        self.id = id
        self.arguments = arguments
        self.directory = directory
        self.trigger = trigger
        self.started = started
        self.hasInput = hasInput
        self.kinds = GitCommandKinds.of(arguments)
        self.status = status
        self.duration = duration
        self.output = output
        self.errorOutput = errorOutput
        self.isOutputCut = isOutputCut
        self.wasStopped = wasStopped
    }

    public var isRunning: Bool { status == nil }
    public var isBackground: Bool { trigger?.isBackground ?? true }
    public var failed: Bool { (status ?? 0) != 0 }

    /// `git push origin "feature/x"`: the command as it can be typed in Terminal.
    public var commandLine: String {
        (["git"] + arguments.map(GitCommandRecord.shellQuoted)).joined(separator: " ")
    }

    /// Quotes an argument for zsh/bash when it needs it.
    public static func shellQuoted(_ argument: String) -> String {
        if argument.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=@%+,^~")
        if argument.unicodeScalars.allSatisfy({ safe.contains($0) }) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// What the runner reports to ``GitRunner/onCommand``.
public enum GitCommandEvent: Sendable {
    /// The process started. `stop` ends it (the command then throws `CancellationError`).
    case started(GitCommandRecord, stop: GitCommandHandle)
    /// A progress line on standard error (only for commands run with `onProgress`).
    case progress(UUID, String)
    case finished(GitCommandRecord)
}

/// Stops a running command.
public final class GitCommandHandle: Sendable {
    private let stopAction: @Sendable () -> Void
    init(_ stop: @escaping @Sendable () -> Void) { stopAction = stop }
    public func stop() { stopAction() }
}

// MARK: - What a command does

extension GitCommandKinds {
    /// Sorts a command by what it does, from its subcommand and options.
    public static func of(_ arguments: [String]) -> GitCommandKinds {
        guard let index = GitRunner.subcommandIndex(of: arguments) else { return [] }
        let command = arguments[index]
        let rest = Array(arguments[(index + 1)...])
        let options = Set(rest.filter { $0.hasPrefix("-") })
        let operands = rest.filter { !$0.hasPrefix("-") }
        func has(_ names: String...) -> Bool { names.contains { name in options.contains { $0 == name || $0.hasPrefix(name + "=") } } }

        switch command {
        case "fetch", "ls-remote":
            return .network
        case "pull", "push", "clone":
            return [.network, .changes]
        case "lfs":
            switch operands.first {
            case "pull", "checkout": return [.network, .changes]
            case "fetch", "push": return .network
            default: return []
            }
        case "submodule":
            return operands.first == "update" ? [.network, .changes] : []
        case "remote":
            switch operands.first {
            case "update": return [.network, .changes]
            case "add", "remove", "rm", "rename", "set-url", "set-head", "set-branches", "prune": return .changes
            default: return []
            }
        case "commit", "add", "rm", "mv", "restore", "reset", "checkout", "switch", "merge", "rebase", "cherry-pick",
             "revert", "update-ref", "update-index", "read-tree", "init", "worktree", "gc", "prune", "mergetool", "am",
             "clean", "notes", "replace":
            if command == "worktree", operands.first == "list" { return [] }
            return .changes
        case "apply":
            return has("--check", "--stat", "--numstat", "--summary") ? [] : .changes
        case "stash":
            switch operands.first {
            case nil, "push", "save", "pop", "apply", "drop", "clear", "store", "branch": return .changes
            default: return []   // list, show, create
            }
        case "branch":
            let lists = has("--list", "-l", "--contains", "--no-contains", "--merged", "--no-merged", "--format",
                            "--show-current", "-a", "--all", "-r", "--remotes", "-v", "-vv", "--points-at")
            let edits = has("-d", "-D", "--delete", "-m", "-M", "--move", "-c", "-C", "--copy", "-u",
                            "--set-upstream-to", "--unset-upstream", "-f", "--force", "--track", "--no-track")
            if edits || (!lists && !operands.isEmpty) { return .changes }
            return []
        case "tag":
            let lists = has("-l", "--list", "--contains", "--no-contains", "--points-at", "-n", "-v", "--verify",
                            "--merged", "--no-merged", "--format", "--sort")
            if has("-d", "--delete", "-a", "-s", "-f", "--force", "-m", "--file", "-F") { return .changes }
            if !lists && !operands.isEmpty { return .changes }
            return []
        case "config":
            let reads = has("--get", "--get-all", "--get-regexp", "--get-urlmatch", "-l", "--list", "--show-origin",
                            "--show-scope", "--get-color", "--get-colorbool")
            return reads ? [] : (operands.isEmpty ? [] : .changes)
        case "symbolic-ref":
            return has("-d", "--delete") || operands.count >= 2 ? .changes : []
        default:
            return []
        }
    }
}

// MARK: - Hiding secrets

/// Hides passwords and tokens before a command or its output is kept anywhere: credentials in
/// URLs, tokens with a known format, `Authorization` headers and `password=` style values.
public enum GitRedaction {
    public static let mask = "***"

    /// Each argument with its secrets masked.
    public static func redact(arguments: [String]) -> [String] {
        arguments.map(redact)
    }

    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        // https://user:token@host/… and https://token@host/… → https://***@host/…
        result = result.replacing(urlCredentials) { match in "\(match.output.1)\(mask)@" }
        // Authorization: Bearer abc / Basic abc (also inside http.extraHeader=…).
        result = result.replacing(authorizationHeader) { match in "\(match.output.1)\(mask)" }
        // password=…, token=…, access_token=… (query strings, credential-helper style input).
        result = result.replacing(secretAssignment) { match in "\(match.output.1)\(match.output.2)\(mask)" }
        for pattern in tokenPatterns {
            result = result.replacing(pattern) { _ in mask }
        }
        return result
    }

    nonisolated(unsafe) private static let urlCredentials =
        /([A-Za-z][A-Za-z0-9+.\-]*:\/\/)[^\/\s@'"]+@/
    nonisolated(unsafe) private static let authorizationHeader =
        /(?i)((?:proxy-)?authorization:\s*)(?:(?:bearer|basic|token|digest)\s+)?[^\s'"]+/
    nonisolated(unsafe) private static let secretAssignment =
        /(?i)\b(password|passwd|pwd|token|access_token|private_token|api_key|apikey|secret|client_secret)(\s*[=:]\s*)[^\s&'",;]+/
    nonisolated(unsafe) private static let tokenPatterns: [Regex<Substring>] = [
        /\bgh[pousr]_[A-Za-z0-9]{20,}\b/,                 // GitHub tokens
        /\bgithub_pat_[A-Za-z0-9_]{20,}\b/,               // GitHub fine-grained tokens
        /\bglpat-[A-Za-z0-9_\-]{20,}\b/,                  // GitLab personal access tokens
        /\bATBB[A-Za-z0-9]{20,}\b/,                       // Bitbucket app passwords
        /\bxox[abprs]-[A-Za-z0-9\-]{10,}\b/,              // Slack
        /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,                  // AWS access keys
        /\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b/,   // JWTs
    ]
}
