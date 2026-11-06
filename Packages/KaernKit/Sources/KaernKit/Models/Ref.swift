import Foundation

public enum RefKind: Sendable, Hashable {
    case localBranch
    case remoteBranch
    case tag
}

/// A branch, remote-tracking branch or tag.
public struct Ref: Sendable, Hashable, Identifiable {
    /// `refs/heads/main`, `refs/remotes/origin/main`, `refs/tags/v1.0`
    public var fullName: String
    public var kind: RefKind
    /// The commit this ref points at (annotated tags are peeled).
    public var target: String
    /// For local branches: the upstream's short name, e.g. `origin/main`.
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    /// The upstream is configured but no longer exists on the remote.
    public var upstreamGone: Bool
    /// `refs/remotes/origin/HEAD` and similar symbolic refs.
    public var isSymbolic: Bool
    /// The branch HEAD points at.
    public var isHead: Bool

    public init(
        fullName: String,
        kind: RefKind,
        target: String,
        upstream: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        upstreamGone: Bool = false,
        isSymbolic: Bool = false,
        isHead: Bool = false
    ) {
        self.fullName = fullName
        self.kind = kind
        self.target = target
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.upstreamGone = upstreamGone
        self.isSymbolic = isSymbolic
        self.isHead = isHead
    }

    public var id: String { fullName }

    /// `main`, `origin/main`, `v1.0`
    public var name: String {
        switch kind {
        case .localBranch: String(fullName.dropFirst("refs/heads/".count))
        case .remoteBranch: String(fullName.dropFirst("refs/remotes/".count))
        case .tag: String(fullName.dropFirst("refs/tags/".count))
        }
    }

    /// For remote-tracking branches, the remote's name (`origin`).
    public var remoteName: String? {
        guard kind == .remoteBranch else { return nil }
        return name.split(separator: "/", maxSplits: 1).first.map(String.init)
    }

    /// The branch name without the remote prefix (`origin/feature/x` → `feature/x`).
    public var branchName: String {
        guard kind == .remoteBranch else { return name }
        let parts = name.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : name
    }
}

/// What HEAD points at.
public enum HeadState: Sendable, Hashable {
    /// On a branch that has at least one commit.
    case branch(String)
    /// Detached at a commit.
    case detached(String)
    /// On a branch with no commits yet (fresh repository).
    case unborn(String)

    public var branchName: String? {
        switch self {
        case .branch(let name), .unborn(let name): name
        case .detached: nil
        }
    }
}

/// All refs of a repository at one moment, indexed for the history view.
public struct RefSnapshot: Sendable, Hashable {
    public var refs: [Ref]
    public private(set) var byTarget: [String: [Ref]]

    public init(refs: [Ref]) {
        self.refs = refs
        var byTarget: [String: [Ref]] = [:]
        for ref in refs where !ref.isSymbolic {
            byTarget[ref.target, default: []].append(ref)
        }
        self.byTarget = byTarget
    }

    public static let empty = RefSnapshot(refs: [])

    public var localBranches: [Ref] { refs.filter { $0.kind == .localBranch } }
    public var remoteBranches: [Ref] { refs.filter { $0.kind == .remoteBranch && !$0.isSymbolic } }
    public var tags: [Ref] { refs.filter { $0.kind == .tag } }
    public var headBranch: Ref? { refs.first { $0.isHead } }

    public var remoteNames: [String] {
        var seen: [String] = []
        for ref in remoteBranches {
            if let remote = ref.remoteName, !seen.contains(remote) {
                seen.append(remote)
            }
        }
        return seen
    }

    public func refs(at commit: String) -> [Ref] { byTarget[commit] ?? [] }

    public func localBranch(named name: String) -> Ref? {
        refs.first { $0.kind == .localBranch && $0.name == name }
    }

    public func remoteBranch(named name: String) -> Ref? {
        refs.first { $0.kind == .remoteBranch && $0.name == name }
    }
}
