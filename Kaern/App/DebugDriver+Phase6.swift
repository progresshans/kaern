#if DEBUG
import AppKit
import KaernKit

/// Phase-6 debug commands: a failed history read.
extension DebugDriver {
    static let phase6Commands: Set<String> = [
        "retryHistory",
    ]

    func phase6(_ command: String, _ args: [String]) {
        guard let window, let tab = window.activeTab else { return }
        let repository = app.repository(for: tab.path)
        switch command {
        case "retryHistory":
            repository.retryHistory()
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
        ]
    }
}
#endif
