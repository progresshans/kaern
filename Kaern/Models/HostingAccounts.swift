import AppKit
import Foundation
import KaernKit

/// A GitHub or GitLab account from Settings › Accounts. Only who and where is kept here; the
/// token lives with git's credential helper in the Keychain.
struct HostingAccount: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case github
        case gitlab
    }

    var kind: Kind
    var host: String
    var login: String
    var name: String?
    /// Clone with SSH instead of HTTPS.
    var clonesWithSSH = false
    /// Commit as: the email for repositories cloned from this account (`nil`: the global one).
    var commitEmail: String?
    /// `12345+login@users.noreply.github.com`
    var noreplyEmail: String?
    var publicEmail: String?

    var id: String { "\(host)/\(login)" }

    /// "GitHub" or "GitLab", for buttons ("Open on GitHub").
    var serviceName: String {
        kind == .github ? "GitHub" : "GitLab"
    }

    var hostName: String {
        switch kind {
        case .github: host == "github.com" ? "GitHub" : "GitHub (\(host))"
        case .gitlab: host == "gitlab.com" ? "GitLab" : "GitLab (\(host))"
        }
    }

    /// The API this account talks to (`-KaernGitHubAPI <url>` points GitHub at a local server
    /// in debug builds).
    var apiURL: URL {
        #if DEBUG
        if kind == .github, let override = UserDefaults.standard.string(forKey: "KaernGitHubAPI"), let url = URL(string: override) {
            return url
        }
        #endif
        return GitHubClient.apiURL(for: host)
    }
}

extension AppModel {
    private static let accountsKey = "hostingAccounts"

    var accounts: [HostingAccount] {
        guard let data = UserDefaults.standard.data(forKey: Self.accountsKey),
              let accounts = try? JSONDecoder().decode([HostingAccount].self, from: data) else { return [] }
        return accounts
    }

    func saveAccounts(_ accounts: [HostingAccount]) {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.accountsKey)
        }
        accountsVersion += 1
    }

    /// The account for a remote's host.
    func account(forHost host: String) -> HostingAccount? {
        _ = accountsVersion
        return accounts.first { $0.host.caseInsensitiveCompare(host) == .orderedSame }
    }

    /// Signs in with a token: asks the host who it belongs to, then hands it to git's
    /// credential helper (so `git fetch` in Terminal can use it too).
    func addAccount(kind: HostingAccount.Kind, host: String, token: String) async throws -> HostingAccount {
        let user: HostingUser
        var account: HostingAccount
        switch kind {
        case .github:
            var probe = HostingAccount(kind: kind, host: host, login: "")
            let client = GitHubClient(baseURL: probe.apiURL, token: token)
            user = try await client.user()
            probe.login = user.login
            account = probe
        case .gitlab:
            user = try await GitLabClient.user(host: host, token: token)
            account = HostingAccount(kind: kind, host: host, login: user.login)
        }
        account.name = user.name
        account.noreplyEmail = kind == .github && host == "github.com" ? user.noreplyEmail : nil
        account.publicEmail = user.email
        try await makeRunner().approveCredential(host: host, username: user.login, secret: token)
        var all = accounts.filter { $0.id != account.id }
        all.append(account)
        saveAccounts(all)
        return account
    }

    func updateAccount(_ account: HostingAccount) {
        saveAccounts(accounts.map { $0.id == account.id ? account : $0 })
    }

    /// Sign Out: the token leaves the Keychain too.
    func signOut(_ account: HostingAccount) async {
        await makeRunner().rejectCredential(host: account.host, username: account.login)
        saveAccounts(accounts.filter { $0.id != account.id })
    }

    func token(for account: HostingAccount) async -> String? {
        await makeRunner().credential(host: account.host, username: account.login)
    }
}
