import AppKit
import KaernKit
import SwiftUI

/// The commit graph: Branch / Tag · Graph · Commit Message · Date · Commit, with the working copy
/// on top. Columns can be resized in the header; Search dims the commits that don't match.
struct HistoryView: View {
    @Bindable var repository: RepositoryModel
    /// Focus mode: the working-copy row becomes an inline commit row.
    var isFocused = false
    /// A row was picked (Focus opens its drawer).
    var onPick: () -> Void = {}

    init(repository: RepositoryModel, isFocused: Bool = false, onPick: @escaping () -> Void = {}) {
        self.repository = repository
        self.isFocused = isFocused
        self.onPick = onPick
        // A tab that was scrolled comes back where it was (`restoreAnchor`): its first rows are the
        // ones there, not the top ones, made and then thrown away.
        if let index = repository.historyScrollAnchorIndex {
            _window = State(initialValue: HistoryWindow(range: max(0, index - Self.overscan)..<index + 40))
        }
    }

    @State private var width: CGFloat = 0
    @Environment(\.windowTier) private var tier
    @FocusState private var listFocused: Bool
    @AppStorage("KaernColumnRef", store: .kaern) private var storedRef: Double = ColumnWidths.defaultRef
    @AppStorage("KaernColumnGraph", store: .kaern) private var storedGraph: Double = 0
    @AppStorage("KaernColumnDate", store: .kaern) private var storedDate: Double = ColumnWidths.defaultDate
    @AppStorage("KaernColumnSHA", store: .kaern) private var storedSHA: Double = ColumnWidths.defaultSHA

    private var columns: HistoryColumns {
        HistoryColumns(
            width: width,
            stored: ColumnWidths(ref: storedRef, graph: storedGraph, date: storedDate, sha: storedSHA),
            automaticGraph: GraphMetrics.automaticWidth(for: repository.graph.prefix(300)),
            tier: tier
        )
    }

    /// Where the scroll view is, between updates. Not observed: it changes every frame while
    /// scrolling, and only `window` should redraw the list.
    @MainActor private final class ScrollState {
        var visible = CGRect.zero
        /// The row at the top the last time the anchor was written.
        var anchorIndex = -1
        /// Where the pointer is over the scroll view, from its top left (`nil`: not over it).
        var pointer: CGPoint?
        /// Where the list was scrolled to at the last update, and the step the window moves in.
        var top: CGFloat = 0
        var step = 4
    }

    @State private var position = ScrollPosition(y: 0)
    @State private var scrollState = ScrollState()
    /// The commit rows that exist as views: the visible ones and `overscan` on each side.
    /// Every row has a fixed height, so each is placed by its number and the rest are nothing at
    /// all. (A LazyVStack keeps every row it ever built: jumping to the oldest of 53,000 commits
    /// held ~600 MB.) In an object the list reads and this view doesn't: scrolling on by a few rows
    /// works out the list again, not the header, the bars and everything hung on the scroll view.
    @State private var window = HistoryWindow()
    /// What the rows do when clicked (`HistoryRowActions`).
    @State private var actions = HistoryRowActions()
    @State private var hasAppeared = false

    private static let overscan = 8

    var body: some View {
        let columns = columns
        // As this pass has them (the latest `onPick`).
        actions.click = click
        actions.switchTo = switchTo
        actions.pickWorkingCopy = { pick(.workingCopy) }
        actions.labelList = { [window] id, onList in
            if onList { window.labelListOwner = id } else if window.labelListOwner == id { window.labelListOwner = nil }
        }
        return VStack(spacing: 0) {
            if !repository.picked.isEmpty {
                SelectionBar(repository: repository)
            }
            if repository.hasBotCommits || repository.showsGraphScope {
                GraphBar(repository: repository)
            }
            HistoryHeader(columns: columns, width: width, ref: $storedRef, graph: $storedGraph, date: $storedDate, sha: $storedSHA)
            ScrollView {
                HistoryList(repository: repository, columns: columns, isFocused: isFocused, window: window, actions: actions)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, visible in
                scrollState.visible = visible
                updateWindow()
                updateHover()
            }
            // The hover tint and the list of labels that opens under the pointer. One hover, on the
            // scroll view: the rows have none of their own. SwiftUI finds what the pointer is on again
            // for each scrolled frame, and with a hover anywhere in what scrolls it went through
            // every row to do it, which was two fifths of what scrolling cost.
            .onContinuousHover(coordinateSpace: .local) { phase in
                if case .active(let location) = phase { scrollState.pointer = location } else { scrollState.pointer = nil }
                updateHover()
            }
            .background(K.content)
            .contextClip()
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onCopyCommand {
                // ⌘C in the graph copies the selected commit's SHA (or every picked one).
                let ids = repository.picked.isEmpty ? [repository.selectedCommitID].compactMap { $0 } : repository.picked
                guard !ids.isEmpty else { return [] }
                repository.showToast(ids.count == 1 ? "Copied \(repository.short(ids[0]))" : "Copied \(ids.count) commit hashes")
                return [NSItemProvider(object: ids.joined(separator: " ") as NSString)]
            }
            // ↑ ↓ move the selection; ⇧↑ ⇧↓ pick a range, as ⇧-click does. Held down, they keep going.
            .onKeyPress(.upArrow, phases: [.down, .repeat]) { press in press.modifiers.contains(.shift) ? extend(-1) : move(-1) }
            .onKeyPress(.downArrow, phases: [.down, .repeat]) { press in press.modifiers.contains(.shift) ? extend(1) : move(1) }
            .onKeyPress(.return) {
                // Return opens the selection in Review (Keyboard Shortcuts › In the Graph).
                guard repository.canReview else { return .ignored }
                repository.review = ReviewState(showsAllFiles: true)
                return .handled
            }
            .onAppear {
                // The first time only: a tab that shows again has its list where it was.
                if !hasAppeared { restoreAnchor() }
                hasAppeared = true
                focusUnlessTyping()
            }
            .onChange(of: repository.historyFocusRequest) { listFocused = true }
            .onChange(of: repository.displayCommits.count) { updateWindow() }
            .onChange(of: repository.scrollRequest) { _, request in
                if let request { center(request.id) }
            }
        }
        .background(K.content)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    // MARK: Scrolling

    private var workingCopyHeight: CGFloat { repository.showsWorkingCopy ? KMetric.wipRow : 0 }

    private func top(ofRow index: Int) -> CGFloat {
        workingCopyHeight + CGFloat(index) * KMetric.graphRow
    }

    /// Moves the window to the visible rows, writes the row at the top (a tab coming back opens
    /// there) and reads more history near the end.
    private func updateWindow() {
        let visible = scrollState.visible
        guard visible.height > 0 else { return }
        let count = repository.displayCommits.count
        let first = max(0, Int(((visible.minY - workingCopyHeight) / KMetric.graphRow).rounded(.down)))
        let last = max(first, Int(((visible.maxY - workingCopyHeight) / KMetric.graphRow).rounded(.up)))
        // The window moves in steps. A step costs about the same whatever it brings in, and a row
        // that comes in costs its own: a row at a time when the list moves slowly (each step fits
        // in a frame), more at a time when it moves fast (fewer steps, each a little late).
        let moved = abs(visible.minY - scrollState.top)
        scrollState.top = visible.minY
        if moved > 0 { scrollState.step = moved < KMetric.graphRow / 2 ? 1 : moved < KMetric.graphRow * 1.5 ? 2 : 4 }
        let step = scrollState.step
        let lower = max(0, (first - Self.overscan) / step * step)
        let upper = min(count, (last + Self.overscan) / step * step + step)
        let next = lower..<max(lower, upper)
        if next != window.range { window.range = next }
        // The row more than half in view at the top; nil while the working copy is.
        let anchor = Int(((visible.minY + KMetric.graphRow / 2 - workingCopyHeight) / KMetric.graphRow).rounded(.down))
        if anchor != scrollState.anchorIndex {
            scrollState.anchorIndex = anchor
            let atTop = visible.minY + KMetric.graphRow / 2 < workingCopyHeight || anchor >= count
            repository.historyScrollAnchor = atTop ? nil : repository.displayCommits[max(0, anchor)].id
            repository.historyScrollAnchorIndex = atTop ? nil : max(0, anchor)
        }
        if last >= count - 40 { repository.loadMoreHistory() }
        // ScreenMarks: the shields of the rows in view.
        if window.range.lowerBound < count {
            repository.loadSignatures(for: repository.displayCommits[window.range.clamped(to: 0..<count)].map(\.id))
        }
    }

    /// The commit row under the pointer, as the list is scrolled now, and where in the row it is.
    private func updateHover() {
        var row: Int?
        var inRow: CGPoint?
        if let pointer = scrollState.pointer {
            let inList = pointer.y + scrollState.visible.minY - workingCopyHeight
            let index = Int((inList / KMetric.graphRow).rounded(.down))
            if inList >= 0, index < repository.displayCommits.count {
                row = index
                inRow = CGPoint(x: pointer.x, y: inList - CGFloat(index) * KMetric.graphRow)
            }
        }
        if window.hovered != row { window.hovered = row }
        if window.pointerInRow != inRow { window.pointerInRow = inRow }
    }

    /// Back on this tab: the row that was at the top is at the top again.
    private func restoreAnchor() {
        let shown = repository.displayCommits
        guard let anchor = repository.historyScrollAnchor, let index = shown.firstIndex(where: { $0.id == anchor }) else { return }
        window.range = max(0, index - Self.overscan)..<min(shown.count, index + 40)
        position.scrollTo(y: top(ofRow: index))
    }

    /// Scrolls a commit (or the folded run it's in) to the middle: a search match, Quick Open, a
    /// parent link. Far jumps don't animate.
    private func center(_ id: String) {
        let shown = repository.displayCommits
        let target = repository.insideRun[id] ?? id
        guard let index = shown.firstIndex(where: { $0.id == target }) else { return }
        let visible = scrollState.visible
        let contentHeight = top(ofRow: shown.count)
        let y = min(max(0, top(ofRow: index) - (visible.height - KMetric.graphRow) / 2), max(0, contentHeight - visible.height))
        if abs(y - visible.minY) > visible.height * 3 {
            window.range = max(0, index - 40)..<min(shown.count, index + 40)
            position.scrollTo(y: y)
        } else {
            withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(y: y) }
        }
    }

