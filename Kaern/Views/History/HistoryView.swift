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

    @State private var width: CGFloat = 0
    @Environment(\.windowWidth) private var windowWidth
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
            tier: NarrowTier(width: windowWidth)
        )
    }

    var body: some View {
        let columns = columns
        VStack(spacing: 0) {
            if !repository.picked.isEmpty {
                SelectionBar(repository: repository)
            }
            if repository.hasBotCommits {
                BotBar(repository: repository)
            }
            HistoryHeader(columns: columns, width: width, ref: $storedRef, graph: $storedGraph, date: $storedDate, sha: $storedSHA)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if repository.showsWorkingCopy, let row = repository.graph.first {
                            WorkingCopyRow(repository: repository, graph: row, columns: columns, inline: isFocused,
                                           isSelected: repository.selection == .workingCopy && repository.picked.isEmpty
                                               && repository.branchCompare == nil,
                                           isDimmed: repository.search.isFiltering) {
                                pick(.workingCopy)
                            }
                            .id("wip")
                        }
                        let offset = repository.showsWorkingCopy ? 1 : 0
                        let headBranch = repository.status.branch
                        let picked = Set(repository.picked)
                        let comparison = repository.comparison?.key == repository.comparisonKey ? repository.comparison : nil
                        let shown = repository.displayCommits
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, commit in
                            let graphIndex = index + offset
                            let row = repository.graph.indices.contains(graphIndex) ? repository.graph[graphIndex] : nil
                            Group {
                                if let run = repository.botRuns[commit.id] {
                                    // ScreenBigRepo: a run of bot commits as one row; the chevron opens it.
                                    BotRunRow(run: run, graph: row, isAlternate: index % 2 == 1,
                                              isDimmed: repository.search.isFiltering, columns: columns)
                                        .contentShape(Rectangle())
                                        .onTapGesture { repository.expandedRuns.insert(run.id) }
                                } else {
                                    CommitRow(
                                        commit: commit,
                                        graph: row,
                                        labels: RefLabelItem.labels(for: repository.refs.refs(at: commit.id), headBranch: headBranch),
                                        isAlternate: index % 2 == 1,
                                        isSelected: picked.isEmpty
                                            ? repository.branchCompare == nil && repository.selection == .commit(commit.id)
                                            : picked.contains(commit.id),
                                        isDimmed: repository.search.isDimmed(commit.id),
                                        tint: CommitRow.Tint(comparison: comparison, id: commit.id),
                                        columns: columns
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture { click(commit.id) }
                                }
                            }
                            .onAppear {
                                if index >= shown.count - 40 { repository.loadMoreHistory() }
                            }
                            .id(commit.id)
                        }
                        if repository.isLoadingMoreHistory {
                            ProgressView().controlSize(.small).padding(8)
                        }
                    }
                    .scrollTargetLayout()
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
                .onKeyPress(.upArrow) { move(-1, proxy: proxy) }
                .onKeyPress(.downArrow) { move(1, proxy: proxy) }
                .onKeyPress(.return) {
                    // Return opens the selection in Review (Keyboard Shortcuts › In the Graph).
                    guard repository.canReview else { return .ignored }
                    repository.review = ReviewState(showsAllFiles: true)
                    return .handled
                }
                .onAppear {
                    if let anchor = repository.historyScrollAnchor { proxy.scrollTo(anchor, anchor: .top) }
                }
                .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.5) { visible in
                    if let first = visible.first { repository.historyScrollAnchor = first }
                }
                .onChange(of: repository.scrollRequest) { _, request in
                    guard let request else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(request.id, anchor: .center) }
                }
            }
        }
        .background(K.content)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func pick(_ selection: HistorySelection) {
        repository.clearPicks()
        repository.selection = selection
        listFocused = true
        onPick()
    }

    /// A click on a commit: ⌘ adds it to the picked commits, ⇧ picks a range.
    private func click(_ id: String) {
        let flags = NSEvent.modifierFlags
        let command = flags.contains(.command), shift = flags.contains(.shift)
        repository.click(commit: id, command: command, shift: shift)
        listFocused = true
        if !command, !shift { onPick() }
    }

    /// ↑ / ↓ move the selection through the working copy and the commits (a folded run is
    /// stepped over).
    private func move(_ step: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        var ids: [HistorySelection] = repository.showsWorkingCopy ? [.workingCopy] : []
        ids += repository.displayCommits.filter { repository.botRuns[$0.id] == nil }.map { .commit($0.id) }
        guard !ids.isEmpty else { return .ignored }
        let current = ids.firstIndex(of: repository.selection) ?? (step > 0 ? -1 : ids.count)
        let next = min(max(current + step, 0), ids.count - 1)
        let selection = ids[next]
        repository.clearPicks()
        repository.selection = selection
        switch selection {
        case .workingCopy: proxy.scrollTo("wip")
        case .commit(let id): proxy.scrollTo(id)
        }
        onPick()
        return .handled
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

    init(width: CGFloat, stored: ColumnWidths, automaticGraph: CGFloat, tier: NarrowTier = .wide) {
        ref = stored.ref
        graph = stored.graph > 0 ? stored.graph : automaticGraph
        date = stored.date
        sha = stored.sha
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
        guard width > 0 else { return }
        showsSHA = showsSHA && width >= 734
        showsDate = showsDate && width >= 560
        if width < 520 { ref = min(ref, 124) }
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
            Text("Branch / Tag").padding(.leading, 10).frame(width: columns.ref, alignment: .leading)
            Text("Graph").frame(width: columns.graph, alignment: .leading)
            Text("Commit Message").padding(.leading, 12).frame(maxWidth: .infinity, alignment: .leading)
            if columns.showsDate {
                Text("Date").frame(width: columns.date, alignment: .leading)
            }
            if columns.showsSHA {
                // The board sets this header in the hash column's monospaced face.
                Text("Commit").font(.system(size: 11.5, design: .monospaced)).fontWeight(.regular)
                    .frame(width: columns.sha, alignment: .leading)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(K.label2)
        .lineLimit(1)
        .frame(height: 26)
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
                get: { graph > 0 ? graph : Double(columns.graph) }, set: { graph = $0 }
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
        .frame(height: 26)
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
            .frame(width: 9, height: 26)
            .overlay {
                if hovering || start != nil {
                    K.sepStrong.frame(width: 1, height: 14)
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
                        let delta = Double(drag.translation.width) * (grows == .right ? 1 : -1)
                        value = min(max(base + delta, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in start = nil }
            )
            .onTapGesture(count: 2) { value = reset }
            .offset(x: edge - 4.5)
            .accessibilityHidden(true)
    }
}

// MARK: - Rows

/// The working-copy row (34 pt): a dashed node and "Uncommitted changes" with file and staged
/// counts. In Focus it's an inline commit row: the change count, a summary field and Commit.
private struct WorkingCopyRow: View {
    @Bindable var repository: RepositoryModel
    let graph: GraphRow
    let columns: HistoryColumns
    let inline: Bool
    let isSelected: Bool
    let isDimmed: Bool
    let pick: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: columns.ref)
            ZStack(alignment: .topLeading) {
                GraphLines(row: graph, height: KMetric.wipRow, dashColor: isSelected ? .white.opacity(0.8) : K.wip)
                WorkingCopyNode(selected: isSelected)
                    .offset(x: GraphMetrics.x(lane: graph.lane) - 9, y: KMetric.wipRow / 2 - 9)
            }
            .frame(width: columns.graph, height: KMetric.wipRow, alignment: .topLeading)
            .clipped()
            if inline {
                inlineForm
            } else {
                HStack(spacing: 6) {
                    Text("Uncommitted changes").font(.system(size: 13, weight: .semibold))
                        .layoutPriority(-1)
                    WorkingChip(text: Formatters.count(repository.changeCount, "file", "files"), selected: isSelected)
                    if repository.statusIsFull { WorkingChip(text: "\(repository.stagedCount) staged", selected: isSelected) }
                }
                .padding(.leading, 12)
                .padding(.trailing, 14)
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
        .font(.system(size: 13))
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
                HStack(spacing: 6) {
                    Text(Formatters.count(repository.changeCount, "change", "changes"))
                        .font(.system(size: 13, weight: .semibold))
                    WorkingChip(text: "\(repository.stagedCount) staged", selected: isSelected)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverPlateStyle(radius: 7, selected: isSelected))
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    TextField("Commit summary", text: $repository.composer.summary)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(K.label)
                        .onSubmit { repository.commit() }
                    SummaryCounter(count: repository.composer.summary.count)
                }
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(K.field))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5))
                Button { repository.commit() } label: {
                    Text(repository.status.stagedCount == 0 && !repository.composer.amend ? "Commit" : repository.commitButtonTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(K.accent))
                }
                .buttonStyle(.plain)
                .disabled(!repository.canCommit)
                .opacity(repository.canCommit ? 1 : 0.45)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
        }
        .padding(.leading, 4)
    }
}

