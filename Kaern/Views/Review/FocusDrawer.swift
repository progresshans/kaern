import KaernKit
import SwiftUI

/// Focus mode's bottom drawer (`.drawer`, 330 pt unless dragged): the selection's title and facts,
/// its files on the left (working-copy files with a checkbox to stage them) and the picked file's diff.
struct FocusDrawer: View {
    static let height: CGFloat = 330

    @Bindable var repository: RepositoryModel
    let height: CGFloat
    let close: () -> Void
    @AppStorage(DiffPreferences.layoutKey, store: .kaern) private var layout = DiffLayout.split
    @State private var expanded: Set<String> = []

    var body: some View {
        let files = repository.reviewFiles
        let current = files.flatMap { files in files.first { $0.path == repository.drawerPath } ?? files.first }
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(files ?? []) { file in
                            DrawerFileRow(repository: repository, file: file, isCurrent: file.path == current?.path) {
                                repository.drawerPath = file.path
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .frame(width: 310)
                .overlay(alignment: .trailing) { K.sep.frame(width: 1) }
                Group {
                    if let current, let special = current.special {
                        SpecialFileView(file: current, special: special, repository: repository)
                    } else if let current {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                let limit = expanded.contains(current.path) ? Int.max : 2_000
                                ForEach(DiffRowItem.rows(for: current, layout: layout, limit: limit, words: AppSettings.diffWords)) { item in
                                    DiffRowView(item: item, repository: repository) { expanded.insert(current.path) }
                                }
                            }
                        }
                        .diffSideScrolling(resetKey: current.path + "\(layout)")
                    } else if files == nil {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text("No changes").font(.system(size: 13)).foregroundStyle(K.label2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(K.content)
            }
        }
        .frame(height: height)
        .background(K.inspector)
        .overlay(alignment: .top) { K.sepStrong.frame(height: 1) }
        .shadow(color: .black.opacity(0.06), radius: 9, y: -6)
        .diffSettings()
        .onAppear { repository.diffViewers += 1 }
        .onDisappear { repository.diffViewers -= 1 }
    }

    /// `.dhead`: title, facts, Split / Unified, Review All, ×.
    private var header: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            Text(meta)
                .font(.system(size: 12))
                .foregroundStyle(K.label2)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            SegmentedChoice(options: [(DiffLayout.split, "Split"), (.unified, "Unified")], selection: $layout, label: "Diff layout")
            GhostButton(title: "Review All") { repository.review = ReviewState(showsAllFiles: true) }
            Button(action: close) {
                Icon(Icons.closeLarge, size: 12)
                    .foregroundStyle(K.label2)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(HoverPlateStyle(radius: 13))
            .accessibilityLabel("Close details")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 40)
        .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
    }

    private var title: String {
        switch repository.selection {
        case .workingCopy: return "Uncommitted changes"
        case .commit(let id): return repository.commits.first { $0.id == id }?.subject ?? String(id.prefix(7))
        }
    }

    private var meta: String {
        switch repository.selection {
        case .workingCopy:
            return Formatters.count(repository.changeCount, "file", "files") + " · \(repository.stagedCount) staged"
        case .commit(let id):
            guard let commit = repository.commits.first(where: { $0.id == id }) else { return "" }
            return "\(commit.author.name) · \(Formatters.historyDate(commit.author.date)) · \(commit.shortID)"
        }
    }
}

/// A file in the drawer's list: a checkbox for working-copy files, then the file.
private struct DrawerFileRow: View {
    let repository: RepositoryModel
    let file: ReviewFile
    let isCurrent: Bool
    let show: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            if file.isWorking {
                let staged = file.hasStaged
                StageCheckbox(isOn: staged, label: (staged ? "Unstage " : "Stage ") + file.path) {
                    if staged { repository.unstage([file.path]) } else { repository.stage([file.path]) }
                }
                .disabled(!repository.canChangeIndex)
            }
            Button(action: show) {
                HStack(spacing: 7) {
                    StatusTile(letter: file.letter, selected: isCurrent)
                    FilePathText(path: file.path, selected: isCurrent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LineCounts(additions: file.additions, deletions: file.deletions, selected: isCurrent)
                }
                .padding(.horizontal, 6)
                .frame(height: KMetric.fileRow)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isCurrent ? K.sel : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(file.path)
        }
    }
}

/// `.cbx`: the system checkbox, 14 pt, with 4 pt on each side.
struct StageCheckbox: View {
    let isOn: Bool
    let label: String
    let toggle: () -> Void

    var body: some View {
        Toggle(label, isOn: Binding(get: { isOn }, set: { _ in toggle() }))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 22, height: KMetric.fileRow)
            .accessibilityLabel(label)
    }
}