    /// Scrolls just enough to show a row (↑ / ↓).
    private func reveal(top y: CGFloat, height: CGFloat) {
        let visible = scrollState.visible
        if y < visible.minY {
            position.scrollTo(y: y)
        } else if y + height > visible.maxY {
            position.scrollTo(y: y + height - visible.height)
        }
    }

    /// Shown again (back from Review, a stash or Explore, another tab): ↑ ↓ work without a click
    /// first, unless something is being typed in. Next turn: the list can't take focus yet.
    private func focusUnlessTyping() {
        DispatchQueue.main.async {
            guard !(NSApp.keyWindow?.firstResponder is NSTextView) else { return }
            listFocused = true
        }
    }

    private func pick(_ selection: HistorySelection) {
        repository.clearPicks()
        // A row picked while a worktree's page is open goes back to the row's details.
        repository.selectedWorktree = nil
        repository.selection = selection
        listFocused = true
        onPick()
    }

    /// A double-click on a label does what one in the sidebar does: a branch's switches to it, a
    /// remote branch's checks out a local branch that tracks it, and a branch checked out in another
    /// worktree opens that worktree in a tab of its own. The branch you're on and tags do nothing.
    private func switchTo(_ label: RefLabelItem) {
        switch label.kind {
        case .branch where label.isHead:
            break
        case .branch:
            if let tree = repository.otherWorktree(checkingOut: label.title) {
                repository.openWorktree(tree.path)
            } else {
                repository.from("History › double-click branch") { repository.switchBranch(label.title) }
            }
        case .remote:
            guard let ref = repository.refs.remoteBranches.first(where: { $0.name == label.title }) else { return }
            repository.from("History › double-click remote branch") { repository.checkoutRemoteBranch(ref) }
        case .tag:
            break
        }
    }

    /// A click on a commit: ⌘ adds it to the picked commits, ⇧ picks a range.
    private func click(_ id: String) {
        let flags = NSEvent.modifierFlags
        let command = flags.contains(.command), shift = flags.contains(.shift)
        repository.click(commit: id, command: command, shift: shift)
        listFocused = true
        if !command, !shift { onPick() }
    }

    /// ⇧↑ / ⇧↓: the picked range grows or shrinks at its moving end, which stays in view.
    private func extend(_ step: Int) -> KeyPress.Result {
        guard let end = repository.extendPick(by: step) else { return .ignored }
        if let index = repository.displayCommits.firstIndex(where: { $0.id == end }) {
            reveal(top: top(ofRow: index), height: KMetric.graphRow)
        }
        listFocused = true
        return .handled
    }

    /// ↑ / ↓ move the selection through the working copy and the commits (a folded run is
    /// stepped over).
    private func move(_ step: Int) -> KeyPress.Result {
        let shown = repository.displayCommits
        var ids: [HistorySelection] = repository.showsWorkingCopy ? [.workingCopy] : []
        ids += shown.filter { repository.botRuns[$0.id] == nil }.map { .commit($0.id) }
        guard !ids.isEmpty else { return .ignored }
        let current = ids.firstIndex(of: repository.selection) ?? (step > 0 ? -1 : ids.count)
        let next = min(max(current + step, 0), ids.count - 1)
        let selection = ids[next]
        repository.clearPicks()
        repository.selection = selection
        switch selection {
        case .workingCopy:
            reveal(top: 0, height: KMetric.wipRow)
        case .commit(let id):
            if let index = shown.firstIndex(where: { $0.id == id }) { reveal(top: top(ofRow: index), height: KMetric.graphRow) }
        }
        onPick()
        return .handled
    }
}

/// The commit rows that exist as views (`HistoryView.window`).
@MainActor @Observable
fileprivate final class HistoryWindow {
    var range: Range<Int>

    init(range: Range<Int> = 0..<40) {
        self.range = range
    }

    /// The commit row the pointer is on (its number), for the hover tint.
    var hovered: Int?
    /// Where the pointer is in that row. Only a row with several labels reads it (they open as a
    /// list under the pointer), so the pointer moving over the others redraws nothing.
    var pointerInRow: CGPoint?
    /// The commit whose list of labels the pointer is on: the list lies over the rows below its own,
    /// and the pointer on it is on its row, not on those.
    var labelListOwner: String?
}

/// The working copy and the rows in the window, each where its number puts it (`HistoryRows`).
/// What the rows show is read here, not in `HistoryView`: a selection, a signature that came in
/// or the window moving on works out this list, and of its rows only the ones that changed.
private struct HistoryList: View {
    let repository: RepositoryModel
    let columns: HistoryColumns
    /// Focus mode: the working-copy row becomes an inline commit row.
    let isFocused: Bool
    let window: HistoryWindow
    let actions: HistoryRowActions

