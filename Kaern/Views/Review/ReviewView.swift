import AppKit
import KaernKit
import SwiftUI

/// Review: the center shows the selection's changes as a diff, all files one under another or
/// one file at a time, Split (default) or Unified. Working-copy hunks can be staged here.
struct ReviewView: View {
    @Bindable var repository: RepositoryModel
    @AppStorage(DiffPreferences.layoutKey, store: .kaern) private var layout = DiffLayout.split
    @AppStorage(SettingsKey.diffWords, store: .kaern) private var words = true
    /// Files whose "Show More Lines" was clicked: how many lines they show.
    @State private var limits: [String: Int] = [:]

    private static let lineLimit = 2_000

    var body: some View {
        let state = repository.review ?? ReviewState()
        let files = repository.reviewFiles
        VStack(spacing: 0) {
            ReviewHeader(repository: repository, files: files ?? [], state: state, layout: $layout)
            if let files, files.contains(where: { !$0.pickable.isEmpty }), state.compare == nil {
                LinePickHint()
            }
            if let files {
                if files.isEmpty {
                    emptyState
                } else {
                    content(files: files, state: state)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(K.content)
        .overlay(alignment: .bottom) {
            if !repository.linePicks.isEmpty {
                LinePickBar(repository: repository)
                    .padding(.bottom, 44)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: repository.linePicks.isEmpty)
        .diffSettings()
        .onAppear { repository.diffViewers += 1 }
        .onDisappear { repository.diffViewers -= 1 }
        .onChange(of: repository.selection) { limits = [:] }
    }

    /// Line picking for a working-copy file whose diffs allow it.
    private func picking(for file: ReviewFile) -> LinePicking? {
        guard file.isWorking, !file.pickable.isEmpty, repository.review?.compare == nil else { return nil }
        let order = file.pickOrder
        let repository = repository
        return LinePicking(file: file, picks: repository.linePicks) { pick in
            let flags = NSEvent.modifierFlags
            repository.pickLine(pick, path: file.path, order: order,
                                command: flags.contains(.command), shift: flags.contains(.shift))
        }
    }

    @ViewBuilder
    private func content(files: [ReviewFile], state: ReviewState) -> some View {
        let shown: [ReviewFile] = state.showsAllFiles
            ? files
            : [files.first { $0.path == state.path } ?? files[0]]
        if !state.showsAllFiles, let file = shown.first, let special = file.special {
            // A picture, an LFS file or a submodule: its own page (ScreenMarks).
            SpecialFileView(file: file, special: special, repository: repository)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list(files: files, shown: shown, state: state)
        }
    }

    private func list(files: [ReviewFile], shown: [ReviewFile], state: ReviewState) -> some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if state.showsAllFiles {
                    FileIndex(files: files) { path in
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("file:" + path, anchor: .top) }
                    }
                }
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(shown) { file in
                            Section {
                                if let special = file.special {
                                    SpecialFileView(file: file, special: special, repository: repository, inList: true)
                                } else {
                                    let rows = DiffRowItem.rows(for: file, layout: layout, limit: limits[file.path] ?? Self.lineLimit, words: words)
                                    let picking = picking(for: file)
                                    ForEach(rows) { item in
                                        DiffRowView(item: item, repository: repository, picking: picking) {
                                            limits[file.path] = Int.max
                                        }
                                    }
                                }
                                K.sep.frame(height: 1)
                            } header: {
                                // The chips scroll to the header, so the file starts below it.
                                if state.showsAllFiles { FileSectionHeader(file: file).id("file:" + file.path) }
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
                .diffSideScrolling(resetKey: shown.map(\.path).joined(separator: "\n") + "\(layout)")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(repository.review?.compare != nil ? "No differences" : repository.selection == .workingCopy ? "No changes to review" : "This commit changes no files")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(K.label2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `.rvhead`: ‹ History, what's reviewed and its line counts, ‹ n of m ›, Split / Unified,
/// One File / All Files, and Stage File for a working-copy file.
private struct ReviewHeader: View {
    let repository: RepositoryModel
    let files: [ReviewFile]
    let state: ReviewState
    @Binding var layout: DiffLayout

    var body: some View {
        let current = currentIndex
        let file = files.indices.contains(current) ? files[current] : nil
        HStack(spacing: 8) {
            Button { repository.review = nil } label: {
                HStack(spacing: 3) {
                    Icon(Icons.arrowLeft, size: 12)
                    Text("History").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(K.accentText)
                .padding(.leading, 5)
                .padding(.trailing, 10)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(AccentPlateStyle())
            .keyboardShortcut(.cancelAction)
            HStack(spacing: 7) {
                if !state.showsAllFiles, let file {
                    StatusTile(letter: file.letter)
                    Text(file.path).truncationMode(.middle)
                    if file.isLFS { LFSBadge() }
                    if case .submodule? = file.special { KindPill(text: "Submodule") }
                } else {
                    Text(title).truncationMode(.tail)
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .layoutPriority(-1)
            if state.showsAllFiles || file?.special == nil {
                LineCounts(additions: state.showsAllFiles ? files.reduce(0) { $0 + $1.additions } : file?.additions ?? 0,
                           deletions: state.showsAllFiles ? files.reduce(0) { $0 + $1.deletions } : file?.deletions ?? 0)
            }
            Spacer(minLength: 0)
            if !state.showsAllFiles, let file, !file.pickable.isEmpty, state.compare == nil {
                Text(Self.stagedLines(file))
                    .font(.system(size: 12))
                    .foregroundStyle(K.label2)
                    .lineLimit(1)
                    .fixedSize()
            }
            if !state.showsAllFiles, !files.isEmpty {
                HStack(spacing: 2) {
                    StepButton(icon: Icons.arrowLeft, label: "Previous file") { show(current - 1) }
                        .disabled(current <= 0)
                    Text("\(current + 1) of \(files.count)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(K.label2)
                        .fixedSize()
                    StepButton(icon: Icons.arrowRight, label: "Next file") { show(current + 1) }
                        .disabled(current >= files.count - 1)
                }
            }
            if state.showsAllFiles || file?.special == nil {
                SegmentedChoice(options: [(DiffLayout.split, "Split"), (.unified, "Unified")], selection: $layout, label: "Diff layout")
            }
            GhostButton(title: state.showsAllFiles ? "One File" : "All Files") {
                repository.review = ReviewState(showsAllFiles: !state.showsAllFiles, path: file?.path, compare: state.compare)
            }
            if !state.showsAllFiles, let file, file.isWorking, state.compare == nil {
                GhostButton(title: file.hasUnstaged ? "Stage File" : "Unstage File") {
                    if file.hasUnstaged { repository.stage([file.path]) } else { repository.unstage([file.path]) }
                }
                .disabled(!repository.canChangeIndex)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: 44)
        .background(K.content)
        .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
    }

    /// "4 of 24 changed lines staged" (`.dmeta`).
    static func stagedLines(_ file: ReviewFile) -> String {
        var staged = 0, total = 0
        for hunk in file.hunks {
            let changed = hunk.hunk.lines.count(where: \.isChange)
            total += changed
            if hunk.stage == .staged { staged += changed }
        }
        return "\(staged) of \(total) changed lines staged"
    }

    private var title: String {
        if let compare = state.compare {
            let base = String(compare.base.prefix(7))
            return compare.target.map { "\(base) → \(String($0.prefix(7)))" } ?? "\(base) ↔ working copy"
        }
        switch repository.selection {
        case .workingCopy:
            return "Uncommitted changes · " + Formatters.count(files.count, "file", "files")
        case .commit(let id):
            return repository.commits.first { $0.id == id }?.subject ?? String(id.prefix(7))
        }
    }

    private var currentIndex: Int {
        guard let path = state.path, let index = files.firstIndex(where: { $0.path == path }) else { return 0 }
        return index
    }

    private func show(_ index: Int) {
        guard files.indices.contains(index) else { return }
        repository.review = ReviewState(showsAllFiles: false, path: files[index].path, compare: state.compare)
    }
}

/// `.kindp`: what a file is ("Submodule"), in a gray capsule.
struct KindPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(K.label2)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(K.hover))
            .fixedSize()
    }
}

/// `.rvindex`: a chip per file; clicking one scrolls to it.
private struct FileIndex: View {
    let files: [ReviewFile]
    let jump: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(files) { file in
                Button { jump(file.path) } label: {
                    HStack(spacing: 6) {
                        StatusTile(letter: file.letter)
                        Text(file.name).font(.system(size: 12)).foregroundStyle(K.label).lineLimit(1)
                    }
                    .padding(.leading, 5)
                    .padding(.trailing, 9)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(K.hover))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(file.path)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(K.content)
        .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
    }
}

/// `.fh`: the sticky header of a file in All Files.
private struct FileSectionHeader: View {
    let file: ReviewFile

    var body: some View {
        HStack(spacing: 8) {
            StatusTile(letter: file.letter)
            FilePathText(path: file.path, nameWeight: .semibold, size: 13)
            if let part = file.partText {
                Text(part).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(K.accentText).fixedSize()
            }
            Spacer(minLength: 0)
            LineCounts(additions: file.additions, deletions: file.deletions)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(height: 36)
        .background(K.inspector)
        .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
    }
}

/// `.back`: accent text with a soft accent plate on hover.
struct AccentPlateStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Plate(configuration: configuration)
    }

    private struct Plate: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering || configuration.isPressed ? K.accentSoft : .clear)
                )
                .onHover { hovering = $0 }
        }
    }
}

/// `.lshint`: how picking works, and the legend.
private struct LinePickHint: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("Click a changed line to pick it · ⇧-click picks a range · ⌘-click adds one")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(K.accentSoft)
                    .overlay(alignment: .leading) { K.accent.frame(width: 3) }
                    .frame(width: 10, height: 10)
                Text("picked")
                RoundedRectangle(cornerRadius: 2).fill(K.addGut)
                    .frame(width: 10, height: 10)
                    .padding(.leading, 8)
                Text("staged")
            }
            .fixedSize()
        }
        .font(.system(size: 11.5))
        .foregroundStyle(K.label2)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(K.alt)
        .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
    }
}

/// `.lsfloat`: what to do with the picked lines.
struct LinePickBar: View {
    let repository: RepositoryModel

    var body: some View {
        let picks = repository.linePicks
        let unstaged = picks.unstaged.count
        let staged = picks.staged.count
        let total = picks.lines.count
        HStack(spacing: 8) {
            Text(total == 1 ? "1 line picked" : "\(total) lines picked")
                .font(KFont.weighted(12.5, 0.35))
                .padding(.trailing, 4)
            if unstaged > 0 {
                PrimaryButton(title: unstaged == 1 ? "Stage 1 Line" : "Stage \(unstaged) Lines") { repository.stagePickedLines() }
                GhostButton(title: unstaged == 1 ? "Discard 1 Line" : "Discard \(unstaged) Lines") { repository.discardPickedLines() }
            } else {
                PrimaryButton(title: staged == 1 ? "Unstage 1 Line" : "Unstage \(staged) Lines") { repository.stagePickedLines() }
            }
            Button { repository.clearLinePicks() } label: {
                Icon(Icons.close, size: 11)
                    .foregroundStyle(K.label2)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverPlateStyle(radius: 6))
            .accessibilityLabel("Clear picked lines")
        }
        .disabled(!repository.canChangeIndex)
        .padding(EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 8))
        .popSurface(radius: 12)
        .fixedSize()
    }
}
