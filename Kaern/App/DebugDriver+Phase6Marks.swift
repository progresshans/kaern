#if DEBUG
import AppKit
import KaernKit

/// Phase-6 debug commands for the working copy and ScreenMarks: the big changes list and its
/// .gitignore suggestion, signatures and worktrees.
extension DebugDriver {
    func phase6Marks(_ command: String, _ args: [String], repository: RepositoryModel) {
        let rest = args.joined(separator: " ")
        switch command {
        case "ignoreSuggestion":
            // ignoreSuggestion add|notNow — the card's buttons.
            if rest == "add" { repository.from("Ignore suggestion") { repository.ignoreSuggestedFolder() } } else { repository.dismissIgnoreSuggestion() }
        case "changeFolder":
            // changeFolder <folder/> on|off — opens or closes a folder in the big changes list.
            guard let folder = args.first else { return }
            if args.last == "off" { repository.openChangeFolders.remove(folder) } else { repository.openChangeFolders.insert(folder) }
        case "changeMore":
            repository.changeFolderExtra[rest, default: 0] += BigChangesList.batch
        case "fileList":
            // fileList path|tree — the panel's Path / Tree.
            UserDefaults.kaern.set(rest == "tree", forKey: DiffPreferences.treeKey)
        case "stageFolder":
            // stageFolder <folder/> — the folder row's checkbox.
            guard let folder = repository.bigChanges?.folders.first(where: { $0.path == rest }) else { return }
            repository.stageFolder(folder, staged: folder.unstagedCount == 0)
        default:
            break
        }
    }

    func phase6MarksDump(_ repository: RepositoryModel) -> [String: Any] {
        var result: [String: Any] = [:]
        if let big = repository.bigChanges {
            result["big"] = [
                "total": big.total, "staged": big.stagedCount, "unstaged": big.unstagedCount,
                "root": big.rootEntries.map(\.path),
                "folders": big.folders.map { "\($0.path) \($0.entries.count) \($0.stagedCount)" },
                "suggestion": big.suggestion.map { "\($0.folder) \($0.count)" } ?? "",
                "shownSuggestion": repository.ignoreSuggestion.map { "\($0.folder) \($0.count)" } ?? "",
                "open": repository.openChangeFolders.sorted(),
                // Line counts of the first files of each open folder: "path +a −d".
                "openStats": big.folders.filter { repository.openChangeFolders.contains($0.path) }.flatMap { $0.entries.prefix(3) }.map { entry in
                    let stat = repository.lineStats.unstaged[entry.path]
                    return "\(entry.path) +\(stat?.additions ?? -1) −\(stat?.deletions ?? -1)"
                },
                "lineStats": repository.lineStats.unstaged.count,
            ] as [String: Any]
        } else {
            result["big"] = NSNull()
        }
        result["changeCount"] = repository.status.entries.count
        result["gitignore"] = repository.repository.flatMap { FileManager.default.contents(atPath: $0.root.appending(path: ".gitignore").path(percentEncoded: false)) }
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        return result
    }
}
#endif