/// `.wchip`: a small count pill in the working-copy row.
private struct WorkingChip: View {
    let text: String
    let selected: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selected ? .white : K.label2)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(selected ? Color.white.opacity(0.22) : K.hover))
            .fixedSize()
    }
}

/// "38/72": the summary's length against the 72 characters a summary should stay under.
struct SummaryCounter: View {
    let count: Int

    var body: some View {
        Text("\(count)/\(CommitDraft.summaryLimit)")
            .font(.system(size: 11))
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
    let isAlternate: Bool
    let isSelected: Bool
    let isDimmed: Bool
    var tint: Tint = .none
    let columns: HistoryColumns

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

    @State private var hovering = false

    private var lane: Int { graph?.lane ?? 0 }
    private var background: Color { isSelected ? K.sel : (isAlternate ? K.alt : K.content) }

    var body: some View {
        let nodeX = GraphMetrics.x(lane: lane)
        let isMerge = graph?.isMerge ?? commit.isMerge
        HStack(spacing: 0) {
            // A fixed-width slot (an empty `if` would collapse the column).
            Color.clear
                .frame(width: columns.ref, height: KMetric.graphRow)
                .overlay(alignment: .leading) { refColumn }
            ZStack(alignment: .topLeading) {
                if !labels.isEmpty {
                    // The label's line carries on from the label column to the node's edge, under the
                    // lanes it passes (drawn first). It's a 1 pt hairline against 2.2 pt lanes, so it
                    // reads as a pointer to the label, not a branch joining at this row (canvas v60).
                    Rectangle()
                        .fill(isSelected ? Color.white.opacity(0.75) : K.lane(lane))
                        .frame(width: max(0, nodeX - (isMerge ? 7 : 12.5)), height: GraphMetrics.labelLineWidth)
                        .offset(y: KMetric.graphRow / 2 - GraphMetrics.labelLineWidth / 2)
                }
                if let graph { GraphLines(row: graph, height: KMetric.graphRow) }
                CommitNode(commit: commit, isMerge: isMerge, lane: lane, gap: background)
                    .offset(x: nodeX - 9, y: KMetric.graphRow / 2 - 9)
            }
            .frame(width: columns.graph, height: KMetric.graphRow, alignment: .topLeading)
            .clipped()
            HStack(spacing: 6) {
                Text(commit.subject)
                    .layoutPriority(1)
                if columns.showsDescriptions, !commit.bodyPreview.isEmpty {
                    Text(commit.bodyPreview)
                        .foregroundStyle(isSelected ? .white.opacity(0.85) : K.label2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .truncationMode(.tail)
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isSelected ? Color.white : K.lane(lane))
                    .frame(width: 2.5)
                    .padding(.vertical, 5)
            }
            if columns.showsDate {
                Text(columns.compactDates ? Formatters.compactDate(commit.author.date) : Formatters.historyDate(commit.author.date))
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : K.label2)
                    .frame(width: columns.date, alignment: .leading)
            }
            if columns.showsSHA {
                Text(commit.shortID)
                    .font(KFont.hash)
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : K.label2)
                    .frame(width: columns.sha, alignment: .leading)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(isSelected ? .white : K.label)
        .lineLimit(1)
        .frame(height: KMetric.graphRow)
        .background {
            // `.row:hover`: the hover tint on the list's background.
            if tint == .inRange, !isSelected { ZStack { K.content; K.accentSoft } }
            else if hovering, !isSelected { ZStack { K.content; K.hover } } else { background }
        }
        .overlay(alignment: .leading) {
            if !isSelected, tint == .ours || tint == .theirs {
                (tint == .ours ? K.accent : K.lane2).frame(width: 3)
            }
        }
        .onHover { hovering = $0 }
        .contextTarget(.commit(commit.id))
        .opacity(isDimmed ? 0.3 : 1)
        .help("\(commit.subject)\n\(commit.author.name) · \(commit.shortID)")
    }

    @ViewBuilder
    private var refColumn: some View {
        if let first = labels.first {
            HStack(spacing: 0) {
                RefLabel(label: first, lane: lane, selected: isSelected)
                    .contextTarget(first.contextTarget, ring: ContextRing(radius: 6, inset: -2))
                    .layoutPriority(1)
                if labels.count > 1 {
                    Text("+\(labels.count - 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? .white.opacity(0.85) : K.label2)
                        .padding(.horizontal, 4)
                        .fixedSize()
                        .help(labels.dropFirst().flatMap(\.names).joined(separator: "\n"))
                }
                Rectangle()
                    .fill(isSelected ? Color.white.opacity(0.75) : K.lane(lane))
                    .frame(minWidth: 8, maxWidth: .infinity)
                    .frame(height: GraphMetrics.labelLineWidth)
            }
            .padding(.leading, 10)
        }
    }
}

/// A plain button with the board's hover plate (`.wsel:hover`).
struct HoverPlateStyle: ButtonStyle {
    var radius: CGFloat = 7
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
        HStack(spacing: 10) {
            Text(repository.picked.count == 1 ? "1 commit picked" : "\(repository.picked.count) commits picked")
            Spacer(minLength: 0)
            Text("⌘-click adds a commit · ⇧-click picks a range")
                .fontWeight(.medium)
                .opacity(0.75)
                .lineLimit(1)
            GhostButton(title: "Clear") { repository.clearPicks() }
        }
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(K.accentText)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 34)
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

/// `.bgbar`: Bots: Collapsed ▾, and how much was folded.
private struct BotBar: View {
    let repository: RepositoryModel
    @AppStorage(SettingsKey.botCommits, store: .kaern) private var mode = BotCommits.collapse

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Bot Commits", selection: $mode) {
                    Text("Collapse Runs").tag(BotCommits.collapse)
                    Text("Show All").tag(BotCommits.show)
                    Text("Hide").tag(BotCommits.hide)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 4) {
                    Text("Bots:").foregroundStyle(K.label2)
                    Text(title).fontWeight(.semibold).foregroundStyle(K.label)
                    Icon(Icons.chevronDown, size: 9).foregroundStyle(K.label2)
                }
                .font(.system(size: 11.5))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(K.hover))
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
            Text(summary).font(.system(size: 11.5)).foregroundStyle(K.label2).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(K.content)
        .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
        .onChange(of: mode) {
            for model in AppModel.shared.openRepositories { model.rebuildGraph() }
        }
    }

