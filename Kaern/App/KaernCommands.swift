import KaernKit
import SwiftUI

extension FocusedValues {
    /// The repository of the key window, for menu commands.
    @Entry var repositoryModel: RepositoryModel?
}

struct KaernCommands: Commands {
    let appModel: AppModel
    @FocusedValue(\.repositoryModel) private var model
    @Environment(\.openWindow) private var openWindow

    private func operationName(_ kind: OperationState.Kind) -> String {
        switch kind {
        case .merge: String(localized: "Merge")
        case .rebase: String(localized: "Rebase")
        case .cherryPick: String(localized: "Cherry-Pick")
        case .revert: String(localized: "Revert")
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Repository…") {
                for url in appModel.chooseRepositories() {
                    appModel.open(url)
                }
            }
            .keyboardShortcut("o")

            Menu("Open Recent") {
                ForEach(appModel.recents) { recent in
                    Button(recent.name) { appModel.open(recent.url) }
                }
                if !appModel.recents.isEmpty {
                    Divider()
                    Button("Clear Menu") { appModel.clearRecents() }
                }
            }

            if RepositorySwitcher.current == .tabs {
                Button("New Tab…") { appModel.tabChooserRequest += 1 }
                    .keyboardShortcut("t")
            }

            Button("Open Quickly…") { model?.showQuickSwitcher(query: "") }
                .keyboardShortcut("o", modifiers: [.shift, .command])
                .disabled(model == nil)

            Divider()

            Button("Clone Repository…") {
                openWindow(id: SceneID.welcome)
                WelcomeActions.shared.request(.clone)
            }
            Button("New Repository…") {
                openWindow(id: SceneID.welcome)
                WelcomeActions.shared.request(.create)
            }
        }

        CommandGroup(after: .sidebar) {
            Button(model?.showSidebar == false ? "Show Sidebar" : "Hide Sidebar") {
                model?.showSidebar.toggle()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .disabled(model == nil)

            Button(model?.isInspectorVisible == false ? "Show Inspector" : "Hide Inspector") {
                model?.toggleInspector()
            }
            .keyboardShortcut("0", modifiers: [.option, .command])
            .disabled(model == nil)

            Divider()

            Button("Show History") {
                if model?.fileHistory != nil { model?.closeFileHistory() } else { model?.closeDiff() }
            }
            .keyboardShortcut("1", modifiers: [.command])
            .disabled(model?.selectedFile == nil && model?.fileHistory == nil)

            Button("Find Commits") {
                model?.searchFocusRequest += 1
            }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(model == nil)

            Button("Find Next") { model?.selectNextSearchMatch() }
                .keyboardShortcut("g", modifiers: [.command])
                .disabled(model?.isSearching != true)

            Button("Find Previous") { model?.selectNextSearchMatch(backwards: true) }
                .keyboardShortcut("g", modifiers: [.shift, .command])
                .disabled(model?.isSearching != true)

            Button("Filter Sidebar") {
                model?.showSidebar = true
                model?.filterFocusRequest += 1
            }
            .keyboardShortcut("f", modifiers: [.option, .command])
            .disabled(model == nil)

            Button("Show All Branches in Graph") { model?.showAllBranchesInGraph() }
                .disabled(model?.historyScope.isFiltered != true)

            Divider()
        }

        CommandMenu("Repository") {
            Button("Fetch") { Task { await model?.fetch() } }
                .keyboardShortcut("f", modifiers: [.shift, .command])
                .disabled(model?.activity != nil || model == nil)
            Button("Pull") { Task { await model?.pull() } }
                .keyboardShortcut("l", modifiers: [.shift, .command])
                .disabled(model?.canStartOperation != true)
            Menu("Pull Using") {
                if let model { PullMenuItems(model: model) }
            }
            .disabled(model == nil)
            Button("Push") { Task { await model?.push() } }
                .keyboardShortcut("p", modifiers: [.shift, .command])
                .disabled(model?.canStartOperation != true)
            Button("Force Push (with Lease)…") {
                if let model, let branch = model.status.branch {
                    model.confirmation = .forcePush(branch: branch)
                }
            }
            .disabled(model?.status.branch == nil || model?.status.upstream == nil || model?.canStartOperation != true)

            if let model, let operation = model.operation {
                Divider()
                Button(operation.kind == .merge ? "Commit Merge" : "Continue \(operationName(operation.kind))") {
                    Task { await model.continueOperation() }
                }
                .disabled(model.status.conflictCount > 0 || model.activity != nil)
                if operation.kind.canSkip {
                    Button("Skip Commit") { Task { await model.skipOperationStep() } }
                        .disabled(model.activity != nil)
                }
                Button("Abort \(operationName(operation.kind))") { model.requestAbortOperation() }
                    .disabled(model.activity != nil)
            }

            Divider()

            Button("Stash Changes…") { model?.sheet = .stash }
                .keyboardShortcut("s", modifiers: [.option, .command])
                .disabled(model?.status.isClean ?? true || model?.operation != nil)
            Button("Pop Latest Stash") {
                if let model, let stash = model.stashes.first {
                    Task { await model.apply(stash, pop: true) }
                }
            }
            .disabled(model?.stashes.isEmpty ?? true)

            Button(model?.restorableEntry.map { model?.restoreTitle(for: $0) ?? "" } ?? String(localized: "Restore Selected File to HEAD")) {
                if let model, let entry = model.restorableEntry {
                    Task { await model.discard([entry]) }
                }
            }
            .keyboardShortcut("z", modifiers: [.option, .command])
            .disabled(model?.restorableEntry == nil || model?.activity != nil)
            Button("Discard All Changes") {
                if let model { Task { await model.discard(model.discardableEntries) } }
            }
            .disabled(model?.discardableEntries.isEmpty ?? true || model?.activity != nil || model?.operation != nil)

            Divider()

            Button("Refresh") { Task { await model?.refreshEverything() } }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model == nil)
            Button("Show in Finder") { model?.openRepositoryInFinder() }
                .disabled(model == nil)
            Button("Open in Terminal") { model?.openInTerminal() }
                .disabled(model == nil)

            Divider()

            Button("Repository Settings…") { model?.sheet = .repositorySettings }
                .keyboardShortcut(",", modifiers: [.option, .command])
                .disabled(model == nil || model?.repository == nil)
        }

