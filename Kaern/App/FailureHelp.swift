import AppKit
import KaernKit

/// A failure said in one sentence, with the button that fixes it (Command Log's "why" box,
/// Activity's Recently, the status bar).
@MainActor
struct FailureHelp {
    let message: String
    /// "Sign In to GitHub…", "Pull", "Resolve Conflicts".
    let fixTitle: String?
    let fix: (() -> Void)?

    /// Short form for the status bar and Activity ("sign in to GitHub").
    let short: String

    static func make(_ failure: GitFailure, repositoryPath: String?, repositoryName: String, auto: Bool) -> FailureHelp {
        let repository = repositoryPath.flatMap { AppModel.shared.openRepository(at: $0) }
        switch failure {
        case .signIn(let host):
            let service = serviceName(host ?? repository?.remoteHost)
            return FailureHelp(
                message: "\(service) turned down the saved sign-in for \(repositoryName)"
                    + (auto ? ", so auto-fetch for this repository is paused until you sign in again." : ". Sign in again to fetch and push."),
                fixTitle: "Sign In to \(service)…",
                fix: { SettingsWindowController.shared.showSignIn(host: host ?? repository?.remoteHost ?? "github.com") },
                short: "sign in to \(service)")
        case .sshKey(let host):
            let name = host ?? repository?.remoteHost ?? "The server"
            return FailureHelp(
                message: "\(name) didn’t accept your SSH key. Add the key to your account there, or switch the remote to HTTPS and sign in with a token.",
                fixTitle: "How to Add an SSH Key",
                fix: { NSWorkspace.shared.open(URL(string: "https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account")!) },
                short: "SSH key not accepted")
        case .network(let host):
            return FailureHelp(
                message: "Kaern couldn’t reach \(host ?? "the server"). Check the connection or VPN, then try again.",
                fixTitle: repository == nil ? nil : "Try Again",
                fix: repository.map { model in { model.from("Command Log") { model.fetch() } } },
                short: "couldn’t reach \(host ?? "the server")")
        case .pushRejected(let remote):
            return FailureHelp(
                message: "\(remote ?? "The remote") has commits your branch doesn’t have yet. Pull them first, then push again.",
                fixTitle: repository == nil ? nil : "Pull",
                fix: repository.map { model in { model.pullWithItsSetting(from: "Command Log") } },
                short: "pull first")
        case .conflicts(let files):
            return FailureHelp(
                message: "It stopped on conflicts in \(Formatters.count(files, "file", "files")). Pick what to keep, then continue.",
                fixTitle: repository == nil ? nil : "Resolve Conflicts",
                fix: repository.map { model in { reveal(model); model.openConflicts() } },
                short: "conflicts to resolve")
        case .localChanges(let files):
            let list = files.count == 1 ? (files[0] as NSString).lastPathComponent : Formatters.count(files.count, "file", "files")
            return FailureHelp(
                message: "Uncommitted changes in \(list.isEmpty ? "some files" : list) are in the way. Stash or commit them, then try again.",
                fixTitle: repository == nil ? nil : "Stash Changes",
                fix: repository.map { model in { model.from("Command Log") { model.stash() } } },
                short: "local changes in the way")
        case .locked(let path):
            return FailureHelp(
                message: "Another git process is using \(repositoryName) (index.lock is there). If nothing else is running, delete the lock file and try again.",
                fixTitle: path == nil ? nil : "Show in Finder",
                fix: path.map { file in { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: file)]) } },
                short: "another git process is running")
        case .hook(let name):
            return FailureHelp(
                message: "The \(name) hook stopped it. Its output says what to fix.",
                fixTitle: repository?.hookFailure != nil ? "Open Hook Output" : nil,
                fix: repository.map { model in { reveal(model) } },
                short: "\(name) hook failed")
        case .remoteBranchGone(let branch):
            return FailureHelp(
                message: "\(branch ?? "The branch") isn’t on the remote anymore — someone deleted it there.",
                fixTitle: nil, fix: nil, short: "branch gone from the remote")
        }
    }

    /// One sentence for a failure where there's no repository yet (Clone).
    static func sentence(for failure: GitFailure?) -> String? {
        switch failure {
        case .signIn(let host)?:
            "\(serviceName(host)) turned down the sign-in, or the repository is private. Sign in, then clone again."
        case .sshKey(let host)?:
            "\(host ?? "The server") didn’t accept your SSH key. Add it to your account there, or clone with the HTTPS URL."
        case .network(let host)?:
            "Kaern couldn’t reach \(host ?? "the server"). Check the connection or VPN, then try again."
        default:
            nil
        }
    }

    /// "GitHub", "GitLab", or the host.
    static func serviceName(_ host: String?) -> String {
        guard let host = host?.lowercased() else { return "the server" }
        if host.contains("github") { return "GitHub" }
        if host.contains("gitlab") { return "GitLab" }
        if host.contains("bitbucket") { return "Bitbucket" }
        return host
    }

    /// Brings the repository's window and tab to the front.
    static func reveal(_ model: RepositoryModel) {
        let app = AppModel.shared
        for controller in app.windows {
            if let tab = controller.model.tabs.first(where: { $0.path == model.path }) {
                controller.model.activate(tab.id)
                controller.window?.makeKeyAndOrderFront(nil)
                NSApp.activate()
                return
            }
        }
    }
}
