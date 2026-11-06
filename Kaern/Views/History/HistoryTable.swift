import AppKit
import KaernKit
import SwiftUI

enum HistoryColumn: String, CaseIterable {
    case graph
    case description
    case author
    case date
    case commit

    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

    var title: String {
        switch self {
        case .graph: String(localized: "Graph")
        case .description: String(localized: "Description")
        case .author: String(localized: "Author")
        case .date: String(localized: "Date")
        case .commit: String(localized: "Commit")
        }
    }

    func makeColumn() -> NSTableColumn {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        switch self {
        case .graph:
            column.width = 72
            column.minWidth = 40
            column.maxWidth = 400
            column.resizingMask = .userResizingMask
        case .description:
            column.width = 468
            column.minWidth = 160
            column.resizingMask = [.autoresizingMask, .userResizingMask]
        case .author:
            column.width = 128
            column.minWidth = 60
            column.resizingMask = .userResizingMask
        case .date:
            column.width = 116
            column.minWidth = 60
            column.resizingMask = .userResizingMask
        case .commit:
            column.width = 96
            column.minWidth = 64
            column.resizingMask = .userResizingMask
        }
        return column
    }
}

/// Takes keyboard focus when the window opens, so the selection shows as focused (blue) and the
/// arrow keys move through history right away.
final class HistoryNSTableView: NSTableView {
    private var didTakeInitialFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didTakeInitialFocus, window != nil else { return }
        didTakeInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.firstResponder === window else { return }
            window.makeFirstResponder(self)
        }
    }
}

/// History table: NSTableView (alternating rows, 26pt) + the custom graph column.
/// Row 0 is always the working copy; row n is `model.commits[n - 1]`.
struct HistoryTable: NSViewRepresentable {
    struct Input: Equatable {
        var historyVersion: Int
        var searchVersion: Int
        var selection: HistorySelection
        var status: WorkingTreeStatus
        var operation: OperationState?
        var showsAuthor: Bool
        var showsCommitColumn: Bool
        var isVisible: Bool
        var focusRequest: Int
        var signatureVersion: Int = 0
        /// The older commit of a comparison (⌘-click a second commit): its row is selected too.
        var comparisonBase: String?
        var avatarVersion: Int = 0
    }

