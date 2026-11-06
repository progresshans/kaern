import KaernKit
import SwiftUI

/// Review: the center shows the selection's changes as a diff, all files one under another or
/// one file at a time, Split (default) or Unified. Working-copy hunks can be staged here.
struct ReviewView: View {
    @Bindable var repository: RepositoryModel
    @AppStorage(DiffPreferences.layoutKey) private var layout = DiffLayout.split
    /// Files whose "Show More Lines" was clicked: how many lines they show.
    @State private var limits: [String: Int] = [:]

    private static let lineLimit = 2_000

    var body: some View {
        let state = repository.review ?? ReviewState()
        let files = repository.reviewFiles
        VStack(spacing: 0) {
            ReviewHeader(repository: repository, files: files ?? [], state: state, layout: $layout)
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
        .onAppear { repository.diffViewers += 1 }
        .onDisappear { repository.diffViewers -= 1 }
        .onChange(of: repository.selection) { limits = [:] }
    }

    @ViewBuilder
    private func content(files: [ReviewFile], state: ReviewState) -> some View {
        let shown: [ReviewFile] = state.showsAllFiles
            ? files
            : [files.first { $0.path == state.path } ?? files[0]]
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
                                let rows = DiffRowItem.rows(for: file, layout: layout, limit: limits[file.path] ?? Self.lineLimit)
                                ForEach(rows) { item in
                                    DiffRowView(item: item, repository: repository) {
                                        limits[file.path] = Int.max
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
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(repository.selection == .workingCopy ? "No changes to review" : "This commit changes no files")
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
                } else {
                    Text(title).truncationMode(.tail)
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .layoutPriority(-1)
            LineCounts(additions: state.showsAllFiles ? files.reduce(0) { $0 + $1.additions } : file?.additions ?? 0,
                       deletions: state.showsAllFiles ? files.reduce(0) { $0 + $1.deletions } : file?.deletions ?? 0)
            Spacer(minLength: 0)
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
            SegmentedChoice(options: [(DiffLayout.split, "Split"), (.unified, "Unified")], selection: $layout, label: "Diff layout")
            GhostButton(title: state.showsAllFiles ? "One File" : "All Files") {
                repository.review = ReviewState(showsAllFiles: !state.showsAllFiles, path: file?.path)
            }
            if !state.showsAllFiles, let file, file.isWorking {
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

    private var title: String {
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
        repository.review = ReviewState(showsAllFiles: false, path: files[index].path)
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
