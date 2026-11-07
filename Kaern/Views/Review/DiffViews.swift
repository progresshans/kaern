import KaernKit
import SwiftUI

// MARK: - Model

/// A hunk as Review shows it: from a commit, or from the working copy's staged (HEAD → index)
/// or unstaged (index → work tree) diff.
struct ReviewHunk: Identifiable, Equatable {
    enum Stage: Hashable { case committed, staged, unstaged }

    let id: String
    let hunk: DiffHunk
    let stage: Stage
    let path: String

    var header: String {
        hunk.section.isEmpty ? hunk.rangeDescription : hunk.rangeDescription + " " + hunk.section
    }
}

/// One file of the selection, with its hunks in file order.
struct ReviewFile: Identifiable, Equatable {
    let path: String
    let letter: String
    var additions = 0
    var deletions = 0
    var hunks: [ReviewHunk] = []
    /// Why there's nothing to show line by line ("Binary file", "Conflicted").
    var note: String?
    var stagedHunks = 0
    var unstagedHunks = 0
    /// Part of the working copy (hunks can be staged).
    var isWorking = false
    /// The working copy has unstaged changes in it (Stage File) — else Unstage File.
    var hasUnstaged = false
    /// The working copy has staged changes in it (the drawer's checkbox is on).
    var hasStaged = false
    /// Which of its diffs can have single lines staged, unstaged or discarded.
    var pickable: Set<ReviewHunk.Stage> = []

    var id: String { path }

    /// The changed lines that can be picked, in the order they show (for ⇧-click ranges).
    var pickOrder: [LinePick] {
        hunks.flatMap { hunk -> [LinePick] in
            guard pickable.contains(hunk.stage) else { return [] }
            return hunk.hunk.lines.filter(\.isChange).map { LinePick(stage: hunk.stage, hunk: hunk.hunk.id, line: $0.id) }
        }
    }
    var directory: String {
        let directory = (path as NSString).deletingLastPathComponent
        return directory.isEmpty ? "" : directory + "/"
    }
    var name: String { (path as NSString).lastPathComponent }

    /// "1 of 3 hunks staged" for a partially staged file.
    var partText: String? {
        guard isWorking, stagedHunks > 0, unstagedHunks > 0 else { return nil }
        return "\(stagedHunks) of \(stagedHunks + unstagedHunks) hunks staged"
    }
}

extension RepositoryModel {
    /// Matches the key `refreshDiffsIfNeeded` stores the compare diffs under.
    func compareKey(_ compare: CompareRange) -> String {
        "\(compare.base):\(compare.target ?? "worktree"):\(DiffPreferences.ignoresWhitespace):\(AppSettings.diffContext)"
    }

