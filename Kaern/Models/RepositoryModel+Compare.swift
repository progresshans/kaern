import Foundation
import KaernKit

// MARK: - Comparing a branch

extension RepositoryModel {
    /// Compare with “main” (the sidebar's branch menu): the branch's tip against HEAD. Commits
    /// further back than the loaded history are looked up first, so the inspector can name them.
    func compare(ref: Ref) async {
        guard let head = status.headID, let repository, ref.target != head else { return }
        for id in [ref.target, head] where commit(withID: id) == nil {
            if let details = try? await repository.commitDetails(id) {
                knownCommits[id] = details.commit
            }
        }
        closeStash()
        closePullRequests()
        closeFileHistory()
        compare(ref.target, head)
    }

    /// The repository's main remote is on GitHub (or a GitHub Enterprise host with an account).
    var isOnGitHub: Bool {
        guard let remote = primaryRemote else { return false }
        return remote.host.lowercased() == "github.com" || AppModel.shared.account(forHost: remote.host)?.kind == .github
    }

    /// "Compare with c92aa17" in the history's menu: the clicked commit against the selected one.
    var comparableSelection: Commit? {
        guard comparisonBase == nil else { return nil }
        return selectedCommit
    }
}
