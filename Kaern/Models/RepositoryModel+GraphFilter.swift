import Foundation
import KaernKit

// MARK: - Hiding branches in the graph

extension RepositoryModel {
    func isHiddenInGraph(_ ref: Ref) -> Bool {
        if hiddenRefs.contains(ref.fullName) { return true }
        if ref.kind == .remoteBranch, let remote = ref.remoteName {
            return hiddenRefs.contains(Self.remotePattern(remote))
        }
        return false
    }

    func isRemoteHiddenInGraph(_ remote: String) -> Bool {
        hiddenRefs.contains(Self.remotePattern(remote))
    }

    /// Hide in Graph: commits only that branch has drop out of the history (ones other branches
    /// share stay). The checked-out branch always shows.
    func setHiddenInGraph(_ ref: Ref, _ hidden: Bool) {
        if hidden {
            hiddenRefs.insert(ref.fullName)
            if soloRef == ref.fullName { soloRef = nil }
        } else {
            hiddenRefs.remove(ref.fullName)
            if ref.kind == .remoteBranch, let remote = ref.remoteName {
                hiddenRefs.remove(Self.remotePattern(remote))
            }
        }
        Task { await graphFiltersChanged() }
    }

    /// Every branch of a remote at once ("Hide Branches of “origin” in Graph").
    func setRemoteHiddenInGraph(_ remote: String, _ hidden: Bool) {
        let pattern = Self.remotePattern(remote)
        // The remote's own branches are covered by the pattern either way.
        hiddenRefs = hiddenRefs.filter { !$0.hasPrefix("refs/remotes/\(remote)/") }
        if hidden { hiddenRefs.insert(pattern) }
        if hidden, let soloRef, soloRef.hasPrefix("refs/remotes/\(remote)/") { self.soloRef = nil }
        Task { await graphFiltersChanged() }
    }

    /// Show Only in Graph: the history shows that branch alone.
    func showOnlyInGraph(_ ref: Ref) {
        soloRef = ref.fullName
        Task { await graphFiltersChanged() }
    }

    func showAllBranchesInGraph() {
        guard !hiddenRefs.isEmpty || soloRef != nil else { return }
        hiddenRefs = []
        soloRef = nil
        Task { await graphFiltersChanged() }
    }

    /// "feature/x", "origin/feature/x", or "origin's branches" for a whole remote.
    static func graphFilterName(_ fullName: String) -> String {
        if fullName.hasPrefix("refs/remotes/"), fullName.hasSuffix("/*") {
            let remote = fullName.dropFirst("refs/remotes/".count).dropLast(2)
            return String(localized: "\(String(remote))’s branches")
        }
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where fullName.hasPrefix(prefix) {
            return String(fullName.dropFirst(prefix.count))
        }
        return fullName
    }

    private static func remotePattern(_ remote: String) -> String {
        "refs/remotes/\(remote)/*"
    }
}
