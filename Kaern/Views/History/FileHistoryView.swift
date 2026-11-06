import AppKit
import KaernKit
import SwiftUI

/// File History (the commits that changed one file, with its diff in the selected one) and
/// Blame (who last changed each line), in place of the history table. "‹ History" or Esc goes
/// back.
struct FileHistoryView: View {
    let model: RepositoryModel
    let state: FileHistoryState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch state.mode {
            case .history:
                historyContent
            case .blame:
                BlameView(model: model, state: state)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onExitCommand { model.closeFileHistory() }
    }

    // MARK: Header

    private var shownPath: String { state.mode == .blame ? state.blamePath : state.path }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                model.closeFileHistory()
            } label: {
                Label("History", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .help("Back to History (Esc)")

            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1, height: 14)

            Image(systemName: "doc")
                .foregroundStyle(.secondary)
            let (directory, name) = PathLabel.split(shownPath)
            let directoryText = Text(directory).foregroundStyle(.secondary)
            let nameText = Text(name).fontWeight(.semibold)
            Text("\(directoryText)\(nameText)")
                .lineLimit(1)
                .truncationMode(.head)
                .help(shownPath)

            Spacer(minLength: 8)

            switch state.mode {
            case .history:
                if let count = state.entries?.count {
                    Text(count == 1 ? "1 commit changed this file" : "\(count) commits changed this file")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            case .blame:
                Text("Blame at")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                blameRevisionPicker
            }

            Picker("View", selection: Binding(get: { state.mode }, set: { model.setFileHistoryMode($0) })) {
                Text("History").tag(FileHistoryState.Mode.history)
                Text("Blame").tag(FileHistoryState.Mode.blame)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    /// Working Copy, the latest commit, and the commits that changed the file.
    private var blameRevisionPicker: some View {
        let entries = Array((state.entries ?? []).prefix(15))
        var options: [(BlameRevision, String, String)] = [
            (.workingCopy, String(localized: "Working Copy"), state.path),
            (.head, String(localized: "Latest Commit (\(model.currentBranchTitle))"), state.path),
        ]
        for entry in entries {
            options.append((.commit(id: entry.commit.id, label: "\(entry.commit.shortID) · \(entry.commit.subject)"),
                            "", entry.path))
        }
        if case .commit(let id, _) = state.blameRevision, !entries.contains(where: { $0.id == id }) {
            options.append((state.blameRevision, "", state.blamePath))
        }
        return Picker("Blame at", selection: Binding(
            get: { state.blameRevision },
            set: { revision in
                let path = options.first { $0.0 == revision }?.2
                model.setBlameRevision(revision, path: path)
            }
        )) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index == 2 { Divider() }
                Text(Self.title(for: option.0, fallback: option.1)).tag(option.0)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        // The menu lists long commit subjects; the button shows the chosen one, cut short.
        .frame(width: 170)
    }

    private static func title(for revision: BlameRevision, fallback: String) -> String {
        if case .commit(_, let label) = revision { return label }
        return fallback
    }

    // MARK: History

    @ViewBuilder
    private var historyContent: some View {
        if let error = state.error {
            ContentUnavailableView {
                Label("Couldn't Load File History", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
        } else if let entries = state.entries {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No Commits Yet", systemImage: "doc")
                } description: {
                    Text("No commit has changed this file. Commit it to start its history.")
                }
            } else {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        FileHistoryList(model: model, entries: entries, selectedID: state.selectedID)
                            .frame(height: listHeight(rows: entries.count, available: geometry.size.height))
                        Divider()
                        selectedDiff
                    }
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Up to about 40% of the pane, so the diff keeps most of it.
    private func listHeight(rows: Int, available: CGFloat) -> CGFloat {
        let natural = CGFloat(rows) * 24 + 4
        return min(natural, max(120, available * 0.4))
    }

    @ViewBuilder
    private var selectedDiff: some View {
        if let entry = state.selectedEntry {
            let showsFile = model.selectedFile == .commit(commitID: entry.id, path: entry.path)
            if showsFile {
                DiffView(model: model, embeddedTitle: EmbeddedDiffTitle(commit: entry.commit, path: entry.path))
            } else if model.isLoadingDetails || model.selection != .commit(entry.id) {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No Changes to Show", systemImage: "doc")
                } description: {
                    Text(entry.commit.isMerge
                         ? "This merge doesn't change the file compared with its first parent."
                         : "This commit doesn't change the file's content.")
                }
            }
        } else {
            Color.clear
        }
    }
}

/// The commits that changed the file: SHA · subject · author · date · +/−.
private struct FileHistoryList: View {
    let model: RepositoryModel
    let entries: [FileHistoryEntry]
    let selectedID: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        List(selection: Binding(get: { selectedID }, set: { model.selectFileHistoryEntry($0) })) {
            ForEach(entries) { entry in
                FileHistoryRow(entry: entry)
                    .tag(entry.id)
                    .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 12))
                    .contextMenu {
                        Button("Show Commit in History") { model.showCommitInHistory(entry.id) }
                        Button("Blame at This Commit") {
                            model.setBlameRevision(.commit(id: entry.id, label: "\(entry.commit.shortID) · \(entry.commit.subject)"), path: entry.path)
                            model.setFileHistoryMode(.blame)
                        }
                        Divider()
                        Button("Copy SHA") { Pasteboard.copy(entry.id) }
                        Button("Copy Subject") { Pasteboard.copy(entry.commit.subject) }
                        if let host = model.primaryRemote {
                            Divider()
                            Button("Open Commit on \(host.hostName)") { model.openCommitOnHost(entry.id) }
                        }
                    }
            }
        }
        .listStyle(.plain)
        .alternatingRowBackgrounds()
        .environment(\.defaultMinListRowHeight, 24)
        .focused($isFocused)
        .onAppear { isFocused = true }
        .accessibilityLabel("Commits That Changed This File")
    }
}

