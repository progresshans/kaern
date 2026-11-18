import KaernKit
import SwiftUI

/// The right panel: what's selected in the history. The working copy shows its Unstaged and
/// Staged files with checkboxes (a partially staged file shows in both) and the commit
/// composer; a commit shows its details and files. Clicking a file opens it in Review.
struct DetailsPanel: View {
    let repository: RepositoryModel

    var body: some View {
        VStack(spacing: 0) {
            if let path = repository.selectedWorktree, let worktree = repository.otherWorktrees.first(where: { $0.path == path }) {
                // ScreenMarks › 워크트리: another working tree picked in the sidebar.
                WorktreePanel(repository: repository, worktree: worktree)
            } else if repository.branchCompare != nil || repository.picked.count == 2 {
                ComparePanel(repository: repository)
            } else if repository.picked.count >= 3 {
                MultiSelectPanel(repository: repository)
            } else {
                switch repository.selection {
                case .workingCopy:
                    WorkingCopyPanel(repository: repository)
                case .commit:
                    CommitPanel(repository: repository)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(K.inspector)
        .overlay(alignment: .leading) { K.sep.frame(width: 1) }
    }
}

// MARK: - Working copy

/// `.fstip` (ScreenBigRepo): git status is slow here; Git's file system monitor makes it quick.
private struct FSMonitorCard: View {
    let repository: RepositoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: z(8)) {
            Text("\(Text("git status takes \(seconds) in this repository.").bold()) Git’s file system monitor makes it close to instant.")
                .font(.system(size: z(12.5)))
                .lineSpacing(z(2))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: z(6)) {
                PrimaryButton(title: "Turn On") { repository.from("File system monitor tip") { repository.turnOnFSMonitor() } }
                    .disabled(repository.activity != nil)
                GhostButton(title: "Not Now") { repository.dismissFSMonitorSuggestion() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, z(12))
        .padding(.vertical, z(10))
        .background(RoundedRectangle(cornerRadius: z(9), style: .continuous).fill(K.accentSoft)
            .overlay(RoundedRectangle(cornerRadius: z(9), style: .continuous).strokeBorder(K.sep, lineWidth: 0.5)))
        .padding(EdgeInsets(top: z(10), leading: z(10), bottom: 0, trailing: z(10)))
    }

    private var seconds: String {
        let duration = repository.statusDuration ?? .zero
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.1f s", value)
    }
}

private struct WorkingCopyPanel: View {
    @Bindable var repository: RepositoryModel
    @AppStorage(DiffPreferences.treeKey, store: .kaern) private var tree = false
    /// The file lists have keyboard focus: ↑ ↓ open the file above or below.
    @FocusState private var filesFocused: Bool
    /// The list the reviewed file was opened from: a partly staged file is in both.
    @State private var openedStaged = false

    var body: some View {
        let entries = repository.status.entries
        VStack(alignment: .leading, spacing: 0) {
            if repository.suggestsFSMonitor {
                FSMonitorCard(repository: repository)
            }
            header(count: entries.count)
            if let big = repository.bigChanges {
                // ScreenBigRepo › 변경 파일 1만 개: folders instead of thousands of rows.
                if let suggestion = repository.ignoreSuggestion {
                    IgnoreSuggestionCard(repository: repository, suggestion: suggestion)
                }
                BigChangesList(repository: repository, big: big, tree: $tree)
            } else if entries.isEmpty {
                VStack(spacing: z(6)) {
                    Text("Working tree clean").font(.system(size: z(13), weight: .semibold)).foregroundStyle(K.label2)
                    Text("Changes you make in this folder show up here.")
                        .font(.system(size: z(12))).foregroundStyle(K.label2).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(z(20))
            } else {
                // In the order they show (a tree sorts them by folder).
                let unstaged = FileList.files(entries.filter(\.hasUnstagedChanges), tree: tree)
                let staged = FileList.files(entries.filter(\.hasStagedChanges), tree: tree)
                let current = current(unstaged: unstaged, staged: staged)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            PanelSectionHeader(title: "Unstaged Files (\(unstaged.count))", action: "Stage All") { repository.stageAll() }
                                .disabled(unstaged.isEmpty || !repository.canChangeIndex)
                            FileList(repository: repository, entries: unstaged, staged: false, tree: tree,
                                     current: current?.staged == false ? current?.path : nil) { open($0, staged: false) }
                            PanelSectionHeader(title: "Staged Files (\(staged.count))", action: "Unstage All") { repository.unstageAll() }
                                .disabled(staged.isEmpty || !repository.canChangeIndex)
                            FileList(repository: repository, entries: staged, staged: true, tree: tree,
                                     current: current?.staged == true ? current?.path : nil) { open($0, staged: true) }
                        }
                        .padding(EdgeInsets(top: 0, leading: z(8), bottom: z(8), trailing: z(8)))
                    }
                    .contextClip()
                    .arrowKeySteps($filesFocused) { step($0, unstaged: unstaged, staged: staged, proxy: proxy) }
                }
            }
            Composer(repository: repository)
        }
    }

