#if DEBUG
import AppKit
import KaernKit

/// Phase-5 debug commands: Clone, Create New Repository, Publish, the Repositories window, the
/// repository switching modes, big repositories and the diff extras.
extension DebugDriver {
    static let phase5Commands: Set<String> = [
        "clone", "cloneField", "cloneSource", "cloneStart", "fakeHosted", "fakeCloneProgress",
        "create", "createField", "createStart", "publishSheet", "windowSheetClose",
        "repositories", "reposFilter", "reposAttention", "reposSelect", "reposFix", "reposOpen", "reposClose", "fakeFetchProblem",
        "listFold", "repoPopover", "flyout", "overlayPanel",
        "loadMore", "expandRun", "botMode", "fsmonitorOn", "fsmonitorNotNow",
    ]

    func phase5(_ command: String, _ args: [String]) {
        let state = RepositoriesWindowController.shared.state
        switch command {
        case "repositories":
            // repositories — Window › Repositories, at the board's size.
            RepositoriesWindowController.shared.show()
            RepositoriesWindowController.shared.window?.setFrame(NSRect(x: 80, y: 60, width: 1260, height: 760), display: true)
            return
        case "reposClose":
            RepositoriesWindowController.shared.window?.close()
            return
        case "reposFilter":
            state.filter = args.joined(separator: " ")
            return
        case "reposAttention":
            state.onlyAttention = args.first == "on"
            return
        case "reposSelect", "reposFix", "reposOpen":
            // reposSelect|reposFix|reposOpen <repository name>
            let name = args.joined(separator: " ")
            let rows = RepositoryTable.sections(app: app, state: state).flatMap(\.rows)
            guard let row = rows.first(where: { $0.name == name }) else { return }
            state.selection = row.path
            if command == "reposFix", let model = row.model {
                switch row.fix {
                case .pull: model.from("Repositories window") { model.pull(model.pullChoice.strategy) }
                case .resolve: FailureHelp.reveal(model); model.openConflicts()
                case .open: FailureHelp.reveal(model)
                default: break
                }
            }
            if command == "reposOpen" {
                if let model = row.model { FailureHelp.reveal(model) } else if let window {
                    app.open([URL(filePath: row.path, directoryHint: .isDirectory)], in: window)
                }
            }
            return
        case "fakeFetchProblem":
            // fakeFetchProblem <tab name> signIn|network <host> — as if its last fetch failed that way.
            guard args.count >= 2, let tab = window?.tabs.first(where: { $0.name == args[0] }) else { return }
            let model = app.repository(for: tab.path)
            let host = args.count > 2 ? args[2] : "github.com"
            let failure: GitFailure = args[1] == "signIn" ? .signIn(host: host) : .network(host: host)
            model.fetchProblem = FetchProblem(failure: failure, remote: "origin", message: "fake", date: .now)
            return
        default:
            break
        }
        guard let window else { return }
        let rest = args.dropFirst().joined(separator: " ")
        switch command {
        case "loadMore", "expandRun", "botMode", "fsmonitorOn", "fsmonitorNotNow":
            guard let tab = window.activeTab else { return }
            let repository = app.repository(for: tab.path)
            switch command {
            case "loadMore":
                repository.loadMoreHistory(count: Int(args.first ?? "") ?? RepositoryModel.pageSize)
            case "expandRun":
                // expandRun <row index among the shown rows>
                if let index = args.first.flatMap(Int.init), repository.displayCommits.indices.contains(index) {
                    repository.expandedRuns.insert(repository.displayCommits[index].id)
                }
            case "botMode":
                UserDefaults.kaern.set(args.first ?? "collapse", forKey: SettingsKey.botCommits)
                for model in app.openRepositories { model.rebuildGraph() }
            case "fsmonitorOn":
                repository.turnOnFSMonitor()
            default:
                repository.dismissFSMonitorSuggestion()
            }
        case "listFold":
            window.listFolded = args.first != "off"
        case "repoPopover":
            window.showsRepositoryPopover = args.first != "off"
        case "flyout":
            // flyout local|remote|tags|stashes|worktrees|off — a narrow window's sidebar section.
            window.sidebarFlyout = SidebarSection(rawValue: args.first ?? "")
        case "overlayPanel":
            window.overlayPanelOpen = args.first != "off"
        case "clone":
            // clone [url…] — File › Clone Repository…, with the URL filled in.
            app.showClone(in: window, url: args.joined(separator: " "))
        case "cloneField":
            // cloneField url|dest|tab <value>
            guard case .clone(let model) = window.sheet else { return }
            switch args.first {
            case "url": model.url = rest
            case "dest":
                model.destination = rest
                model.destinationEdited = true
            case "tab": model.opensTab = rest == "on"
            default: break
            }
        case "cloneSource":
            guard case .clone(let model) = window.sheet, let source = CloneModel.Source(rawValue: args.first ?? "") else { return }
            model.source = source
        case "cloneStart":
            if case .clone(let model) = window.sheet { app.startClone(model, in: window) }
        case "fakeHosted":
            // fakeHosted — a GitHub list without the network, to check how the list looks.
            guard case .clone(let model) = window.sheet else { return }
            let now = Date.now
            model.hosted = [
                HostedRepository(id: 1, fullName: "progresshans/kaern", name: "kaern", isPrivate: true, summary: "A Git client for the Mac",
                                 httpsURL: "https://github.com/progresshans/kaern.git", sshURL: "git@github.com:progresshans/kaern.git",
                                 updated: now.addingTimeInterval(-3600)),
                HostedRepository(id: 2, fullName: "progresshans/powerlens", name: "powerlens", isPrivate: false, summary: "Battery and charging insight",
                                 httpsURL: "https://github.com/progresshans/powerlens.git", sshURL: "git@github.com:progresshans/powerlens.git",
                                 updated: now.addingTimeInterval(-86_400 * 2)),
                HostedRepository(id: 3, fullName: "progresshans/godj", name: "godj", isPrivate: false,
                                 summary: nil, httpsURL: "https://github.com/progresshans/godj.git",
                                 sshURL: "git@github.com:progresshans/godj.git", updated: now.addingTimeInterval(-86_400 * 9)),
            ]
            model.listState = .loaded
        case "fakeCloneProgress":
            // fakeCloneProgress <git progress line> — how the sheet looks mid-clone.
            guard case .clone(let model) = window.sheet else { return }
            model.isCloning = true
            model.progress = GitProgress.parse(args.joined(separator: " "))
        case "create":
            // create [folder] — File › Create New Repository…, or Create Repository Here… for a folder.
            app.showCreate(in: window, folder: args.first.map { URL(filePath: $0, directoryHint: .isDirectory) })
        case "createField":
            // createField name|location|branch|ignore|license|readme|first|publish|private <value>
            guard case .create(let model) = window.sheet else { return }
            switch args.first {
            case "name": model.name = rest
            case "location": model.location = URL(filePath: rest, directoryHint: .isDirectory)
            case "branch": model.branch = rest
            case "ignore": model.ignore = IgnoreTemplate(rawValue: rest) ?? model.ignore
            case "license": model.license = LicenseChoice(rawValue: rest) ?? model.license
            case "readme": model.readme = rest == "on"
            case "first": model.firstCommit = rest == "on"
            case "publish": model.publish = rest == "on"
            case "private": model.isPrivate = rest == "on"
            default: break
            }
        case "createStart":
            if case .create(let model) = window.sheet { app.startCreate(model, in: window) }
        case "publishSheet":
            if let tab = window.activeTab { app.showPublish(app.repository(for: tab.path), in: window) }
        case "windowSheetClose":
            app.closeSheet(in: window)
        default:
            break
        }
    }

