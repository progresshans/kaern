import AppKit
import KaernKit

// MARK: - Confirmations

extension RepositoryModel {
    struct ConfirmationText {
        var title: String
        var message: String
        var action: String
        var isDestructive: Bool
    }

    func text(for confirmation: Confirmation) -> ConfirmationText {
        switch confirmation {
        case .forcePush(let branch):
            ConfirmationText(
                title: String(localized: "Force push “\(branch)”?"),
                message: String(localized: "This replaces the branch on the remote with your local history. Kaern uses --force-with-lease, so it stops if someone else pushed in the meantime."),
                action: String(localized: "Force Push"),
                isDestructive: true)
        case .abortOperation(let kind):
            ConfirmationText(
                title: {
                    switch kind {
                    case .merge: String(localized: "Abort the merge?")
                    case .rebase: String(localized: "Abort the rebase?")
                    case .cherryPick: String(localized: "Abort the cherry-pick?")
                    case .revert: String(localized: "Abort the revert?")
                    }
                }(),
                message: String(localized: "The conflicts you already resolved are thrown away and everything goes back to how it was before."),
                action: String(localized: "Abort"),
                isDestructive: true)
        case .deleteRemoteBranch(let ref):
            ConfirmationText(
                title: String(localized: "Delete “\(ref.branchName)” from \(ref.remoteName ?? "the remote")?"),
                message: String(localized: "The branch is removed from the remote for everyone. Kaern can't undo this."),
                action: String(localized: "Delete from Remote"),
                isDestructive: true)
        case .forceDeleteBranch(let ref):
            ConfirmationText(
                title: String(localized: "“\(ref.name)” isn't merged. Delete it anyway?"),
                message: String(localized: "Its commits aren't on any other branch. You can bring the branch back with ⌘Z."),
                action: String(localized: "Delete Branch"),
                isDestructive: true)
        case .resetHard(let commit, let leaving):
            ConfirmationText(
                title: String(localized: "Reset “\(currentBranchTitle)” to \(commit.shortID)?"),
                message: resetHardMessage(leaving: leaving),
                action: String(localized: "Reset"),
                isDestructive: true)
        case .useSSH(let remote, let url, _):
            ConfirmationText(
                title: String(localized: "Switch \(remote) to SSH?"),
                message: String(localized: "\(remote) will use \(url). Your SSH key needs to be added to your account there. ⌘Z switches back."),
                action: String(localized: "Switch to SSH"),
                isDestructive: false)
        }
    }

    /// "2 commits will leave this branch and 13 uncommitted changes will be put aside. …"
    private func resetHardMessage(leaving: Int) -> String {
        let changes = status.entries.count { !$0.isUntracked }
        var parts: [String] = []
        if leaving > 0 {
            parts.append(leaving == 1
                ? String(localized: "1 commit will leave this branch")
                : String(localized: "\(leaving) commits will leave this branch"))
        }
        if changes > 0 {
            parts.append(changes == 1
                ? String(localized: "1 uncommitted change will be put aside")
                : String(localized: "\(changes) uncommitted changes will be put aside"))
        }
        let what = parts.isEmpty ? String(localized: "The branch moves to this commit") : parts.joined(separator: String(localized: " and "))
        return what + ". " + (changes > 0
            ? String(localized: "Kaern stashes them first, so ⌘Z brings everything back.")
            : String(localized: "⌘Z brings the branch back."))
    }

    func performConfirmed(_ confirmation: Confirmation) async {
        switch confirmation {
        case .forcePush: await forcePush()
        case .abortOperation: await abortOperation()
        case .deleteRemoteBranch(let ref): await deleteRemoteBranch(ref)
        case .forceDeleteBranch(let ref): await deleteBranch(ref, force: true)
        case .resetHard(let commit, _): await reset(to: commit, mode: .hard)
        case .useSSH(let remote, let url, let retry): await switchToSSH(remote: remote, url: url, retry: retry)
        }
    }

    // MARK: Finder and editors

    func fileURL(for path: String) -> URL? {
        repository?.root.appending(path: path)
    }

    func revealInFinder(_ path: String) {
        guard let url = fileURL(for: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openInEditor(_ path: String) {
        guard let url = fileURL(for: path) else { return }
        let editor = Preferences.editor
        if let application = editor.applicationURL {
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func openRepositoryInFinder() {
        guard let root = repository?.root else { return }
        NSWorkspace.shared.open(root)
    }

    func openInTerminal() {
        guard let root = repository?.root,
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([root], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

enum Pasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