    var body: some View {
        let shown = repository.displayCommits
        let range = window.range.clamped(to: 0..<shown.count)
        let offset = repository.showsWorkingCopy ? 1 : 0
        let headBranch = repository.currentBranch
        let picked = Set(repository.picked)
        let comparison = repository.comparison?.key == repository.comparisonKey ? repository.comparison : nil
        let worktreeBranches = repository.branchesInOtherWorktrees
        let top = repository.showsWorkingCopy ? KMetric.wipRow : 0
        let hovered = window.labelListOwner == nil ? window.hovered : nil
        HistoryRows(count: shown.count, top: top) {
            if repository.showsWorkingCopy, let row = repository.graph.first {
                WorkingCopyRow(repository: repository, graph: row, columns: columns, inline: isFocused,
                               isSelected: repository.selection == .workingCopy && repository.picked.isEmpty
                                   && repository.branchCompare == nil,
                               isDimmed: repository.search.isFiltering, actions: actions)
                    .layoutValue(key: HistorySlot.self, value: .top)
            }
            ForEach(range.map { (index: $0, commit: shown[$0]) }, id: \.commit.id) { item in
                let index = item.index, commit = item.commit
                let graphIndex = index + offset
                let row = repository.graph.indices.contains(graphIndex) ? repository.graph[graphIndex] : nil
                if let run = repository.botRuns[commit.id] {
                    // ScreenBigRepo: a run of bot commits as one row; the chevron opens it.
                    BotRunRow(repository: repository, run: run, graph: row, isAlternate: index % 2 == 1,
                              isHovered: hovered == index, isDimmed: repository.search.isFiltering, columns: columns)
                        .layoutValue(key: HistorySlot.self, value: .row(index))
                } else {
                    CommitRow(
                        commit: commit,
                        graph: row,
                        labels: RefLabelItem.labels(for: repository.refs.refs(at: commit.id), headBranch: headBranch,
                                                    worktrees: worktreeBranches),
                        signature: repository.signatureMark(of: commit.id),
                        isAlternate: index % 2 == 1,
                        isSelected: picked.isEmpty
                            ? repository.branchCompare == nil && repository.selection == .commit(commit.id)
                            : picked.contains(commit.id),
                        isHovered: hovered == index || window.labelListOwner == commit.id,
                        pointerInRow: window.hovered == index && repository.refs.refs(at: commit.id).count > 1 ? window.pointerInRow : nil,
                        isDimmed: repository.search.isDimmed(commit.id),
                        tint: CommitRow.Tint(comparison: comparison, id: commit.id),
                        columns: columns,
                        actions: actions
                    )
                    .layoutValue(key: HistorySlot.self, value: .row(index))
                }
            }
            HistoryEnd(repository: repository, columns: columns, hasRows: !shown.isEmpty)
                .layoutValue(key: HistorySlot.self, value: .end)
        }
    }
}

/// Where a view of the history's list goes (`HistoryRows`).
nonisolated private enum HistoryRowSlot: Equatable {
    /// The working copy, on top.
    case top
    /// A commit row, by its number in the list.
    case row(Int)
    /// What follows the last row (`HistoryEnd`).
    case end
}

nonisolated private struct HistorySlot: LayoutValueKey {
    static let defaultValue = HistoryRowSlot.end
}

/// The history's rows, each placed by its number: every commit row is as tall as the others, so a
/// row's place doesn't depend on any other view, and the rows that aren't views (the list keeps
/// only the ones near the visible part) are space the list doesn't have to stand in for.
///
/// A stack with a spacer above and below the rows did the same, but asked every row for its size
/// again each time the spacers changed, which is each time the visible rows moved on.
private struct HistoryRows: Layout {
    /// How many commit rows the list has (most of them aren't views).
    var count: Int
    /// The working copy row's height, 0 without one.
    var top: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        var end: CGFloat = 0
        for subview in subviews where subview[HistorySlot.self] == .end {
            end += subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        return CGSize(width: width, height: top + CGFloat(count) * KMetric.graphRow + end)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var end = bounds.minY + top + CGFloat(count) * KMetric.graphRow
        for subview in subviews {
            switch subview[HistorySlot.self] {
            // Centered, as the stack had them: a row a point wider than a narrow window's list sits
            // half a point to each side, and the spinner is narrower than the list.
            case .top:
                subview.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: ProposedViewSize(width: bounds.width, height: top))
            case .row(let index):
                subview.place(at: CGPoint(x: bounds.midX, y: bounds.minY + top + CGFloat(index) * KMetric.graphRow), anchor: .top,
                              proposal: ProposedViewSize(width: bounds.width, height: KMetric.graphRow))
            case .end:
                let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subview.place(at: CGPoint(x: bounds.midX, y: end), anchor: .top, proposal: ProposedViewSize(width: bounds.width, height: nil))
                end += size.height
            }
        }
    }
}

/// What follows the last row: the spinner while a page of older history is read, or the end of a
/// shallow clone. A view of its own, so a page being read redraws this and not every row.
private struct HistoryEnd: View {
    let repository: RepositoryModel
    let columns: HistoryColumns
    let hasRows: Bool

    var body: some View {
        if repository.isLoadingMoreHistory {
            ProgressView().controlSize(.small).padding(z(8))
        } else if repository.isShallow, !repository.hasMoreHistory, hasRows {
            ShallowEndRow(repository: repository, columns: columns,
                          lane: repository.graph.last?.lane ?? 0)
        }
    }
}

/// `.shend`: where a shallow clone's history stops (ScreenBigRepo): a dashed line under the last
/// commit, what the clone has, Fetch 100 More and Fetch Full History.
private struct ShallowEndRow: View {
    let repository: RepositoryModel
    let columns: HistoryColumns
    let lane: Int

    var body: some View {
        let count = repository.commits.count
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: columns.ref, height: 1)
            Path { path in
                let x = GraphMetrics.x(lane: lane)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: 30))
            }
            .stroke(K.lane(lane), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [3, 3]))
            .frame(width: columns.graph, height: z(40), alignment: .topLeading)
            VStack(alignment: .leading, spacing: z(8)) {
                Text("History stops here. This clone has the newest \(count.formatted()) \(count == 1 ? "commit" : "commits") (git clone --depth \(count)).")
                    .font(.system(size: z(12.5)))
                    .foregroundStyle(K.label2)
                    .fixedSize(horizontal: false, vertical: true)
                if let activity = repository.activity, activity.statusText.hasPrefix("Fetching") {
                    HStack(spacing: z(8)) {
                        ProgressView().controlSize(.small)
                        Text(activity.statusText).font(.system(size: z(11.5))).foregroundStyle(K.label2)
                    }
                }
                HStack(spacing: z(6)) {
                    GhostButton(title: "Fetch 100 More") {
                        repository.from("History") { repository.fetchMoreHistory(100) }
                    }
                    GhostButton(title: "Fetch Full History") {
                        repository.from("History") { repository.fetchMoreHistory(nil) }
                    }
                }
                .disabled(repository.activity != nil || repository.remotes.isEmpty)
            }
            .padding(EdgeInsets(top: z(10), leading: z(12), bottom: 0, trailing: z(14)))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, z(14))
        .frame(minHeight: z(92), alignment: .top)
        .overlay(alignment: .top) {
            // `border-top: 1px dashed`.
            GeometryReader { proxy in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0.5))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: 0.5))
                }
                .stroke(K.sepStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .frame(height: 1)
        }
    }
}

// MARK: - Columns

/// The widths the user dragged the columns to (0 for the graph: fit the lanes).
struct ColumnWidths: Equatable {
    var ref: Double
    var graph: Double
    var date: Double
    var sha: Double

    static let defaultRef: Double = 176
    static let defaultDate: Double = 104
    static let defaultSHA: Double = 72
    static let refRange: ClosedRange<Double> = 60...420
    static let graphRange: ClosedRange<Double> = 40...600
    static let dateRange: ClosedRange<Double> = 60...240
    static let shaRange: ClosedRange<Double> = 50...160
}

/// Which columns fit and how wide they are: the hash goes first, then the date, then the label
/// column narrows (the Narrow board folds the window in that order).
struct HistoryColumns: Equatable {
    var ref: CGFloat
    var graph: CGFloat
    var date: CGFloat
    var sha: CGFloat
    var showsDate = true
    var showsSHA = true
    /// "2h", "1d" (ScreenNarrow < 1,180 pt).
    var compactDates = false
    /// The gray description after the subject (hidden under 860 pt).
    var showsDescriptions = true