    func phase5Dump(_ window: WindowModel?) -> [String: Any] {
        var result: [String: Any] = [:]
        switch window?.sheet {
        case .clone(let model)?:
            result["sheet"] = [
                "kind": "clone", "url": model.url, "destination": model.destination, "source": model.source.rawValue,
                "problem": model.problem ?? "", "cloning": model.isCloning, "error": model.error ?? "",
                "progress": model.progress.map { "\($0.phase) \($0.percent ?? -1)%" } ?? "", "account": model.account?.id ?? "",
                "list": "\(model.listState)", "hosted": model.hosted.map(\.fullName),
            ] as [String: Any]
        case .create(let model)?:
            result["sheet"] = [
                "kind": "create", "name": model.name, "folder": model.folder.path(percentEncoded: false), "branch": model.branch,
                "ignore": model.ignore.rawValue, "license": model.license.rawValue, "nameNote": model.nameCheck.note ?? "",
                "nameError": model.nameCheck.isError, "ignoreNote": model.ignoreNote, "firstNote": model.firstCommitNote,
                "canCreate": model.canCreate, "running": model.isRunning, "error": model.error ?? "",
                "steps": model.steps.map { "\($0.state) \($0.text)" },
            ] as [String: Any]
        case .publish(let model)?:
            result["sheet"] = ["kind": "publish", "name": model.name, "error": model.error ?? "", "account": model.account?.id ?? ""]
        case nil:
            result["sheet"] = NSNull()
        }
        if let window, let tab = window.activeTab {
            let repository = app.repository(for: tab.path)
            result["phase"] = "\(repository.phase)"
            result["survey"] = repository.folderSurvey.map { survey -> [String: Any] in
                ["kind": survey.kind ?? "", "marker": survey.marker ?? "", "files": survey.files, "bytes": survey.bytes,
                 "template": survey.template.rawValue, "generated": survey.generated.map { "\($0.name) \($0.files)" }]
            } ?? NSNull()
            result["createdNote"] = repository.createdNote ?? ""
            result["publishBanner"] = repository.showsPublishBanner
            result["remotes"] = repository.remotes.map(\.name)
            result["history"] = [
                "commits": repository.commits.count,
                "shown": repository.displayCommits.count,
                "hasMore": repository.hasMoreHistory,
                "loadingMore": repository.isLoadingMoreHistory,
                "stream": repository.historyStream.map { "skip \($0.skipped) read \($0.count) finished \($0.isFinished)" } ?? "none",
                "runs": repository.displayCommits.enumerated().compactMap { index, commit in
                    repository.botRuns[commit.id].map { "\(index): \($0.title) — \($0.detail)" }
                },
                "folded": repository.foldedBotCount, "hidden": repository.hiddenBotCount, "hasBots": repository.hasBotCommits,
                "total": repository.totalCommitCount ?? -1,
                "statusSeconds": repository.statusDuration.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 } ?? -1,
                "fsmonitorOn": repository.fsmonitorOn.map { $0 ? "on" : "off" } ?? "unknown",
                "suggestsFSMonitor": repository.suggestsFSMonitor,
                "searchOlder": repository.search.olderMatches, "searchPaging": repository.search.isPaging,
                "searchMatches": repository.search.matches.count,
                "timings": repository.debugTimings,
                "topRow": repository.historyScrollAnchor.flatMap { id in repository.displayCommits.firstIndex { $0.id == id } } ?? 0,
                "selection": { if case .commit(let id) = repository.selection { return repository.commits.first { $0.id == id }?.subject ?? id } else { return "wip" } }(),
            ] as [String: Any]
        }
        let reposState = RepositoriesWindowController.shared.state
        result["repositories"] = [
            "open": RepositoriesWindowController.shared.window?.isVisible ?? false,
            "selection": reposState.selection.map { ($0 as NSString).lastPathComponent } ?? "",
            "sections": RepositoryTable.filtered(RepositoryTable.sections(app: app, state: reposState), state: reposState).map { section -> [String: Any] in
                ["name": section.name, "note": section.note,
                 "rows": section.rows.map { "\($0.name) | \($0.branch) | \($0.changes.map(String.init) ?? "—") | \($0.toPush.map(String.init) ?? "—") | \($0.toPull.map(String.init) ?? "—") | \($0.tone) | \($0.status) | \($0.fixTitle ?? "")" }]
            },
        ] as [String: Any]
        result["lastFetchAll"] = AutoFetcher.shared.lastFetchAll.map { "\($0)" } ?? ""
        result["layout"] = [
            "switching": AppSettings.repositorySwitching.rawValue,
            "listFolded": window?.listFolded ?? false,
            "repoPopover": window?.showsRepositoryPopover ?? false,
            "flyout": window?.sidebarFlyout?.rawValue ?? "",
            "overlayPanel": window?.overlayPanelOpen ?? false,
            "width": controller?.window?.frame.width ?? 0,
            "chromeHeight": (controller?.window as? KaernWindow)?.chromeHeight ?? 0,
        ] as [String: Any]
        result["activity"] = ActivityCenter.shared.running.map { "\($0.title) \($0.detail ?? "") \($0.fraction.map { String(format: "%.2f", $0) } ?? "-")" }
        result["recentActivity"] = ActivityCenter.shared.recent.prefix(4).map { "\($0.title): \($0.result ?? "")" }
        return result
    }
}
#endif