    /// The files Review and the Focus drawer show for the selection, in order. `nil` while the
    /// diffs are loading.
    var reviewFiles: [ReviewFile]? {
        if let compare = review?.compare {
            guard let loaded = compareDiffs, loaded.key == compareKey(compare) else { return nil }
            return loaded.diffs.map { diff in
                let letter = diff.isNewFile ? "A" : diff.isDeletedFile ? "D" : diff.oldPath != nil ? "R" : "M"
                var file = ReviewFile(path: diff.path, letter: letter, additions: diff.additions, deletions: diff.deletions)
                file.hunks = diff.hunks.map { ReviewHunk(id: "c\($0.id)", hunk: $0, stage: .committed, path: diff.path) }
                if diff.isBinary { file.note = "Binary file" } else if diff.hunks.isEmpty { file.note = "No line changes (mode or type only)" }
                return file
            }
        }
        switch selection {
        case .workingCopy:
            guard workingDiffsLoaded else { return nil }
            return status.entries.map { entry in
                let diffs = workingDiffs[entry.path]
                var hunks: [(key: Int, order: Int, hunk: ReviewHunk)] = []
                for hunk in diffs?.staged?.hunks ?? [] {
                    // Staged hunks count lines in the index (their new side)…
                    hunks.append((hunk.newStart, 0, ReviewHunk(id: "s\(hunk.id)", hunk: hunk, stage: .staged, path: entry.path)))
                }
                for hunk in diffs?.unstaged?.hunks ?? [] {
                    // …and unstaged ones too (their old side), so they interleave in file order.
                    hunks.append((hunk.oldStart, 1, ReviewHunk(id: "u\(hunk.id)", hunk: hunk, stage: .unstaged, path: entry.path)))
                }
                hunks.sort { ($0.key, $0.order) < ($1.key, $1.order) }
                var file = ReviewFile(path: entry.path, letter: entry.isUntracked ? "A" : entry.kind.letter)
                file.hunks = hunks.map(\.hunk)
                file.isWorking = true
                file.hasUnstaged = entry.hasUnstagedChanges
                file.hasStaged = entry.hasStagedChanges
                file.stagedHunks = diffs?.staged?.hunks.count ?? 0
                file.unstagedHunks = diffs?.unstaged?.hunks.count ?? 0
                if let staged = diffs?.staged, staged.supportsPartialPatches, !staged.stagesWholeFile { file.pickable.insert(.staged) }
                if let unstaged = diffs?.unstaged, unstaged.supportsPartialPatches, !unstaged.stagesWholeFile, !entry.isUntracked {
                    file.pickable.insert(.unstaged)
                }
                let staged = lineStats.staged[entry.path], unstaged = lineStats.unstaged[entry.path]
                file.additions = (staged?.additions ?? 0) + (unstaged?.additions ?? 0)
                file.deletions = (staged?.deletions ?? 0) + (unstaged?.deletions ?? 0)
                if entry.isConflicted {
                    file.note = "This file has conflicts. Resolve them in an editor, then stage it."
                } else if diffs?.staged?.isBinary == true || diffs?.unstaged?.isBinary == true {
                    file.note = "Binary file"
                } else if file.hunks.isEmpty {
                    file.note = entry.submodule != nil ? "Submodule changes" : "No line changes (mode or type only)"
                }
                return file
            }
        case .commit(let id):
            guard let loaded = commitDiffs, loaded.id == id else { return nil }
            let kinds = Dictionary(selectedFiles.map { ($0.path, $0.kind) }, uniquingKeysWith: { first, _ in first })
            return loaded.diffs.map { diff in
                let letter = kinds[diff.path]?.letter
                    ?? (diff.isNewFile ? "A" : diff.isDeletedFile ? "D" : diff.oldPath != nil ? "R" : "M")
                var file = ReviewFile(path: diff.path, letter: letter, additions: diff.additions, deletions: diff.deletions)
                file.hunks = diff.hunks.map { ReviewHunk(id: "c\($0.id)", hunk: $0, stage: .committed, path: diff.path) }
                if diff.isBinary { file.note = "Binary file" } else if diff.hunks.isEmpty { file.note = "No line changes (mode or type only)" }
                return file
            }
        }
    }
}

/// Changed character ranges of a line (Settings › Diff › Highlight the changed words).
typealias WordMarks = [Range<Int>]

/// One line of a rendered diff (flattened, so a long file scrolls lazily).
enum DiffRowItem: Identifiable {
    case header(ReviewHunk)
    case unified(String, DiffLine, ReviewHunk, marks: WordMarks?)
    case split(String, left: DiffLine?, right: DiffLine?, hunk: ReviewHunk, leftMarks: WordMarks?, rightMarks: WordMarks?)
    case note(String, String)
    case more(String, hidden: Int)

    var id: String {
        switch self {
        case .header(let hunk): "h:" + hunk.id
        case .unified(let id, _, _, _), .split(let id, _, _, _, _, _), .note(let id, _), .more(let id, _): id
        }
    }

