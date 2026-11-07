#if DEBUG
import AppKit
import KaernKit

/// Phase-4 debug commands: Settings, conflicts, stashes, sheets, interactive rebase, file
/// history and blame, the Activity popover and auto-fetch.
extension DebugDriver {
    static let phase4Commands: Set<String> = [
        "settings", "setting", "fakeAccount",
        "conflicts", "conflictShow", "conflictPick", "conflictKeep", "conflictEdit", "markResolved", "continueOp", "skipOp", "abortOp",
        "undoPop", "openStash", "closeScreen", "stashBranch", "renameStash", "sheet", "sheetName", "sheetSubmit", "sheetClose",
        "irAction", "irMove", "irStart", "squash", "type",
        "history", "blame", "historySelect", "blameFocus", "blameBefore", "exploreMode", "blameOption", "showInHistory",
    ]

    func phase4(_ command: String, _ args: [String]) {
        switch command {
        case "settings":
            // settings <General|Accounts|Git|Diff|Advanced> | settings close
            if args.first == "close" {
                SettingsWindowController.shared.window?.close()
            } else {
                let pane = SettingsWindowController.Pane(rawValue: args.first ?? "General") ?? .general
                SettingsWindowController.shared.show(pane)
            }
            return
        case "setting":
            // setting <key> <value> — in this test instance's own settings file.
            guard args.count >= 2 else { return }
            let value = args.dropFirst().joined(separator: " ")
            if let number = Int(value) {
                UserDefaults.kaern.set(number, forKey: args[0])
            } else if value == "YES" || value == "NO" {
                UserDefaults.kaern.set(value == "YES", forKey: args[0])
            } else if value == "-" {
                UserDefaults.kaern.removeObject(forKey: args[0])
            } else {
                UserDefaults.kaern.set(value, forKey: args[0])
            }
            NotificationCenter.default.post(name: .kaernSettingsChanged, object: args[0])
            if args[0] == SettingsKey.theme { AppSettings.applyTheme() }
            return
        case "type":
            // type <text…> — key events for each character, to the focused field of the window.
            typeText(args.joined(separator: " "))
            return
        case "fakeAccount":
            // fakeAccount <login> <host> [Full Name] — shows an account without a token (Accounts pane).
            guard args.count >= 2 else { return }
            var list = HostingAccount.all
            list.append(HostingAccount(kind: args[1].contains("gitlab") ? .gitlab : .github, host: args[1], login: args[0],
                                       name: args.count > 2 ? args.dropFirst(2).joined(separator: " ") : nil, userID: 4_120_731,
                                       email: nil))
            HostingAccount.all = list
            return
        default:
            break
        }
        guard let window, let tab = window.activeTab else { return }
        let repository = app.repository(for: tab.path)
        func commitID(_ text: String?) -> String? {
            guard let text, let index = Int(text), repository.commits.indices.contains(index) else { return nil }
            return repository.commits[index].id
        }
        let rest = args.joined(separator: " ")
        switch command {
        case "conflicts":
            repository.openConflicts(path: args.first)
        case "conflictShow":
            repository.showConflict(rest)
        case "conflictPick":
            // conflictPick <block> ours|theirs|both
            if args.count == 2, let index = Int(args[0]) { repository.pickConflict(index, resolution(args[1])) }
        case "conflictKeep":
            repository.keepAll(resolution(args.first ?? "ours"))
        case "conflictEdit":
            repository.toggleDirectEdit()
        case "markResolved":
            repository.from("Debug") { repository.markResolved() }
        case "continueOp":
            repository.from("Debug") { repository.continueOperation() }
        case "skipOp":
            repository.from("Debug") { repository.skipOperationCommit() }
        case "abortOp":
            repository.from("Debug") { repository.abortOperation() }
        case "undoPop":
            repository.from("Debug") { repository.takeBackStashConflict() }
        case "openStash":
            if let index = args.first.flatMap(Int.init), repository.stashes.indices.contains(index) {
                repository.openStash(repository.stashes[index].id)
            }
        case "closeScreen":
            repository.screen = nil
        case "stashBranch":
            // stashBranch <n> <name>
            if args.count == 2, let index = Int(args[0]), repository.stashes.indices.contains(index) {
                repository.from("Debug") { repository.createBranch(args[1], from: repository.stashes[index]) }
            }
        case "renameStash":
            // renameStash <n> <title…>
            if args.count >= 2, let index = Int(args[0]), repository.stashes.indices.contains(index) {
                repository.from("Debug") { repository.renameStash(repository.stashes[index], to: args.dropFirst().joined(separator: " ")) }
            }
        case "sheet":
            // sheet newBranch [n] | rename <branch> | tag <n> | merge | rebase | delete | settings | ir <n> | fromStash <n> | renameStash <n>
            switch args.first {
            case "newBranch": repository.askCreateBranch(at: commitID(args.count > 1 ? args[1] : nil))
            case "rename": repository.askRename(branch: args.count > 1 ? args[1] : repository.status.branch ?? "")
            case "tag": if let id = commitID(args.count > 1 ? args[1] : "0") { repository.askCreateTag(at: id) }
            case "merge": repository.askMerge()
            case "rebase": repository.askRebase()
            case "delete": repository.askDeleteBranch(args.count > 1 ? args[1] : nil)
            case "settings": repository.sheet = .repositorySettings
            case "ir": if let id = commitID(args.count > 1 ? args[1] : nil) { repository.askInteractiveRebase(onto: id) }
            case "fromStash": if let index = args.count > 1 ? Int(args[1]) : nil, repository.stashes.indices.contains(index) { repository.askBranchFromStash(repository.stashes[index]) }
            case "renameStash": if let index = args.count > 1 ? Int(args[1]) : nil, repository.stashes.indices.contains(index) { repository.sheet = .renameStash(repository.stashes[index]) }
            default: break
            }
        case "sheetClose":
            repository.sheet = nil
        case "irAction":
            // irAction <row> <pick|reword|edit|squash|fixup|drop> [new message…]
            if args.count >= 2, let row = Int(args[0]), let action = RebaseStep.Action(rawValue: args[1]) {
                repository.updateRebaseDraft { draft in
                    guard draft.steps.indices.contains(row) else { return }
                    draft.steps[row].action = action
                    if action == .reword { draft.steps[row].message = args.count > 2 ? args.dropFirst(2).joined(separator: " ") : draft.steps[row].commit.subject }
                }
            }
        case "irMove":
            // irMove <row> <offset>
            if args.count == 2, let row = Int(args[0]), let offset = Int(args[1]) {
                repository.updateRebaseDraft { draft in
                    let target = row + offset
                    guard draft.steps.indices.contains(row), draft.steps.indices.contains(target) else { return }
                    draft.steps.swapAt(row, target)
                }
            }
        case "irStart":
            if case .interactiveRebase(let draft) = repository.sheet { repository.from("Debug") { repository.startInteractiveRebase(draft) } }
        case "history":
            // history <path> [commit row]
            if let path = args.first { repository.showFileHistory(path, at: commitID(args.count > 1 ? args[1] : nil)) }
        case "blame":
            // blame <path> [commit row]
            if let path = args.first { repository.showBlame(path, at: commitID(args.count > 1 ? args[1] : nil)) }
        case "historySelect":
            // historySelect <entry index>
            if let index = args.first.flatMap(Int.init), let entries = repository.fileHistory?.entries, entries.indices.contains(index) {
                repository.selectHistoryEntry(entries[index].commit.id)
            }
        case "blameFocus":
            // blameFocus <chunk index>
            if let index = args.first.flatMap(Int.init), let blame = repository.currentBlame, blame.chunks.indices.contains(index) {
                repository.focusBlame(blame.chunks[index].commitID, chunk: blame.chunks[index].id)
            }
        case "blameBefore":
            if let focused = repository.explore?.focused { repository.blameBefore(focused) }
        case "exploreMode":
            repository.setExploreMode(args.first == "blame" ? .blame : .history)
        case "blameOption":
            // blameOption ws|moves on|off
            if args.count == 2 {
                if args[0] == "ws" { repository.setBlameOptions(ignoreWhitespace: args[1] == "on") } else { repository.setBlameOptions(detectMoves: args[1] == "on") }
            }
        case "showInHistory":
            if let id = repository.exploreCommitID { repository.showCommitInHistory(id) }
        case "squash":
            // squash <n> <n>…
            let ids = args.compactMap { commitID($0) }
            repository.from("Debug") { repository.askSquash(ids) }
        default:
            break
        }
    }

