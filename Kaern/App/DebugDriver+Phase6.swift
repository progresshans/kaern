#if DEBUG
import AppKit
import KaernKit

/// Phase-6 debug commands: a failed history read, Pull with rebase over uncommitted changes.
extension DebugDriver {
    static let phase6Commands: Set<String> = [
        "retryHistory", "pullWith",
    ]

    func phase6(_ command: String, _ args: [String]) {
        guard let window, let tab = window.activeTab else { return }
        let repository = app.repository(for: tab.path)
        switch command {
        case "retryHistory":
            repository.retryHistory()
        case "pullWith":
            // pullWith rebase|merge|ff — Pull with that choice, as from the toolbar.
            let strategy: GitRepository.PullStrategy = switch args.first {
            case "rebase": .rebase
            case "ff": .fastForwardOnly
            default: .merge
            }
            repository.from("Toolbar") { repository.pull(strategy) }
        default:
            break
        }
    }

    func phase6Dump(_ window: WindowModel?) -> [String: Any] {
        guard let window, let tab = window.activeTab else { return [:] }
        let repository = app.repository(for: tab.path)
        return [
            "historyError": repository.historyError ?? "",
            "commits": repository.commits.count,
            "subjects": repository.commits.prefix(60).map(\.subject),
            "hasMore": repository.hasMoreHistory,
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
    }
}
#endif
