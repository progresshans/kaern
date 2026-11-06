import AppKit
import KaernKit

/// A fetch, pull or push the remote turned down or didn't answer. Each kind has its own sheet
/// with the reason and the next step (design: "Sheets — 오류 · 확인").
struct RemoteProblem: Identifiable {
    enum Kind: Equatable {
        case authentication
        case sshAuthentication
        case unknownHostKey
        case unreachable
    }

    let id = UUID()
    var kind: Kind
    var remote: String
    var url: RemoteURL?
    var username: String?
    /// What git printed, for Show Log.
    var log: String
    var retry: RemoteAction

    var host: String { url?.host ?? remote }
}

/// The remote command to run again after signing in, switching to SSH or Try Again.
enum RemoteAction: Equatable {
    case fetch
    case pull
    case push
    case pullThenPush
    case forcePush
}

extension RepositoryModel {
    func retry(_ action: RemoteAction) async {
        switch action {
        case .fetch: await fetch()
        case .pull: await pull()
        case .push: await push()
        case .pullThenPush: await pullThenPush()
        case .forcePush: await forcePush()
        }
    }

    /// Shows the remote problem sheet when a failure is about signing in or reaching the host.
    /// Returns `false` for other failures, which get the usual alert.
    func handleRemoteFailure(_ error: any Error, retry: RemoteAction) async -> Bool {
        let message = (error as? GitError)?.message ?? error.localizedDescription
        let kind: RemoteProblem.Kind
        switch RemoteFailure.classify(message) {
        case .authentication(let overSSH): kind = overSSH ? .sshAuthentication : .authentication
        case .unknownHostKey: kind = .unknownHostKey
        case .unreachable: kind = .unreachable
        case .other: return false
        }
        let remote = upstreamRemote ?? defaultRemote ?? "origin"
        let url = await repository?.remoteURL(remote).flatMap(RemoteURL.init)
        var username = url?.isSSH == true ? nil : url?.user
        if username == nil, kind == .authentication {
            username = await repository?.config("credential.username")
        }
        remoteProblem = RemoteProblem(kind: kind, remote: remote, url: url, username: username, log: error.localizedDescription, retry: retry)
        return true
    }

    // MARK: Next steps

    /// Sign In with Browser…: the token goes to git's credential helper, then the command runs again.
    func signIn(to problem: RemoteProblem, username: String, token: String, keep: Bool) async -> Bool {
        guard let repository else { return false }
        do {
            try await repository.approveCredential(host: problem.host, username: username, secret: token)
        } catch {
            showError(error, title: String(localized: "Couldn't Save the Token"))
            return false
        }
        await retry(problem.retry)
        if !keep {
            await repository.rejectCredential(host: problem.host, username: username)
        }
        return true
    }

    /// Use SSH Instead…: points the remote at the SSH address and runs the command again.
    /// ⌘Z puts the old address back.
    func switchToSSH(remote: String, url: String, retry action: RemoteAction) async {
        guard let repository, let previous = await repository.remoteURL(remote) else { return }
        let switched = await perform(.working(String(localized: "Switching \(remote) to SSH…")), failureTitle: String(localized: "Couldn't Change \(remote)")) { repository in
            try await repository.setRemoteURL(remote, to: url)
        }
        guard switched else { return }
        registerUndo(String(localized: "Use SSH"), hint: String(localized: "\(remote) now uses SSH")) { model in
            await model.undoStep(String(localized: "Use SSH")) { repository in
                try await repository.setRemoteURL(remote, to: previous)
            }
        }
        await retry(action)
    }

    /// Work Offline: no background fetches until the next fetch, pull or push that gets through.
    func workOffline() {
        isWorkingOffline = true
    }
}
