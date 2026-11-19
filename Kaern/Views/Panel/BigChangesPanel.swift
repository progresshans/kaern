import KaernKit
import SwiftUI

/// `.bigtip` (ScreenBigRepo › 변경 파일 1만 개): most of the changes are new files in one folder.
struct IgnoreSuggestionCard: View {
    let repository: RepositoryModel
    let suggestion: IgnoreSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: z(8)) {
            Text("\(Text("\(suggestion.count.formatted()) of them are in \(suggestion.folder).").bold()) They look generated. Ignore the folder?")
                .font(.system(size: z(12)))
                .lineSpacing(z(2))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: z(6)) {
                PrimaryButton(title: "Add to .gitignore") {
                    repository.from("Ignore suggestion") { repository.ignoreSuggestedFolder() }
                }
                .disabled(repository.activity != nil)
                GhostButton(title: "Not Now") { repository.dismissIgnoreSuggestion() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, z(12))
        .padding(.vertical, z(10))
        .background(RoundedRectangle(cornerRadius: z(9), style: .continuous).fill(K.modBg)
            .overlay(RoundedRectangle(cornerRadius: z(9), style: .continuous).strokeBorder(K.sep, lineWidth: 0.5)))
        .padding(EdgeInsets(top: z(10), leading: z(10), bottom: 0, trailing: z(10)))
    }
}

/// The working copy's files when there are thousands: one list with checkboxes (on: staged), the
/// files at the top of the repository, then a row per folder with how many files it holds, biggest
/// first. An open folder shows its first files and "309 more in apps/web/". Path lists the
/// first paths and points to Tree for the rest. Rows are built as they scroll into view.
struct BigChangesList: View {
    @Bindable var repository: RepositoryModel
    let big: BigChanges
    @Binding var tree: Bool

    static let firstFiles = 50
    static let batch = 500
    static let firstPaths = 300

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PanelSectionHeader(title: "Changes (\(big.unstagedCount.formatted()) unstaged · \(big.stagedCount.formatted()) staged)",
                              action: big.unstagedCount > 0 ? "Stage All" : "Unstage All") {
                    if big.unstagedCount > 0 { repository.stageAll() } else { repository.unstageAll() }
                }
                .disabled(!repository.canChangeIndex)
                if tree {
                    ForEach(big.rootEntries) { entry in
                        BigFileRow(repository: repository, entry: entry, shownPath: entry.path)
                    }
                    ForEach(big.folders) { folder in
                        folderRows(folder)
                    }
                } else {
                    let paths = firstPaths()
                    ForEach(paths) { entry in
                        BigFileRow(repository: repository, entry: entry, shownPath: entry.path)
                    }
                    if big.total > paths.count {
                        MoreRow(title: "\((big.total - paths.count).formatted()) more · Tree lists them by folder") { tree = true }
                    }
                }
            }
            .padding(EdgeInsets(top: 0, leading: z(8), bottom: z(8), trailing: z(8)))
        }
        .contextClip()
    }

    @ViewBuilder
    private func folderRows(_ folder: BigChanges.Folder) -> some View {
        let open = repository.openChangeFolders.contains(folder.path)
        BigFolderRow(repository: repository, folder: folder, open: open,
                     suggested: repository.ignoreSuggestion?.folder == folder.path)
        if open {
            let limit = Self.firstFiles + (repository.changeFolderExtra[folder.path] ?? 0)
            ForEach(folder.entries.prefix(limit)) { entry in
                BigFileRow(repository: repository, entry: entry, shownPath: String(entry.path.dropFirst(folder.path.count)))
                    .padding(.leading, z(22))
            }
            if folder.entries.count > limit {
                MoreRow(title: "\((folder.entries.count - limit).formatted()) more in \(folder.path)") {
                    repository.changeFolderExtra[folder.path, default: 0] += Self.batch
                }
                .padding(.leading, z(22))
            }
        }
    }

    /// The first paths in the order Tree lists them, without joining every folder's files.
    private func firstPaths() -> [StatusEntry] {
        var result = Array(big.rootEntries.prefix(Self.firstPaths))
        for folder in big.folders where result.count < Self.firstPaths {
            result += folder.entries.prefix(Self.firstPaths - result.count)
        }
        return result
    }
}

