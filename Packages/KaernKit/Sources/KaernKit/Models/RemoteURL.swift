import Foundation

/// A remote's URL, split into what the sign-in and "Use SSH Instead" flows need.
/// Understands `https://[user@]host[:port]/path`, `ssh://[user@]host[:port]/path` and the
/// scp-like `user@host:path`.
public struct RemoteURL: Sendable, Hashable {
    public enum Scheme: Sendable, Hashable {
        case https
        case http
        case ssh
        case other(String)
    }

    public var scheme: Scheme
    public var user: String?
    public var host: String
    /// `owner/repo.git` (no leading slash).
    public var path: String

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed), let scheme = components.scheme, let host = components.host, !host.isEmpty {
            switch scheme.lowercased() {
            case "https": self.scheme = .https
            case "http": self.scheme = .http
            case "ssh", "git+ssh", "ssh+git": self.scheme = .ssh
            default: self.scheme = .other(scheme)
            }
            self.user = components.user
            self.host = host
            self.path = String(components.path.drop(while: { $0 == "/" }))
            return
        }
        // scp-like: [user@]host:path — no "://", and the colon comes before any slash.
        guard !trimmed.contains("://"), let colon = trimmed.firstIndex(of: ":") else { return nil }
        let before = trimmed[..<colon]
        guard !before.contains("/"), !before.isEmpty else { return nil }
        if let at = before.firstIndex(of: "@") {
            user = String(before[..<at])
            host = String(before[before.index(after: at)...])
        } else {
            user = nil
            host = String(before)
        }
        scheme = .ssh
        path = String(trimmed[trimmed.index(after: colon)...].drop(while: { $0 == "/" }))
        guard !host.isEmpty, !path.isEmpty else { return nil }
    }

    public var isSSH: Bool { scheme == .ssh }

    /// `git@github.com:owner/repo.git` for an HTTPS remote.
    public var sshEquivalent: String {
        var repository = path
        if !repository.hasSuffix(".git") { repository += ".git" }
        return "git@\(host):\(repository)"
    }

    /// `https://github.com/owner/repo.git` for an SSH remote.
    public var httpsEquivalent: String {
        var repository = path
        if !repository.hasSuffix(".git") { repository += ".git" }
        return "https://\(host)/\(repository)"
    }

    /// `owner/repo` without `.git`.
    public var repositoryPath: String {
        path.hasSuffix(".git") ? String(path.dropLast(4)) : path
    }

    /// Whether this is `owner/name` on `host`, written as HTTPS or SSH, with or without `.git`.
    /// Hosts and GitHub's names don't tell upper case from lower.
    public func names(_ repository: String, on host: String) -> Bool {
        let path = repositoryPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return self.host.caseInsensitiveCompare(host) == .orderedSame && path.caseInsensitiveCompare(repository) == .orderedSame
    }

    /// The host as people call it: GitHub, GitLab, Bitbucket, or the host name.
    public var hostName: String {
        switch host.lowercased() {
        case "github.com": "GitHub"
        case "gitlab.com": "GitLab"
        case "bitbucket.org": "Bitbucket"
        default: host
        }
    }

    /// The repository's page on its host.
    public var webPage: URL? {
        guard !repositoryPath.isEmpty else { return nil }
        return URL(string: "https://\(host)/\(repositoryPath)")
    }

    /// A commit's page: GitHub and most hosts use `/commit/<sha>`, GitLab `/-/commit/<sha>`,
    /// Bitbucket `/commits/<sha>`.
    public func commitPage(_ sha: String) -> URL? {
        guard let webPage else { return nil }
        switch host.lowercased() {
        case "gitlab.com": return webPage.appending(path: "-/commit/\(sha)")
        case "bitbucket.org": return webPage.appending(path: "commits/\(sha)")
        default: return webPage.appending(path: "commit/\(sha)")
        }
    }

    /// Where to create a token for this host in the browser.
    public var tokenPage: URL? {
        switch host.lowercased() {
        case "github.com":
            URL(string: "https://github.com/settings/tokens/new?scopes=repo,workflow&description=Kaern")
        case "gitlab.com":
            URL(string: "https://gitlab.com/-/user_settings/personal_access_tokens?name=Kaern&scopes=read_repository,write_repository")
        case "bitbucket.org":
            URL(string: "https://bitbucket.org/account/settings/app-passwords/")
        default:
            URL(string: "https://\(host)/")
        }
    }
}

/// What went wrong talking to a remote, from git's message.
public enum RemoteFailure: Sendable, Hashable {
    /// The remote didn't accept the credentials (or there were none to offer).
    case authentication(overSSH: Bool)
    /// SSH doesn't trust the host key yet.
    case unknownHostKey
    /// The host couldn't be reached (DNS, offline, VPN, timeout).
    case unreachable
    case other

    public static func classify(_ message: String) -> RemoteFailure {
        let text = message.lowercased()
        if text.contains("host key verification failed") {
            return .unknownHostKey
        }
        if text.contains("permission denied (publickey") || text.contains("permission denied, please try again") {
            return .authentication(overSSH: true)
        }
        let authentication = [
            "authentication failed", "could not read username", "could not read password",
            "invalid username or password", "invalid username or token", "returned error: 401",
            "returned error: 403", "access denied", "http basic: access denied",
            "support for password authentication was removed",
        ]
        if authentication.contains(where: text.contains) {
            return .authentication(overSSH: false)
        }
        // GitHub answers "not found" for private repositories when you aren't signed in.
        if text.contains("repository not found") && !text.contains("ssh") {
            return .authentication(overSSH: false)
        }
        let network = [
            "could not resolve host", "could not resolve hostname", "timed out", "network is unreachable",
            "connection refused", "failed to connect", "operation too slow", "connection reset",
            "no route to host", "unable to access",
        ]
        if network.contains(where: text.contains) {
            return .unreachable
        }
        return .other
    }
}
