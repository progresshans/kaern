import Foundation

/// Which branches the history graph shows.
public enum HistoryScope: Sendable, Hashable {
    /// Every branch, remote branch and tag except these refs (full names such as
    /// `refs/heads/feature/x`, or `refs/remotes/origin/*` for all of a remote's branches).
    case all(hidden: [String])
    /// One branch alone (a full ref name), without HEAD unless that branch is checked out.
    case only(String)
    /// The local branches and these remote branches (short names such as `origin/main`): the
    /// remote's default branch and the ones picked to be drawn (Graph: Local + main, for
    /// repositories with many remote branches). Tags show as labels on the commits drawn, but
    /// don't bring in history of their own.
    case local(remoteBranches: [String])
    /// HEAD and what it contains (Graph: Current branch only).
    case current

    public var isFiltered: Bool {
        switch self {
        case .all(let hidden): !hidden.isEmpty
        case .only, .local, .current: true
        }
    }
}
