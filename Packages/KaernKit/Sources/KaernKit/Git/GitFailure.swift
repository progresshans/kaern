import Foundation

/// What went wrong when a git command failed, read from its error output, so the app can say it
/// in one sentence and offer the fix (Command Log, Activity, the status bar).
public enum GitFailure: Sendable, Hashable {
    /// The server turned down the credentials (HTTPS) — a token expired or was revoked.
    case signIn(host: String?)
    /// The server didn't accept the SSH key.
    case sshKey(host: String?)
    /// The server couldn't be reached (DNS, connection, timeout).
    case network(host: String?)
    /// Push refused: the remote has commits the branch doesn't.
    case pushRejected(remote: String?)
    /// Stopped on conflicts.
    case conflicts(files: Int)
    /// Uncommitted changes in files the command would overwrite.
    case localChanges(files: [String])
    /// Another git process holds the index lock.
    case locked(path: String?)
    /// A hook (pre-commit, commit-msg, pre-push…) stopped it.
    case hook(name: String)
    /// The remote branch isn't there anymore.
    case remoteBranchGone(branch: String?)

    /// Reads a failed command. `nil` when it's nothing Kaern has words for.
    public static func explain(arguments: [String], errorOutput: String, output: String = "", status: Int32?) -> GitFailure? {
        guard let status, status != 0 else { return nil }
        let text = errorOutput + "\n" + output
        let lower = text.lowercased()
        let host = Self.host(in: text)

        if lower.contains("authentication failed") || lower.contains("invalid username or token")
            || lower.contains("could not read username") || lower.contains("could not read password")
            || lower.contains("terminal prompts disabled") || lower.contains("http basic: access denied")
            || lower.contains("the requested url returned error: 401") || lower.contains("the requested url returned error: 403")
            || lower.contains("support for password authentication was removed") {
            return .signIn(host: host)
        }
        if lower.contains("permission denied (publickey") || lower.contains("host key verification failed") {
            return .sshKey(host: host ?? Self.sshHost(in: text))
        }
        if lower.contains("could not resolve host") || lower.contains("failed to connect to") || lower.contains("connection timed out")
            || lower.contains("operation timed out") || lower.contains("network is unreachable") || lower.contains("connection refused")
            || lower.contains("could not read from remote repository") && !lower.contains("permission denied") && lower.contains("connection")
            || lower.contains("ssh: connect to host") || lower.contains("the remote end hung up unexpectedly") && lower.contains("timed out") {
            return .network(host: host ?? Self.sshHost(in: text))
        }
        if lower.contains("[rejected]") || lower.contains("non-fast-forward") || lower.contains("fetch first")
            || lower.contains("updates were rejected") {
            return .pushRejected(remote: Self.remote(in: arguments))
        }
        if lower.contains("index.lock") && (lower.contains("file exists") || lower.contains("unable to create")) {
            return .locked(path: Self.quoted(in: text, containing: "index.lock"))
        }
        if lower.contains("your local changes to the following files would be overwritten")
            || lower.contains("untracked working tree files would be overwritten") {
            return .localChanges(files: Self.indentedFiles(in: errorOutput))
        }
        let conflicts = text.split(separator: "\n").count { $0.hasPrefix("CONFLICT") }
        if conflicts > 0 || lower.contains("fix conflicts and then commit") || lower.contains("resolve all conflicts manually") {
            return .conflicts(files: max(conflicts, 1))
        }
        if lower.contains("couldn't find remote ref") {
            return .remoteBranchGone(branch: Self.quotedAfter(text, "couldn't find remote ref"))
        }
        if let subcommand = GitRunner.subcommand(of: arguments), subcommand == "commit" || subcommand == "push" {
            for hook in ["pre-commit", "commit-msg", "prepare-commit-msg", "pre-push"] where lower.contains("\(hook) hook") || lower.contains("hook \(hook)") {
                return .hook(name: hook)
            }
        }
        return nil
    }

    /// The host of the first URL in the text ("github.com" in "…for 'https://github.com/***/recipe-box.git/'").
    static func host(in text: String) -> String? {
        guard let match = text.firstMatch(of: /https?:\/\/(?:[^@\/\s']*@)?([A-Za-z0-9.\-]+)/) else { return nil }
        return String(match.output.1)
    }

    /// "github.com" in "git@github.com: Permission denied" or "ssh: connect to host github.com port 22".
    static func sshHost(in text: String) -> String? {
        if let match = text.firstMatch(of: /connect to host ([A-Za-z0-9.\-]+)/) { return String(match.output.1) }
        if let match = text.firstMatch(of: /[A-Za-z0-9_.\-]+@([A-Za-z0-9.\-]+):/) { return String(match.output.1) }
        return nil
    }

    /// The remote a push or fetch named (the first argument after the subcommand that isn't an option).
    static func remote(in arguments: [String]) -> String? {
        guard let index = GitRunner.subcommandIndex(of: arguments) else { return nil }
        return arguments[(index + 1)...].first { !$0.hasPrefix("-") }
    }

    /// Files listed with a tab or spaces in front (git's "would be overwritten" lists).
    static func indentedFiles(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("\t") || line.hasPrefix("    ") else { return nil }
            let file = line.trimmingCharacters(in: .whitespaces)
            return file.isEmpty ? nil : file
        }
    }

    static func quoted(in text: String, containing needle: String) -> String? {
        for match in text.matches(of: /'([^']+)'/) where match.output.1.contains(needle) {
            return String(match.output.1)
        }
        return nil
    }

    static func quotedAfter(_ text: String, _ marker: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        let rest = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let word = rest.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        return word?.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }
}