    /// `width` and `automaticGraph` are what's on screen. The stored widths and the widths the
    /// columns fold at are the design's: the columns are worked out at actual size, then set at the zoom.
    init(width: CGFloat, stored: ColumnWidths, automaticGraph: CGFloat, tier: NarrowTier = .wide) {
        let scale = UIScale.value
        let width = width / scale
        var ref = CGFloat(stored.ref)
        var date = CGFloat(stored.date)
        // The window folds in the Narrow board's order; the history's own width still decides
        // when panels leave it little room.
        if tier >= .shortDates {
            compactDates = true
            date = min(date, 58)
        }
        if tier >= .panelOverlay { ref = min(ref, 132) }
        if tier >= .compact { showsDescriptions = false }
        showsSHA = tier < .noHash
        showsDate = tier < .compact
        if width > 0 {
            showsSHA = showsSHA && width >= 734
            showsDate = showsDate && width >= 560
            if width < 520 { ref = min(ref, 124) }
        }
        // Whole points: a column dragged to 163.3 would put every row's lanes and texts between
        // pixels (the header's borders too).
        self.ref = (ref * scale).rounded()
        graph = (stored.graph > 0 ? CGFloat(stored.graph) * scale : automaticGraph).rounded()
        self.date = (date * scale).rounded()
        sha = (CGFloat(stored.sha) * scale).rounded()
    }
}

/// The column titles, with a resize handle on each border that's draggable.
private struct HistoryHeader: View {
    let columns: HistoryColumns
    let width: CGFloat
    @Binding var ref: Double
    @Binding var graph: Double
    @Binding var date: Double
    @Binding var sha: Double

    var body: some View {
        HStack(spacing: 0) {
            Text("Branch / Tag").padding(.leading, z(10)).frame(width: columns.ref, alignment: .leading)
            Text("Graph").frame(width: columns.graph, alignment: .leading)
            Text("Commit Message").padding(.leading, z(12)).frame(maxWidth: .infinity, alignment: .leading)
            if columns.showsDate {
                Text("Date").frame(width: columns.date, alignment: .leading)
            }
            if columns.showsSHA {
                // The board sets this header in the hash column's monospaced face.
                HStack(spacing: z(5)) {
                    Text("Commit").font(.system(size: z(11.5), design: .monospaced)).fontWeight(.regular)
                    SignatureLegendButton()
                }
                .frame(width: columns.sha, alignment: .leading)
            }
        }
        .font(.system(size: z(11), weight: .semibold))
        .foregroundStyle(K.label2)
        .lineLimit(1)
        .frame(height: z(26))
        .background(K.content)
        .overlay(alignment: .topLeading) { handles }
        .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
    }

    @ViewBuilder
    private var handles: some View {
        ZStack(alignment: .topLeading) {
            ColumnResizeHandle(edge: columns.ref, value: $ref, range: ColumnWidths.refRange, grows: .right,
                               reset: ColumnWidths.defaultRef)
            ColumnResizeHandle(edge: columns.ref + columns.graph, value: Binding(
                get: { graph > 0 ? graph : Double(columns.graph / UIScale.value) }, set: { graph = $0 }
            ), range: ColumnWidths.graphRange, grows: .right, reset: 0)
            if columns.showsDate {
                ColumnResizeHandle(edge: width - (columns.showsSHA ? columns.sha : 0) - columns.date, value: $date,
                                   range: ColumnWidths.dateRange, grows: .left, reset: ColumnWidths.defaultDate)
            }
            if columns.showsSHA {
                ColumnResizeHandle(edge: width - columns.sha, value: $sha, range: ColumnWidths.shaRange, grows: .left,
                                   reset: ColumnWidths.defaultSHA)
            }
        }
        .frame(height: z(26))
    }
}

/// A 9 pt grip over a column border: drag to resize, double-click to go back to the default.
private struct ColumnResizeHandle: View {
    enum Growth { case left, right }

    let edge: CGFloat
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Which way dragging makes the column wider.
    let grows: Growth
    let reset: Double

    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: z(9), height: z(26))
            .overlay {
                if hovering || start != nil {
                    K.sepStrong.frame(width: 1, height: z(14))
                }
            }
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let base = start ?? value
                        if start == nil { start = value }
                        // The stored width is the design's: the drag is on screen, at the zoom.
                        let delta = Double(drag.translation.width / UIScale.value) * (grows == .right ? 1 : -1)
                        value = min(max(base + delta, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in start = nil }
            )
            .onTapGesture(count: 2) { value = reset }
            .offset(x: edge - z(4.5))
            .accessibilityHidden(true)
    }
}

// MARK: - Rows

/// What the history's rows do when clicked: one object, the same for as long as the list lives. A
/// row handed a closure made new on every pass looks changed to SwiftUI, so selecting one commit or
/// scrolling on by a row worked all of them out again.
@MainActor
fileprivate final class HistoryRowActions {
    var click: (String) -> Void = { _ in }
    var switchTo: (RefLabelItem) -> Void = { _ in }
    var pickWorkingCopy: () -> Void = {}
    /// The pointer came onto a commit's list of labels, or left it.
    var labelList: (String, Bool) -> Void = { _, _ in }
}

/// A commit row's picture: its background, the graph with the commit's node, the subject and the
/// description, the date and the hash, drawn in one Canvas.
///
/// As views these were about eighty per row, and making, laying out and comparing them was most
/// of what scrolling the history and switching to a tab cost. The drawing puts every piece where
/// the views were, to the pixel (compared row by row, in every state and at many widths, when it
/// was written: on a width that isn't whole points only the row's last pixel column differed).
private struct CommitRowDrawing: View, Equatable {
    let commit: Commit
    let graph: GraphRow?
    /// The label column has a label: its line carries on to the node.
    let hasLabels: Bool
    let isSelected: Bool
    let isAlternate: Bool
    let isHovered: Bool
    let tint: CommitRow.Tint
    let columns: HistoryColumns
    /// Without a signature the hash is drawn here; with one, the row shows hash and shield as views.
    let drawsHash: Bool
    /// Search is filtering and this commit doesn't match (`.dim`).
    let isDimmed: Bool

