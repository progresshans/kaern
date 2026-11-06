import KaernKit
import SwiftUI

/// The commit list for phase 1: Branch / Tag · Graph · Commit Message · Date · Commit, with
/// the working copy on top. The full graph (label connectors, curves tuned per lane, avatars
/// with photos, search dimming) is phase 2.
struct HistoryView: View {
    @Bindable var repository: RepositoryModel
    @State private var width: CGFloat = 0

    static let dateColumn: CGFloat = 104
    static let shaColumn: CGFloat = 72

    private var graphWidth: CGFloat {
        let lanes = repository.graph.prefix(300).map(\.width).max() ?? 1
        return min(max(84, GraphMetrics.x(lane: lanes - 1) + 14), 220)
    }

    var body: some View {
        let graphWidth = graphWidth
        let columns = HistoryColumns(width: width)
        VStack(spacing: 0) {
            header(graphWidth: graphWidth, columns: columns)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if repository.showsWorkingCopy, let row = repository.graph.first {
                            WorkingCopyRow(repository: repository, graph: row, graphWidth: graphWidth, columns: columns,
                                           isSelected: repository.selection == .workingCopy)
                                .onTapGesture { repository.selection = .workingCopy }
                                .id("wip")
                        }
                        let offset = repository.showsWorkingCopy ? 1 : 0
                        ForEach(Array(repository.commits.enumerated()), id: \.element.id) { index, commit in
                            let graphIndex = index + offset
                            CommitRow(
                                commit: commit,
                                graph: repository.graph.indices.contains(graphIndex) ? repository.graph[graphIndex] : nil,
                                previousLane: graphIndex > 0 && repository.graph.indices.contains(graphIndex - 1) ? repository.graph[graphIndex - 1].lane : nil,
                                refs: repository.refs.refs(at: commit.id),
                                headBranch: repository.status.branch,
                                isAlternate: index % 2 == 1,
                                isSelected: repository.selection == .commit(commit.id),
                                graphWidth: graphWidth,
                                columns: columns
                            )
                            .onTapGesture { repository.selection = .commit(commit.id) }
                            .onAppear {
                                if index >= repository.commits.count - 40 { repository.loadMoreHistory() }
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
                .onAppear {
                    if let anchor = repository.historyScrollAnchor { proxy.scrollTo(anchor, anchor: .top) }
                }
                .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.5) { visible in
                    if let first = visible.first { repository.historyScrollAnchor = first }
                }
            }
        }
        .background(K.content)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func header(graphWidth: CGFloat, columns: HistoryColumns) -> some View {
        HStack(spacing: 0) {
            Text("Branch / Tag").padding(.leading, 10).frame(width: columns.ref, alignment: .leading)
            Text("Graph").frame(width: graphWidth, alignment: .leading)
            Text("Commit Message").padding(.leading, 12).frame(maxWidth: .infinity, alignment: .leading)
            if columns.showsDate {
                Text("Date").frame(width: Self.dateColumn, alignment: .leading)
            }
            if columns.showsSHA {
                // The board sets this header in the hash column's monospaced face.
                Text("Commit").font(.system(size: 11.5, design: .monospaced)).fontWeight(.regular)
                    .frame(width: Self.shaColumn, alignment: .leading)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(K.label2)
        .lineLimit(1)
        .frame(height: 26)
        .background(K.content)
        .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
    }
}

/// Which columns fit: the hash goes first, then the date, then the label column narrows
/// (the Narrow board folds the window in that order).
struct HistoryColumns: Equatable {
    var ref: CGFloat = 176
    var showsDate = true
    var showsSHA = true

    init(width: CGFloat) {
        guard width > 0 else { return }
        showsSHA = width >= 734
        showsDate = width >= 560
        ref = width >= 520 ? 176 : 124
    }
}

nonisolated enum GraphMetrics {
    static func x(lane: Int) -> CGFloat { 16 + 22 * CGFloat(lane) }
}

/// Lines of one row: edges from the row above to this node (upper half) and from this node
/// to the row below (lower half).
///
/// An edge that changes lanes bends within half a row, like the board: right below a node
/// that it leaves (a merge's second parent, a branch's last commit), otherwise right above the
/// node it joins (a branch curving back into its fork point).
struct GraphLines: View {
    let row: GraphRow
    /// Lane of the row above's node (`nil` for the first row).
    var previousLane: Int?
    let height: CGFloat
    var selected = false

    var body: some View {
        Canvas { context, size in
            let mid = height / 2
            func stroke(_ edge: GraphEdge, from y0: CGFloat, to y1: CGFloat, bends: Bool, atStart: Bool) {
                let xFrom = GraphMetrics.x(lane: edge.from)
                let xTo = GraphMetrics.x(lane: edge.to)
                var path = Path()
                if xFrom == xTo || !bends {
                    // Straight: before the bend (upper row) or after it (lower row).
                    let x = atStart ? xFrom : xTo
                    path.move(to: CGPoint(x: x, y: y0))
                    path.addLine(to: CGPoint(x: x, y: y1))
                } else {
                    let span = y1 - y0
                    path.move(to: CGPoint(x: xFrom, y: y0))
                    path.addCurve(to: CGPoint(x: xTo, y: y1),
                                  control1: CGPoint(x: xFrom, y: y0 + span * 0.57),
                                  control2: CGPoint(x: xTo, y: y0 + span * 0.43))
                }
                let color: Color = edge.dashed ? K.wip : K.lane(edge.lane)
                let style = edge.dashed
                    ? StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [2.4, 3])
                    : StrokeStyle(lineWidth: 2.2, lineCap: .round)
                context.stroke(path, with: .color(selected && !edge.dashed ? .white.opacity(0.85) : color), style: style)
            }
            for edge in row.up {
                // Bent in the row above when it left that row's node.
                let bentAbove = edge.from == previousLane
                stroke(edge, from: 0, to: mid, bends: !bentAbove, atStart: false)
            }
            for edge in row.down {
                stroke(edge, from: mid, to: size.height, bends: edge.from == row.lane, atStart: true)
            }
        }
        .frame(height: height)
    }
}

/// The working-copy row (34 pt): dashed node, "Uncommitted changes", file and staged counts.
private struct WorkingCopyRow: View {
    let repository: RepositoryModel
    let graph: GraphRow
    let graphWidth: CGFloat
    let columns: HistoryColumns
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: columns.ref)
            ZStack(alignment: .topLeading) {
                GraphLines(row: graph, height: KMetric.wipRow, selected: isSelected)
                Circle()
                    .strokeBorder(isSelected ? Color.white : K.wip, style: StrokeStyle(lineWidth: 1.8, dash: [2.6, 2.2]))
                    .background(Circle().fill(isSelected ? K.sel : K.content))
                    .frame(width: 18, height: 18)
                    .offset(x: GraphMetrics.x(lane: graph.lane) - 9, y: KMetric.wipRow / 2 - 9)
            }
            .frame(width: graphWidth, height: KMetric.wipRow, alignment: .topLeading)
            HStack(spacing: 6) {
                Text("Uncommitted changes").font(.system(size: 13, weight: .semibold))
                    .layoutPriority(-1)
                chip(Formatters.count(repository.changeCount, "file", "files"))
                if repository.statusIsFull { chip("\(repository.stagedCount) staged") }
            }
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            if columns.showsDate {
                Text("Now")
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : K.label2)
                    .frame(width: HistoryView.dateColumn, alignment: .leading)
            }
            if columns.showsSHA {
                Color.clear.frame(width: HistoryView.shaColumn)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(isSelected ? .white : K.label)
        .lineLimit(1)
        .frame(height: KMetric.wipRow)
        .background(isSelected ? K.sel : K.content)
        .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
        .contentShape(Rectangle())
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isSelected ? .white : K.label2)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(isSelected ? Color.white.opacity(0.22) : K.hover))
            .fixedSize()
    }
}

