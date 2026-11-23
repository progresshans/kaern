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
    /// The process started. During an automatic stash or its recovery, Stop cancels the enclosing
    /// operation once the protected commands have finished. Otherwise it stops this process.
    case started(GitCommandRecord, stop: GitCommandHandle)
    /// A progress line on standard error (only for commands run with `onProgress`).
    case progress(UUID, String)
    case finished(GitCommandRecord)
}

/// Stops a running command.
public final class GitCommandHandle: Sendable {
    @TaskLocal static var deferredStop: GitCommandHandle?
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

    /// Most of what git prints has nothing to hide, and ten patterns over all of it took longer
    /// than many of the commands themselves (0.1 s for 64 KB, before the command returned). So
    /// the text is first looked through for the plain words a pattern can't match without; only
    /// the patterns whose words are there run.
    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var text = text
        let found = text.withUTF8 { Triggers($0) }
        guard found.any else { return text }
        return redact(text, found)
    }

    /// Every pattern, whatever the text has (what `redact` did before; the tests compare the two).
    static func redactWithEveryPattern(_ text: String) -> String {
        redact(text, Triggers(all: true))
    }

    private static func redact(_ text: String, _ found: Triggers) -> String {
        var result = text
        // https://user:token@host/… and https://token@host/… → https://***@host/…
        if found.url { result = result.replacing(urlCredentials) { match in "\(match.output.1)\(mask)@" } }
        // Authorization: Bearer abc / Basic abc (also inside http.extraHeader=…).
        if found.authorization { result = result.replacing(authorizationHeader) { match in "\(match.output.1)\(mask)" } }
        // password=…, token=…, access_token=… (query strings, credential-helper style input).
        if found.assignment { result = result.replacing(secretAssignment) { match in "\(match.output.1)\(match.output.2)\(mask)" } }
        for (index, pattern) in tokenPatterns.enumerated() where found.tokens[index] {
            result = result.replacing(pattern) { _ in mask }
        }
        return result
    }

    /// Which patterns can match at all: each needs one of its plain words in the text.
    private struct Triggers {
        var url = false
        var authorization = false
        var assignment = false
        /// One per entry of `tokenPatterns`.
        var tokens = [Bool](repeating: false, count: 7)

        var any: Bool { url || authorization || assignment || tokens.contains(true) }

        init(all: Bool) {
            url = all; authorization = all; assignment = all
            tokens = [Bool](repeating: all, count: 7)
        }

        init(_ bytes: UnsafeBufferPointer<UInt8>) {
            func has(_ word: StaticString, anyCase: Bool = false) -> Bool {
                word.withUTF8Buffer { Self.contains(bytes, $0, anyCase: anyCase) }
            }
            url = has("://") && has("@")
            // The patterns that ignore case also take the two letters that only fold to ASCII
            // ones: "ſ" (s) and the Kelvin sign (k). A text with either one runs them all.
            let folds = has("\u{17F}") || has("\u{212A}")
            authorization = folds || has("authorization", anyCase: true)
            assignment = folds || ["password", "passwd", "pwd", "token", "key", "secret"].contains { (word: StaticString) in has(word, anyCase: true) }
            tokens[0] = has("ghp_") || has("gho_") || has("ghu_") || has("ghs_") || has("ghr_")
            tokens[1] = has("github_pat_")
            tokens[2] = has("glpat-")
            tokens[3] = has("ATBB")
            tokens[4] = has("xox")
            tokens[5] = has("AKIA") || has("ASIA")
            tokens[6] = has("eyJ")
        }

        /// Whether `text` has `word`. `anyCase`: `word` is lowercase ASCII letters, and letters of
        /// either case match it.
        private static func contains(_ text: UnsafeBufferPointer<UInt8>, _ word: UnsafeBufferPointer<UInt8>, anyCase: Bool) -> Bool {
            guard !word.isEmpty, text.count >= word.count else { return false }
            let fold: UInt8 = anyCase ? 0x20 : 0
            let first = word[0]
            let last = text.count - word.count
            var index = 0
            while index <= last {
                if text[index] | fold == first {
                    var offset = 1
                    while offset < word.count, text[index + offset] | fold == word[offset] { offset += 1 }
                    if offset == word.count { return true }
                }
                index += 1
            }
            return false
        }
    }

    nonisolated(unsafe) private static let urlCredentials =
        /([A-Za-z][A-Za-z0-9+.\-]*:\/\/)[^\/\s@'"]+@/
    nonisolated(unsafe) private static let authorizationHeader =
        /(?i)((?:proxy-)?authorization:\s*)(?:(?:bearer|basic|token|digest)\s+)?[^\s'"]+/
    // Any key that ends in one of these: access_token, oauth_refresh_token, client_secret…
    nonisolated(unsafe) private static let secretAssignment =
        /(?i)\b([a-z0-9_.\-]*(?:password|passwd|pwd|token|api_?key|secret))(\s*[=:]\s*)[^\s&'",;]+/
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