private struct FileHistoryRow: View {
    let entry: FileHistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.commit.shortID)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            HStack(spacing: 6) {
                Text(entry.commit.subject)
                    .lineLimit(1)
                if let oldPath = entry.oldPath {
                    Text("renamed from \((oldPath as NSString).lastPathComponent)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.commit.author.name)
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)
            Text(Formatters.historyDate(entry.commit.author.date))
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
            LineStatLabel(stat: entry.stat)
                .frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 12))
        .frame(height: 24)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Blame

/// Each line's last change on the left: blocks of lines from the same commit, with a stripe
/// that gets darker the more recent the change (orange: not committed yet).
struct BlameView: View {
    let model: RepositoryModel
    let state: FileHistoryState
    @AppStorage(PreferenceKey.blameIgnoreWhitespace) private var ignoreWhitespace = true
    @AppStorage(PreferenceKey.blameDetectMoves) private var detectMoves = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            legend
            Divider()
            content
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        // ↑↓ move between blocks.
        .onKeyPress(.downArrow) { moveSelection(1) }
        .onKeyPress(.upArrow) { moveSelection(-1) }
        .onChange(of: ignoreWhitespace) { Task { await model.loadBlame() } }
        .onChange(of: detectMoves) { Task { await model.loadBlame() } }
    }

    private func moveSelection(_ offset: Int) -> KeyPress.Result {
        guard let chunks = state.blame?.chunks, !chunks.isEmpty else { return .ignored }
        let current = chunks.firstIndex { $0.id == state.selectedChunk }
        let next = current.map { min(max($0 + offset, 0), chunks.count - 1) } ?? (offset > 0 ? 0 : chunks.count - 1)
        model.selectBlameChunk(chunks[next])
        return .handled
    }

    private var legend: some View {
        HStack(spacing: 6) {
            Text("Older")
            HStack(spacing: 2) {
                ForEach(0 ..< 4) { level in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(BlameColors.age(level))
                        .frame(width: 10, height: 10)
                }
            }
            .accessibilityHidden(true)
            Text("Newer")
            RoundedRectangle(cornerRadius: 1.5)
                .fill(BlameColors.uncommitted)
                .frame(width: 10, height: 10)
                .padding(.leading, 12)
                .accessibilityHidden(true)
            Text("Not committed")
            if state.isLoadingBlame, state.blame != nil {
                ProgressView().controlSize(.mini).padding(.leading, 6)
            }
            Spacer(minLength: 12)
            Toggle("Ignore Whitespace", isOn: $ignoreWhitespace)
                .help("Changes that only add or remove spaces don't count (git blame -w)")
            Toggle("Detect Moved Lines", isOn: $detectMoves)
                .help("Lines moved or copied within the file or from other files keep their original commit (git blame -M -C)")
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Color(Palette.diffGutter))
    }

    @ViewBuilder
    private var content: some View {
        if let error = state.blameError {
            ContentUnavailableView {
                Label("Nothing to Blame", systemImage: "person.crop.rectangle.stack")
            } description: {
                Text(error)
            }
        } else if let blame = state.blame {
            if blame.isBinary {
                ContentUnavailableView("Binary File", systemImage: "doc", description: Text("Blame shows text files line by line."))
            } else if blame.lines.isEmpty {
                ContentUnavailableView("Empty File", systemImage: "doc")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(blame.chunks) { chunk in
                                BlameChunkRow(
                                    chunk: chunk,
                                    blame: blame,
                                    isSelected: state.selectedChunk == chunk.id,
                                    model: model
                                )
                                .id(chunk.id)
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .onChange(of: state.selectedChunk) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

enum BlameColors {
    static func age(_ level: Int) -> Color {
        Color(nsColor: .systemBlue).opacity([0.2, 0.42, 0.68, 1][min(max(level, 0), 3)])
    }

    static let uncommitted = Color(nsColor: .systemOrange)
}

private struct BlameChunkRow: View {
    let chunk: BlameChunk
    let blame: Blame
    let isSelected: Bool
    let model: RepositoryModel

    private var commit: BlameCommit? { blame.commits[chunk.commitID] }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            annotation
                .frame(width: 214, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(isSelected ? Color.accentColor : Color(Palette.diffGutter))
                .overlay(alignment: .leading) {
                    stripe.frame(width: 3)
                }
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(chunk.lines, id: \.self) { index in
                    BlameLineRow(line: blame.lines[index])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.13) : .clear)
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.6)).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectBlameChunk(chunk) }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var stripe: Color {
        guard let commit else { return .clear }
        if commit.isUncommitted { return BlameColors.uncommitted }
        return BlameColors.age(blame.ageLevels[commit.id] ?? 0)
    }

    private var annotation: some View {
        HStack(spacing: 6) {
            if let commit, commit.isUncommitted {
                Text("Not Committed Yet")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                Spacer(minLength: 4)
                Text("Now")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color(nsColor: .tertiaryLabelColor))
            } else if let commit {
                Text(commit.shortID)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color(nsColor: .tertiaryLabelColor))
                Text(commit.author)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                Text(Formatters.compactDate(commit.date))
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: BlameLineRow.height)
        .help(commit.map { $0.isUncommitted ? String(localized: "Not committed yet") : "\($0.shortID) \($0.summary)\n\($0.author) · \(Formatters.detailDate($0.date))" } ?? "")
    }

    @ViewBuilder
    private var menu: some View {
        if let commit {
            let committed = !commit.isUncommitted
            Button("Show Commit in History") { model.showCommitInHistory(commit.id) }
                .disabled(!committed)
            Button("Blame Before This Commit") { model.blameBefore(commit.id) }
                .disabled(!committed || commit.previousID == nil)
            Divider()
            Button("Copy SHA") { Pasteboard.copy(commit.id) }
                .disabled(!committed)
            Button("Copy Commit Message") { Task { await model.copyMessage(of: commit.id) } }
                .disabled(!committed)
            if let host = model.primaryRemote {
                Divider()
                Button("Open Commit on \(host.hostName)") { model.openCommitOnHost(commit.id) }
                    .disabled(!committed)
            }
        }
    }
}

private struct BlameLineRow: View {
    static let height: CGFloat = 18

    let line: Blame.Line

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("\(line.number)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .trailing)
                .padding(.trailing, 12)
            Text(line.text.hasSuffix("\r") ? String(line.text.dropLast()) : line.text)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(minHeight: Self.height)
    }
}