    /// The row of the file Review shows: in the list it was opened from, else the one it's in.
    private func current(unstaged: [StatusEntry], staged: [StatusEntry]) -> (path: String, staged: Bool)? {
        guard let review = repository.review, !review.showsAllFiles, let path = review.path else { return nil }
        func has(_ list: [StatusEntry]) -> Bool { list.contains { $0.path == path } }
        if has(openedStaged ? staged : unstaged) { return (path, openedStaged) }
        if has(openedStaged ? unstaged : staged) { return (path, !openedStaged) }
        return nil
    }

    /// A click on a file, or ↑ ↓ onto it: Review shows it, and the lists take the arrow keys.
    private func open(_ path: String, staged: Bool) {
        openedStaged = staged
        filesFocused = true
        repository.review = ReviewState(showsAllFiles: false, path: path)
    }

    /// ↑ / ↓: opens the file above or below, from the end of Unstaged on into Staged.
    private func step(_ offset: Int, unstaged: [StatusEntry], staged: [StatusEntry], proxy: ScrollViewProxy) -> KeyPress.Result {
        let rows = unstaged.map { (path: $0.path, staged: false) } + staged.map { (path: $0.path, staged: true) }
        guard !rows.isEmpty else { return .ignored }
        let current = current(unstaged: unstaged, staged: staged)
        let index = current.flatMap { current in rows.firstIndex { $0.path == current.path && $0.staged == current.staged } }
        let next = ArrowKeyStep.target(from: index, by: offset, count: rows.count)
        guard next != index else { return .handled }
        open(rows[next].path, staged: rows[next].staged)
        proxy.scrollTo(FileList.rowID(rows[next].path, staged: rows[next].staged))
        return .handled
    }

    /// "git status 2.8 s · 12,408 files" (ScreenBigRepo).
    private func bigNote(count: Int) -> String {
        let files = Formatters.count(count, "file", "files")
        guard let duration = repository.statusDuration else { return files }
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "git status %.1f s · ", seconds) + files
    }

    /// `.ph`: "13 file changes on [branch]", then Path / Tree and Review All.
    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: z(9)) {
            let branch = repository.currentBranch ?? (repository.operation?.kind == .rebase ? repository.operation?.branch : nil)
            FlowLayout(spacing: z(5)) {
                Text((count == 0 ? "No changes" : Formatters.count(count, "file change", "file changes")) + (branch == nil ? "" : " on"))
                    .font(.system(size: z(12.5), weight: .semibold))
                    .frame(height: z(20))
                if let branch {
                    Text(branch)
                        .font(.system(size: z(11.5), weight: .semibold))
                        .foregroundStyle(K.accentText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, z(7))
                        .frame(height: z(20))
                        .background(RoundedRectangle(cornerRadius: z(5), style: .continuous).fill(K.lt1))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: z(6)) {
                SegmentedChoice(options: [(false, "Path"), (true, "Tree")], selection: $tree, label: "File list style")
                Spacer(minLength: 0)
                if repository.bigChanges != nil {
                    // Thousands of files: how long git status takes instead of Review All.
                    Text(bigNote(count: count))
                        .font(.system(size: z(11)))
                        .foregroundStyle(K.label2)
                        .lineLimit(1)
                } else {
                    GhostButton(title: "Review All") { repository.review = ReviewState(showsAllFiles: true) }
                        .disabled(count == 0)
                }
            }
        }
        .padding(EdgeInsets(top: z(12), leading: z(14), bottom: z(8), trailing: z(14)))
    }
}