    /// The sizes the row is drawn with (the Tokens board's, as the views had them).
    private enum Metric {
        static var textSize: CGFloat { z(13) }
        static var messageLeading: CGFloat { z(12) }
        static var messageTrailing: CGFloat { z(14) }
        static var descriptionGap: CGFloat { z(6) }
        static var laneBarWidth: CGFloat { z(2.5) }
        static var laneBarInset: CGFloat { z(5) }
        static var tintBarWidth: CGFloat { z(3) }
    }

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .accessibilityElement()
        .accessibilityLabel([commit.subject, commit.bodyPreview, dateText, commit.shortID].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private var dateText: String {
        columns.compactDates ? Formatters.compactDate(commit.author.date) : Formatters.historyDate(commit.author.date)
    }

    private var background: Color { isSelected ? K.sel : (isAlternate ? K.alt : K.content) }
    private var secondary: Color { isSelected ? .white.opacity(0.85) : K.label2 }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        // Views sit on whole pixels; what is drawn here is put on them the same way.
        let scale = context.environment.displayScale
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let height = size.height
        let whole = Path(CGRect(origin: .zero, size: size))
        // A dimmed row's pieces are each see-through, as the views were (not the row as one
        // picture made see-through: where pieces lie over each other that looks different).
        context.opacity = isDimmed ? CommitRow.dimmedOpacity : 1

        // `.row`, `.row:hover`, `.inr`.
        if tint == .inRange, !isSelected {
            context.fill(whole, with: .color(K.content))
            context.fill(whole, with: .color(K.accentSoft))
        } else if isHovered, !isSelected {
            context.fill(whole, with: .color(K.content))
            context.fill(whole, with: .color(K.hover))
        } else {
            context.fill(whole, with: .color(background))
        }

        let lane = graph?.lane ?? 0
        let isMerge = graph?.isMerge ?? commit.isMerge
        let graphX = snap(columns.ref)
        let messageX = snap(columns.ref + columns.graph)
        let shaX = snap(size.width - (columns.showsSHA ? columns.sha : 0))
        let dateX = snap(size.width - (columns.showsSHA ? columns.sha : 0) - (columns.showsDate ? columns.date : 0))

        // The graph cell: the label's line under the lanes, the lanes, the node.
        do {
            var cell = context
            cell.clip(to: Path(CGRect(x: graphX, y: 0, width: columns.graph, height: height)))
            cell.translateBy(x: graphX, y: 0)
            let nodeX = GraphMetrics.x(lane: lane)
            if hasLabels {
                let line = CGRect(x: 0, y: height / 2 - GraphMetrics.labelLineWidth / 2,
                                  width: max(0, nodeX - z(isMerge ? 7 : 12.5)), height: GraphMetrics.labelLineWidth)
                cell.fill(Path(line), with: .color(isSelected ? Color.white.opacity(0.75) : K.lane(lane)))
            }
            // The lanes are one picture (they were a Canvas of their own).
            if let graph { cell.drawLayer { lines in GraphLines.draw(graph, in: &lines, height: height) } }
            let center = CGPoint(x: nodeX, y: height / 2)
            // `diameter` is the design's.
            func disc(_ design: CGFloat, _ color: Color) {
                let diameter = z(design)
                let rect = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
                cell.fill(Path(ellipseIn: rect), with: .color(color))
            }
            if isMerge {
                disc(14, background)
                disc(10, K.lane(lane))
            } else {
                disc(25, K.lane(lane))
                disc(21, background)
                disc(18, AvatarPalette.color(for: commit.author.email.isEmpty ? commit.author.name : commit.author.email))
                let initials = cell.resolve(Text(commit.author.initials).font(.system(size: z(7.5), weight: .bold)).tracking(0.2).foregroundStyle(.white))
                let fits = initials.measure(in: CGSize(width: CGFloat.infinity, height: .infinity))
                let rect = CGRect(x: snap(graphX + center.x - fits.width / 2) - graphX, y: snap(center.y - fits.height / 2),
                                  width: fits.width, height: fits.height)
                if isDimmed { cell.drawLayer { $0.draw(initials, in: rect) } } else { cell.draw(initials, in: rect) }
            }
        }

        let body = Font.system(size: Metric.textSize)
        let subject = Text(commit.subject).font(body).foregroundStyle(isSelected ? Color.white : K.label)

        // The lane's bar at the message's edge: as tall as the line of text, less its inset.
        let textHeight = context.resolve(subject).measure(in: CGSize(width: CGFloat.infinity, height: height)).height
        let bar = CGRect(x: messageX, y: snap((height - textHeight) / 2) + Metric.laneBarInset,
                         width: Metric.laneBarWidth, height: textHeight - Metric.laneBarInset * 2)
        context.fill(Path(roundedRect: bar, cornerRadius: z(2)), with: .color(isSelected ? Color.white : K.lane(lane)))

        // One line of text, cut with "…" where its room ends, centered in the row.
        @discardableResult
        func line(_ text: Text, at x: CGFloat, width: CGFloat) -> CGFloat {
            guard width > 0 else { return 0 }
            let resolved = context.resolve(text)
            let fits = resolved.measure(in: CGSize(width: width, height: height))
            let single = resolved.measure(in: CGSize(width: CGFloat.infinity, height: height)).height
            let rect = CGRect(x: snap(x), y: snap((height - single) / 2), width: width, height: single)
            // Dimmed, the text is drawn whole and then made see-through, as a text view is.
            if isDimmed { context.drawLayer { $0.draw(resolved, in: rect) } } else { context.draw(resolved, in: rect) }
            return min(fits.width, width)
        }

        // The subject, then the description in what is left of the message's room.
        let textX = messageX + Metric.messageLeading
        // (Its room as the layout had it, not from where the date was put on a pixel.)
        let messageEnd = size.width - (columns.showsSHA ? columns.sha : 0) - (columns.showsDate ? columns.date : 0)
        let room = messageEnd - (columns.ref + columns.graph) - Metric.messageLeading - Metric.messageTrailing
        if columns.showsDescriptions, !commit.bodyPreview.isEmpty {
            let description = Text(commit.bodyPreview).font(body).foregroundStyle(secondary)
            // The subject comes first (`layoutPriority`): it gets all but the least the description takes.
            let least = context.resolve(description).measure(in: CGSize(width: 0, height: height)).width
            let used = line(subject, at: textX, width: room - Metric.descriptionGap - least)
            line(description, at: textX + used + Metric.descriptionGap, width: room - used - Metric.descriptionGap)
        } else {
            line(subject, at: textX, width: room)
        }

        if columns.showsDate {
            line(Text(dateText).font(body).foregroundStyle(secondary), at: dateX, width: columns.date)
        }
        if columns.showsSHA, drawsHash {
            line(Text(commit.shortID).font(KFont.hash).foregroundStyle(secondary), at: shaX, width: columns.sha)
        }

        // `.ahd`, `.bhd`: only on this branch, only on the other one.
        if !isSelected, tint == .ours || tint == .theirs {
            context.fill(Path(CGRect(x: 0, y: 0, width: Metric.tintBarWidth, height: height)), with: .color(tint == .ours ? K.accent : K.lane2))
        }
    }
}

/// A row is the same while what it shows is: SwiftUI then leaves it alone.
extension CommitRow: Equatable {
    static func == (a: CommitRow, b: CommitRow) -> Bool {
        a.isSelected == b.isSelected && a.isHovered == b.isHovered && a.pointerInRow == b.pointerInRow && a.isAlternate == b.isAlternate
            && a.isDimmed == b.isDimmed && a.tint == b.tint && a.signature == b.signature && a.actions === b.actions && a.columns == b.columns && a.commit == b.commit
            && a.graph == b.graph && a.labels == b.labels
    }
}

extension BotRunRow: Equatable {
    static func == (a: BotRunRow, b: BotRunRow) -> Bool {
        a.isAlternate == b.isAlternate && a.isHovered == b.isHovered && a.isDimmed == b.isDimmed && a.repository === b.repository
            && a.columns == b.columns
            && a.graph == b.graph && a.run == b.run
    }
}

/// The working-copy row (34 pt): a dashed node and "Uncommitted changes" with file and staged
/// counts. In Focus it's an inline commit row: the change count, a summary field and Commit.
private struct WorkingCopyRow: View {
    @Bindable var repository: RepositoryModel
    let graph: GraphRow
    let columns: HistoryColumns
    let inline: Bool
    let isSelected: Bool
    let isDimmed: Bool
    let actions: HistoryRowActions

    private func pick() { actions.pickWorkingCopy() }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: columns.ref)
            ZStack(alignment: .topLeading) {
                GraphLines(row: graph, height: KMetric.wipRow, dashColor: isSelected ? .white.opacity(0.8) : K.wip)
                WorkingCopyNode(selected: isSelected)
                    .offset(x: GraphMetrics.x(lane: graph.lane) - z(9), y: KMetric.wipRow / 2 - z(9))
            }
            .frame(width: columns.graph, height: KMetric.wipRow, alignment: .topLeading)
            .clipped()
            if inline {
                inlineForm
            } else {
                HStack(spacing: z(6)) {
                    Text("Uncommitted changes").font(.system(size: z(13), weight: .semibold))
                        .layoutPriority(-1)
                    WorkingChip(text: Formatters.count(repository.changeCount, "file", "files"), selected: isSelected)
                    if repository.statusIsFull { WorkingChip(text: "\(repository.stagedCount) staged", selected: isSelected) }
                }
                .padding(.leading, z(12))
                .padding(.trailing, z(14))
                .frame(maxWidth: .infinity, alignment: .leading)
                if columns.showsDate {
                    Text(columns.compactDates ? "now" : "Now")
                        .foregroundStyle(isSelected ? .white.opacity(0.85) : K.label2)
                        .frame(width: columns.date, alignment: .leading)
                }
                if columns.showsSHA {
                    Color.clear.frame(width: columns.sha)
                }
            }
        }
        .font(.system(size: z(13)))
        .foregroundStyle(isSelected ? .white : K.label)
        .lineLimit(1)
        .frame(height: KMetric.wipRow)
        .background(isSelected ? K.sel : K.content)
        .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(perform: pick)
        .opacity(isDimmed ? 0.3 : 1)
    }

    /// `.wsel` + `.wipform`: "13 changes [3 staged]", the summary with its counter, Commit.
    private var inlineForm: some View {
        HStack(spacing: 0) {
            Button(action: pick) {
                HStack(spacing: z(6)) {
                    Text(Formatters.count(repository.changeCount, "change", "changes"))
                        .font(.system(size: z(13), weight: .semibold))
                    WorkingChip(text: "\(repository.stagedCount) staged", selected: isSelected)
                }
                .padding(.horizontal, z(8))
                .frame(height: z(26))
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverPlateStyle(radius: z(7), selected: isSelected))
            HStack(spacing: z(8)) {
                HStack(spacing: z(6)) {
                    TextField("Commit summary", text: $repository.composer.summary)
                        .textFieldStyle(.plain)
                        .font(.system(size: z(13), weight: .semibold))
                        .foregroundStyle(K.label)
                        .onSubmit { repository.commit() }
                    SummaryCounter(count: repository.composer.summary.count)
                }
                .padding(.horizontal, z(9))
                .frame(height: z(26))
                .background(RoundedRectangle(cornerRadius: z(7), style: .continuous).fill(K.field))
                .overlay(RoundedRectangle(cornerRadius: z(7), style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5))
                Button { repository.commit() } label: {
                    Text(repository.status.stagedCount == 0 && !repository.composer.amend ? "Commit" : repository.commitButtonTitle)
                        .font(.system(size: z(13), weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, z(12))
                        .frame(height: z(26))
                        .background(RoundedRectangle(cornerRadius: z(7), style: .continuous).fill(K.accent))
                }
                .buttonStyle(.plain)
                .disabled(!repository.canCommit)
                .opacity(repository.canCommit ? 1 : 0.45)
            }
            .padding(.horizontal, z(12))
            .frame(maxWidth: .infinity)
        }
        .padding(.leading, z(4))
    }
}

