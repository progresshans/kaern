#if DEBUG
import AppKit
import KaernKit

/// What the last `relocate` command got back ("refused" for `nil`).
@MainActor var debugLastRelocate = ""

/// Phase-5 debug commands: Clone, Create New Repository, Publish, the Repositories window, the
/// repository switching modes, big repositories and the diff extras.
extension DebugDriver {
    static let phase5Commands: Set<String> = [
        "clone", "cloneField", "cloneSource", "cloneStart", "fakeHosted", "fakeCloneProgress",
        "create", "createField", "createStart", "publishSheet", "windowSheetClose",
        "repositories", "reposFilter", "reposAttention", "reposSelect", "reposFix", "reposOpen", "reposClose", "fakeFetchProblem",
        "listFold", "repoPopover", "flyout", "overlayPanel",
        "loadMore", "expandRun", "botMode", "fsmonitorOn", "fsmonitorNotNow",
        "diffWrap", "scrollWheel", "selectSubject", "quickLook", "alwaysLFS", "imageMode", "downloadLFS",
        "useWindow", "focusGraph", "targetFrame", "initSubmodule", "deepen", "updateRecorded", "relocate",
    ]

    /// A trackpad scroll by (dx, dy) points at the window point (x, y) (top-left origin), through the
    /// event queue like a real one (event monitors see it).
    func postScroll(x: Double, y: Double, dx: Double, dy: Double) {
        guard let nsWindow = controller?.window, let screen = nsWindow.screen ?? NSScreen.main else { return }
        // Quartz event locations are global, top-left of the main display.
        let flipped = NSPoint(x: nsWindow.frame.minX + x, y: nsWindow.frame.maxY - y)
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
        cg.location = CGPoint(x: flipped.x, y: mainHeight - flipped.y)
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // The driver's own: it passes when the real pointer is kept out (-KaernDebugIgnorePointer).
        cg.setIntegerValueField(.eventSourceUserData, value: DebugDriver.ownEventMark)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(nsWindow.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(nsWindow.windowNumber))
        if let event = NSEvent(cgEvent: cg) { NSApp.postEvent(event, atStart: false) }
    }

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
                case .pull: model.pullWithItsSetting(from: "Repositories window")
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
        case "useWindow":
            // useWindow <n> | useWindow off — later commands go to that window.
            DebugDriver.chosenWindow = args.first.flatMap(Int.init)
            return
        case "targetFrame":
            // targetFrame file <path> | commitFile <path> | commit <index> | branch <name> | remote <name> | tag <name> |
            // worktree <folder name> —
            // writes where its row (the smallest view showing it) is, in window points, into the dump's
            // `targetFrame`. targetFrame labels list|row: the list of labels the driver opened (`labels`),
            // and where its row shows the first label and "+N".
            guard let controller, args.count >= 2, let tab = controller.model.activeTab else { return }
            let repository = app.repository(for: tab.path)
            let rest = args.dropFirst().joined(separator: " ")
            if args[0] == "labels" {
                let labels = DebugRefLabels.shared
                lastTargetFrame = rest == "list" ? labels.frames["list"] : labels.open.flatMap { labels.frames["row \($0)"] }
                return
            }
            let target: ContextTarget? = switch args[0] {
            case "file": .file(path: rest, staged: false)
            case "fileStaged": .file(path: rest, staged: true)
            case "commitFile": repository.selectedCommitID.map { .commitFile(path: rest, commit: $0) }
            case "commit": Int(rest).flatMap { repository.commits.indices.contains($0) ? .commit(repository.commits[$0].id) : nil }
            case "branch": .branch(rest)
            case "remote": .remoteBranch(rest)
            case "tag": .tag(rest)
            case "worktree": repository.worktrees.first { $0.name == rest }.map { .worktree($0.path) }
            default: nil
            }
            lastTargetFrame = target.flatMap { controller.contextTracker.frame(of: $0) }
            return
        case "imageMode":
            // imageMode 2up|swipe|onion
            UserDefaults.kaern.set(args.first ?? "swipe", forKey: SettingsKey.imageDiffMode)
            return
        case "diffWrap":
            // diffWrap on|off — Settings › Diff › Wrap long lines.
            UserDefaults.kaern.set(args.first != "off", forKey: SettingsKey.diffWrap)
            return
        case "scrollWheel":
            // scrollWheel x y dx dy — a trackpad scroll by (dx, dy) points at window points (top-left
            // origin), through the event queue like a real one (event monitors see it).
            let values = args.compactMap(Double.init)
            guard args.count == 4, values.count == 4 else { return }
            postScroll(x: values[0], y: values[1], dx: values[2], dy: values[3])
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
        // Clone and Create sheets: in the start window while it's open (it holds their window model).
        let sheetCommands: Set<String> = ["clone", "cloneField", "cloneSource", "cloneStart", "create", "createField",
                                          "createStart", "fakeCloneProgress", "fakeHosted", "windowSheetClose"]
        guard let window = sheetCommands.contains(command) ? (app.welcome?.model ?? self.window) : self.window else { return }
        let rest = args.dropFirst().joined(separator: " ")
        switch command {
        case "relocate":
            // relocate <old path> <new path> — Locate…'s choice; the dump's lastRelocate says what happened.
            guard args.count == 2 else { return }
            Task { debugLastRelocate = await app.relocate(args[0], to: URL(filePath: args[1], directoryHint: .isDirectory)) ?? "refused" }
            return
        case "selectSubject", "quickLook", "alwaysLFS", "downloadLFS", "focusGraph", "initSubmodule", "deepen", "updateRecorded":
            guard let tab = window.activeTab else { return }
            let repository = app.repository(for: tab.path)
            switch command {
            case "selectSubject":
                // selectSubject <subject…> — the newest loaded commit with that subject.
                let subject = args.joined(separator: " ")
                if let commit = repository.commits.first(where: { $0.subject == subject }) {
                    repository.clearPicks()
                    repository.selection = .commit(commit.id)
                }
            case "downloadLFS":
                // downloadLFS <path> — the LFS page's Download, for the selected commit or the work tree.
                let commit: String? = if case .commit(let id) = repository.selection { id } else { nil }
                repository.from("LFS file") { repository.downloadLFS([args.joined(separator: " ")], at: commit) }
            case "focusGraph":
                repository.historyFocusRequest += 1
            case "deepen":
                // deepen <count> | deepen all — the shallow end row's Fetch 100 More / Fetch Full History.
                repository.from("History") { repository.fetchMoreHistory(args.first.flatMap(Int.init)) }
            case "initSubmodule":
                // initSubmodule <path> — the sidebar's Initialize.
                repository.from("Sidebar") { repository.initializeSubmodule(args.joined(separator: " ")) }
            case "updateRecorded":
                // updateRecorded <path> <label> — the submodule page's Update to Recorded (<label>).
                guard args.count >= 2 else { return }
                repository.from("Submodule") { repository.updateSubmoduleToRecorded(args[0], label: args[1]) }
            case "quickLook":
                // quickLook — Space: the file Review shows; again closes it.
                _ = controller?.toggleQuickLook()
            default:
                // alwaysLFS on|off — Always Download in <repository>.
                repository.alwaysDownloadsLFS = args.first != "off"
            }
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
                HostedRepository(id: 1, fullName: "progresshans/kaern", name: "kaern", isPrivate: false, summary: "A Git client for the Mac",
                                 httpsURL: "https://github.com/progresshans/kaern.git", sshURL: "git@github.com:progresshans/kaern.git",
                                 updated: now.addingTimeInterval(-3600)),
                HostedRepository(id: 2, fullName: "progresshans/powerlens", name: "powerlens", isPrivate: false, summary: "Battery and charging insight",
                                 httpsURL: "https://github.com/progresshans/powerlens.git", sshURL: "git@github.com:progresshans/powerlens.git",
                                 updated: now.addingTimeInterval(-86_400 * 2)),
                HostedRepository(id: 3, fullName: "progresshans/godj", name: "godj", isPrivate: false,
                                 summary: nil, httpsURL: "https://github.com/progresshans/godj.git",
                                 sshURL: "git@github.com:progresshans/godj.git", updated: now.addingTimeInterval(-86_400 * 9)),
                HostedRepository(id: 4, fullName: "acme/recipe-box", name: "recipe-box", isPrivate: true, summary: "What we cook at home",
                                 httpsURL: "https://github.com/acme/recipe-box.git", sshURL: "git@github.com:acme/recipe-box.git",
                                 updated: now.addingTimeInterval(-86_400 * 12)),
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
                "statusSeconds": repository.exactStatusDuration.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 } ?? -1,
                "fsmonitorOn": repository.fsmonitorOn.map { $0 ? "on" : "off" } ?? "unknown",
                "suggestsFSMonitor": repository.suggestsFSMonitor,
                "searchOlder": repository.search.olderMatches, "searchPaging": repository.search.isPaging,
                "searchMatches": repository.search.matches.count,
                "timings": repository.debugTimings,
                "shallow": repository.isShallow,
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
        if let window, let tab = window.activeTab {
            let repository = app.repository(for: tab.path)
            func sizes(_ value: [String: LFSSizes]) -> [String: String] {
                value.mapValues { "\($0.old.map(String.init) ?? "-")→\($0.new.map(String.init) ?? "-")" }
            }
            result["marks"] = [
                "lfs": sizes(repository.workingMarks.lfsSizes),
                "pointers": repository.workingMarks.lfsPointers.sorted(),
                "submodules": repository.workingMarks.submoduleNotes,
                "commit": repository.commitMarks.map { ["id": String($0.id.prefix(7)), "lfs": sizes($0.lfsSizes), "missing": $0.lfsMissing.sorted()] as [String: Any] } ?? NSNull(),
                "files": (repository.reviewFiles ?? []).map { file -> String in
                    let kind: String
                    switch file.special {
                    case .image?: kind = "image"
                    case .lfs?: kind = "lfs"
                    case .submodule(let sides)?: kind = "submodule \(sides.stage) \(sides.old.map { String($0.prefix(7)) } ?? "-")→\(sides.new.map { String($0.prefix(7)) } ?? "now")"
                    case nil: kind = "text"
                    }
                    return "\(file.letter) \(file.path) \(kind)\(file.isLFS ? " lfs" : "")"
                },
                "quickLook": repository.quickLookURL?.lastPathComponent ?? "",
                "quickLookFile": repository.quickLookFile?.path ?? "",
                "alwaysLFS": repository.alwaysDownloadsLFS,
                "sidebarSubmodules": repository.submoduleItems.map { "\($0.path) | \($0.detail) | \($0.state)" },
                "alert": repository.alert.map { "\($0.title) — \($0.message)" } ?? "",
                "toast": repository.toast?.message ?? "",
                "quickLookCopies": (try? FileManager.default.contentsOfDirectory(atPath: QuickLookCopies.folder.path(percentEncoded: false)).count) ?? 0,
            ] as [String: Any]
        }
        result["lastRelocate"] = debugLastRelocate
        result["windows"] = app.windows.enumerated().map { index, controller -> [String: Any] in
            let tab = controller.model.activeTab
            return ["index": index, "tab": tab?.name ?? "", "lastTarget": controller.contextTracker.lastTarget.map { "\($0)" } ?? "",
                    "lastTargetRepo": tab.map { app.repository(for: $0.path).name } ?? "",
                    "targetInRepo": {
                        guard let tab, case .commit(let id)? = controller.contextTracker.lastTarget else { return false }
                        return app.repository(for: tab.path).commit(id) != nil
                    }()]
        }
        result["targetFrame"] = lastTargetFrame.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? NSNull()
        result["sideScroll"] = DiffSideScroll.current.map { side -> [String: Any] in
            ["offset": side.offset, "content": side.contentWidth, "column": side.columnWidth, "max": side.maxOffset, "lastSeen": side.lastSeen]
        } ?? NSNull()
        result["lastFetchAll"] = AutoFetcher.shared.lastFetchAll.map { "\($0)" } ?? ""
        result["layout"] = [
            "switching": AppSettings.repositorySwitching.rawValue,
            "listFolded": window?.listFolded ?? false,
            "repoPopover": window?.showsRepositoryPopover ?? false,
            "flyout": window?.sidebarFlyout?.rawValue ?? "",
            "overlayPanel": window?.overlayPanelOpen ?? false,
            "width": controller?.window?.frame.width ?? 0,
            "chromeHeight": (controller?.window as? KaernWindow)?.chromeHeight ?? 0,
            // The sizes kept for the panes (0: the boards'), and where each pane is now (window points).
            "panes": [
                "sidebar": UserDefaults.kaern.double(forKey: PaneSizes.sidebarKey),
                "panel": UserDefaults.kaern.double(forKey: PaneSizes.panelKey),
                "drawer": UserDefaults.kaern.double(forKey: PaneSizes.drawerKey),
                "list": UserDefaults.kaern.double(forKey: PaneSizes.listKey),
                "frames": (window.flatMap { PaneFrames.frames[$0.id] } ?? [:]).mapValues { [$0.minX, $0.minY, $0.width, $0.height] },
            ] as [String: Any],
        ] as [String: Any]
        result["activity"] = ActivityCenter.shared.running.map { "\($0.title) \($0.detail ?? "") \($0.fraction.map { String(format: "%.2f", $0) } ?? "-")" }
        result["recentActivity"] = ActivityCenter.shared.recent.prefix(4).map { "\($0.title): \($0.result ?? "")" }
        return result
    }
}
#endif
