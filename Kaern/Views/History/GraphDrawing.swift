import KaernKit
import SwiftUI

/// Graph geometry (Tokens board › 그래프): first lane at x 16, 22 between lanes, 2.2 pt lines,
/// rounded corners of 10 where a fork or merge line turns, and 1 pt lines from a ref label to its
/// commit (canvas v60).
nonisolated enum GraphMetrics {
    static let firstLane: CGFloat = 16
    static let laneSpacing: CGFloat = 22
    static let corner: CGFloat = 10
    static let lineWidth: CGFloat = 2.2
    static let labelLineWidth: CGFloat = 1

    static func x(lane: Int) -> CGFloat { firstLane + laneSpacing * CGFloat(lane) }

    /// The graph column wide enough for the widest of the first rows (84…220, like the board).
    static func automaticWidth(for rows: ArraySlice<GraphRow>) -> CGFloat {
        let lanes = rows.map(\.width).max() ?? 1
        return min(max(84, x(lane: lanes - 1) + 14), 220)
    }
}

/// The lines of one row. Fork and merge lines meet a commit node, never the line between two
/// commits (canvas v54, `graphFor` in WindowBase):
/// - a merge's line leaves the side of the merge dot and turns down into its lane with a rounded
///   corner, below the node's center (``GraphEdge/Turn/leavesNode``);
/// - a branch comes down its lane and turns into the side of the commit it grew from, above that
///   node's center (``GraphEdge/Turn/joinsNode``).
/// Everything else runs straight down its lane.
struct GraphLines: View {
    let row: GraphRow
    let height: CGFloat
    /// The working copy's dashed line (white on the selected working-copy row).
    var dashColor: Color = K.wip