/// `.psec`: "Unstaged Files (10)" with Stage All on the right.
struct PanelSectionHeader: View {
    let title: String
    let action: String
    let run: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        HStack(spacing: z(6)) {
            Text(title)
                .font(.system(size: z(11.5), weight: .semibold))
                .foregroundStyle(K.label2)
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.9)
            Spacer(minLength: 0)
            Button(action: run) {
                Text(action)
                    .font(.system(size: z(11.5), weight: .semibold))
                    .foregroundStyle(K.accentText)
                    .padding(.horizontal, z(5))
                    .padding(.vertical, z(2))
                    .background(RoundedRectangle(cornerRadius: z(5), style: .continuous).fill(hovering && isEnabled ? K.accentSoft : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
        }
        .padding(.horizontal, z(6))
        .frame(height: z(28))
        .padding(.top, z(4))
    }
}

/// The files of one list, as paths or as a tree (folder rows, files indented under them).
private struct FileList: View {
    let repository: RepositoryModel
    let entries: [StatusEntry]
    let staged: Bool
    let tree: Bool
    /// The file Review shows, when its row is in this list.
    let current: String?
    let open: (String) -> Void

    var body: some View {
        ForEach(Self.rows(entries, tree: tree, root: repository.name)) { row in
            switch row.kind {
            case .folder(let label):
                HStack(spacing: z(6)) {
                    Icon(Icons.folder, size: 13)
                    Text(label).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: z(12)))
                .foregroundStyle(K.label2)
                .padding(.horizontal, z(6))
                .frame(height: z(24))
            case .file(let entry):
                PanelFileRow(repository: repository, entry: entry, staged: staged, showsDirectory: !tree,
                             isReviewed: entry.path == current) { open(entry.path) }
                    .padding(.leading, tree ? z(14) : 0)
                    .id(Self.rowID(entry.path, staged: staged))
            }
        }
    }

    struct Row: Identifiable {
        enum Kind { case folder(String), file(StatusEntry) }
        let id: String
        let kind: Kind
    }

    /// A file's row, for scrolling to it (a partly staged file has one in each list).
    static func rowID(_ path: String, staged: Bool) -> String {
        (staged ? "staged:" : "unstaged:") + path
    }

    /// The files in the order the list shows them.
    static func files(_ entries: [StatusEntry], tree: Bool) -> [StatusEntry] {
        rows(entries, tree: tree, root: "").compactMap { row in
            if case .file(let entry) = row.kind { entry } else { nil }
        }
    }

    /// `root`: the label of the folder row for the files at the top level.
    static func rows(_ entries: [StatusEntry], tree: Bool, root: String) -> [Row] {
        guard tree else { return entries.map { Row(id: $0.path, kind: .file($0)) } }
        // Folders first (by path), then the files at the top level, like the board.
        func folder(_ path: String) -> String {
            let directory = (path as NSString).deletingLastPathComponent
            return directory.isEmpty ? "" : directory + "/"
        }
        let sorted = entries.sorted { lhs, rhs in
            let left = folder(lhs.path), right = folder(rhs.path)
            let leftKey = (left.isEmpty ? "1" : "0" + left) + "\u{0}" + lhs.path
            let rightKey = (right.isEmpty ? "1" : "0" + right) + "\u{0}" + rhs.path
            return leftKey.localizedStandardCompare(rightKey) == .orderedAscending
        }
        var result: [Row] = []
        var last: String?
        for entry in sorted {
            let directory = folder(entry.path)
            if directory != last {
                last = directory
                result.append(Row(id: "dir:" + directory, kind: .folder(directory.isEmpty ? "\(root) (root)" : directory)))
            }
            result.append(Row(id: entry.path, kind: .file(entry)))
        }
        return result
    }
}