/// `.wchip`: a small count pill in the working-copy row.
private struct WorkingChip: View {
    let text: String
    let selected: Bool

    var body: some View {
        Text(text)
            .font(.system(size: z(11), weight: .semibold))
            .foregroundStyle(selected ? .white : K.label2)
            .padding(.horizontal, z(7))
            .frame(height: z(18))
            .background(Capsule().fill(selected ? Color.white.opacity(0.22) : K.hover))
            .fixedSize()
    }
}

/// "38/72": the summary's length against the 72 characters a summary should stay under.
struct SummaryCounter: View {
    let count: Int

    var body: some View {
        Text("\(count)/\(CommitDraft.summaryLimit)")
            .font(.system(size: z(11)))
            .monospacedDigit()
            .foregroundStyle(count > CommitDraft.summaryLimit ? K.warn : K.label2)
            .fixedSize()
    }
}

/// One commit (28 pt).
private struct CommitRow: View {
    let commit: Commit
    let graph: GraphRow?
    let labels: [RefLabelItem]
    /// The signature's shield after the hash (`nil`: unsigned, or not read yet).
    var signature: SignatureMark?
    let isAlternate: Bool
    let isSelected: Bool
    /// The pointer is on the row (the list tells: `HistoryList`).
    let isHovered: Bool
    /// Where the pointer is in the row, told while it's on a row with several labels.
    var pointerInRow: CGPoint?
    let isDimmed: Bool
    var tint: Tint = .none
    let columns: HistoryColumns
    /// A click on the row, and a double-click on one of its labels, here or in its list.
    let actions: HistoryRowActions
    /// How see-through a commit is that the search doesn't match.
    static let dimmedOpacity = 0.3
    private var dim: Double { isDimmed ? Self.dimmedOpacity : 1 }

    private func switchTo(_ label: RefLabelItem) { actions.switchTo(label) }

    /// Compare marks: between two picked commits (`.inr`), only on the current branch (`.ahd`)
    /// or only on the other one (`.bhd`).
    enum Tint: Equatable {
        case none, inRange, ours, theirs

        init(comparison: Comparison?, id: String) {
            guard let comparison else { self = .none; return }
            if comparison.rangeIDs.contains(id) { self = .inRange }
            else if comparison.oursIDs.contains(id) { self = .ours }
            else if comparison.theirsIDs.contains(id) { self = .theirs }
            else { self = .none }
        }
    }

    /// Several refs here and the pointer on their label: every label shows, in a list that unfolds
    /// from it (`RefLabelList`).
    @State private var showsAllLabels = false
    @State private var pointerOnLabels = false
    @State private var pointerOnList = false
    @State private var labelsTimer: Task<Void, Never>?
    /// How big the row shows its first label and "+N": the list is at least as wide, so it covers
    /// them and the pointer that opened it is on it.
    @State private var shownLabelsSize = CGSize.zero
    private var shownLabelsWidth: CGFloat { shownLabelsSize.width }

    /// The pointer is on the first label or "+N" (they sit 10 pt in, centered in the row).
    private var pointerIsOnLabels: Bool {
        guard labels.count > 1, let pointerInRow else { return false }
        return CGRect(x: 10, y: (KMetric.graphRow - shownLabelsSize.height) / 2, width: shownLabelsSize.width, height: shownLabelsSize.height)
            .contains(pointerInRow)
    }

    private var lane: Int { graph?.lane ?? 0 }

    var body: some View {
        drawn
        // The whole row takes the pointer, its empty parts too. Only the row: the list of labels lies
        // outside it, over other rows, and takes the pointer there (it is this row's, above the others).
        .contentShape(Rectangle())
        .overlay(alignment: .topLeading) {
            // Over the whole row: its node and lanes too. The first label sits where the column has it.
            if listShown {
                RefLabelList(labels: labels, lane: lane, origin: CGPoint(x: 10, y: (KMetric.graphRow - RefLabelList.labelHeight) / 2),
                             minWidth: shownLabelsWidth, switchTo: switchTo) {
                    pointer(onList: $0)
                }
                .opacity(dim)
                .transition(.opacity)
            }
        }
        // (A dimmed row: the drawing dims its own pieces, the views over it where they are made.)
        .contextTarget(.commit(commit.id))
        .help("\(commit.subject)\n\(commit.author.name) · \(commit.shortID)")
        // The list of labels lies over the rows below.
        .zIndex(listShown ? 1 : 0)
        // The pointer on the list is on this row (`HistoryWindow.labelListOwner`).
        .onChange(of: pointerOnList && listShown) { _, onList in actions.labelList(commit.id, onList) }
        .onChange(of: pointerIsOnLabels) { _, inside in pointer(onLabels: inside) }
        // Beside a label's double-click (which switches), not after it: the click picks the
        // commit at once instead of waiting to see whether a second one follows.
        .simultaneousGesture(TapGesture().onEnded { actions.click(commit.id) })
    }

    /// The row as one drawing (`CommitRowDrawing`), with the parts that are more than a picture
    /// on top as views: the labels (they open a list, take double-clicks and have menus) and a
    /// signature's shield with its tooltip.
    private var drawn: some View {
        CommitRowDrawing(commit: commit, graph: graph, hasLabels: !labels.isEmpty, isSelected: isSelected, isAlternate: isAlternate,
                         isHovered: isHovered, tint: tint, columns: columns, drawsHash: signature == nil, isDimmed: isDimmed)
            .frame(height: KMetric.graphRow)
            .overlay(alignment: .leading) {
                if !labels.isEmpty {
                    Color.clear
                        .frame(width: columns.ref, height: KMetric.graphRow)
                        .overlay(alignment: .leading) { refColumn }
                        .opacity(dim)
                }
            }
            .overlay(alignment: .trailing) {
                if let signature, columns.showsSHA { hashCell(signature).opacity(dim) }
            }
            .font(.system(size: z(13)))
            .foregroundStyle(isSelected ? .white : K.label)
            .lineLimit(1)
    }

    /// The hash with a signature's shield (`.sig`): in its color, white on the selected row.
    private func hashCell(_ signature: SignatureMark) -> some View {
        HStack(spacing: z(5)) {
            Text(commit.shortID)
                .font(KFont.hash)
                .foregroundStyle(isSelected ? .white.opacity(0.85) : K.label2)
            Icon(signature.icon, size: 12)
                .foregroundStyle(isSelected ? Color.white : signature.color)
                .help(signature.tooltip)
        }
        .frame(width: columns.sha, alignment: .leading)
    }

