import Foundation
import KaernKit

/// What the graph draws (ScreenBigRepo's "Graph:" chip).
enum GraphScope: String, CaseIterable {
    /// Every branch, remote branch and tag.
    case all
    /// Local branches with their upstreams and the remote's default branch. Remote-only branches
    /// come in when they're picked in the sidebar.
    case local
    /// The current branch and what it contains.
    case current
}

extension RepositoryModel {
    /// From this many remote branches a repository opens with Graph: Local + main, and the bar
    /// over the graph offers the choice.
    static let manyRemoteBranches = 500

    var hasManyRemoteBranches: Bool { refs.remoteBranches.count >= Self.manyRemoteBranches }

    /// The bar over the graph shows the Graph: chip.
    var showsGraphScope: Bool { hasManyRemoteBranches || graphScope != .all }

    /// The chip's label: "Local + main", "Current branch".
    var graphScopeLabel: String {
        switch graphScope {
        case .all: "All branches"
        case .local: "Local + " + (mainRemoteBranch.map { String($0.split(separator: "/", maxSplits: 1).last ?? Substring($0)) } ?? "main")
        case .current: "Current branch"
        }
    }

    /// What `git log` reads for the graph (also the search and the commit count).
    var historyScope: HistoryScope {
        switch graphScope {
        case .all: .all(hidden: [])
        case .local: .local(remoteBranches: drawnRemoteNames)
        case .current: .current
        }
    }

    /// The remote branches Local + main draws: the remote's default branch, the upstreams of
    /// the local branches, and the ones picked in the sidebar.
    var drawnRemoteNames: [String] {
        var names: [String] = []
        if let main = mainRemoteBranch { names.append(main) }
        for ref in refs.localBranches {
            if let upstream = ref.upstream, !ref.upstreamGone { names.append(upstream) }
        }
        names += drawnRemoteBranches
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// The remote's default branch: what `origin/HEAD` points at, else origin/main or origin/master.
    var mainRemoteBranch: String? {
        let remote = defaultRemote ?? "origin"
        if let head = refs.refs.first(where: { $0.fullName == "refs/remotes/\(remote)/HEAD" }),
           let target = head.symbolicTarget, target.hasPrefix("refs/remotes/") {
            return String(target.dropFirst("refs/remotes/".count))
        }
        for name in ["main", "master"] where refs.remoteBranch(named: "\(remote)/\(name)") != nil {
            return "\(remote)/\(name)"
        }
        return nil
    }

    /// Whether the graph draws `ref`'s history.
    func draws(_ ref: Ref) -> Bool {
        switch graphScope {
        case .all: true
        case .local: ref.kind == .localBranch || (ref.kind == .remoteBranch && drawnRemoteNames.contains(ref.name))
        case .current: isOnCurrentBranch(ref.target)
        }
    }

    /// On the first load: the scope kept for this repository, else Local + main when it has
    /// many remote branches.
    func decideGraphScope() {
        guard !graphScopeDecided else { return }
        graphScopeDecided = true
        let kept = (UserDefaults.kaern.dictionary(forKey: SettingsKey.graphScopes) as? [String: String])?[path]
        graphScope = kept.flatMap(GraphScope.init(rawValue:)) ?? (hasManyRemoteBranches ? .local : .all)
    }

    /// The Graph: menu. History is read again for the new scope. Picking Local + main again
    /// lets go of the remote branches picked meanwhile.
    func setGraphScope(_ scope: GraphScope) {
        let changed = scope != graphScope || !drawnRemoteBranches.isEmpty
        graphScope = scope
        graphScopeDecided = true
        drawnRemoteBranches = []
        var kept = UserDefaults.kaern.dictionary(forKey: SettingsKey.graphScopes) as? [String: String] ?? [:]
        kept[path] = scope.rawValue
        UserDefaults.kaern.set(kept, forKey: SettingsKey.graphScopes)
        if changed { reloadHistory(trigger: "Graph scope") }
    }

    /// A remote branch picked in the sidebar: drawn when the graph leaves it out, then selected.
    func showRemoteBranch(_ ref: Ref) {
        if graphScope == .local, !drawnRemoteNames.contains(ref.name) {
            drawnRemoteBranches.append(ref.name)
            selectAfterReload = ref.target
            reloadHistory(trigger: "Sidebar › \(ref.name)")
            showToast("\(ref.name) is now drawn in the graph")
            return
        }
        if graphScope == .current, !isOnCurrentBranch(ref.target) {
            showToast("The graph shows \(currentBranch ?? "the current branch") only · Graph › Local branches and main draws \(ref.name)")
            return
        }
        reveal(ref.target)
    }

    /// Selects a commit and scrolls to it, reading older history first when it's further back.
    func reveal(_ id: String) {
        if commit(id) != nil {
            clearPicks()
            selection = .commit(id)
            scrollRequest = ScrollRequest(id: id)
            return
        }
        Task {
            guard await loadHistory(until: [id]) else { return }
            clearPicks()
            selection = .commit(id)
            scrollRequest = ScrollRequest(id: id)
        }
    }
}