/// `.frow`: a checkbox (on in the Staged list) and the file (`.file`): status tile, path,
/// "partial" when the file is in both lists, line counts. Clicking the file opens it in Review.
private struct PanelFileRow: View {
    let repository: RepositoryModel
    let entry: StatusEntry
    let staged: Bool
    let showsDirectory: Bool
    /// Review shows this row's file (only one of a partly staged file's two rows).
    let isReviewed: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let stat = staged ? repository.lineStats.staged[entry.path] : repository.lineStats.unstaged[entry.path]
        HStack(spacing: z(2)) {
            StageCheckbox(isOn: staged, label: (staged ? "Unstage " : "Stage ") + entry.path) {
                if staged { repository.unstage([entry.path]) } else { repository.stage([entry.path]) }
            }
            .disabled(!repository.canChangeIndex)
            Button(action: open) {
                HStack(spacing: z(7)) {
                    StatusTile(letter: letter, selected: isReviewed)
                    FilePathText(path: entry.path, showsDirectory: showsDirectory, selected: isReviewed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if entry.stageState == .partial {
                        Text("partial")
                            .font(.system(size: z(10.5), weight: .semibold))
                            .foregroundStyle(isReviewed ? .white.opacity(0.85) : K.accentText)
                    }
                    let marks = FileMarks(lfs: repository.workingMarks.lfsSizes[entry.path],
                                          notDownloaded: !staged && repository.workingMarks.lfsPointers.contains(entry.path),
                                          submoduleNote: staged ? nil : repository.workingMarks.submoduleNotes[entry.path],
                                          selected: isReviewed)
                    if marks.isEmpty {
                        LineCounts(additions: stat?.additions, deletions: stat?.deletions, selected: isReviewed)
                    } else {
                        marks
                    }
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

    /// The staged list shows what's in the index, the unstaged list what's in the work tree.
    private var letter: String {
        if entry.isConflicted { return "!" }
        if entry.submodule != nil { return "S" }
        if entry.isUntracked { return "A" }
        let status = staged ? entry.indexStatus : entry.worktreeStatus
        return ChangeKind(statusLetter: status)?.letter ?? entry.kind.letter
    }
}

/// `.composer`: Amend, the summary with its counter, the description, Commit N Files ▾.
private struct Composer: View {
    @Bindable var repository: RepositoryModel
    @FocusState private var descriptionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: z(7)) {
            Toggle(isOn: Binding(get: { repository.composer.amend }, set: { repository.setAmend($0) })) {
                Text("Amend previous commit")
                    .font(.system(size: z(12)))
                    .foregroundStyle(K.label2)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(repository.status.headID == nil)
            HStack(spacing: z(6)) {
                TextField("Commit summary", text: $repository.composer.summary)
                    .textFieldStyle(.plain)
                    .font(.system(size: z(13), weight: .semibold))
                    .onSubmit { descriptionFocused = true }
                SummaryCounter(count: repository.composer.summary.count)
            }
            .padding(.horizontal, z(9))
            .frame(height: z(30))
            .background(FieldBackground())
            TextEditor(text: $repository.composer.body)
                .font(.system(size: z(12)))
                .lineSpacing(z(3))
                .scrollContentBackground(.hidden)
                .focused($descriptionFocused)
                .padding(.horizontal, z(4))
                .padding(.vertical, z(5))
                .frame(height: z(64))
                .background(FieldBackground())
                .overlay(alignment: .topLeading) {
                    if repository.composer.body.isEmpty {
                        Text("Description")
                            .font(.system(size: z(12)))
                            .foregroundStyle(K.label2)
                            .padding(.leading, z(9))
                            .padding(.top, z(7))
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: 0) {
                Button { repository.commit() } label: {
                    Text(repository.commitButtonTitle)
                        .font(.system(size: z(13), weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!repository.canCommit)
                .opacity(repository.canCommit ? 1 : 0.45)
                Menu {
                    Button("Commit Without Running Hooks") { repository.commit(runHooks: false) }
                        .disabled(!repository.canCommit)
                    Divider()
                    Toggle("Amend Previous Commit", isOn: Binding(get: { repository.composer.amend }, set: { repository.setAmend($0) }))
                        .disabled(repository.status.headID == nil)
                } label: {
                    Icon(Icons.chevronDown, size: 11)
                        .foregroundStyle(.white)
                        .frame(width: z(30), height: z(32))
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .overlay(alignment: .leading) { Color.white.opacity(0.3).frame(width: 1) }
                .accessibilityLabel("Commit options")
            }
            .frame(height: z(32))
            .background(K.accent)
            .clipShape(RoundedRectangle(cornerRadius: z(8), style: .continuous))
        }
        .padding(EdgeInsets(top: z(10), leading: z(12), bottom: z(12), trailing: z(12)))
        .overlay(alignment: .top) { K.sep.frame(height: 1) }
    }
}

/// `--field` with the 0.5 pt `--sepStrong` ring and 7 pt corners.
private struct FieldBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: z(7), style: .continuous)
            .fill(K.field)
            .overlay(RoundedRectangle(cornerRadius: z(7), style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5))
    }
}

// MARK: - Commit details

private struct CommitPanel: View {
    let repository: RepositoryModel

    var body: some View {
        if let details = repository.selectedDetails {
            CommitInfoView(repository: repository, details: details, files: repository.selectedFiles,
                           highlightedPath: repository.review.flatMap { $0.showsAllFiles ? nil : $0.path },
                           openFile: { file in repository.review = ReviewState(showsAllFiles: false, path: file.path) },
                           reviewAll: { repository.review = ReviewState(showsAllFiles: true) })
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A commit's details (`.cd`): hash and parents, author, message, files, then Revert ·
/// Create Branch… · ⋯. Used for the selected commit and while exploring a file.
struct CommitInfoView: View {
    let repository: RepositoryModel
    let details: CommitDetails
    let files: [FileChange]
    var highlightedPath: String?
    let openFile: (FileChange) -> Void
    var reviewAll: (() -> Void)?
    /// The file rows have keyboard focus: ↑ ↓ open the file above or below.
    @FocusState private var filesFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            content
                .arrowKeySteps($filesFocused) { step($0, proxy) }
        }
        CommitActions(repository: repository, commit: details.commit)
    }

    /// Hash and parents, author, message, files.
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: z(8)) {
                    Text("commit").foregroundStyle(K.label2)
                    Text(details.commit.shortID).font(KFont.hash).foregroundStyle(K.label)
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(details.commit.id, forType: .string)
                    } label: {
                        Icon(Icons.copy, size: 12).foregroundStyle(K.label2).frame(width: z(18), height: z(18)).contentShape(Rectangle())
                    }
                    .buttonStyle(HoverPlateStyle(radius: z(5)))
                    .help("Copy the full commit hash")
                    ForEach(details.commit.parents, id: \.self) { parent in
                        Text("parent").foregroundStyle(K.label2)
                        Button {
                            if repository.commits.contains(where: { $0.id == parent }) {
                                repository.screen = nil
                                repository.selection = .commit(parent)
                                repository.scrollRequest = ScrollRequest(id: parent)
                            }
                        } label: {
                            Text(parent.prefix(7)).font(KFont.hash).foregroundStyle(K.accentText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.system(size: z(11.5)))
                HStack(spacing: z(9)) {
                    Text(details.commit.author.initials)
                        .font(.system(size: z(11), weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: z(28), height: z(28))
                        .background(Circle().fill(AvatarPalette.color(for: details.commit.author.email.isEmpty
                            ? details.commit.author.name : details.commit.author.email)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(details.commit.author.name).font(.system(size: z(13), weight: .semibold))
                        Text("authored \(Formatters.authoredAt(details.commit.author.date))")
                            .font(.system(size: z(11.5))).foregroundStyle(K.label2)
                    }
                }
                .padding(.top, z(12))
                // ScreenMarks › 서명: who signed it (the selected commit's panel).
                if let signed = repository.selectedSignature, signed.id == details.commit.id {
                    SignatureCard(repository: repository, signed: signed, committer: details.committer)
                }
                Text(details.commit.subject)
                    .font(.system(size: z(14), weight: .semibold))
                    .lineSpacing(z(2))
                    .padding(.top, z(12))
                    .textSelection(.enabled)
                if !details.body.isEmpty {
                    Text(details.body)
                        .font(.system(size: z(13)))
                        .foregroundStyle(K.label2)
                        .lineSpacing(z(2))
                        .padding(.top, z(5))
                        .textSelection(.enabled)
                }
                HStack(spacing: z(6)) {
                    Text(files.count == 1 ? "1 file changed" : "\(files.count.formatted()) files changed")
                    LineCounts(additions: files.reduce(0) { $0 + ($1.stat?.additions ?? 0) },
                               deletions: files.reduce(0) { $0 + ($1.stat?.deletions ?? 0) })
                    Spacer(minLength: 0)
                    if let reviewAll {
                        GhostButton(title: "Review All", action: reviewAll)
                            .disabled(files.isEmpty)
                    }
                }
                .font(.system(size: z(11.5), weight: .semibold))
                .foregroundStyle(K.label2)
                .padding(.top, z(16))
                .padding(.bottom, z(4))
                ForEach(files) { file in
                    CommitFileRow(file: file, isHighlighted: file.path == highlightedPath,
                                  marks: repository.commitMarks?.id == details.commit.id ? repository.commitMarks : nil) {
                        filesFocused = true
                        openFile(file)
                    }
                    .contextTarget(.commitFile(path: file.path, commit: details.commit.id), ring: ContextRing(radius: z(6), inset: 0))
                    .id("file:" + file.path)
                }
            }
            .padding(EdgeInsets(top: z(14), leading: z(14), bottom: z(10), trailing: z(14)))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contextClip()
    }

    /// ↑ / ↓: opens the file above or below the highlighted one, scrolled into view.
    private func step(_ offset: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !files.isEmpty else { return .ignored }
        let index = files.firstIndex { $0.path == highlightedPath }
        let next = ArrowKeyStep.target(from: index, by: offset, count: files.count)
        guard next != index else { return .handled }
        openFile(files[next])
        proxy.scrollTo("file:" + files[next].path)
        return .handled
    }
}

/// `.cdacts` under commit details: Revert, Create Branch… and ⋯ (the commit menu).
private struct CommitActions: View {
    let repository: RepositoryModel
    let commit: Commit

    var body: some View {
        let idle = repository.activity == nil
        PanelActions {
            GhostButton(title: "Revert") { repository.from("Commit details") { repository.revert([commit.id]) } }
                .disabled(!idle || !repository.isOnCurrentBranch(commit.id))
                .help(repository.isOnCurrentBranch(commit.id) ? "Revert \(commit.shortID) with a new commit" : "Not on this branch")
            GhostButton(title: "Create Branch…") { repository.from("Commit details") { repository.askCreateBranch(at: commit.id) } }
                .disabled(!idle)
            GhostButton(title: "⋯") {
                guard let menu = ContextMenus.commitMenu(commit.id, repository).map(ContextMenus.fitHeader), let event = NSApp.currentEvent,
                      let window = NSApp.keyWindow as? KaernWindow, let view = window.contentView else { return }
                window.showContextMenu(menu, for: window.contextTracker?.view(for: .commit(commit.id)), event: event, in: view)
            }
            .accessibilityLabel("More commit actions")
            Spacer(minLength: 0)
        }
    }
}

/// A file of a commit; clicking it opens it (in Review, or its history while exploring).
private struct CommitFileRow: View {
    let file: FileChange
    let isHighlighted: Bool
    var marks: CommitMarks?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: z(7)) {
                StatusTile(letter: file.submodule != nil ? "S" : file.kind.letter, selected: isHighlighted)
                FilePathText(path: file.path, selected: isHighlighted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                let fileMarks = FileMarks(lfs: marks?.lfsSizes[file.path], notDownloaded: marks?.lfsMissing.contains(file.path) == true,
                                          selected: isHighlighted)
                if fileMarks.isEmpty {
                    LineCounts(additions: file.stat?.additions, deletions: file.stat?.deletions, selected: isHighlighted)
                } else {
                    fileMarks
                }
            }
            .padding(.horizontal, z(6))
            .frame(height: KMetric.fileRow)
            .background(
                RoundedRectangle(cornerRadius: z(6), style: .continuous)
                    .fill(isHighlighted ? K.sel : (hovering ? K.hover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
    }
}