    private var title: String {
        switch mode {
        case .collapse: "Collapsed"
        case .show: "Shown"
        case .hide: "Hidden"
        }
    }

    /// "212,408 commits · 207 bot commits folded into 13 rows".
    private var summary: String {
        let total = repository.totalCommitCount.map { Formatters.count($0, "commit", "commits") }
            ?? "\(Formatters.count(repository.commits.count, "commit", "commits")) loaded"
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

/// A folded run (`.row.grp`): the lane runs through a pill node, › and the title in the message
/// column, the time it spans, and ×N where the hash goes.
private struct BotRunRow: View {
    let run: BotRun
    let graph: GraphRow?
    let isAlternate: Bool
    let isDimmed: Bool
    let columns: HistoryColumns
    @State private var hovering = false

    var body: some View {
        let lane = graph?.lane ?? 0
        HStack(spacing: 0) {
            Color.clear.frame(width: columns.ref, height: KMetric.graphRow)
            ZStack(alignment: .topLeading) {
                if let graph { GraphLines(row: graph, height: KMetric.graphRow) }
                // `.node.gnode`: a 20 × 12 pill with two dots, ringed in the lane color.
                Capsule()
                    .fill(K.content)
                    .frame(width: 20, height: 12)
                    .overlay(Capsule().strokeBorder(K.lane(lane), lineWidth: 1.5))
                    .overlay {
                        HStack(spacing: 4) {
                            Circle().fill(K.lane(lane)).frame(width: 3, height: 3)
                            Circle().fill(K.lane(lane)).frame(width: 3, height: 3)
                        }
                    }
                    .background(Capsule().fill(isAlternate ? K.alt : K.content).padding(-3))
                    .offset(x: GraphMetrics.x(lane: lane) - 10, y: KMetric.graphRow / 2 - 6)
            }
            .frame(width: columns.graph, height: KMetric.graphRow, alignment: .topLeading)
            .clipped()
            HStack(spacing: 7) {
                Icon(Icons.arrowRight, size: 10).foregroundStyle(K.label2)
                Text(run.title).fontWeight(.semibold).layoutPriority(1)
                if columns.showsDescriptions {
                    Text(run.detail).foregroundStyle(K.label2).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .truncationMode(.tail)
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            if columns.showsDate {
                Text(dateRange)
                    .foregroundStyle(K.label2)
                    .frame(width: columns.date, alignment: .leading)
            }
            if columns.showsSHA {
                Text("×\(run.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(K.label2)
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(Capsule().fill(K.hover))
                    .frame(width: columns.sha, alignment: .leading)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(K.label)
        .lineLimit(1)
        .frame(height: KMetric.graphRow)
        .background { if hovering { ZStack { K.content; K.hover } } else { isAlternate ? K.alt : K.content } }
        .onHover { hovering = $0 }
        .opacity(isDimmed ? 0.3 : 1)
        .help("\(run.title) — click to show each commit")
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the \(run.count) commits")
    }

    /// "9m – 2h" (newest – oldest), one date when they're the same.
    private var dateRange: String {
        let newest = Formatters.compactDate(run.newest)
        let oldest = Formatters.compactDate(run.oldest)
        return newest == oldest ? newest : "\(newest) – \(oldest)"
    }
}