/// One commit (28 pt).
private struct CommitRow: View {
    let commit: Commit
    let graph: GraphRow?
    let previousLane: Int?
    let refs: [Ref]
    let headBranch: String?
    let isAlternate: Bool
    let isSelected: Bool
    let graphWidth: CGFloat
    let columns: HistoryColumns

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
                if let graph { GraphLines(row: graph, previousLane: previousLane, height: KMetric.graphRow, selected: isSelected) }
                if !refs.isEmpty {
                    Rectangle()
                        .fill(isSelected ? Color.white.opacity(0.75) : K.lane(lane))
                        .frame(width: max(0, nodeX - (isMerge ? 7 : 12.5)), height: 1.5)
                        .offset(y: KMetric.graphRow / 2 - 0.75)
                }
                CommitNode(commit: commit, isMerge: isMerge, lane: lane, gap: background)
                    .offset(x: nodeX - 9, y: KMetric.graphRow / 2 - 9)
            }
            .frame(width: graphWidth, height: KMetric.graphRow, alignment: .topLeading)
            HStack(spacing: 6) {
                Text(commit.subject)
                    .truncationMode(.tail)
            }
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
                Text(Formatters.historyDate(commit.author.date))
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : K.label2)
                    .frame(width: HistoryView.dateColumn, alignment: .leading)
            }
            if columns.showsSHA {
                Text(commit.shortID)
                    .font(KFont.hash)
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : K.label2)
                    .frame(width: HistoryView.shaColumn, alignment: .leading)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(isSelected ? .white : K.label)
        .lineLimit(1)
        .frame(height: KMetric.graphRow)
        .background(background)
        .contentShape(Rectangle())
        .help("\(commit.subject)\n\(commit.author.name) · \(commit.shortID)")
    }

    @ViewBuilder
    private var refColumn: some View {
        if let first = sortedRefs.first {
            HStack(spacing: 4) {
                RefLabel(ref: first, isHead: first.kind == .localBranch && first.name == headBranch, lane: lane, selected: isSelected)
                if sortedRefs.count > 1 {
                    Text("+\(sortedRefs.count - 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? .white.opacity(0.85) : K.label2)
                        .fixedSize()
                        .help(sortedRefs.dropFirst().map(\.name).joined(separator: "\n"))
                }
                Rectangle()
                    .fill(isSelected ? Color.white.opacity(0.75) : K.lane(lane))
                    .frame(minWidth: 8, maxWidth: .infinity)
                    .frame(height: 1.5)
            }
            .padding(.leading, 10)
        }
    }

    /// HEAD's branch first, then local branches, remote branches and tags.
    private var sortedRefs: [Ref] {
        refs.sorted { rank($0) < rank($1) }
    }

    private func rank(_ ref: Ref) -> Int {
        if ref.kind == .localBranch, ref.name == headBranch { return 0 }
        switch ref.kind {
        case .localBranch: return 1
        case .remoteBranch: return 2
        case .tag: return 3
        }
    }
}