    /// Rows of one file: at most `limit` rows of lines, and a "Show More" row for the rest.
    /// `words`: mark the changed words of edited lines.
    static func rows(for file: ReviewFile, layout: DiffLayout, limit: Int, words: Bool = false) -> [DiffRowItem] {
        if let note = file.note { return [.note(file.path + ":note", note)] }
        var rows: [DiffRowItem] = []
        var budget = limit
        var consumed = 0
        let total = file.hunks.reduce(0) { $0 + $1.hunk.lines.count }
        hunks: for hunk in file.hunks {
            guard budget > 0 else { break }
            rows.append(.header(hunk))
            let prefix = hunk.id + ":"
            let marks = words ? InlineDiff.highlights(for: hunk.hunk.lines.map { ($0.id, $0.kind, $0.text) }) : [:]
            switch layout {
            case .unified:
                for line in hunk.hunk.lines {
                    guard budget > 0 else { break hunks }
                    rows.append(.unified(prefix + "\(line.id)", line, hunk, marks: marks[line.id]))
                    budget -= 1
                    consumed += 1
                }
            case .split:
                // Context on both sides; a run of deletions next to the additions that follow it.
                var deletions: [DiffLine] = []
                var additions: [DiffLine] = []
                var index = 0
                func flush() {
                    for row in 0..<max(deletions.count, additions.count) where budget > 0 {
                        let left = row < deletions.count ? deletions[row] : nil
                        let right = row < additions.count ? additions[row] : nil
                        rows.append(.split(prefix + "p\(index)", left: left, right: right, hunk: hunk,
                                           leftMarks: left.flatMap { marks[$0.id] }, rightMarks: right.flatMap { marks[$0.id] }))
                        index += 1
                        budget -= 1
                        consumed += (left == nil ? 0 : 1) + (right == nil ? 0 : 1)
                    }
                    deletions.removeAll()
                    additions.removeAll()
                }
                for line in hunk.hunk.lines {
                    switch line.kind {
                    case .deletion: deletions.append(line)
                    case .addition: additions.append(line)
                    case .context:
                        flush()
                        guard budget > 0 else { break hunks }
                        rows.append(.split(prefix + "p\(index)", left: line, right: line, hunk: hunk, leftMarks: nil, rightMarks: nil))
                        index += 1
                        budget -= 1
                        consumed += 1
                    case .noNewline:
                        // Split view leaves the marker out; it counts as shown.
                        consumed += 1
                    }
                }
                flush()
            }
        }
        let hidden = total - consumed
        if hidden > 0 { rows.append(.more(file.path + ":more", hidden: hidden)) }
        return rows
    }
}

// MARK: - Rows

/// Line picking in one working-copy file of Review: which lines can be picked and what a click does.
struct LinePicking {
    let file: ReviewFile
    let picks: LinePicks
    let pick: (LinePick) -> Void

    /// The pick for `line` of `hunk`, when it can be picked.
    func pick(for line: DiffLine?, in hunk: ReviewHunk) -> LinePick? {
        guard let line, line.isChange, file.pickable.contains(hunk.stage) else { return nil }
        return LinePick(stage: hunk.stage, hunk: hunk.hunk.id, line: line.id)
    }

    func isPicked(_ pick: LinePick?) -> Bool {
        guard let pick, picks.path == file.path else { return false }
        return picks.lines.contains(pick)
    }
}

/// Draws one diff row; hunk headers get Stage Hunk / Unstage Hunk on the working copy. With
/// `picking`, changed lines can be picked one by one (click, ⇧, ⌘).
struct DiffRowView: View {
    let item: DiffRowItem
    let repository: RepositoryModel
    var picking: LinePicking?
    var onShowMore: () -> Void = {}