/// `.brow.tdir`: checkbox (stages the whole folder), chevron, folder, its path and how many files
/// it holds; the folder the card suggests ignoring is in the modified color.
private struct BigFolderRow: View {
    let repository: RepositoryModel
    let folder: BigChanges.Folder
    let open: Bool
    let suggested: Bool
    @State private var hovering = false

    var body: some View {
        let allStaged = folder.unstagedCount == 0
        HStack(spacing: z(2)) {
            StageCheckbox(isOn: allStaged, label: (allStaged ? "Unstage " : "Stage ") + folder.path) {
                repository.stageFolder(folder, staged: allStaged)
            }
            .disabled(!repository.canChangeIndex)
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if open { repository.openChangeFolders.remove(folder.path) } else { repository.openChangeFolders.insert(folder.path) }
                }
            } label: {
                HStack(spacing: z(6)) {
                    Icon(Icons.chevronDown, size: 9)
                        .foregroundStyle(K.label2)
                        .rotationEffect(.degrees(open ? 0 : -90))
                    Icon(Icons.folder, size: 13)
                        .foregroundStyle(K.label2)
                    Text(folder.path)
                        .font(.system(size: z(12.5), weight: .semibold))
                        .foregroundStyle(suggested ? K.mod : K.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(folder.entries.count.formatted())
                        .font(KFont.weighted(11, 0.65))
                        .monospacedDigit()
                        .foregroundStyle(suggested ? K.mod : K.label2)
                }
                .padding(.horizontal, z(6))
                .frame(height: KMetric.fileRow)
                .background(RoundedRectangle(cornerRadius: z(6), style: .continuous).fill(hovering ? K.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityValue(open ? "expanded" : "collapsed")
            .help("\(folder.path) — \(Formatters.count(folder.entries.count, "changed file", "changed files"))")
        }
    }
}

/// A file in the big list: the checkbox is on when all of it is staged; the path is shown from
/// its folder ("base/scheduler.yaml" under apps/web/). Clicking it opens it in Review.
private struct BigFileRow: View {
    let repository: RepositoryModel
    let entry: StatusEntry
    let shownPath: String
    @State private var hovering = false

    var body: some View {
        let staged = entry.stageState == .staged
        let isReviewed = repository.review.map { !$0.showsAllFiles && $0.path == entry.path } ?? false
        let stat = entry.hasUnstagedChanges ? repository.lineStats.unstaged[entry.path] : repository.lineStats.staged[entry.path]
        HStack(spacing: z(2)) {
            StageCheckbox(isOn: staged, label: (staged ? "Unstage " : "Stage ") + entry.path) {
                if staged { repository.unstage([entry.path]) } else { repository.stage([entry.path]) }
            }
            .disabled(!repository.canChangeIndex)
            Button {
                repository.review = ReviewState(showsAllFiles: false, path: entry.path)
            } label: {
                HStack(spacing: z(7)) {
                    StatusTile(letter: letter, selected: isReviewed)
                    FilePathText(path: shownPath, selected: isReviewed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if entry.stageState == .partial {
                        Text("partial")
                            .font(.system(size: z(10.5), weight: .semibold))
                            .foregroundStyle(isReviewed ? .white.opacity(0.85) : K.accentText)
                    }
                    LineCounts(additions: stat?.additions, deletions: stat?.deletions, selected: isReviewed)
                }
                .padding(.horizontal, z(6))
                .frame(height: KMetric.fileRow)
                .background(
                    RoundedRectangle(cornerRadius: z(6), style: .continuous)
                        .fill(isReviewed ? K.sel : (hovering ? K.hover : .clear))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(entry.path)
            .contextTarget(.file(path: entry.path, staged: staged), ring: ContextRing(radius: z(6), inset: 0))
        }
    }

    private var letter: String {
        if entry.isConflicted { return "!" }
        if entry.submodule != nil { return "S" }
        if entry.isUntracked { return "A" }
        let status = entry.hasStagedChanges ? entry.indexStatus : entry.worktreeStatus
        return ChangeKind(statusLetter: status)?.letter ?? entry.kind.letter
    }
}

/// `.tmore`: "309 more in apps/web/" — a click shows the next ones.
private struct MoreRow: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: z(11.5)))
                .foregroundStyle(hovering ? K.accentText : K.label2)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(EdgeInsets(top: z(3), leading: z(26), bottom: z(5), trailing: z(6)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
