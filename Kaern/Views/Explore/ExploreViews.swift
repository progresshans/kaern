import AppKit
import KaernKit
import SwiftUI

/// File History and Blame (ScreenExplore): one file in the center — the commits that changed it
/// with the picked one's change below, or each line's last commit with an age stripe.
struct ExploreView: View {
    @Bindable var repository: RepositoryModel
    @AppStorage(DiffPreferences.layoutKey, store: .kaern) private var layout = DiffLayout.split
    @AppStorage(SettingsKey.diffWords, store: .kaern) private var words = true

    var body: some View {
        VStack(spacing: 0) {
            if let state = repository.explore {
                header(state)
                switch state.mode {
                case .history: history(state)
                case .blame: BlameView(repository: repository, state: state)
                }
            }
        }
        .background(K.content)
        .diffSettings()
    }

    // MARK: Header

    private func header(_ state: ExploreState) -> some View {
        HStack(spacing: 8) {
            Button { repository.screen = nil } label: {
                HStack(spacing: 3) {
                    Icon(Icons.arrowLeft, size: 12)
                    Text("Graph").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(K.accentText)
                .padding(.leading, 5)
                .padding(.trailing, 10)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(AccentPlateStyle())
            .keyboardShortcut(.cancelAction)
            HStack(spacing: 6) {
                Icon(Icons.file, size: 14).foregroundStyle(K.label2)
                FilePathText(path: state.path, nameWeight: .semibold, size: 13)
            }
            .layoutPriority(-1)
            Spacer(minLength: 0)
            if state.mode == .history {
                if let entries = repository.fileHistory?.entries, repository.fileHistory?.path == state.path {
                    Text(Formatters.count(entries.count, "commit changed this file", "commits changed this file") + " · follows renames")
                        .font(.system(size: 12))
                        .foregroundStyle(K.label2)
                        .lineLimit(1)
                }
            } else {
                HStack(spacing: 7) {
                    Text("Blame at").font(.system(size: 12)).foregroundStyle(K.label2)
                    Picker("Blame at", selection: Binding(get: { state.blameAt ?? "" }, set: { value in
                        repository.setBlameOptions(at: .some(value.isEmpty ? nil : value))
                    })) {
                        Text("Working Copy").tag("")
                        ForEach(blameRevisions(state), id: \.id) { choice in Text(choice.title).tag(choice.id) }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
            }
            SegmentedChoice(options: [(ExploreState.Mode.history, "History"), (.blame, "Blame")],
                            selection: Binding(get: { state.mode }, set: { repository.setExploreMode($0) }), label: "File view")
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: 44)
        .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
    }

    /// Blame at: the working copy, then the commits that changed the file.
    private func blameRevisions(_ state: ExploreState) -> [(id: String, title: String)] {
        var choices: [(String, String)] = []
        if let entries = repository.fileHistory?.entries, repository.fileHistory?.path == state.path {
            choices = entries.prefix(40).map { ($0.commit.id, "\($0.commit.shortID) · \($0.commit.subject)") }
        }
        if let at = state.blameAt, !choices.contains(where: { $0.0 == at }) {
            choices.insert((at, String(at.prefix(7))), at: 0)
        }
        return choices
    }

    // MARK: History

    @ViewBuilder
    private func history(_ state: ExploreState) -> some View {
        if let entries = repository.fileHistory?.entries, repository.fileHistory?.path == state.path {
            if entries.isEmpty {
                Text("No commits changed this file — it isn’t committed yet.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(K.label2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        historyList(entries, state: state)
                            .frame(height: min(CGFloat(entries.count) * 30 + 8, max(geometry.size.height * 0.4, 128)))
                        K.sep.frame(height: 1)
                        historyDiff(state)
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func historyList(_ entries: [FileHistoryEntry], state: ExploreState) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        HistoryRow(entry: entry, note: repository.historyNote(entry, index: index, entries: entries),
                                   isOn: state.selected == entry.commit.id, isAlt: index % 2 == 1) {
                            repository.selectHistoryEntry(entry.commit.id)
                        }
                        .contextTarget(.commit(entry.commit.id), ring: ContextRing(radius: 0, inset: 0))
                        .id(entry.commit.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .contextClip()
            .onAppear { if let id = state.selected { proxy.scrollTo(id, anchor: .center) } }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { step(-1, entries) }
            .onKeyPress(.downArrow) { step(1, entries) }
        }
    }

    private func step(_ offset: Int, _ entries: [FileHistoryEntry]) -> KeyPress.Result {
        guard let selected = repository.explore?.selected, let index = entries.firstIndex(where: { $0.commit.id == selected }) else {
            return .ignored
        }
        let next = min(max(index + offset, 0), entries.count - 1)
        repository.selectHistoryEntry(entries[next].commit.id)
        return .handled
    }

    @ViewBuilder
    private func historyDiff(_ state: ExploreState) -> some View {
        let entry = state.selected.flatMap { id in repository.fileHistory?.entries.first { $0.commit.id == id } }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let entry {
                    Text(entry.commit.shortID).font(KFont.hash).foregroundStyle(K.label2)
                    Text(entry.commit.subject).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text((entry.path as NSString).lastPathComponent).font(.system(size: 12)).foregroundStyle(K.label2).lineLimit(1)
                }
                Spacer(minLength: 0)
                SegmentedChoice(options: [(DiffLayout.split, "Split"), (.unified, "Unified")], selection: $layout, label: "Diff layout")
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(height: 40)
            .background(K.alt)
            .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
            if let file = repository.historyReviewFile, repository.fileHistoryDiff?.key.hasPrefix((state.selected ?? "") + ":") == true {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(DiffRowItem.rows(for: file, layout: layout, limit: 4_000, words: words)) { item in
                            DiffRowView(item: item, repository: repository)
                        }
                    }
                    .padding(.bottom, 20)
                }
                .diffSideScrolling(resetKey: (state.selected ?? "") + file.path + "\(layout)")
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// `.fhr`: hash, subject (and a rename note), author, date, line counts.
private struct HistoryRow: View {
    let entry: FileHistoryEntry
    let note: String?
    let isOn: Bool
    let isAlt: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(entry.commit.shortID)
                    .font(KFont.hash)
                    .foregroundStyle(isOn ? .white.opacity(0.88) : K.label2)
                    .frame(width: 72, alignment: .leading)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.commit.subject).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                    if let note {
                        Text(note).font(.system(size: 11)).foregroundStyle(isOn ? .white.opacity(0.88) : K.label2).lineLimit(1).layoutPriority(-1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.commit.author.name)
                    .font(.system(size: 13))
                    .foregroundStyle(isOn ? .white.opacity(0.88) : K.label2)
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
                Text(Formatters.historyDate(entry.commit.author.date))
                    .font(.system(size: 13))
                    .foregroundStyle(isOn ? .white.opacity(0.88) : K.label2)
                    .lineLimit(1)
                    .frame(width: 96, alignment: .leading)
                LineCounts(additions: entry.stat?.additions, deletions: entry.stat?.deletions, selected: isOn)
                    .frame(width: 76, alignment: .trailing)
            }
            .foregroundStyle(isOn ? .white : K.label)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(isOn ? K.sel : (hovering ? K.hover : (isAlt ? K.alt : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Blame

/// `.blame`: a block per run of lines from one commit — hash, author, when, an age stripe on
/// the left (darker is newer, red is uncommitted). Clicking a block highlights that commit's
/// lines; ⋯ or a right-click has Show Commit in History and Blame Before This Commit.
private struct BlameView: View {
    let repository: RepositoryModel
    let state: ExploreState
    @Environment(\.diffStyle) private var style

    var body: some View {
        VStack(spacing: 0) {
            legend
            if let at = state.blameAt {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 12))
                    Text("Blame as of \(String(at.prefix(7))) — lines changed since don’t show here.")
                    Spacer(minLength: 0)
                    GhostButton(title: "Back to Working Copy") { repository.setBlameOptions(at: .some(nil)) }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(K.accentText)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(K.accentSoft)
            }
            if let blame = repository.currentBlame {
                if blame.lines.isEmpty {
                    Text(blame.commits.isEmpty ? "Kaern couldn’t blame this file — it may be new, binary or gone at this commit." : "This file is empty.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(K.label2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if blame.isBinary {
                    Text("Binary file").font(.system(size: 13, weight: .semibold)).foregroundStyle(K.label2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(blame.chunks.enumerated()), id: \.element.id) { index, chunk in
                                BlameChunkView(repository: repository, blame: blame, chunk: chunk,
                                               continues: index > 0 && blame.chunks[index - 1].commitID == chunk.commitID,
                                               focused: state.focused, isClicked: state.focusedChunk == chunk.id)
                            }
                        }
                        .padding(.bottom, 20)
                    }
                    .contextClip()
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 8) {
            Text("Older")
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2).fill(K.blameAge(level)).frame(width: 11, height: 11)
                }
            }
            Text("Newer")
            RoundedRectangle(cornerRadius: 2).fill(K.err).frame(width: 11, height: 11).padding(.leading, 10)
            Text("Not committed")
            Spacer(minLength: 0)
            Toggle("Ignore Whitespace", isOn: Binding(get: { state.ignoreWhitespace }, set: { repository.setBlameOptions(ignoreWhitespace: $0) }))
                .toggleStyle(.checkbox)
            Toggle("Detect Moved Lines", isOn: Binding(get: { state.detectMoves }, set: { repository.setBlameOptions(detectMoves: $0) }))
                .toggleStyle(.checkbox)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(K.label2)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(K.alt)
        .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
    }
}

/// `.bk`: the gutter (`.bgut`, 236 pt) and the lines (`.bcode`).
private struct BlameChunkView: View {
    let repository: RepositoryModel
    let blame: Blame
    let chunk: BlameChunk
    /// The block above is from the same commit (`.cont`: the gutter text is left out).
    let continues: Bool
    let focused: String?
    /// This block was clicked (`.bcur`); the commit's other blocks are only tinted (`.same`).
    let isClicked: Bool
    @Environment(\.diffStyle) private var style
    @State private var hovering = false

    var body: some View {
        let commit = blame.commits[chunk.commitID]
        let uncommitted = commit?.isUncommitted ?? false
        let isCurrent = isClicked && focused == chunk.commitID && !uncommitted
        let level = repository.blameAge(chunk.commitID, in: blame)
        let stripe = uncommitted ? K.err : (isCurrent ? Color.white : K.blameAge(level))
        HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if uncommitted {
                        Text("Not Committed Yet").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(K.err)
                        Spacer(minLength: 0)
                        Text("Now").font(.system(size: 11)).foregroundStyle(K.err)
                    } else if !continues, let commit {
                        Text(commit.shortID).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(isCurrent ? .white : K.label2)
                        Text(commit.author).font(.system(size: 11.5)).foregroundStyle(isCurrent ? .white : K.label)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        Text(Formatters.historyDate(commit.date)).font(.system(size: 11))
                            .foregroundStyle(isCurrent ? .white.opacity(0.85) : K.label3)
                            .lineLimit(1)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .padding(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 26))
                .frame(height: 24, alignment: .center)
                if !uncommitted, hovering || isCurrent {
                    Button { showMenu() } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isCurrent ? .white : K.label2)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverPlateStyle(radius: 5))
                    .padding(.top, 2)
                    .padding(.trailing, 4)
                    .accessibilityLabel("More for \(commit?.shortID ?? "")")
                    .background(MenuAnchorView(anchor: anchor))
                }
            }
            .frame(width: 236, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(isCurrent ? K.sel : (focused == chunk.commitID ? K.accentSoft : K.alt))
            .overlay(alignment: .leading) { stripe.frame(width: 3) }
            .overlay(alignment: .trailing) { K.sep.frame(width: 1) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(chunk.lines, id: \.self) { index in
                    let line = blame.lines[index]
                    HStack(alignment: .top, spacing: 0) {
                        Text("\(line.number)")
                            .foregroundStyle(K.label3)
                            .frame(width: 44, alignment: .trailing)
                            .padding(.trailing, 12)
                        Text(displayText(line.text))
                            .foregroundStyle(K.code)
                            .lineLimit(style.wraps ? nil : 1)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 16)
                    }
                    .frame(minHeight: 20)
                }
            }
            .font(style.font)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(uncommitted ? K.delBg : (focused == chunk.commitID && !isCurrent ? K.accentSoft : .clear))
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { if !uncommitted { repository.focusBlame(chunk.commitID, chunk: chunk.id) } }
        .onHover { hovering = $0 }
        .contextTarget(.blame(chunk.commitID), ring: nil)
    }

    @State private var anchor = MenuAnchor()

    private func showMenu() {
        guard let view = anchor.view, let menu = ContextMenus.blameMenu(chunk.commitID, repository) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: view)
    }
}

/// The right panel while exploring: the picked commit's details; its file rows open their own
/// history.
struct ExplorePanel: View {
    let repository: RepositoryModel

    var body: some View {
        VStack(spacing: 0) {
            if let commit = repository.exploreCommit, commit.id == repository.exploreCommitID, let state = repository.explore {
                let entryPath = repository.fileHistory?.entries.first { $0.commit.id == commit.id }?.path ?? state.path
                CommitInfoView(repository: repository, details: commit.details, files: commit.files, highlightedPath: entryPath,
                               openFile: { file in
                                   if state.mode == .history { repository.showFileHistory(file.path, at: commit.id) } else { repository.showBlame(file.path, at: commit.id) }
                               },
                               reviewAll: repository.commit(commit.id) == nil ? nil : {
                                   repository.showCommitInHistory(commit.id)
                                   repository.review = ReviewState(showsAllFiles: true)
                               })
            } else if repository.exploreCommitID == nil {
                Text("Pick a commit")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(K.label2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: KMetric.panelWidth)
        .frame(maxHeight: .infinity)
        .background(K.inspector)
        .overlay(alignment: .leading) { K.sep.frame(width: 1) }
    }
}

extension K {
    /// The blame stripe's five shades of blue, older to newer (`.ag1` … `.ag5`).
    static func blameAge(_ level: Int) -> Color {
        switch level {
        case ...1: blameAge1
        case 2: blameAge2
        case 3: blameAge3
        case 4: blameAge4
        default: blameAge5
        }
    }
}
