import KaernKit
import SwiftUI

enum DiffLayout: String, CaseIterable, Identifiable {
    case unified
    case split

    var id: String { rawValue }
    var title: LocalizedStringKey { self == .unified ? "Unified" : "Split" }
}

/// Which side of the index a hunk belongs to.
enum HunkSide: Hashable {
    /// `git diff --cached` (checkbox on, can be unstaged)
    case staged
    /// `git diff` (checkbox off, can be staged or discarded)
    case unstaged
    /// A commit's diff (read-only)
    case commit
}

/// Lines picked with click / shift-click inside one hunk.
struct LineSelection: Equatable {
    var side: HunkSide
    var hunk: Int
    var lines: Set<Int>
    var anchor: Int
}

/// The commit and file a diff inside File History belongs to.
struct EmbeddedDiffTitle: Equatable {
    var commit: Commit
    var path: String
}

/// The diff of the selected file, in place of the history table ("‹ History" goes back).
/// Inside File History it gets a title bar for the commit instead.
struct DiffView: View {
    let model: RepositoryModel
    var embeddedTitle: EmbeddedDiffTitle?
    @AppStorage("diffLayout") private var layout: DiffLayout = .unified
    @AppStorage(PreferenceKey.diffIgnoreWhitespace) private var ignoresWhitespace = false
    @State private var lineSelection: LineSelection?
    /// Gaps between hunks opened with a click: the block below the gap → its unchanged lines.
    @State private var expandedGaps: [String: [DiffLine]] = [:]
    @State private var inlineHighlights = InlineHighlightCache()
    /// Keyboard focus, so Esc goes back and the toolbar's search field doesn't take over when
    /// the history table hides.
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let embeddedTitle {
                embeddedHeader(embeddedTitle)
            } else {
                header
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .focusable(embeddedTitle == nil)
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { if embeddedTitle == nil { isFocused = true } }
        .onExitCommand {
            if embeddedTitle != nil { model.closeFileHistory() } else { model.closeDiff() }
        }
        .onChange(of: model.selectedFile) { lineSelection = nil; expandedGaps = [:] }
        .onChange(of: model.diff) { lineSelection = nil; expandedGaps = [:] }
        .onChange(of: ignoresWhitespace) { model.reloadDiff() }
    }

    /// "c92aa17  fix: restore automatic alpha releases — AlphaVersion.swift"
    private func embeddedHeader(_ title: EmbeddedDiffTitle) -> some View {
        HStack(spacing: 8) {
            Text(title.commit.shortID)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("\(title.commit.subject) — \((title.path as NSString).lastPathComponent)")
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            whitespaceToggle
            layoutPicker
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color(Palette.diffGutter))
    }

    /// `git diff -w`: lines that only changed in white space drop out of the diff.
    private var whitespaceToggle: some View {
        Toggle("Ignore Whitespace", isOn: $ignoresWhitespace)
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Hide changes that only add or remove spaces, tabs or blank space in a line (git diff -w)")
    }