    private func typeText(_ text: String) {
        guard let nsWindow = controller?.window else { return }
        for character in text {
            let characters = String(character)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: nsWindow.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: character == " " ? 49 : 0
                ) else { continue }
                nsWindow.sendEvent(event)
            }
        }
    }

    private func resolution(_ text: String) -> ConflictDocument.Resolution {
        switch text {
        case "theirs": .theirs
        case "both": .both
        default: .ours
        }
    }

    /// What `dump` adds for phase 4.
    func phase4Dump(_ repository: RepositoryModel) -> [String: Any] {
        var result: [String: Any] = [
            "screen": repository.screen.map { "\($0)" } ?? "",
            "sheet": repository.sheet?.id ?? "",
            "operationFinish": repository.operationFinish.map { $0.title + " " + $0.detail } ?? "",
            "conflicted": repository.conflictedPaths,
            "mergedAutomatically": repository.mergedAutomatically.map(\.path),
            "stashConflict": repository.stashConflict.map { ["stash": $0.stash.reference, "files": $0.conflicted] as [String: Any] } ?? NSNull(),
            "stashDetails": repository.stashDetails.map { ["stash": $0.stash.reference, "files": $0.files.map(\.path), "base": String($0.baseID.prefix(7)),
                                                         "branch": $0.branch ?? "", "untracked": Array($0.untrackedPaths)] as [String: Any] } ?? NSNull(),
            "runsHooks": repository.runsHooks,
            "pullOverride": repository.pullOverride?.rawValue ?? "",
            "recentBranches": repository.recentBranches,
        ]
        if let session = repository.conflictSession {
            let names = repository.conflictSides
            result["conflictSession"] = [
                "files": session.files, "path": session.path ?? "", "blocks": session.original?.conflictCount ?? -1,
                "open": session.openBlocks, "choices": session.choices.map { "\($0.key):\($0.value)" }.sorted(),
                "editing": session.editingText != nil, "message": session.message,
                "ours": names.oursTitle, "theirs": names.theirsTitle,
            ] as [String: Any]
        }
        if let state = repository.explore {
            let blame = repository.currentBlame
            result["explore"] = [
                "path": state.path, "mode": "\(state.mode)", "selected": state.selected.map { String($0.prefix(7)) } ?? "",
                "blameAt": state.blameAt.map { String($0.prefix(7)) } ?? "", "focused": state.focused.map { String($0.prefix(7)) } ?? "",
                "history": (repository.fileHistory?.entries ?? []).map { "\($0.commit.shortID) \($0.path)\($0.oldPath.map { " <- " + $0 } ?? "")" },
                "diffHunks": repository.historyReviewFile?.hunks.count ?? -1,
                "chunks": blame.map { blame in blame.chunks.map { "\(String($0.commitID.prefix(7))):\($0.lines.count)" } } ?? [],
                "panel": repository.exploreCommit.map { String($0.id.prefix(7)) } ?? "",
                "summary": repository.exploreSummary ?? "",
            ] as [String: Any]
        }
        if case .interactiveRebase(let draft) = repository.sheet {
            result["rebase"] = [
                "base": String(draft.base.prefix(7)), "steps": draft.steps.map { "\($0.action.rawValue) \($0.commit.shortID) \($0.commit.subject)" },
                "pushed": draft.pushed.map { String($0.prefix(7)) }.sorted(), "result": draft.resultCount, "canStart": draft.canStart,
                "rewritesPushed": draft.rewritesPushed, "loading": draft.isLoading,
            ] as [String: Any]
        }
        return result
    }
}
#endif
