import Foundation

/// Which branches the history graph shows.
public enum HistoryScope: Sendable, Hashable {
    /// Every branch, remote branch and tag except these refs (full names such as
    /// `refs/heads/feature/x`, or `refs/remotes/origin/*` for all of a remote's branches).
    case all(hidden: [String])
    /// One branch alone (a full ref name), without HEAD unless that branch is checked out.
    case only(String)

    public var isFiltered: Bool {
        switch self {
        case .all(let hidden): !hidden.isEmpty
        case .only: true
        }
    }
}