    private var layoutPicker: some View {
        Picker("Layout", selection: $layout) {
            ForEach(DiffLayout.allCases) { layout in
                Text(layout.title).tag(layout)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
    }

    // MARK: Header

    private var path: String {
        switch model.selectedFile {
        case .working(let path): path
        case .commit(_, let path): path
        case nil: ""
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                model.closeDiff()
            } label: {
                Label("History", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .help("Back to History (Esc)")

            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1, height: 14)

            Image(systemName: submoduleChange == nil ? "doc" : "shippingbox")
                .foregroundStyle(.secondary)
            let (directory, name) = PathLabel.split(path)
            let directoryText = Text(directory).foregroundStyle(.secondary)
            let nameText = Text(name).fontWeight(.semibold)
            Text("\(directoryText)\(nameText)")
                .lineLimit(1)
                .truncationMode(.head)
                .help(path)

            Spacer(minLength: 8)

            if let summary = headerSummary {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // A submodule or a Git LFS file has no lines to lay out.
            if submoduleChange == nil && !isLFSDiff {
                whitespaceToggle
                layoutPicker
            }

            Menu {
                fileMenu
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("File History, Blame and more")
            .accessibilityLabel("More")

            if case .working(let working) = model.diff {
                if working.entry.stageState == .staged {
                    Button("Unstage File") { Task { await model.unstage([working.entry]) } }
                        .controlSize(.small)
                } else {
                    Button("Stage File") { Task { await model.stage([working.entry]) } }
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    /// Show File History · Blame · Open · Reveal · Copy Path for the file on screen.
    @ViewBuilder
    private var fileMenu: some View {
        switch model.selectedFile {
        case .working(let path):
            let entry = model.status.entries.first { $0.path == path }
            let isNew = entry?.isUntracked == true || entry?.kind == .added
            Button("Show File History") { model.showFileHistory(entry?.originalPath ?? path) }
                .disabled(isNew)
            Button("Blame") { model.showFileHistory(path, mode: .blame) }
                .disabled(isNew || entry?.kind == .deleted)
            Divider()
            Button("Open in \(Preferences.editor.title)") { model.openInEditor(path) }
            Button("Reveal in Finder") { model.revealInFinder(path) }
            Button("Copy Path") { Pasteboard.copy(path) }
        case .commit(let commitID, let path):
            let deleted = model.detailFiles.first { $0.path == path }?.kind == .deleted
            Button("Show File History") { model.showFileHistory(path, from: commitID) }
            Button("Blame") { model.showFileHistory(path, from: commitID, mode: .blame) }
                .disabled(deleted)
            Divider()
            Button("Copy Path") { Pasteboard.copy(path) }
        case nil:
            EmptyView()
        }
    }

    private var headerSummary: String? {
        guard submoduleChange == nil, !isLFSDiff, case .working(let working) = model.diff else { return nil }
        let staged = working.staged?.hunks.count ?? 0
        let total = staged + (working.unstaged?.hunks.count ?? 0)
        guard total > 0 else { return nil }
        var text = String(localized: "\(staged) of \(total) hunks staged")
        if let lineSelection, !lineSelection.lines.isEmpty {
            text += " · " + (lineSelection.lines.count == 1
                ? String(localized: "1 line selected")
                : String(localized: "\(lineSelection.lines.count) lines selected"))
        }
        return text
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let submoduleChange {
            SubmoduleNote(model: model, path: path, change: submoduleChange)
        } else if let error = model.diffError {
            ContentUnavailableView {
                Label("Couldn't Load Diff", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
        } else if let diff = model.diff, let lfs = Self.lfsDiff(diff), let change = lfs.lfsChange {
            LFSNote(path: lfs.path, change: change, content: diff, model: model)
        } else if let diff = model.diff {
            switch diff {
            case .working(let working):
                let blocks = HunkBlock.blocks(for: working)
                if blocks.isEmpty {
                    placeholder(for: working.unstaged ?? working.staged, entry: working.entry, ignoringWhitespace: working.ignoresWhitespace)
                } else {
                    hunkList(blocks)
                }
            case .commit(_, _, let fileDiff):
                let blocks = fileDiff.hunks.map { HunkBlock(side: .commit, diff: fileDiff, hunk: $0) }
                if blocks.isEmpty {
                    placeholder(for: fileDiff, entry: nil, ignoringWhitespace: fileDiff.ignoresWhitespace)
                } else {
                    hunkList(blocks)
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Loads the unchanged lines between two hunks from the file on that side (the commit, the
    /// index for staged hunks, or the file on disk).
    private func expand(gap: Int, before block: HunkBlock, after previous: HunkBlock) {
        guard let repository = model.repository, let diff = model.diff else { return }
        let revision: String?
        switch (diff, block.side) {
        case (.commit(let commit, _, _), _): revision = commit.id
        case (_, .staged): revision = ":"
        default: revision = nil
        }
        let path = block.diff.path
        let newStart = previous.hunk.newStart + previous.hunk.newCount
        let oldStart = previous.hunk.oldStart + previous.hunk.oldCount
        Task {
            guard let lines = await repository.fileLines(path, at: revision) else { return }
            let slice = (0 ..< gap).compactMap { offset -> DiffLine? in
                let index = newStart - 1 + offset
                guard lines.indices.contains(index) else { return nil }
                return DiffLine(id: 100_000 + offset, kind: .context, text: lines[index], oldNumber: oldStart + offset, newNumber: newStart + offset)
            }
            expandedGaps[block.id] = slice
        }
    }

    /// The diff to check for a Git LFS pointer.
    private static func lfsDiff(_ content: DiffContent) -> FileDiff? {
        switch content {
        case .working(let working): working.unstaged ?? working.staged
        case .commit(_, _, let diff): diff
        }
    }

    private var isLFSDiff: Bool {
        guard let diff = model.diff, let lfs = Self.lfsDiff(diff) else { return false }
        return lfs.lfsChange != nil
    }

    /// The selected file is a submodule: its commits instead of a diff.
    private var submoduleChange: SubmoduleNote.Change? {
        switch model.selectedFile {
        case .working(let path):
            guard let entry = model.status.entries.first(where: { $0.path == path }), entry.submodule != nil else { return nil }
            return .working(entry)
        case .commit(_, let path):
            guard let file = model.detailFiles.first(where: { $0.path == path }), file.submodule != nil else { return nil }
            return .commit(file)
        case nil:
            return nil
        }
    }

    /// `git diff -w` prints nothing at all for a file that only changed in white space.
    @ViewBuilder
    private func placeholder(for diff: FileDiff?, entry: StatusEntry?, ignoringWhitespace: Bool) -> some View {
        if ignoringWhitespace && diff?.isBinary != true && entry?.isUntracked != true {
            ContentUnavailableView {
                Label("Only white space changed", systemImage: "eye.slash")
            } actions: {
                Button("Show White-Space Changes") { ignoresWhitespace = false }
            }
        } else {
            let text: LocalizedStringKey = if diff?.isBinary == true {
                "Binary file — no text changes to show"
            } else if entry?.isUntracked == true {
                "Empty file"
            } else {
                "No content changes (mode or rename only)"
            }
            ContentUnavailableView {
                Label(text, systemImage: "doc")
            }
        }
    }

    /// With Ignore Whitespace on, a working-copy diff can only be staged as a whole file.
    @ViewBuilder
    private var whitespaceNote: some View {
        if case .working(let working) = model.diff, working.ignoresWhitespace {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                Text("White-space changes are hidden, so hunks and lines can't be staged one at a time.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Show Them") { ignoresWhitespace = false }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Color(Palette.diffGutter))
        }
    }

    private func hunkList(_ blocks: [HunkBlock]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                whitespaceNote
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    if index > 0, let gap = block.gap(after: blocks[index - 1]), gap > 0 {
                        if let lines = expandedGaps[block.id] {
                            ForEach(lines.map { Keyed(id: "\(block.id)-gap-\($0.id)", value: $0) }) { keyed in
                                switch layout {
                                case .unified:
                                    UnifiedLineRow(line: keyed.value, isSelected: false, isSelectable: false)
                                case .split:
                                    SplitLineRow(row: SplitRow(id: keyed.value.id, left: keyed.value, right: keyed.value), isSelected: { _ in false })
                                }
                            }
                        } else {
                            UnchangedLinesRow(count: gap)
                                .contentShape(Rectangle())
                                .onTapGesture { expand(gap: gap, before: block, after: blocks[index - 1]) }
                                .help("Show the unchanged lines")
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    HunkHeaderRow(
                        block: block,
                        selection: lineSelection?.side == block.side && lineSelection?.hunk == block.hunk.id ? lineSelection : nil,
                        model: model,
                        onClearSelection: { lineSelection = nil }
                    )
                    // Line IDs restart in every hunk; the lazy stack needs IDs that are unique across hunks.
                    let highlights = inlineHighlights.highlights(for: block, version: model.diffVersion)
                    switch layout {
                    case .unified:
                        ForEach(block.hunk.lines.map { Keyed(id: "\(block.id)-\($0.id)", value: $0) }) { keyed in
                            let line = keyed.value
                            UnifiedLineRow(
                                line: line,
                                highlights: highlights[line.id],
                                isSelected: isSelected(line, in: block),
                                isSelectable: block.side != .commit && line.isChange && block.diff.supportsPartialPatches
                            )
                            .onTapGesture { toggle(line, in: block) }
                        }
                    case .split:
                        ForEach(SplitRow.rows(for: block.hunk).map { Keyed(id: "\(block.id)-split-\($0.id)", value: $0) }) { keyed in
                            let row = keyed.value
                            SplitLineRow(row: row, highlights: highlights, isSelected: { isSelected($0, in: block) })
                                .onTapGesture {
                                    if let line = row.right ?? row.left, line.isChange { toggle(line, in: block) }
                                }
                        }
                    }
                }
                Color.clear.frame(height: 24)
            }
        }
        .id(model.diffVersion)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func isSelected(_ line: DiffLine, in block: HunkBlock) -> Bool {
        guard let lineSelection, lineSelection.side == block.side, lineSelection.hunk == block.hunk.id else { return false }
        return lineSelection.lines.contains(line.id)
    }

    /// Click toggles a line, shift-click extends from the last clicked line.
    private func toggle(_ line: DiffLine, in block: HunkBlock) {
        guard block.side != .commit, line.isChange, block.diff.supportsPartialPatches else { return }
        let extend = NSEvent.modifierFlags.contains(.shift)
        if var current = lineSelection, current.side == block.side, current.hunk == block.hunk.id {
            if extend {
                let range = min(current.anchor, line.id)...max(current.anchor, line.id)
                for candidate in block.hunk.lines where range.contains(candidate.id) && candidate.isChange {
                    current.lines.insert(candidate.id)
                }
            } else if current.lines.contains(line.id) {
                current.lines.remove(line.id)
                current.anchor = line.id
            } else {
                current.lines.insert(line.id)
                current.anchor = line.id
            }
            lineSelection = current.lines.isEmpty ? nil : current
        } else {
            lineSelection = LineSelection(side: block.side, hunk: block.hunk.id, lines: [line.id], anchor: line.id)
        }
    }
}

/// A value with an ID that's unique inside one lazy stack.
struct Keyed<Value>: Identifiable {
    let id: String
    let value: Value
}

/// One hunk plus where it comes from. Staged and unstaged hunks are interleaved in index order:
/// the staged diff's new side and the unstaged diff's old side are both the index.
struct HunkBlock: Identifiable {
    var side: HunkSide
    var diff: FileDiff
    var hunk: DiffHunk

    var id: String { "\(side)-\(hunk.id)" }

    private var indexStart: Int { side == .staged ? hunk.newStart : hunk.oldStart }

    static func blocks(for working: WorkingDiff) -> [HunkBlock] {
        var blocks: [HunkBlock] = []
        if let staged = working.staged {
            blocks += staged.hunks.map { HunkBlock(side: .staged, diff: staged, hunk: $0) }
        }
        if let unstaged = working.unstaged {
            blocks += unstaged.hunks.map { HunkBlock(side: .unstaged, diff: unstaged, hunk: $0) }
        }
        return blocks.sorted { $0.indexStart < $1.indexStart }
    }

    /// Unchanged lines between two hunks of the same diff.
    func gap(after previous: HunkBlock) -> Int? {
        guard previous.side == side else { return nil }
        let gap = hunk.oldStart - (previous.hunk.oldStart + previous.hunk.oldCount)
        return gap > 0 ? gap : nil
    }
}

struct UnchangedLinesRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
            Text(count == 1 ? "1 unchanged line" : "\(count) unchanged lines")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .background(Color(Palette.diffGutter))
    }
}

private struct HunkHeaderRow: View {
    let block: HunkBlock
    let selection: LineSelection?
    let model: RepositoryModel
    let onClearSelection: () -> Void

    private var canPatch: Bool { block.diff.supportsPartialPatches }
    private var selectedCount: Int { selection?.lines.count ?? 0 }

    var body: some View {
        HStack(spacing: 8) {
            if block.side != .commit {
                StageCheckbox(state: block.side == .staged ? .staged : .unstaged) {
                    Task { await model.applyPatch(block.side == .staged ? .unstage : .stage, diff: block.diff, hunk: block.hunk.id) }
                }
                .frame(width: 16)
                .disabled(!canPatch)
                .help(block.side == .staged ? "Unstage Hunk" : "Stage Hunk")
            }
            Text(block.hunk.rangeDescription)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(block.hunk.section)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color(Palette.diffHunkBackground))
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var actions: some View {
        switch block.side {
        case .commit:
            EmptyView()
        case .staged:
            if selectedCount > 0 {
                Button(selectedCount == 1 ? "Unstage 1 Line" : "Unstage \(selectedCount) Lines") {
                    let lines = selection?.lines
                    onClearSelection()
                    Task { await model.applyPatch(.unstage, diff: block.diff, hunk: block.hunk.id, lines: lines) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button("Unstage Hunk") {
                    Task { await model.applyPatch(.unstage, diff: block.diff, hunk: block.hunk.id) }
                }
                .controlSize(.small)
                .disabled(!canPatch)
            }
        case .unstaged:
            if selectedCount > 0 {
                Button(selectedCount == 1 ? "Stage 1 Line" : "Stage \(selectedCount) Lines") {
                    let lines = selection?.lines
                    onClearSelection()
                    Task { await model.applyPatch(.stage, diff: block.diff, hunk: block.hunk.id, lines: lines) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button(selectedCount == 1 ? "Discard 1 Line" : "Discard \(selectedCount) Lines", role: .destructive) {
                    let lines = selection?.lines
                    onClearSelection()
                    Task { await model.applyPatch(.discard, diff: block.diff, hunk: block.hunk.id, lines: lines) }
                }
                .help("⌘Z brings the lines back")
                .controlSize(.small)
            } else {
                Button("Stage Hunk") {
                    Task { await model.applyPatch(.stage, diff: block.diff, hunk: block.hunk.id) }
                }
                .controlSize(.small)
                .disabled(!canPatch)
                Button("Discard", role: .destructive) {
                    Task { await model.applyPatch(.discard, diff: block.diff, hunk: block.hunk.id) }
                }
                .help("⌘Z brings the hunk back")
                .controlSize(.small)
                .disabled(!canPatch)
            }
        }
    }
}

extension DiffLine {
    /// Tabs as four spaces, no trailing carriage return.
    var displayText: String {
        var text = self.text
        if text.hasSuffix("\r") { text.removeLast() }
        return text.replacingOccurrences(of: "\t", with: "    ")
    }

    /// `displayText` with the words that changed (offsets from ``InlineDiff``) marked.
    func highlightedText(_ ranges: [Range<Int>]?) -> AttributedString {
        var text = AttributedString(displayText)
        guard let ranges, isChange else { return text }
        let color = Color(kind == .addition ? Palette.diffAddedWord : Palette.diffRemovedWord)
        let count = text.characters.count
        for range in ranges where range.lowerBound < count {
            let start = text.index(text.startIndex, offsetByCharacters: range.lowerBound)
            let end = text.index(start, offsetByCharacters: min(range.count, count - range.lowerBound))
            text[start ..< end].backgroundColor = color
        }
        return text
    }
}

/// Word highlights of each hunk, worked out once per diff rather than on every redraw.
final class InlineHighlightCache {
    private var version = -1
    private var blocks: [String: [Int: [Range<Int>]]] = [:]

    func highlights(for block: HunkBlock, version: Int) -> [Int: [Range<Int>]] {
        if version != self.version {
            blocks = [:]
            self.version = version
        }
        if let cached = blocks[block.id] { return cached }
        let computed = InlineDiff.highlights(for: block.hunk.lines.map { ($0.id, $0.kind, $0.displayText) })
        blocks[block.id] = computed
        return computed
    }
}

struct UnifiedLineRow: View {
    let line: DiffLine
    var highlights: [Range<Int>]?
    let isSelected: Bool
    let isSelectable: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Group {
                Text(line.oldNumber.map(String.init) ?? "")
                    .frame(width: 42, alignment: .trailing)
                Text(line.newNumber.map(String.init) ?? "")
                    .frame(width: 42, alignment: .trailing)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.vertical, 1)

            Text(marker)
                .frame(width: 22)
                .foregroundStyle(markerColor)
            Text(line.kind == .noNewline ? AttributedString(String(localized: "No newline at end of file")) : line.highlightedText(highlights))
                .foregroundStyle(line.kind == .noNewline ? Color.secondary : Color.primary)
                .italic(line.kind == .noNewline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 1)
                .padding(.trailing, 12)
        }
        .font(.system(size: 12, design: .monospaced))
        .background(alignment: .leading) {
            HStack(spacing: 0) {
                gutterColor.frame(width: 84)
                lineColor
            }
        }
        .overlay(alignment: .leading) {
            if isSelected {
                Color.accentColor.frame(width: 3)
            }
        }
        .background(isSelected ? Color(Palette.diffSelection) : .clear)
        .contentShape(Rectangle())
        .help(isSelectable ? "Click to select lines, Shift-click to extend" : "")
    }

    private var marker: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "-"
        case .context, .noNewline: ""
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .addition: Color(Palette.added)
        case .deletion: Color(Palette.deleted)
        default: .secondary
        }
    }

    private var lineColor: Color {
        switch line.kind {
        case .addition: Color(Palette.diffAddedBackground)
        case .deletion: Color(Palette.diffRemovedBackground)
        default: .clear
        }
    }

    private var gutterColor: Color {
        switch line.kind {
        case .addition: Color(Palette.diffAddedGutter)
        case .deletion: Color(Palette.diffRemovedGutter)
        default: Color(Palette.diffGutter)
        }
    }
}

/// Side-by-side rows: context on both sides, deletions paired with the additions that follow.
struct SplitRow: Identifiable {
    var id: Int
    var left: DiffLine?
    var right: DiffLine?

    static func rows(for hunk: DiffHunk) -> [SplitRow] {
        var rows: [SplitRow] = []
        var deletions: [DiffLine] = []
        var additions: [DiffLine] = []
        func flush() {
            for index in 0 ..< max(deletions.count, additions.count) {
                rows.append(SplitRow(
                    id: rows.count,
                    left: index < deletions.count ? deletions[index] : nil,
                    right: index < additions.count ? additions[index] : nil
                ))
            }
            deletions.removeAll()
            additions.removeAll()
        }
        for line in hunk.lines {
            switch line.kind {
            case .deletion:
                if !additions.isEmpty { flush() }
                deletions.append(line)
            case .addition:
                additions.append(line)
            case .context:
                flush()
                rows.append(SplitRow(id: rows.count, left: line, right: line))
            case .noNewline:
                continue
            }
        }
        flush()
        return rows
    }
}

struct SplitLineRow: View {
    let row: SplitRow
    var highlights: [Int: [Range<Int>]] = [:]
    let isSelected: (DiffLine) -> Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            side(row.left, number: row.left?.oldNumber)
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
            side(row.right, number: row.right?.newNumber)
        }
        .font(.system(size: 12, design: .monospaced))
        .contentShape(Rectangle())
    }

    private func side(_ line: DiffLine?, number: Int?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .trailing)
                .padding(.trailing, 8)
                .padding(.vertical, 1)
                .background(gutter(line))
            Text(line.map { $0.highlightedText(highlights[$0.id]) } ?? AttributedString())
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 1)
                .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(line))
        .overlay(alignment: .leading) {
            if let line, isSelected(line) { Color.accentColor.frame(width: 3) }
        }
    }

    private func background(_ line: DiffLine?) -> Color {
        guard let line else { return Color(Palette.diffGutter).opacity(0.5) }
        if isSelected(line) { return Color(Palette.diffSelection) }
        switch line.kind {
        case .addition: return Color(Palette.diffAddedBackground)
        case .deletion: return Color(Palette.diffRemovedBackground)
        default: return .clear
        }
    }

    private func gutter(_ line: DiffLine?) -> Color {
        switch line?.kind {
        case .addition: Color(Palette.diffAddedGutter)
        case .deletion: Color(Palette.diffRemovedGutter)
        default: Color(Palette.diffGutter)
        }
    }
}