    var body: some View {
        Canvas { context, size in
            let mid = height / 2
            let radius = GraphMetrics.corner
            for edge in row.up {
                let from = GraphMetrics.x(lane: edge.from)
                let to = GraphMetrics.x(lane: edge.to)
                var path = Path()
                switch edge.turn {
                case .straight:
                    path.move(to: CGPoint(x: from, y: 0))
                    path.addLine(to: CGPoint(x: from, y: mid))
                case .leavesNode:
                    // The turn happened in the row above; here the line is already in its lane.
                    path.move(to: CGPoint(x: to, y: 0))
                    path.addLine(to: CGPoint(x: to, y: mid))
                case .joinsNode:
                    // Down the lane, a quarter circle, then along the row's center into the node.
                    path.move(to: CGPoint(x: from, y: 0))
                    path.addArc(tangent1End: CGPoint(x: from, y: mid), tangent2End: CGPoint(x: to, y: mid), radius: radius)
                    path.addLine(to: CGPoint(x: to, y: mid))
                }
                stroke(path, edge, in: &context)
            }
            for edge in row.down {
                let from = GraphMetrics.x(lane: edge.from)
                let to = GraphMetrics.x(lane: edge.to)
                var path = Path()
                switch edge.turn {
                case .straight, .joinsNode:
                    // A joining lane makes its turn in the row below.
                    path.move(to: CGPoint(x: from, y: mid))
                    path.addLine(to: CGPoint(x: from, y: size.height))
                case .leavesNode:
                    // Out of the merge dot's side, a quarter circle, then down the new lane.
                    path.move(to: CGPoint(x: from, y: mid))
                    path.addArc(tangent1End: CGPoint(x: to, y: mid), tangent2End: CGPoint(x: to, y: size.height), radius: radius)
                    path.addLine(to: CGPoint(x: to, y: size.height))
                }
                stroke(path, edge, in: &context)
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }

    private func stroke(_ path: Path, _ edge: GraphEdge, in context: inout GraphicsContext) {
        if edge.dashed {
            context.stroke(path, with: .color(dashColor),
                           style: StrokeStyle(lineWidth: GraphMetrics.lineWidth, lineCap: .round, dash: [2.4, 3]))
        } else {
            context.stroke(path, with: .color(K.lane(edge.lane)),
                           style: StrokeStyle(lineWidth: GraphMetrics.lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

/// The commit node (`.node`): the author's initials on their color, a gap ring in the row's
/// background and a ring in the lane color; merge commits are small dots (`.node.m`).
struct CommitNode: View {
    let commit: Commit
    let isMerge: Bool
    let lane: Int
    /// The row's background, for the gap around the node.
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

/// The working copy's node: a dashed ring, r 8.5.
struct WorkingCopyNode: View {
    let selected: Bool

    var body: some View {
        Circle()
            .strokeBorder(selected ? Color.white : K.wip, style: StrokeStyle(lineWidth: 1.8, dash: [2.6, 2.2]))
            .background(Circle().fill(selected ? K.sel : K.content))
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }
}

/// One label in the Branch / Tag column: a branch together with its remote-tracking copies that
/// point at the same commit (laptop and cloud icons in one label, GitKraken style), a remote
/// branch on its own, or a tag.
struct RefLabelItem: Identifiable, Equatable {
    enum Kind: Equatable { case branch, remote, tag }

    let id: String
    let title: String
    let kind: Kind
    let isHead: Bool
    /// A local branch is in the label (laptop icon).
    let hasLocal: Bool
    /// A remote-tracking branch is in the label (cloud icon).
    let hasRemote: Bool
    /// Every ref name in the label, for the tooltip.
    let names: [String]
    /// The other worktree that has this branch checked out (ScreenMarks › 워크트리).
    var worktree: String?

    /// HEAD's branch first, then local branches, remote branches and tags. `worktrees`: branch →
    /// the other worktree that has it checked out.
    static func labels(for refs: [Ref], headBranch: String?, worktrees: [String: String] = [:]) -> [RefLabelItem] {
        var result: [RefLabelItem] = []
        var mergedRemotes = Set<String>()
        let locals = refs.filter { $0.kind == .localBranch }
        let remotes = refs.filter { $0.kind == .remoteBranch }
        for local in locals {
            let twins = remotes.filter { $0.branchName == local.name }
            mergedRemotes.formUnion(twins.map(\.fullName))
            result.append(RefLabelItem(
                id: local.fullName, title: local.name, kind: .branch,
                isHead: local.name == headBranch, hasLocal: true, hasRemote: !twins.isEmpty,
                names: [local.name] + twins.map(\.name), worktree: worktrees[local.name]
            ))
        }
        for remote in remotes where !mergedRemotes.contains(remote.fullName) {
            result.append(RefLabelItem(id: remote.fullName, title: remote.name, kind: .remote, isHead: false,
                                       hasLocal: false, hasRemote: true, names: [remote.name]))
        }
        for tag in refs where tag.kind == .tag {
            result.append(RefLabelItem(id: tag.fullName, title: tag.name, kind: .tag, isHead: false,
                                       hasLocal: false, hasRemote: false, names: [tag.name]))
        }
        return result.enumerated().sorted { lhs, rhs in
            let left = rank(lhs.element), right = rank(rhs.element)
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func rank(_ label: RefLabelItem) -> Int {
        if label.isHead { return 0 }
        switch label.kind {
        case .branch: return 1
        case .remote: return 2
        case .tag: return 3
        }
    }
}

/// A branch or tag label (`.lab`): tinted with the lane color, solid for HEAD's branch, with
/// kind icons after the name.
struct RefLabel: View {
    let label: RefLabelItem
    let lane: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 4) {
            if label.isHead {
                Icon(Icons.labelHead, size: 10)
            }
            Text(label.title)
                .lineLimit(1)
                .truncationMode(.tail)
            switch label.kind {
            case .branch:
                Icon(Icons.labelLocal, size: 12).foregroundStyle(iconColor)
                if label.hasRemote { Icon(Icons.labelRemote, size: 12).foregroundStyle(iconColor) }
                if let worktree = label.worktree {
                    // `.wtb`: checked out in another worktree.
                    Icon(Icons.worktreeMark, size: 12)
                        .foregroundStyle(label.isHead || selected ? Color.white : K.accentText)
                        .help("Checked out in the worktree \(worktree)")
                }
            case .remote:
                Icon(Icons.labelRemote, size: 12).foregroundStyle(iconColor)
            case .tag:
                Icon(Icons.labelTag, size: 11).foregroundStyle(iconColor)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(label.isHead || selected ? Color.white : K.label)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(selected ? Color.white.opacity(0.22) : (label.isHead ? K.lane1 : K.laneTint(lane)))
        )
        .overlay {
            // `.lab.wtlab`: a thin accent ring around a branch another worktree has.
            if label.worktree != nil, !selected, !label.isHead {
                RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(K.worktreeRing, lineWidth: 1)
            }
        }
        .help((label.names + [label.worktree.map { "Checked out in the worktree \($0)" }, doubleClick].compactMap { $0 })
            .joined(separator: "\n"))
    }

    private var iconColor: Color { label.isHead || selected ? .white : K.label2 }

    /// What a double-click on the label does (HistoryView's `switchTo`), as the sidebar says it.
    private var doubleClick: String? {
        switch label.kind {
        case .branch where label.isHead: nil
        case .branch: label.worktree == nil ? "Double-click to switch." : "Double-click to open the worktree."
        case .remote: "Double-click to check out a local branch that tracks it."
        case .tag: nil
        }
    }
}
