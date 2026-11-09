#if DEBUG
import AppKit
import KaernKit

/// Phase-6 debug commands: a failed history read, Pull with rebase over uncommitted changes,
/// the graph's scope and remote branch folders.
extension DebugDriver {
    static let phase6Commands: Set<String> = [
        "graphScope", "showRemote", "remoteOpen", "remoteFolder", "remoteMore", "sidebarFilter", "retryHistory", "pullWith", "selectRef",
        "ignoreSuggestion", "changeFolder", "changeMore", "fileList", "stageFolder",
    ]

    func phase6(_ command: String, _ args: [String]) {
        guard let window, let tab = window.activeTab else { return }
        let repository = app.repository(for: tab.path)
        let rest = args.joined(separator: " ")
        switch command {
        case "graphScope":
            // graphScope all|local|current — the Graph: menu.
            guard let scope = GraphScope(rawValue: rest) else { return }
            repository.from("Graph menu") { repository.setGraphScope(scope) }
        case "showRemote":
            // showRemote <origin/name> — a click on the remote branch in the sidebar.
            guard let ref = repository.refs.remoteBranch(named: rest) else { return }
            repository.showRemoteBranch(ref)
        case "remoteOpen":
            // remoteOpen <remote> on|off
            guard let remote = args.first else { return }
            if args.last == "off" { repository.sidebar.openRemotes.remove(remote) } else { repository.sidebar.openRemotes.insert(remote) }
        case "remoteFolder":
            // remoteFolder <remote>/<prefix> on|off
            guard let key = args.first else { return }
            if args.last == "off" { repository.sidebar.openRemoteFolders.remove(key) } else { repository.sidebar.openRemoteFolders.insert(key) }
        case "remoteMore":
            // remoteMore <remote>/<prefix> — the folder's "N more".
            repository.sidebar.remoteFolderExtra[rest, default: 0] += RemoteFolders.batch
        case "sidebarFilter":
            repository.sidebar.filter = rest
        case "retryHistory":
            repository.retryHistory()
        case "pullWith":
            // pullWith rebase|merge|ff — Pull with that choice, as from the toolbar.
            let strategy: GitRepository.PullStrategy = switch rest {
            case "rebase": .rebase
            case "ff": .fastForwardOnly
            default: .merge
            }
            repository.from("Toolbar") { repository.pull(strategy) }
        case "selectRef":
            // selectRef <name> — selects the commit a branch, remote branch or tag points at.
            if let ref = repository.refs.refs.first(where: { $0.name == rest }) { repository.reveal(ref.target) }
        default:
            phase6Marks(command, args, repository: repository)
        }
    }

    func phase6Dump(_ window: WindowModel?) -> [String: Any] {
        guard let window, let tab = window.activeTab else { return [:] }
        let repository = app.repository(for: tab.path)
        var result: [String: Any] = [
            "historyError": repository.historyError ?? "",
            "graphScope": repository.graphScope.rawValue,
            "graphScopeLabel": repository.graphScopeLabel,
            "showsGraphScope": repository.showsGraphScope,
            "showsBar": repository.hasBotCommits || repository.showsGraphScope,
            "drawnRemotes": repository.drawnRemoteNames,
            "pickedRemotes": repository.drawnRemoteBranches,
            "total": repository.totalCommitCount ?? -2,
            "commits": repository.commits.count,
            "subjects": repository.commits.prefix(60).map(\.subject),
            "hasMore": repository.hasMoreHistory,
            "selection": { if case .commit(let id) = repository.selection { return repository.commit(id)?.subject ?? id } else { return "wip" } }(),
            "toast": repository.toast?.message ?? "",
            "alert": repository.alert.map { "\($0.title) — \($0.message)" } ?? "",
            "undo": repository.undoSteps.map(\.label),
            "redo": repository.redoSteps.map(\.label),
            "staged": repository.status.entries.filter(\.hasStagedChanges).map(\.path).sorted(),
            "unstaged": repository.status.entries.filter(\.hasUnstagedChanges).map(\.path).sorted(),
            "operation": repository.operation.map { "\($0.kind)" } ?? "",
            "screen": repository.screen.map { "\($0)" } ?? "",
            "operationFinish": repository.operationFinish.map { "\($0.title) \($0.detail)" } ?? "",
            "stashes": repository.stashes.map(\.message),
            "head": repository.status.headID.map { String($0.prefix(7)) } ?? "",
            "activity": repository.activity?.statusText ?? "",
            "sidebarRemote": sidebarRemoteLines(repository),
            "filter": repository.sidebar.filter,
        ]
        result.merge(phase6MarksDump(repository)) { _, new in new }
        return result
    }

    /// The Remote section as the sidebar lists it: "origin ▾", "  release 41 ▸", "    2026.11", "    35 more".
    private func sidebarRemoteLines(_ repository: RepositoryModel) -> [String] {
        let filter = repository.sidebar.filter.trimmingCharacters(in: .whitespaces)
        func matches(_ text: String) -> Bool { filter.isEmpty || text.localizedCaseInsensitiveContains(filter) }
        var lines: [String] = []
        let names = Array(Set(repository.remotes.map(\.name) + repository.refs.remoteNames)).sorted()
        for remote in names {
            let all = repository.refs.remoteBranches.filter { $0.remoteName == remote }
            let members = filter.isEmpty ? all : all.filter { matches($0.name) }
            let open = !filter.isEmpty || repository.sidebar.openRemotes.contains(remote)
            guard filter.isEmpty || !members.isEmpty else { continue }
            lines.append("\(remote) \(open ? "▾" : "▸")")
            guard open else { continue }
            let groups = RemoteFolders(members)
            let totals = RemoteFolders.counts(all)
            for folder in groups.folders {
                let key = "\(remote)/\(folder.name)"
                let total = totals[folder.name] ?? folder.branches.count
                let folderOpen = !filter.isEmpty || repository.sidebar.openRemoteFolders.contains(key)
                let count = filter.isEmpty || folder.branches.count == total ? "\(total)" : "\(folder.branches.count) of \(total)"
                lines.append("  \(folder.name) \(count) \(folderOpen ? "▾" : "▸")")
                guard folderOpen else { continue }
                let limit = RemoteFolders.firstNames + (repository.sidebar.remoteFolderExtra[key] ?? 0)
                for ref in folder.branches.prefix(limit) { lines.append("    " + ref.branchName.dropFirst(folder.name.count + 1)) }
                if folder.branches.count > limit { lines.append("    \(folder.branches.count - limit) more") }
            }
            for ref in groups.loose { lines.append("  " + ref.branchName) }
        }
        return lines
    }
}
#endif