/// A branch or tag label (`.lab`): lane tint, HEAD solid, kind icon.
private struct RefLabel: View {
    let ref: Ref
    let isHead: Bool
    let lane: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isHead {
                Icon(Icons.labelHead, size: 10).foregroundStyle(.white)
            }
            Text(ref.name)
                .lineLimit(1)
                .truncationMode(.middle)
            switch ref.kind {
            case .localBranch:
                if !isHead { Icon(Icons.labelLocal, size: 12).foregroundStyle(selected ? .white : K.label2) }
            case .remoteBranch:
                Icon(Icons.labelRemote, size: 12).foregroundStyle(selected || isHead ? .white : K.label2)
            case .tag:
                Icon(Icons.labelTag, size: 11).foregroundStyle(selected ? .white : K.label2)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(isHead || selected ? .white : K.label)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(selected ? Color.white.opacity(0.22) : (isHead ? K.lane1 : K.laneTint(lane)))
        )
        .layoutPriority(1)
    }
}

/// The commit node: the author's initials ringed in the lane color; merges are small dots.
private struct CommitNode: View {
    let commit: Commit
    let isMerge: Bool
    let lane: Int
    let gap: Color

    var body: some View {
        ZStack {
            if isMerge {
                Circle().fill(gap).frame(width: 14, height: 14)
                Circle().fill(K.lane(lane)).frame(width: 10, height: 10)
            } else {
                Circle().fill(K.lane(lane)).frame(width: 25, height: 25)
                Circle().fill(gap).frame(width: 21, height: 21)
                Circle().fill(AvatarPalette.color(for: commit.author.email.isEmpty ? commit.author.name : commit.author.email))
                    .frame(width: 18, height: 18)
                Text(commit.author.initials)
                    .font(.system(size: 7.5, weight: .bold))
                    .tracking(0.2)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}
