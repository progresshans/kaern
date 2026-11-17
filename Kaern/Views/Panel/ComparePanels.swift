import AppKit
import KaernKit
import SwiftUI

/// The right panel while comparing (ScreenFlowReview): two picked commits, or the current
/// branch against another. Files open in Review on that comparison.
struct ComparePanel: View {
    let repository: RepositoryModel

    var body: some View {
        let comparison = repository.comparison?.key == repository.comparisonKey ? repository.comparison : nil
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let comparison {
                        switch comparison.kind {
                        case .commits(let older, let newer):
                            commits(comparison, older: older, newer: newer)
                        case .branches(let theirs):
                            branches(comparison, theirs: theirs)
                        }
                        files(comparison)
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            PanelActions {
                GhostButton(title: "Done") { repository.clearPicks() }
                Spacer(minLength: 0)
                if let comparison, case .branches(let theirs) = comparison.kind, comparison.theirsCount > 0 {
                    PrimaryButton(title: "Merge into Current Branch") {
                        repository.clearPicks()
                        repository.from("Compare panel") { repository.merge(theirs) }
                    }
                    .help("Merge \(theirs) into \(repository.status.branch ?? "HEAD")")
                    .disabled(repository.activity != nil || repository.status.branch == nil)
                }
            }
        }
    }

    // MARK: Two commits

