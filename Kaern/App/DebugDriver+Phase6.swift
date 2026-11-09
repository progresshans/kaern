#if DEBUG
import AppKit
import KaernKit

/// Phase-6 debug commands: a failed history read, Pull with rebase over uncommitted changes and
/// the graph's scope.
extension DebugDriver {
    static let phase6Commands: Set<String> = [
        "graphScope", "showRemote", "retryHistory", "pullWith", "selectRef",
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
            break
        }
    }

    func phase6Dump(_ window: WindowModel?) -> [String: Any] {
        guard let window, let tab = window.activeTab else { return [:] }
        let repository = app.repository(for: tab.path)
        let result: [String: Any] = [
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
        ]
        return result
    }
}
#endif