        CommandMenu("Branch") {
            Button("New Branch…") {
                model?.sheet = .newBranch(startPoint: nil, label: model?.headTitle ?? "HEAD")
            }
            .keyboardShortcut("n", modifiers: [.shift, .command])
            .disabled(model?.hasHead != true)

            Divider()

            Button("Merge into Current Branch…") { model?.sheet = .chooseBranch(.merge) }
                .disabled(model?.canStartOperation != true || model?.hasHead != true)
            Button("Rebase Current Branch onto…") { model?.sheet = .chooseBranch(.rebase) }
                .disabled(model?.canStartOperation != true || model?.hasHead != true)
            Button("Interactive Rebase…") { model?.requestInteractiveRebase() }
                .disabled(model?.canStartOperation != true || model?.hasHead != true)
            Button("Rename Current Branch…") {
                if let model, let ref = model.refs.headBranch { model.sheet = .renameBranch(ref) }
            }
            .disabled(model?.refs.headBranch == nil)
            Button("New Worktree…") { model?.sheet = .newWorktree }
                .disabled(model?.hasHead != true || model?.activity != nil)

            Divider()

            Button("New Tag…") {
                guard let model else { return }
                if let commit = model.selectedCommit {
                    model.sheet = .newTag(commitID: commit.id, label: commit.shortID)
                } else if let head = model.status.headID {
                    model.sheet = .newTag(commitID: head, label: model.headTitle)
                }
            }
            .disabled(model?.hasHead != true)
            Button("Cherry-Pick Selected Commit") {
                if let model, let commit = model.selectedCommit { Task { await model.cherryPick(commit) } }
            }
            .disabled(model?.selectedCommit == nil || model?.selectedCommit?.isMerge == true || model?.canStartOperation != true)

            Divider()

            Button("Copy Commit SHA") {
                if let commit = model?.selectedCommit {
                    Pasteboard.copy(commit.id)
                }
            }
            .keyboardShortcut("c", modifiers: [.shift, .command])
            .disabled(model?.selectedCommit == nil)
        }
    }
}