    @ViewBuilder
    private func commits(_ comparison: Comparison, older: String, newer: String) -> some View {
        let swapped = repository.compareSwapped
        let a = swapped ? newer : older, b = swapped ? older : newer
        PanelKicker(text: "Comparing two commits")
        HStack(spacing: 8) {
            HashChip(text: repository.short(a))
            Icon(Icons.arrowRightLong, size: 14).foregroundStyle(K.label2)
            HashChip(text: repository.short(b))
            Spacer(minLength: 0)
            Button { repository.compareSwapped.toggle() } label: {
                Icon(Icons.swap, size: 12).foregroundStyle(K.label2).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(HoverPlateStyle(radius: 6))
            .help("Swap")
            .accessibilityLabel("Swap sides")
        }
        .padding(.top, 8)
        let count = comparison.betweenCount
        let range = Formatters.count(count, "commit", "commits") + " from \(repository.short(older)) to \(repository.short(newer))"
        let split = comparison.linear ? "" : comparison.base.map { " · they split at \(repository.short($0))" } ?? ""
        PanelBody(text: range + split + (swapped ? " · shown in reverse" : ""))
        PanelHeading(text: comparison.linear ? "Commits in between" : "Commits since \(comparison.base.map(repository.short) ?? "they split")")
        CommitList(commits: comparison.between, total: count, repository: repository)
    }

    // MARK: Branches

    @ViewBuilder
    private func branches(_ comparison: Comparison, theirs: String) -> some View {
        let ours = repository.status.branch ?? "HEAD"
        PanelKicker(text: "Comparing branches")
        BranchCountRow(color: K.accent, name: ours, count: comparison.oursCount, tip: "\(comparison.oursCount) commits only on \(ours)")
            .padding(.top, 6)
        BranchCountRow(color: K.lane2, name: theirs, count: comparison.theirsCount, tip: "\(comparison.theirsCount) commits only on \(theirs)")
        PanelBody(text: branchSummary(comparison, ours: ours, theirs: theirs))
        PanelHeading(text: "Only on \(ours)", bar: K.accent)
        CommitList(commits: comparison.ours, total: comparison.oursCount, repository: repository)
        PanelHeading(text: "Only on \(theirs)", bar: K.lane2)
        CommitList(commits: comparison.theirs, total: comparison.theirsCount, repository: repository)
    }

    private func branchSummary(_ comparison: Comparison, ours: String, theirs: String) -> String {
        if comparison.theirsCount == 0 { return "\(theirs) is already part of \(ours). Nothing to merge." }
        if comparison.oursCount == 0 { return "Merging would fast-forward \(ours)." }
        guard let base = comparison.base else { return "They don’t share any history." }
        let date = repository.commit(base).map { " · " + Formatters.historyDate($0.author.date) } ?? ""
        return "They split at \(repository.short(base))\(date)."
    }

    // MARK: Files

    @ViewBuilder
    private func files(_ comparison: Comparison) -> some View {
        let additions = comparison.files.reduce(0) { $0 + ($1.stat?.additions ?? 0) }
        let deletions = comparison.files.reduce(0) { $0 + ($1.stat?.deletions ?? 0) }
        let isBranches: Bool = { if case .branches = comparison.kind { true } else { false } }()
        HStack(spacing: 6) {
            Text(Formatters.count(comparison.files.count, "file", "files") + (isBranches ? " differ" : " changed"))
            LineCounts(additions: additions, deletions: deletions)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(K.label2)
        .padding(.top, 16)
        .padding(.bottom, 4)
        ForEach(comparison.files) { file in
            CompareFileRow(file: file) { open(file.path, comparison) }
        }
    }

    private func open(_ path: String, _ comparison: Comparison) {
        let range: CompareRange
        switch comparison.kind {
        case .commits(let older, let newer):
            range = repository.compareSwapped ? CompareRange(base: newer, target: older) : CompareRange(base: older, target: newer)
        case .branches(let theirs):
            range = CompareRange(base: repository.status.headID ?? "HEAD", target: theirs)
        }
        repository.review = ReviewState(showsAllFiles: false, path: path, compare: range)
    }
}

/// The panel with 3+ picked commits: what they are and what to do with all of them.
struct MultiSelectPanel: View {
    let repository: RepositoryModel

    var body: some View {
        let ids = repository.picked.sorted { repository.row(of: $0) < repository.row(of: $1) }
        let commits = ids.compactMap(repository.commit)
        let branch = repository.status.branch ?? "HEAD"
        let onBranch = commits.filter { repository.isOnCurrentBranch($0.id) }
        let elsewhere = commits.count - onBranch.count
        let idle = repository.activity == nil
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("\(commits.count) commits selected")
                        .font(.system(size: 14, weight: .semibold))
                    PanelBody(text: elsewhere == commits.count ? "None of them are on \(branch)."
                              : onBranch.count == commits.count ? "All of them are on \(branch)."
                              : "\(onBranch.count) on \(branch), \(elsewhere) elsewhere.")
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(commits) { commit in
                            HStack(spacing: 8) {
                                Circle().fill(K.lane(repository.lane(of: commit.id))).frame(width: 8, height: 8)
                                Text(commit.shortID).font(KFont.hash).foregroundStyle(K.label2)
                                Text(commit.subject).lineLimit(1).truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button { repository.picked.removeAll { $0 == commit.id } } label: {
                                    Icon(Icons.close, size: 9).foregroundStyle(K.label2).frame(width: 18, height: 18).contentShape(Rectangle())
                                }
                                .buttonStyle(HoverPlateStyle(radius: 5))
                                .accessibilityLabel("Remove \(commit.shortID) from the selection")
                            }
                            .font(.system(size: 12.5))
                            .frame(minHeight: 24)
                        }
                    }
                    .padding(.top, 8)
                    PanelHeading(text: "With all of them")
                    VStack(spacing: 6) {
                        let noneOnBranch = elsewhere == commits.count
                        let allOnBranch = onBranch.count == commits.count
                        let hasMerge = commits.contains(where: \.isMerge)
                        // The branch name wraps as a whole (word joiners after its / and -).
                        let unbroken = branch.replacingOccurrences(of: "/", with: "/\u{2060}")
                            .replacingOccurrences(of: "-", with: "-\u{2060}")
                        BulkAction(title: "Cherry-pick \(commits.count) Commits onto \(unbroken)",
                                   note: noneOnBranch ? (hasMerge ? "Merge commits can’t be picked together" : "Oldest first, as new commits") : "Some are already on \(branch)",
                                   isDefault: true, enabled: idle && noneOnBranch && !hasMerge) {
                            let picked = repository.picked
                            repository.clearPicks()
                            repository.from("Multi-select panel") { repository.cherryPick(picked) }
                        }
                        BulkAction(title: "Revert \(commits.count) Commits",
                                   note: allOnBranch ? (hasMerge ? "Merge commits can’t be reverted together" : "Newest first, one revert commit each") : "Only commits on \(branch) can be reverted",
                                   enabled: idle && allOnBranch && !hasMerge) {
                            let picked = repository.picked
                            repository.clearPicks()
                            repository.from("Multi-select panel") { repository.revert(picked) }
                        }
                        let squashReason = repository.squashUnavailableReason(repository.picked)
                        BulkAction(title: "Squash \(commits.count) into One…",
                                   note: squashReason ?? "Opens the interactive rebase with them folded into the oldest",
                                   enabled: idle && squashReason == nil) {
                            let picked = repository.picked
                            repository.clearPicks()
                            repository.from("Multi-select panel") { repository.askSquash(picked) }
                        }
                        if let oldest = commits.last, let newest = commits.first {
                            BulkAction(title: "Compare Oldest with Newest", note: "\(oldest.shortID) → \(newest.shortID)") {
                                repository.picked = [oldest.id, newest.id]
                            }
                        }
                        BulkAction(title: "Copy \(commits.count) SHAs", note: commits.map(\.shortID).joined(separator: " ")) {
                            repository.copySHAs(commits.map(\.id))
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            PanelActions {
                GhostButton(title: "Clear Selection") { repository.clearPicks() }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Pieces

/// `.cdacts`: buttons along the panel's bottom edge.
struct PanelActions<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { K.sep.frame(height: 1) }
    }
}

/// `.cmpk`: "COMPARING TWO COMMITS".
private struct PanelKicker: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(KFont.weighted(11, 0.35))
            .kerning(0.3)
            .foregroundStyle(K.label2)
    }
}

/// `.cdbody`: a sentence in secondary text.
private struct PanelBody: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .lineSpacing(2)
            .foregroundStyle(K.label2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
    }
}

/// `.prH`: a small heading, with the branch's bar in branch compare.
private struct PanelHeading: View {
    let text: String
    var bar: Color?