    @ViewBuilder
    private var refColumn: some View {
        if let first = labels.first {
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    RefLabel(label: first, lane: lane, selected: isSelected)
                        .onTapGesture(count: 2) { switchTo(first) }
                        .contextTarget(first.contextTarget, ring: ContextRing(radius: z(6), inset: -2))
                        .layoutPriority(1)
                    if labels.count > 1 {
                        Text("+\(labels.count - 1)")
                            .font(.system(size: z(11), weight: .semibold))
                            .foregroundStyle(isSelected ? .white.opacity(0.85) : K.label2)
                            .padding(.horizontal, z(4))
                            .fixedSize()
                            .opacity(listShown ? 0 : 1)
                            .accessibilityLabel("\(labels.count - 1) more: " + labels.dropFirst().map(\.title).joined(separator: ", "))
                    }
                }
                .layoutPriority(1)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    if labels.count > 1 { shownLabelsSize = size }
                }
                .debugLabelsFrame("row \(commit.id)")
                Rectangle()
                    .fill(isSelected ? Color.white.opacity(0.75) : K.lane(lane))
                    .frame(minWidth: z(8), maxWidth: .infinity)
                    .frame(height: GraphMetrics.labelLineWidth)
            }
            .padding(.leading, z(10))
        }
    }

    /// The list of every label is open (debug builds: or the driver opened it, `labels <index or hash>`).
    private var listShown: Bool {
        #if DEBUG
        if labels.count > 1, DebugRefLabels.shared.open == commit.id { return true }
        #endif
        return showsAllLabels
    }

    /// The list opens after a moment on the label and closes a moment after the pointer has left
    /// both the label and the list: passing over a row doesn't flash it, and the pointer can move
    /// from the label into the list (which then lies over the label and "+N").
    private func pointer(onLabels: Bool? = nil, onList: Bool? = nil) {
        #if DEBUG
        // A test instance's window lies wherever the real pointer happens to be: there only the driver
        // opens a list (`labels`).
        if TestSession.stem != nil { return }
        #endif
        if let onLabels { pointerOnLabels = onLabels }
        if let onList { pointerOnList = onList }
        let wanted = pointerOnLabels || pointerOnList
        labelsTimer?.cancel()
        guard wanted != showsAllLabels else { return }
        labelsTimer = Task {
            try? await Task.sleep(for: .milliseconds(wanted ? 150 : 120))
            guard !Task.isCancelled else { return }
            // A list that goes away doesn't always say the pointer left it.
            if !wanted { pointerOnList = false }
            withAnimation(.easeOut(duration: 0.12)) { showsAllLabels = wanted }
        }
    }
}

#if DEBUG
/// Debug builds: the commit whose list of labels the driver opened (`labels <index or hash>|off`);
/// a test window in the background gets no hover. `frames`: where the open list is ("list") and
/// where each row shows its first label and "+N" ("row <commit>"), in window points (top-left
/// origin), for the driver's `targetFrame labels list|row`.
@Observable
final class DebugRefLabels {
    static let shared = DebugRefLabels()
    var open: String?
    @ObservationIgnored var frames: [String: CGRect] = [:]
}

extension View {
    /// Debug builds: tells the driver where this part of a commit's labels is (`DebugRefLabels.frames`).
    func debugLabelsFrame(_ key: String) -> some View {
        modifier(DebugFrameReport(key: "label:\(key)") { DebugRefLabels.shared.frames[key] = $0 })
    }
}
#else
extension View {
    func debugLabelsFrame(_ key: String) -> some View { self }
}
#endif

/// Every label of a commit with several refs, unfolding from its first one and "+N" (which it
/// covers): down over the rows below, or up, the other way round, when the history shows more room
/// above. It lies over the row's own node and lanes too. The labels are whole, and each keeps its
/// right-click menu.
private struct RefLabelList: View {
    let labels: [RefLabelItem]
    let lane: Int
    /// Where the row shows its first label (the row's coordinates).
    let origin: CGPoint
    /// How wide the row shows its first label and "+N", from `origin`.
    let minWidth: CGFloat
    /// A double-click on a label (`HistoryView.switchTo`).
    let switchTo: (RefLabelItem) -> Void
    let hover: (Bool) -> Void

    static var labelHeight: CGFloat { z(20) }
    private static var gap: CGFloat { z(4) }
    private static var pad: CGFloat { z(4) }

    var body: some View {
        GeometryReader { proxy in
            // The row's coordinates; `visible` is what the history shows of them.
            let visible = proxy.bounds(of: .scrollView) ?? .infinite
            let height = CGFloat(labels.count) * Self.labelHeight + CGFloat(labels.count - 1) * Self.gap + Self.pad * 2
            let top = origin.y - Self.pad, bottom = origin.y + Self.labelHeight + Self.pad
            let roomBelow = visible.maxY - top
            let roomAbove = bottom - visible.minY
            let up = height > roomBelow && roomAbove > roomBelow
            VStack(alignment: .leading, spacing: Self.gap) {
                ForEach(up ? labels.reversed() : labels) { label in
                    RefLabel(label: label, lane: lane, selected: false)
                        .fixedSize()
                        .onTapGesture(count: 2) { switchTo(label) }
                        .contextTarget(label.contextTarget, ring: ContextRing(radius: z(6), inset: -2))
                }
            }
            .frame(minWidth: minWidth, alignment: .leading)
            .padding(Self.pad)
            // Solid: the rows under it don't show through.
            .background {
                RoundedRectangle(cornerRadius: z(8), style: .continuous)
                    .fill(K.popSolid)
                    .shadow(color: K.shadowPop, radius: z(8), y: 6)
            }
            .overlay {
                RoundedRectangle(cornerRadius: z(8), style: .continuous)
                    .strokeBorder(K.popRing, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onHover(perform: hover)
            .debugLabelsFrame("list")
            .offset(x: origin.x - Self.pad, y: up ? bottom - height : top)
        }
    }
}

/// A plain button with the board's hover plate (`.wsel:hover`).
struct HoverPlateStyle: ButtonStyle {
    var radius: CGFloat = z(7)
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        HoverPlate(configuration: configuration, radius: radius, selected: selected)
    }

    private struct HoverPlate: View {
        let configuration: ButtonStyleConfiguration
        let radius: CGFloat
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(hovering || configuration.isPressed ? (selected ? Color.white.opacity(0.15) : K.hover) : .clear)
                )
                .onHover { hovering = $0 }
        }
    }
}

/// `.selbar`: how many commits are picked, how to pick more, and Clear.
private struct SelectionBar: View {
    let repository: RepositoryModel

    var body: some View {
        HStack(spacing: z(10)) {
            Text(repository.picked.count == 1 ? "1 commit picked" : "\(repository.picked.count) commits picked")
            Spacer(minLength: 0)
            Text("⌘-click adds a commit · ⇧-click picks a range")
                .fontWeight(.medium)
                .opacity(0.75)
                .lineLimit(1)
            GhostButton(title: "Clear") { repository.clearPicks() }
        }
        .font(.system(size: z(12.5), weight: .semibold))
        .foregroundStyle(K.accentText)
        .padding(.leading, z(14))
        .padding(.trailing, z(12))
        .frame(height: z(34))
        .background { ZStack { K.content; K.accentSoft } }
        .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
    }
}

extension RefLabelItem {
    /// A branch label's menu is the branch menu; a remote branch's and a tag's their own.
    var contextTarget: ContextTarget {
        switch kind {
        case .branch: .branch(title)
        case .remote: .remoteBranch(title)
        case .tag: .tag(title)
        }
    }
}

// MARK: - Bot commits (ScreenBigRepo)

/// `.bgbar`: Bots: Collapsed ▾ (when there are bot commits) and Graph: Local + main ▾ (many
/// remote branches), then how much the graph holds.
private struct GraphBar: View {
    let repository: RepositoryModel
    @AppStorage(SettingsKey.botCommits, store: .kaern) private var mode = BotCommits.collapse