    var body: some View {
        switch item {
        case .header(let hunk):
            HunkHeaderRow(hunk: hunk, repository: repository)
        case .unified(_, let line, let hunk, let marks):
            UnifiedLineRow(line: line, hunk: hunk, picking: picking, marks: marks)
        case .split(_, let left, let right, let hunk, let leftMarks, let rightMarks):
            SplitLineRow(left: left, right: right, hunk: hunk, picking: picking, leftMarks: leftMarks, rightMarks: rightMarks)
        case .note(_, let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(K.label2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        case .more(_, let hidden):
            Button(action: onShowMore) {
                Text("Show \(hidden.formatted()) More Lines")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(K.accentText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// `.hh`: the hunk's range and section on the hunk color, with its staging button.
private struct HunkHeaderRow: View {
    let hunk: ReviewHunk
    let repository: RepositoryModel

    var body: some View {
        HStack(spacing: 8) {
            Text(hunk.header)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(K.hunkText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch hunk.stage {
            case .committed:
                EmptyView()
            case .unstaged:
                HunkButton(title: "Stage Hunk", isOn: false) {
                    repository.stageHunk(path: hunk.path, hunk: hunk.hunk.id)
                }
                .disabled(!repository.canChangeIndex)
            case .staged:
                HunkButton(title: "Unstage Hunk", isOn: true) {
                    repository.unstageHunk(path: hunk.path, hunk: hunk.hunk.id)
                }
                .disabled(!repository.canChangeIndex)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 28)
        .background(K.hunk)
    }
}

/// `.hbtn`: Stage Hunk (outlined) or Unstage Hunk (filled, the hunk is staged).
private struct HunkButton: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : K.accentText)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isOn ? K.accent : K.content))
                .overlay {
                    if !isOn {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .fixedSize()
    }
}

/// Line text as shown: tabs as four spaces, no carriage return.
nonisolated func displayText(_ text: String) -> String {
    var result = text
    if result.hasSuffix("\r") { result.removeLast() }
    if result.contains("\t") { result = result.replacingOccurrences(of: "\t", with: "    ") }
    return result
}

/// `.dl`: old number, new number, (✓ staged), marker, text. A picked line gets the accent
/// edge and tint (`.dl.lsel`).
private struct UnifiedLineRow: View {
    let line: DiffLine
    let hunk: ReviewHunk
    let picking: LinePicking?
    var marks: WordMarks?
    @Environment(\.diffStyle) private var style

    var body: some View {
        let colors = DiffColors(kind: line.kind)
        let pick = picking?.pick(for: line, in: hunk)
        let picked = picking?.isPicked(pick) ?? false
        HStack(alignment: .top, spacing: 0) {
            LineNumber(number: line.oldNumber, width: 36, trailing: 10, gutter: colors.gutter, picked: picked)
            LineNumber(number: line.newNumber, width: 36, trailing: 10, gutter: colors.gutter, picked: picked)
            if picking != nil {
                StagedMark(shows: hunk.stage == .staged && line.isChange)
            }
            Text(line.kind == .addition ? "+" : line.kind == .deletion ? "−" : "")
                .foregroundStyle(line.kind == .addition ? K.add : K.del)
                .frame(width: 18)
            DiffLineText(text: line.kind == .noNewline ? "No newline at end of file" : line.text, kind: line.kind,
                         marks: marks, color: line.kind == .noNewline ? K.label2 : K.code)
                .padding(.trailing, 16)
        }
        .font(style.font)
        .lineSpacing(style.lineSpacing)
        .frame(minHeight: 20)
        .background(picked ? K.accentSoft : colors.line)
        .overlay(alignment: .leading) { if picked { K.accent.frame(width: 3) } }
        .pickable(pick, picking: picking)
    }
}

/// A line's text: wrapped or on one line (Settings › Diff › Wrap long lines), with its changed
/// words marked.
struct DiffLineText: View {
    let text: String
    let kind: DiffLine.Kind
    var marks: WordMarks?
    var color: Color = K.code
    @Environment(\.diffStyle) private var style

    var body: some View {
        content
            .foregroundStyle(color)
            .lineLimit(style.wraps ? nil : 1)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(style.wraps ? "" : text)
    }

    private var content: Text {
        let shown = displayText(text)
        guard let marks, !marks.isEmpty, kind == .addition || kind == .deletion else { return Text(shown) }
        var attributed = AttributedString(shown)
        let characters = Array(shown)
        // Ranges count Characters of the raw text; tabs became four spaces.
        let offsets = Self.displayOffsets(text)
        for range in marks {
            let lower = offsets[min(range.lowerBound, offsets.count - 1)]
            let upper = offsets[min(range.upperBound, offsets.count - 1)]
            guard lower < upper, upper <= characters.count else { continue }
            let start = attributed.index(attributed.startIndex, offsetByCharacters: lower)
            let end = attributed.index(attributed.startIndex, offsetByCharacters: upper)
            attributed[start..<end].backgroundColor = kind == .addition ? K.addWord : K.delWord
        }
        return Text(attributed)
    }

    /// Where each raw character starts in the shown text (one past the end last).
    private static func displayOffsets(_ text: String) -> [Int] {
        var offsets: [Int] = []
        var position = 0
        for character in text {
            offsets.append(position)
            if character == "\t" { position += 4 } else if character == "\r" { continue } else { position += 1 }
        }
        offsets.append(position)
        return offsets
    }
}

/// `.srow`: the old side and the new side; a missing side is striped. Each changed side can
/// be picked on its own.
private struct SplitLineRow: View {
    let left: DiffLine?
    let right: DiffLine?
    let hunk: ReviewHunk
    let picking: LinePicking?
    var leftMarks: WordMarks?
    var rightMarks: WordMarks?
    @Environment(\.diffStyle) private var style

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            side(left, number: left?.oldNumber, changed: left?.kind == .deletion, marks: leftMarks)
            K.sep.frame(width: 1)
            side(right, number: right?.newNumber, changed: right?.kind == .addition, marks: rightMarks)
        }
        .font(style.font)
        .lineSpacing(style.lineSpacing)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func side(_ line: DiffLine?, number: Int?, changed: Bool, marks: WordMarks?) -> some View {
        if let line {
            let colors = DiffColors(kind: changed ? line.kind : .context)
            let pick = changed ? picking?.pick(for: line, in: hunk) : nil
            let picked = picking?.isPicked(pick) ?? false
            HStack(alignment: .top, spacing: 0) {
                LineNumber(number: number, width: 35, trailing: 9, gutter: colors.gutter, picked: picked)
                if picking != nil {
                    StagedMark(shows: changed && hunk.stage == .staged)
                }
                DiffLineText(text: line.text, kind: changed ? line.kind : .context, marks: changed ? marks : nil)
                    .padding(.leading, picking == nil ? 8 : 2)
                    .padding(.trailing, 12)
            }
            .frame(maxWidth: .infinity, minHeight: 20, maxHeight: .infinity, alignment: .topLeading)
            .background(picked ? K.accentSoft : colors.line)
            .overlay(alignment: .leading) { if picked { K.accent.frame(width: 3) } }
            .pickable(pick, picking: picking)
        } else {
            StripeFill()
                .frame(maxWidth: .infinity, minHeight: 20, maxHeight: .infinity)
        }
    }
}

/// A line number in its gutter; bold accent on the accent tint when the line is picked.
struct LineNumber: View {
    let number: Int?
    let width: CGFloat
    let trailing: CGFloat
    let gutter: Color
    let picked: Bool

    var body: some View {
        Text(number.map(String.init) ?? "")
            .fontWeight(picked ? .bold : .regular)
            .foregroundStyle(picked ? K.accentText : K.label2)
            .frame(width: width, alignment: .trailing)
            .padding(.trailing, trailing)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(picked ? K.accentSoft : gutter)
    }
}

/// `.lmk`: a ✓ on lines that are staged.
private struct StagedMark: View {
    let shows: Bool

    var body: some View {
        Text(shows ? "✓" : "")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(K.add)
            .frame(width: 14)
    }
}

private extension View {
    /// Clicking picks the line (the caller reads ⇧ and ⌘).
    @ViewBuilder
    func pickable(_ pick: LinePick?, picking: LinePicking?) -> some View {
        if let pick, let picking {
            contentShape(Rectangle())
                .onTapGesture { picking.pick(pick) }
                .pointerStyle(.link)
        } else {
            self
        }
    }
}

/// Line and gutter colors of a diff line.
struct DiffColors {
    let line: Color
    let gutter: Color

    init(kind: DiffLine.Kind) {
        switch kind {
        case .addition:
            line = K.addBg
            gutter = K.addGut
        case .deletion:
            line = K.delBg
            gutter = K.delGut
        case .context, .noNewline:
            line = .clear
            gutter = .clear
        }
    }
}

/// The empty side of a split row: 5 pt diagonal stripes every 10 pt (`.sd.empty`).
struct StripeFill: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 10 * 2.0.squareRoot()
            var offset: CGFloat = -size.height
            var path = Path()
            while offset < size.width + size.height {
                path.move(to: CGPoint(x: offset, y: size.height))
                path.addLine(to: CGPoint(x: offset + size.height, y: 0))
                offset += step
            }
            context.stroke(path, with: .color(K.emptyA), lineWidth: 5)
        }
        .clipped()
    }
}

// MARK: - Shared bits

/// The status letter tile (`.st`): M, A, D… on its color.
struct StatusTile: View {
    let letter: String
    var selected = false

    var body: some View {
        Text(letter)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(selected ? .white : foreground)
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(selected ? Color.white.opacity(0.22) : fill))
    }

    private var foreground: Color {
        switch letter {
        case "A", "U", "?": K.add
        case "D": K.del
        case "!": K.err
        default: K.mod
        }
    }

    private var fill: Color {
        switch letter {
        case "A", "U", "?": K.addBg
        case "D": K.delBg
        case "!": K.delBg
        default: K.modBg
        }
    }
}

/// `+12 −3` in the monospaced stat style.
struct LineCounts: View {
    let additions: Int?
    let deletions: Int?
    var selected = false