    var body: some View {
        HStack(spacing: 7) {
            if let bar { RoundedRectangle(cornerRadius: 2).fill(bar).frame(width: 3, height: 12) }
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .font(KFont.weighted(11.5, 0.35))
        .foregroundStyle(K.label2)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }
}

/// `.cmpa`: a hash in a gray chip.
private struct HashChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(K.chip2))
    }
}

/// `.bcrow`: a branch's bar, name and how many commits only it has.
private struct BranchCountRow: View {
    let color: Color
    let name: String
    let count: Int
    let tip: String

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3, height: 16)
            Text(name)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(count)")
                .font(KFont.weighted(11, 0.35))
                .foregroundStyle(K.label2)
                .padding(.horizontal, 6)
                .frame(minWidth: 20, minHeight: 18)
                .background(Capsule().fill(K.chip2))
                .help(tip)
        }
        .frame(minHeight: 26)
    }
}

/// `.ckr` rows: hash and summary; "and N more" when the list is cut.
private struct CommitList: View {
    let commits: [CommitSummary]
    let total: Int
    let repository: RepositoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if commits.isEmpty {
                Text("None").font(.system(size: 12.5)).foregroundStyle(K.label3).frame(minHeight: 24)
            }
            ForEach(commits) { commit in
                Button {
                    if repository.commit(commit.id) != nil { repository.scrollRequest = ScrollRequest(id: commit.id) }
                } label: {
                    HStack(spacing: 8) {
                        Text(commit.shortID).font(KFont.hash).foregroundStyle(K.label2)
                        Text(commit.subject).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 12.5))
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if total > commits.count {
                Text("and \(total - commits.count) more").font(.system(size: 12)).foregroundStyle(K.label2).frame(minHeight: 22)
            }
        }
    }
}

/// A changed file of the comparison; opens it in Review.
private struct CompareFileRow: View {
    let file: FileChange
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 7) {
                StatusTile(letter: file.kind.letter)
                FilePathText(path: file.path).frame(maxWidth: .infinity, alignment: .leading)
                LineCounts(additions: file.stat?.additions, deletions: file.stat?.deletions)
            }
            .padding(.horizontal, 6)
            .frame(height: KMetric.fileRow)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? K.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
    }
}

/// `.mab`: a bulk action with what it does under its title; the first one is filled.
private struct BulkAction: View {
    let title: String
    let note: String
    var isDefault = false
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let filled = isDefault && enabled
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(note).font(.system(size: 11)).foregroundStyle(filled ? Color.white.opacity(0.85) : K.label2).lineLimit(2)
            }
            .foregroundStyle(filled ? Color.white : K.label)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                if filled {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(K.accent)
                        .shadow(color: K.shadowCtl, radius: 0.75, y: 0.5)
                } else {
                    Color.clear.controlSurface(radius: 8)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(hovering && enabled ? K.accent : .clear, lineWidth: 1))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
    }
}

extension RepositoryModel {
    /// A commit's row in the loaded history (newer rows are lower numbers).
    func row(of id: String) -> Int { commits.firstIndex { $0.id == id } ?? Int.max }

    /// The lane a loaded commit is drawn in.
    func lane(of id: String) -> Int {
        guard let index = commits.firstIndex(where: { $0.id == id }) else { return 0 }
        let graphIndex = index + (showsWorkingCopy ? 1 : 0)
        return graph.indices.contains(graphIndex) ? graph[graphIndex].lane : 0
    }
}