    var body: some View {
        HStack(spacing: z(6)) {
            if repository.hasBotCommits {
                Menu {
                    Picker("Bot Commits", selection: $mode) {
                        Text("Collapse Runs").tag(BotCommits.collapse)
                        Text("Show All").tag(BotCommits.show)
                        Text("Hide").tag(BotCommits.hide)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    BarChip(label: "Bots:", value: botTitle)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if repository.showsGraphScope {
                GraphScopeChip(repository: repository)
            }
            Spacer()
            Text(summary).font(.system(size: z(11.5))).foregroundStyle(K.label2).lineLimit(1)
        }
        .padding(.horizontal, z(10))
        .frame(height: z(32))
        .background(K.content)
        .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
        .onChange(of: mode) {
            for model in AppModel.shared.openRepositories { model.rebuildGraph() }
        }
    }

    private var botTitle: String {
        switch mode {
        case .collapse: "Collapsed"
        case .show: "Shown"
        case .hide: "Hidden"
        }
    }

    /// "212,408 commits · 207 bot commits folded into 13 rows".
    private var summary: String {
        let total = repository.totalCommitCount.flatMap { $0 >= 0 ? Formatters.count($0, "commit", "commits") : nil }
            ?? "\(Formatters.count(repository.commits.count, "commit", "commits")) loaded"
        guard repository.hasBotCommits else { return total }
        switch mode {
        case .collapse where repository.foldedBotCount > 0:
            return "\(total) · \(repository.foldedBotCount.formatted()) bot commits folded into \(Formatters.count(repository.botRuns.count, "row", "rows"))"
        case .hide where repository.hiddenBotCount > 0:
            return "\(total) · \(Formatters.count(repository.hiddenBotCount, "bot commit", "bot commits")) hidden"
        default:
            return total
        }
    }
}

/// "Graph: Local + main ▾": opens the AppKit menu `ContextMenus.graphScopeMenu` under the chip.
private struct GraphScopeChip: View {
    let repository: RepositoryModel
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button {
            guard let view = anchor.view else { return }
            ContextMenus.graphScopeMenu(repository).popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
        } label: {
            BarChip(label: "Graph:", value: repository.graphScopeLabel)
                .background(MenuAnchorView(anchor: anchor))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("What the graph draws")
        .accessibilityLabel("Graph: \(repository.graphScopeLabel)")
    }
}

/// `.bgchip`: "Bots: Collapsed ▾" — a gray capsule with the label dimmed and the value bold.
private struct BarChip: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: z(4)) {
            Text(label).foregroundStyle(K.label2)
            Text(value).fontWeight(.semibold).foregroundStyle(K.label)
            Icon(Icons.chevronDown, size: 9).foregroundStyle(K.label2)
        }
        .font(.system(size: z(11.5)))
        .padding(.horizontal, z(8))
        .frame(height: z(22))
        .background(Capsule().fill(K.hover))
        .contentShape(Capsule())
    }
}

/// A folded run (`.row.grp`): the lane runs through a pill node, › and the title in the message
/// column, the time it spans, and ×N where the hash goes.
private struct BotRunRow: View {
    let repository: RepositoryModel
    let run: BotRun
    let graph: GraphRow?
    let isAlternate: Bool
    /// The pointer is on the row (the list tells: `HistoryList`).
    let isHovered: Bool
    let isDimmed: Bool
    let columns: HistoryColumns

    var body: some View {
        let lane = graph?.lane ?? 0
        HStack(spacing: 0) {
            Color.clear.frame(width: columns.ref, height: KMetric.graphRow)
            ZStack(alignment: .topLeading) {
                if let graph { GraphLines(row: graph, height: KMetric.graphRow) }
                // `.node.gnode`: a 20 × 12 pill with two dots, ringed in the lane color.
                Capsule()
                    .fill(K.content)
                    .frame(width: z(20), height: z(12))
                    .overlay(Capsule().strokeBorder(K.lane(lane), lineWidth: 1.5))
                    .overlay {
                        HStack(spacing: z(4)) {
                            Circle().fill(K.lane(lane)).frame(width: z(3), height: z(3))
                            Circle().fill(K.lane(lane)).frame(width: z(3), height: z(3))
                        }
                    }
                    .background(Capsule().fill(isAlternate ? K.alt : K.content).padding(-z(3)))
                    .offset(x: GraphMetrics.x(lane: lane) - z(10), y: KMetric.graphRow / 2 - z(6))
            }
            .frame(width: columns.graph, height: KMetric.graphRow, alignment: .topLeading)
            .clipped()
            HStack(spacing: z(7)) {
                Icon(Icons.arrowRight, size: 10).foregroundStyle(K.label2)
                Text(run.title).fontWeight(.semibold).layoutPriority(1)
                if columns.showsDescriptions {
                    Text(run.detail).foregroundStyle(K.label2).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .truncationMode(.tail)
            .padding(.leading, z(12))
            .padding(.trailing, z(14))
            .frame(maxWidth: .infinity, alignment: .leading)
            if columns.showsDate {
                Text(dateRange)
                    .foregroundStyle(K.label2)
                    .frame(width: columns.date, alignment: .leading)
            }
            if columns.showsSHA {
                Text("×\(run.count)")
                    .font(.system(size: z(11), weight: .semibold))
                    .foregroundStyle(K.label2)
                    .padding(.horizontal, z(6))
                    .frame(height: z(17))
                    .background(Capsule().fill(K.hover))
                    .frame(width: columns.sha, alignment: .leading)
            }
        }
        .font(.system(size: z(13)))
        .foregroundStyle(K.label)
        .lineLimit(1)
        .frame(height: KMetric.graphRow)
        .background { if isHovered { ZStack { K.content; K.hover } } else { isAlternate ? K.alt : K.content } }
        .opacity(isDimmed ? 0.3 : 1)
        .help("\(run.title) — click to show each commit")
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the \(run.count) commits")
        .contentShape(Rectangle())
        .onTapGesture { repository.expandedRuns.insert(run.id) }
    }

    /// "9m – 2h" (newest – oldest), one date when they're the same.
    private var dateRange: String {
        let newest = Formatters.compactDate(run.newest)
        let oldest = Formatters.compactDate(run.oldest)
        return newest == oldest ? newest : "\(newest) – \(oldest)"
    }
}

// MARK: - Signatures (ScreenMarks › 서명)

extension SignatureMark {
    var color: Color {
        switch self {
        case .verified: K.ok
        case .unverified: K.warn
        case .bad: K.err
        }
    }

    var tooltip: String {
        switch self {
        case .verified: "Verified signature"
        case .unverified: "Signed, key not trusted on this Mac"
        case .bad: "Bad signature"
        }
    }
}

/// `.sglg`: the outline shield next to "Commit"; hovering it shows what the shields mean (`.sglt`).
private struct SignatureLegendButton: View {
    @State private var hovering = false

    var body: some View {
        Icon(Icons.shieldOutline, size: 11)
            .foregroundStyle(hovering ? K.label2 : K.label3)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .popover(isPresented: $hovering, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: z(5)) {
                    Text("Signatures").font(.system(size: z(11.5), weight: .bold))
                    legendRow(K.ok, "Verified")
                    legendRow(K.warn, "Signed, key not trusted")
                    legendRow(K.err, "Bad signature")
                    HStack(spacing: z(7)) {
                        RoundedRectangle(cornerRadius: z(3), style: .continuous).strokeBorder(K.label3, lineWidth: 1.5).frame(width: z(10), height: z(10))
                        Text("Not signed")
                    }
                }
                .font(.system(size: z(11.5), weight: .medium))
                .foregroundStyle(K.label)
                .padding(EdgeInsets(top: z(9), leading: z(11), bottom: z(9), trailing: z(11)))
                .frame(width: z(190), alignment: .leading)
            }
            .accessibilityLabel("Signature marks")
    }

    private func legendRow(_ color: Color, _ title: String) -> some View {
        HStack(spacing: z(7)) {
            RoundedRectangle(cornerRadius: z(3), style: .continuous).fill(color).frame(width: z(10), height: z(10))
            Text(title)
        }
    }
}