    let model: RepositoryModel
    let input: Input

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = HistoryNSTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.intercellSpacing = .zero
        table.rowHeight = HistoryMetrics.rowHeight
        // Two commits at most: ⌘- or ⇧-click a second one to compare them.
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = false
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.gridStyleMask = []
        for column in HistoryColumn.allCases {
            table.addTableColumn(column.makeColumn())
        }
        table.autosaveName = "KaernHistoryColumns"
        table.autosaveTableColumns = true
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.menu = coordinator.contextMenu
        table.setAccessibilityLabel(String(localized: "History"))
        coordinator.tableView = table

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.didScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        coordinator.apply(input, force: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.apply(input, force: false)
        scrollView.isHidden = !input.isVisible
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var model: RepositoryModel
        weak var tableView: NSTableView?
        let contextMenu = NSMenu()
        private var lastInput: Input?
        private var isSyncingSelection = false
        private var handledFocusRequest: Int?

        init(model: RepositoryModel) {
            self.model = model
            super.init()
            contextMenu.delegate = self
        }

        // MARK: Updates from SwiftUI

        func apply(_ input: Input, force: Bool) {
            guard let table = tableView else { return }
            let previous = lastInput
            lastInput = input

            table.tableColumn(withIdentifier: HistoryColumn.author.identifier)?.isHidden = !input.showsAuthor
            table.tableColumn(withIdentifier: HistoryColumn.commit.identifier)?.isHidden = !input.showsCommitColumn

            let historyChanged = force || previous?.historyVersion != input.historyVersion
            if historyChanged {
                // Reloading can move or reset the table's selection; the model's selection wins.
                isSyncingSelection = true
                table.reloadData()
                isSyncingSelection = false
            } else if previous?.searchVersion != input.searchVersion || previous?.status != input.status
                        || previous?.operation != input.operation || previous?.signatureVersion != input.signatureVersion
                        || previous?.avatarVersion != input.avatarVersion {
                reloadVisibleRows()
            }
            if historyChanged || previous?.selection != input.selection || previous?.comparisonBase != input.comparisonBase {
                syncSelection(scrollToVisible: !historyChanged || force)
            }
            // A focus request made while the diff covers the table waits until the table shows.
            if let handled = handledFocusRequest, handled != input.focusRequest, input.isVisible {
                table.window?.makeFirstResponder(table)
                handledFocusRequest = input.focusRequest
            } else if handledFocusRequest == nil {
                handledFocusRequest = input.focusRequest
            }
        }

        /// The Commit column shows a seal for signed commits. Each row that's drawn asks for its
        /// commit's signature; the asks are batched into one `git log` per run-loop turn.
        private var pendingSignatures: [String] = []

        private func requestSignature(of id: String) {
            guard model.signatureCodes[id] == nil else { return }
            if pendingSignatures.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let ids = pendingSignatures
                    pendingSignatures = []
                    model.loadSignatures(for: ids)
                }
            }
            pendingSignatures.append(id)
        }

        private func reloadVisibleRows() {
            guard let table = tableView else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            table.reloadData(
                forRowIndexes: IndexSet(integersIn: visible.location ..< visible.location + visible.length),
                columnIndexes: IndexSet(integersIn: 0 ..< table.numberOfColumns)
            )
            updateRowDimming()
        }

        private func row(for selection: HistorySelection) -> Int? {
            switch selection {
            case .workingCopy: 0
            case .commit(let id): model.commitIndex[id].map { $0 + 1 }
            }
        }

        private func syncSelection(scrollToVisible: Bool) {
            guard let table = tableView, let row = row(for: model.selection), row < table.numberOfRows else { return }
            var rows = IndexSet(integer: row)
            if let base = model.comparisonBase, let baseRow = model.commitIndex[base].map({ $0 + 1 }), baseRow < table.numberOfRows {
                rows.insert(baseRow)
            }
            if table.selectedRowIndexes != rows {
                isSyncingSelection = true
                table.selectRowIndexes(rows, byExtendingSelection: false)
                isSyncingSelection = false
            }
            if scrollToVisible {
                table.scrollRowToVisible(row)
            }
            updateGraphHighlight()
        }

        /// Faded lanes when a commit is selected (the selected commit's lane stays solid).
        private var highlightLane: Int? {
            guard case .commit(let id) = model.selection, let index = model.commitIndex[id],
                  index + 1 < model.graph.count else { return nil }
            return model.graph[index + 1].lane
        }

        private func updateGraphHighlight() {
            guard let table = tableView else { return }
            let lane = highlightLane
            let graphColumn = table.column(withIdentifier: HistoryColumn.graph.identifier)
            guard graphColumn >= 0 else { return }
            table.enumerateAvailableRowViews { rowView, row in
                if let cell = rowView.view(atColumn: graphColumn) as? GraphCellView {
                    cell.highlightLane = lane
                }
            }
        }

        private func isDimmed(row: Int) -> Bool {
            guard let matches = model.searchMatches, row > 0, row - 1 < model.commits.count else { return false }
            return !matches.contains(model.commits[row - 1].id)
        }

        private func updateRowDimming() {
            tableView?.enumerateAvailableRowViews { rowView, row in
                rowView.alphaValue = isDimmed(row: row) ? 0.35 : 1
            }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int {
            model.commits.count + 1
        }

        // MARK: Delegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = HistoryColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let commit = row > 0 && row - 1 < model.commits.count ? model.commits[row - 1] : nil

            switch column {
            case .graph:
                let cell = reuse(GraphCellView.self, in: tableView, identifier: "graph") { GraphCellView(frame: .zero) }
                cell.row = row < model.graph.count ? model.graph[row] : nil
                cell.highlightLane = highlightLane
                return cell

            case .description:
                let cell = reuse(DescriptionCellView.self, in: tableView, identifier: "description") { DescriptionCellView(frame: .zero) }
                if let commit {
                    let lane = row < model.graph.count ? model.graph[row].lane : 0
                    cell.configure(
                        subject: commit.subject,
                        chips: ChipBuilder.chips(
                            for: commit.id, lane: lane, refs: model.refs, status: model.status,
                            detachedTitle: model.operation == nil ? String(localized: "HEAD (detached)") : "HEAD"
                        ),
                        detail: nil
                    )
                } else {
                    cell.configure(subject: workingCopyTitle, chips: [], detail: workingCopyDetail)
                }
                return cell

            case .author:
                let cell = reuse(AuthorCellView.self, in: tableView, identifier: "author") { AuthorCellView() }
                // Avatars where GitHub has some to show: elsewhere a column of initials only adds noise.
                let image = commit.flatMap { commit in
                    Preferences.showAvatars && model.isOnGitHub
                        ? AvatarStore.shared.columnImage(name: commit.author.name, email: commit.author.email, size: HistoryMetrics.avatarSize)
                        : nil
                }
                cell.configure(name: commit?.author.name ?? "", image: image, toolTip: commit.map { "\($0.author.name) <\($0.author.email)>" })
                return cell

            case .date:
                let cell = reuse(TextCellView.self, in: tableView, identifier: "date") { TextCellView(monospaced: false) }
                if let commit {
                    cell.configure(Formatters.historyDate(commit.author.date), toolTip: Formatters.detailDate(commit.author.date))
                } else {
                    cell.configure(String(localized: "Now"))
                }
                return cell

            case .commit:
                let cell = reuse(CommitCellView.self, in: tableView, identifier: "commit") { CommitCellView() }
                cell.configure(commit?.shortID ?? "", signature: commit.flatMap { model.signatureCodes[$0.id] }, toolTip: commit?.id)
                if let commit { requestSignature(of: commit.id) }
                return cell
            }
        }

        private func reuse<T: NSView>(_ type: T.Type, in tableView: NSTableView, identifier: String, make: () -> T) -> T {
            let id = NSUserInterfaceItemIdentifier(identifier)
            if let view = tableView.makeView(withIdentifier: id, owner: self) as? T {
                return view
            }
            let view = make()
            view.identifier = id
            return view
        }

        private var workingCopyTitle: String {
            if let operation = model.operation {
                let conflicts = model.status.conflictCount
                let sha = String((operation.incoming ?? "").prefix(7))
                let base: String
                switch operation.kind {
                case .rebase: base = String(localized: "Rebase stopped at \(sha)")
                case .merge: base = String(localized: "Merging \(model.theirsLabel)")
                case .cherryPick: base = String(localized: "Cherry-pick stopped at \(sha)")
                case .revert: base = String(localized: "Revert stopped at \(sha)")
                }
                if conflicts == 0 {
                    return base + " — " + String(localized: "ready to continue")
                }
                return base + " — " + (conflicts == 1 ? String(localized: "1 conflict") : String(localized: "\(conflicts) conflicts"))
            }
            return model.status.isClean ? String(localized: "Working tree clean") : String(localized: "Uncommitted Changes")
        }

        private var workingCopyDetail: String {
            if let operation = model.operation {
                if model.status.conflictCount > 0 { return String(localized: "resolve to continue") }
                return operation.kind == .merge ? String(localized: "press Commit Merge") : String(localized: "press Continue")
            }
            let status = model.status
            guard !status.isClean else { return String(localized: "nothing to commit") }
            let files = status.entries.count == 1 ? String(localized: "1 file") : String(localized: "\(status.entries.count) files")
            let staged = status.stagedCount
            return staged > 0 ? files + " · " + String(localized: "\(staged) staged") : files
        }

        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            rowView.alphaValue = isDimmed(row: row) ? 0.35 : 1
        }

        /// At most two rows, both commits: a ⌘-click adds the second commit of a comparison, a
        /// ⇧-click compares the ends of the range, and a further ⌘-click replaces the other one.
        func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
            guard proposed.count > 1 else { return proposed }
            let commits = IndexSet(proposed.filter { $0 > 0 && $0 - 1 < model.commits.count })
            guard commits.count > 1 else { return IndexSet(integer: tableView.clickedRow >= 0 ? tableView.clickedRow : proposed.first!) }
            guard commits.count > 2 else { return commits }
            let clicked = tableView.clickedRow
            let anchor = row(for: model.selection).flatMap { commits.contains($0) && $0 != clicked ? $0 : nil }
            if clicked > 0, commits.contains(clicked), let anchor {
                return IndexSet([anchor, clicked])
            }
            return IndexSet([commits.first!, commits.last!])
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            updateGraphHighlight()
            guard !isSyncingSelection, let table = tableView else { return }
            let rows = table.selectedRowIndexes.filter { $0 > 0 && $0 - 1 < model.commits.count }
            if rows.count == 2 {
                model.compare(model.commits[rows[0] - 1].id, model.commits[rows[1] - 1].id)
                return
            }
            let row = table.selectedRow
            let selection: HistorySelection
            if row > 0, row - 1 < model.commits.count {
                selection = .commit(model.commits[row - 1].id)
            } else {
                selection = .workingCopy
            }
            if model.selection != selection {
                model.selection = selection
            } else if model.comparisonBase != nil {
                // Back from a comparison to the same commit alone.
                model.endComparison()
            }
        }

        @objc func didScroll(_ notification: Notification) {
            guard let table = tableView else { return }
            let visible = table.rows(in: table.visibleRect)
            if visible.location + visible.length > table.numberOfRows - 200, model.hasMoreHistory, !model.isLoadingMore {
                Task { await model.loadMoreHistory() }
            }
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row > 0, row - 1 < model.commits.count else { return }
            let commit = model.commits[row - 1]
            let branches = model.refs.refs(at: commit.id).filter { $0.kind == .localBranch && !$0.isHead }
            if let branch = branches.first {
                model.requestSwitch(to: branch)
            }
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table = tableView else { return }
            // clickedRow is -1 when the menu comes from the keyboard or accessibility.
            let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            if row == 0 {
                addItem(to: menu, title: String(localized: "Stash Changes…"), action: #selector(stashChanges(_:)), enabled: !model.status.isClean)
                addItem(to: menu, title: String(localized: "Discard All Changes"), action: #selector(discardAll(_:)),
                        enabled: !model.discardableEntries.isEmpty && model.activity == nil && model.operation == nil)
                return
            }
            guard row > 0, row - 1 < model.commits.count else { return }
            let commit = model.commits[row - 1]
            let canStart = model.canStartOperation
            let current = model.currentBranchTitle
            addItem(to: menu, title: String(localized: "Copy SHA"), action: #selector(copySHA(_:)), object: commit.id)
            addItem(to: menu, title: String(localized: "Copy Subject"), action: #selector(copySubject(_:)), object: commit.subject)
            if let host = model.primaryRemote {
                addItem(to: menu, title: String(localized: "Open Commit on \(host.hostName)"), action: #selector(openOnHost(_:)), object: commit.id)
            }
            menu.addItem(.separator())
            if let selected = model.comparableSelection, selected.id != commit.id {
                addItem(to: menu, title: String(localized: "Compare with \(selected.shortID)"), action: #selector(compareWithSelection(_:)), object: commit.id)
            }
            addItem(to: menu, title: String(localized: "Create Branch Here…"), action: #selector(createBranch(_:)), object: commit.id)
            addItem(to: menu, title: String(localized: "Create Tag Here…"), action: #selector(createTag(_:)), object: commit.id)
            addItem(to: menu, title: String(localized: "Check Out This Commit"), action: #selector(checkOut(_:)), object: commit.id, enabled: canStart)
            // Branches at this commit can be merged or rebased onto by name.
            let branches = model.refs.refs(at: commit.id)
                .filter { ($0.kind == .localBranch && !$0.isHead) || ($0.kind == .remoteBranch && $0.name != model.status.upstream) }
                .prefix(2)
            if !branches.isEmpty {
                menu.addItem(.separator())
                for ref in branches {
                    addItem(to: menu, title: String(localized: "Merge “\(ref.name)” into “\(current)”"), action: #selector(mergeRef(_:)), object: ref.fullName, enabled: canStart)
                    addItem(to: menu, title: String(localized: "Rebase “\(current)” onto “\(ref.name)”"), action: #selector(rebaseOntoRef(_:)), object: ref.fullName, enabled: canStart)
                }
            }
            menu.addItem(.separator())
            addItem(to: menu, title: String(localized: "Cherry-Pick onto “\(current)”"), action: #selector(cherryPick(_:)), object: commit.id,
                    enabled: canStart && !commit.isMerge && commit.id != model.status.headID)
            addItem(to: menu, title: String(localized: "Revert Commit"), action: #selector(revert(_:)), object: commit.id, enabled: canStart)
            addItem(to: menu, title: String(localized: "Interactively Rebase from Here…"), action: #selector(interactiveRebase(_:)), object: commit.id,
                    enabled: canStart && model.hasHead && commit.id != model.status.headID)
            if model.hasHead, commit.id != model.status.headID {
                let reset = NSMenuItem(title: String(localized: "Reset “\(current)” to This Commit"), action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                addItem(to: submenu, title: String(localized: "Soft — Keep Changes Staged"), action: #selector(resetSoft(_:)), object: commit.id, enabled: canStart)
                addItem(to: submenu, title: String(localized: "Mixed — Keep Changes Unstaged"), action: #selector(resetMixed(_:)), object: commit.id, enabled: canStart)
                addItem(to: submenu, title: String(localized: "Hard — Put Changes Aside…"), action: #selector(resetHard(_:)), object: commit.id, enabled: canStart)
                reset.submenu = submenu
                menu.addItem(reset)
            }
        }

        private func addItem(to menu: NSMenu, title: String, action: Selector, object: Any? = nil, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            item.representedObject = object
            menu.addItem(item)
        }

        @objc private func stashChanges(_ sender: NSMenuItem) {
            model.sheet = .stash
        }

        @objc private func discardAll(_ sender: NSMenuItem) {
            let entries = model.discardableEntries
            Task { await model.discard(entries) }
        }

        @objc private func copySHA(_ sender: NSMenuItem) {
            if let sha = sender.representedObject as? String { Pasteboard.copy(sha) }
        }

        @objc private func copySubject(_ sender: NSMenuItem) {
            if let subject = sender.representedObject as? String { Pasteboard.copy(subject) }
        }

        @objc private func openOnHost(_ sender: NSMenuItem) {
            if let sha = sender.representedObject as? String { model.openCommitOnHost(sha) }
        }

        @objc private func compareWithSelection(_ sender: NSMenuItem) {
            guard let sha = sender.representedObject as? String, let selected = model.selectedCommit else { return }
            model.compare(selected.id, sha)
        }

        @objc private func createBranch(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String, let commit = model.commit(withID: id) else { return }
            model.sheet = .newBranch(startPoint: commit.id, label: commit.shortID)
        }

        @objc private func createTag(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String, let commit = model.commit(withID: id) else { return }
            model.sheet = .newTag(commitID: commit.id, label: commit.shortID)
        }

        @objc private func mergeRef(_ sender: NSMenuItem) {
            guard let fullName = sender.representedObject as? String, let ref = model.refs.refs.first(where: { $0.fullName == fullName }) else { return }
            Task { await model.merge(ref) }
        }

        @objc private func rebaseOntoRef(_ sender: NSMenuItem) {
            guard let fullName = sender.representedObject as? String, let ref = model.refs.refs.first(where: { $0.fullName == fullName }) else { return }
            Task { await model.rebase(onto: ref) }
        }

        @objc private func cherryPick(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String, let commit = model.commit(withID: id) else { return }
            Task { await model.cherryPick(commit) }
        }

        @objc private func checkOut(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String, let commit = model.commit(withID: id) else { return }
            Task { await model.checkOut(commit: commit) }
        }

        @objc private func interactiveRebase(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String, let commit = model.commit(withID: id) else { return }
            model.requestInteractiveRebase(from: commit)
        }

        @objc private func revert(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String, let commit = model.commit(withID: id) else { return }
            Task { await model.revert(commit) }
        }

        @objc private func resetSoft(_ sender: NSMenuItem) { reset(sender, mode: .soft) }
        @objc private func resetMixed(_ sender: NSMenuItem) { reset(sender, mode: .mixed) }
        @objc private func resetHard(_ sender: NSMenuItem) { reset(sender, mode: .hard) }

        private func reset(_ sender: NSMenuItem, mode: GitRepository.ResetMode) {
            guard let id = sender.representedObject as? String, let commit = model.commit(withID: id) else { return }
            model.requestReset(to: commit, mode: mode)
        }
    }
}