    var body: some View {
        HStack(spacing: 5) {
            if let additions, additions > 0 { Text("+\(additions)").foregroundStyle(selected ? .white.opacity(0.85) : K.add) }
            if let deletions, deletions > 0 { Text("−\(deletions)").foregroundStyle(selected ? .white.opacity(0.85) : K.del) }
        }
        .font(.system(size: 11, design: .monospaced))
        .fixedSize()
    }
}

/// The folder in secondary text, then the file name (`.fpath`).
struct FilePathText: View {
    let path: String
    var showsDirectory = true
    var nameWeight: Font.Weight = .regular
    var selected = false
    var size: CGFloat = 12.5

    var body: some View {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        HStack(spacing: 0) {
            if showsDirectory, !directory.isEmpty {
                Text(directory + "/")
                    .foregroundStyle(selected ? .white.opacity(0.85) : K.label2)
                    .truncationMode(.tail)
            }
            Text(name)
                .fontWeight(nameWeight)
                .foregroundStyle(selected ? .white : K.label)
                .layoutPriority(1)
        }
        .font(.system(size: size))
        .lineLimit(1)
    }
}

// MARK: - Diff settings

/// How diffs are drawn (Settings › Diff): font, wrapping, changed-word marks.
struct DiffStyle {
    var font: Font = .system(size: 12, design: .monospaced)
    var lineSpacing: CGFloat = 4
    var wraps = true
    var words = true
}

extension EnvironmentValues {
    @Entry var diffStyle = DiffStyle()
}

/// Reads the diff settings and hands them to the rows below.
struct DiffSettingsReader: ViewModifier {
    @AppStorage(SettingsKey.diffWrap, store: .kaern) private var wraps = true
    @AppStorage(SettingsKey.diffWords, store: .kaern) private var words = true
    @AppStorage(SettingsKey.diffFontName, store: .kaern) private var fontName = ""
    @AppStorage(SettingsKey.diffFontSize, store: .kaern) private var fontSize = 12.0

    func body(content: Content) -> some View {
        _ = (fontName, fontSize)
        let font = AppSettings.diffFont
        let size = font.pointSize
        return content.environment(\.diffStyle, DiffStyle(font: Font(font), lineSpacing: max(2, 20 - size * 1.33), wraps: wraps, words: words))
    }
}

extension View {
    func diffSettings() -> some View { modifier(DiffSettingsReader()) }
}
