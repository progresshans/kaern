import KaernKit
import SwiftUI

/// Lines picked from both sides of one conflict block. The side picked first goes first in the
/// result; within a side, lines keep their order.
struct LinePicks: Equatable {
    var ours: Set<Int> = []
    var theirs: Set<Int> = []
    var theirsFirst = false

    var isEmpty: Bool { ours.isEmpty && theirs.isEmpty }

    func selected(_ side: ConflictSide) -> Set<Int> { side == .ours ? ours : theirs }

    /// The lines that go into the result, with the side each came from.
    func lines(of block: ConflictDocument.Block) -> [(text: String, side: ConflictSide)] {
        let fromOurs = block.ours.indices.filter(ours.contains).map { (text: block.ours[$0], side: ConflictSide.ours) }
        let fromTheirs = block.theirs.indices.filter(theirs.contains).map { (text: block.theirs[$0], side: ConflictSide.theirs) }
        return theirsFirst ? fromTheirs + fromOurs : fromOurs + fromTheirs
    }
}

/// Resolving one conflicted file: both sides on top, the result below. Check lines on either
/// side (or a whole block) to build the result, pick a side per block, or edit the result as
/// text. Mark Resolved writes the result and stages it.
struct ConflictEditorView: View {
    let model: RepositoryModel
    let path: String

    /// The file as git left it.
    @State private var original: ConflictDocument?
    /// Picks per block index. A block with an entry is resolved, even when the entry is empty
    /// ("Use develop" where develop has no lines).
    @State private var picks: [Int: LinePicks] = [:]
    /// The result after editing it as text; replaces the picks until Start Over.
    @State private var editedResult: ConflictDocument?
    @State private var isEditingText = false
    @State private var editedText = ""
    @State private var didLoad = false

    private var entry: StatusEntry? { model.status.entries.first { $0.path == path } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let original {
                VSplitView {
                    HStack(spacing: 0) {
                        ConflictSidePane(
                            rows: SideRow.rows(for: original, side: .ours),
                            side: .ours, title: oursTitle, subtitle: oursSubtitle,
                            picks: picks, isEnabled: editedResult == nil && !isEditingText,
                            onToggleLine: { toggle(.ours, block: $0, line: $1) },
                            onToggleBlock: { toggleBlock(.ours, block: $0, in: original) }
                        )
                        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                        ConflictSidePane(
                            rows: SideRow.rows(for: original, side: .theirs),
                            side: .theirs, title: theirsTitle, subtitle: theirsSubtitle,
                            picks: picks, isEnabled: editedResult == nil && !isEditingText,
                            onToggleLine: { toggle(.theirs, block: $0, line: $1) },
                            onToggleBlock: { toggleBlock(.theirs, block: $0, in: original) }
                        )
                    }
                    .frame(minHeight: 120, idealHeight: 300)
                    resultPane(original)
                        .frame(minHeight: 140, idealHeight: 300)
                }
            } else if didLoad {
                wholeFileChoice
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onExitCommand { model.closeDiff() }
        .task(id: path) { load() }
    }

    private func load() {
        let document = model.repository?.conflictDocument(path)
        original = document?.hasConflicts == true ? document : nil
        picks = [:]
        editedResult = nil
        isEditingText = false
        didLoad = true
    }

    /// The file as it will be written: the picks applied to the original, or the edited text.
    private func result(from original: ConflictDocument) -> ConflictDocument {
        if isEditingText { return ConflictDocument(text: editedText) }
        if let editedResult { return editedResult }
        let blocks = original.blocks
        var resolutions: [Int: [String]] = [:]
        for (index, pick) in picks where index < blocks.count {
            resolutions[index] = pick.lines(of: blocks[index]).map(\.text)
        }
        return original.applying(resolutions)
    }

    // MARK: Picking

    private func toggle(_ side: ConflictSide, block: Int, line: Int) {
        var pick = picks[block] ?? LinePicks()
        if pick.isEmpty { pick.theirsFirst = side == .theirs }
        switch side {
        case .ours: pick.ours.formSymmetricDifference([line])
        case .theirs: pick.theirs.formSymmetricDifference([line])
        }
        // Unchecking the last line makes the block a conflict again.
        picks[block] = pick.isEmpty ? nil : pick
    }

    private func toggleBlock(_ side: ConflictSide, block: Int, in original: ConflictDocument) {
        let lines = side == .ours ? original.blocks[block].ours : original.blocks[block].theirs
        guard !lines.isEmpty else { return }
        var pick = picks[block] ?? LinePicks()
        let all = Set(lines.indices)
        let isAll = pick.selected(side) == all
        if pick.isEmpty { pick.theirsFirst = side == .theirs }
        switch side {
        case .ours: pick.ours = isAll ? [] : all
        case .theirs: pick.theirs = isAll ? [] : all
        }
        picks[block] = pick.isEmpty ? nil : pick
    }

    private func use(_ resolution: ConflictDocument.Resolution, block: Int, in original: ConflictDocument) {
        let lines = original.blocks[block]
        switch resolution {
        case .ours: picks[block] = LinePicks(ours: Set(lines.ours.indices))
        case .theirs: picks[block] = LinePicks(theirs: Set(lines.theirs.indices), theirsFirst: true)
        case .both: picks[block] = LinePicks(ours: Set(lines.ours.indices), theirs: Set(lines.theirs.indices))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                model.closeDiff()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .help("Back to History (Esc)")
            .accessibilityLabel("History")

            Image(systemName: "doc")
                .foregroundStyle(.secondary)
            let (directory, name) = PathLabel.split(path)
            let directoryText = Text(directory).foregroundStyle(.secondary)
            let nameText = Text(name).fontWeight(.semibold)
            Text("\(directoryText)\(nameText)")
                .lineLimit(1)
                .truncationMode(.head)
                .help(path)

            Spacer(minLength: 8)

            if let original {
                let result = result(from: original)
                Text(progress(total: original.conflictCount, left: result.conflictCount))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Group {
                    Button("Keep \(model.oursLabel)") { save(original.resolvingAll(with: .ours)) }
                    Button("Keep \(model.theirsLabel)") { save(original.resolvingAll(with: .theirs)) }
                    Button("Keep Both") { save(original.resolvingAll(with: .both)) }
                    Button("Mark Resolved") { save(result) }
                        .buttonStyle(.borderedProminent)
                        .disabled(result.hasConflicts)
                        .help(result.hasConflicts ? "Pick lines or a side for every block first" : "Save the result and stage it")
                }
                .controlSize(.small)
                .lineLimit(1)
                .fixedSize()
                .disabled(model.activity != nil)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private func progress(total: Int, left: Int) -> String {
        if left == 0 {
            return total == 1 ? String(localized: "Conflict resolved") : String(localized: "All \(total) conflicts resolved")
        }
        return String(localized: "Conflict \(total - left + 1) of \(total) in this file")
    }

    private func save(_ document: ConflictDocument) {
        let text = document.text
        Task { await model.saveResolution(text, for: path) }
    }

    // MARK: Side labels

    private var oursTitle: String {
        guard let operation = model.operation else { return model.oursLabel }
        let id = operation.kind == .rebase ? operation.onto : model.status.headID
        return "\(model.oursLabel) · \(String((id ?? "").prefix(7)))"
    }

    private var oursSubtitle: String {
        model.operation?.kind == .rebase ? String(localized: "base you are rebasing onto") : String(localized: "your branch")
    }

    private var theirsTitle: String {
        guard let operation = model.operation else { return model.theirsLabel }
        let sha = String((operation.incoming ?? "").prefix(7))
        if operation.kind == .merge {
            return "\(model.theirsLabel) · \(sha)"
        }
        if let subject = model.incomingSubject {
            return "\(sha) · \(subject)"
        }
        return sha
    }

    private var theirsSubtitle: String {
        switch model.operation?.kind {
        case .rebase: String(localized: "commit being replayed")
        case .merge: String(localized: "being merged in")
        case .cherryPick: String(localized: "commit being picked")
        case .revert: String(localized: "change being reverted")
        case nil: ""
        }
    }

    // MARK: Result

    private func resultPane(_ original: ConflictDocument) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Result")
                    .font(.system(size: 11, weight: .semibold))
                Text(resultHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(isEditingText ? "Done Editing" : "Edit as Text") {
                    if isEditingText {
                        editedResult = ConflictDocument(text: editedText)
                        isEditingText = false
                    } else {
                        editedText = result(from: original).text
                        isEditingText = true
                    }
                }
                .controlSize(.small)
                Button("Start Over") { load() }
                    .controlSize(.small)
                    .disabled(picks.isEmpty && editedResult == nil && !isEditingText)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color(Palette.diffGutter))
            .overlay(alignment: .top) { Divider() }

            if isEditingText {
                TextEditor(text: $editedText)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .autocorrectionDisabled()
                    .padding(.leading, 6)
                    .accessibilityLabel("Result")
            } else {
                let rows = editedResult.map { ResultRow.rows(for: $0) } ?? ResultRow.rows(for: original, picks: picks)
                CodeScrollView { _ in
                    ForEach(rows) { row in
                        switch row.kind {
                        case .line(let number, let text, let origin):
                            CodeLineRow(number: number, text: text, highlight: origin.map { ConflictSidePane.tint($0).opacity(0.12) })
                        case .block(let index, let block):
                            ConflictBlockBar(
                                block: block,
                                oursLabel: model.oursLabel,
                                theirsLabel: model.theirsLabel
                            ) { resolution in
                                if editedResult == nil {
                                    use(resolution, block: index, in: original)
                                } else if let edited = editedResult {
                                    editedResult = edited.resolving(index, with: resolution)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var resultHint: String {
        if isEditingText { return String(localized: "leftover markers stay conflicts") }
        if editedResult != nil { return String(localized: "edited as text — Start Over to pick lines again") }
        return String(localized: "check lines above, or pick a side per block — edit it directly if neither side is right")
    }

    // MARK: Binary, deleted or unreadable files

    private var wholeFileChoice: some View {
        ContentUnavailableView {
            Label(wholeFileTitle, systemImage: "doc.questionmark")
        } description: {
            Text("Keep one side of the whole file, or resolve it in another app and mark it as resolved.")
        } actions: {
            HStack {
                Button("Keep \(model.oursLabel)") { Task { await model.resolveConflict(path, taking: .ours) } }
                Button("Keep \(model.theirsLabel)") { Task { await model.resolveConflict(path, taking: .theirs) } }
                Button("Mark Resolved") { Task { await model.markResolved(path) } }
            }
            .disabled(model.activity != nil)
        }
    }

    private var wholeFileTitle: String {
        if let entry {
            let description = ResolveConflictsInspector.conflictDescription(entry)
            if !description.isEmpty { return String(localized: "Conflict: \(description)") }
        }
        return String(localized: "This file can't be merged line by line")
    }
}

// MARK: - Side panes

/// Rows of one side: every line of that side's file, with a header above each conflict block.
private struct SideRow: Identifiable {
    enum Kind {
        case header(block: Int, lineCount: Int)
        case line(number: Int, text: String, block: Int?, index: Int?)
    }

    var id: Int
    var kind: Kind

    static func rows(for document: ConflictDocument, side: ConflictSide) -> [SideRow] {
        var rows: [SideRow] = []
        var number = 1
        var block = 0
        for segment in document.segments {
            switch segment {
            case .common(let lines):
                for line in lines {
                    rows.append(SideRow(id: rows.count, kind: .line(number: number, text: line, block: nil, index: nil)))
                    number += 1
                }
            case .conflict(let conflict):
                let lines = side == .ours ? conflict.ours : conflict.theirs
                rows.append(SideRow(id: rows.count, kind: .header(block: block, lineCount: lines.count)))
                for (index, line) in lines.enumerated() {
                    rows.append(SideRow(id: rows.count, kind: .line(number: number, text: line, block: block, index: index)))
                    number += 1
                }
                block += 1
            }
        }
        return rows
    }
}

/// One side of the conflict: the whole file as that side has it. Lines in conflict blocks get a
/// checkbox; the block header's checkbox takes the whole block.
private struct ConflictSidePane: View {
    let rows: [SideRow]
    let side: ConflictSide
    let title: String
    let subtitle: String
    let picks: [Int: LinePicks]
    let isEnabled: Bool
    let onToggleLine: (_ block: Int, _ line: Int) -> Void
    let onToggleBlock: (_ block: Int) -> Void

    static func tint(_ side: ConflictSide) -> Color {
        side == .ours ? Color(Palette.added) : Color.accentColor
    }

    private var tint: Color { Self.tint(side) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5).fill(tint).frame(width: 3, height: 14)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color(Palette.diffGutter))
            .overlay(alignment: .bottom) { Divider() }

            CodeScrollView { proxy in
                ForEach(rows) { row in
                    switch row.kind {
                    case .header(let block, let count):
                        blockHeader(block: block, count: count)
                            .id(row.id)
                    case .line(let number, let text, let block, let index):
                        if let block, let index {
                            let isPicked = picks[block]?.selected(side).contains(index) ?? false
                            CodeLineRow(
                                number: number,
                                text: text,
                                highlight: tint.opacity(isPicked ? 0.28 : 0.12),
                                checkbox: .toggle(isOn: isPicked, isEnabled: isEnabled) {
                                    onToggleLine(block, index)
                                },
                                source: title
                            )
                            .id(row.id)
                        } else {
                            CodeLineRow(number: number, text: text, highlight: nil, checkbox: .spacer)
                                .id(row.id)
                        }
                    }
                }
                .onAppear {
                    // Start at the first conflict with a few lines of context above it.
                    if let first = rows.firstIndex(where: { if case .header = $0.kind { true } else { false } }), first > 3 {
                        proxy.scrollTo(first - 3, anchor: .top)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(subtitle)")
    }

    private func blockHeader(block: Int, count: Int) -> some View {
        let selected = picks[block]?.selected(side).count ?? 0
        let state: StageState = selected == 0 ? .unstaged : (selected == count ? .staged : .partial)
        return HStack(spacing: 6) {
            StageCheckbox(state: state) { onToggleBlock(block) }
                .frame(width: 16)
                .disabled(!isEnabled || count == 0)
                .accessibilityLabel("Use conflict \(block + 1) from \(title)")
            Group {
                if count == 0 {
                    Text("Conflict \(block + 1) · nothing on this side")
                } else {
                    Text("Conflict \(block + 1) · ^[\(count) line](inflect: true)")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .frame(height: 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.06))
        .overlay(alignment: .top) { Rectangle().fill(tint.opacity(0.35)).frame(height: 1) }
    }
}

// MARK: - Shared rows

/// Code that scrolls both ways, pinned to the top-leading corner. Rows are at least as wide as
/// the pane, so highlights run to the edge.
struct CodeScrollView<Content: View>: View {
    @ViewBuilder var content: (ScrollViewProxy) -> Content

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        content(proxy)
                    }
                    .padding(.vertical, 4)
                    .padding(.bottom, 12)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }
            }
        }
    }
}

/// A numbered line of code, optionally with a checkbox in front.
private struct CodeLineRow: View {
    enum Checkbox {
        /// No checkbox column (the result pane).
        case none
        /// An empty checkbox column, to line up with checked rows.
        case spacer
        case toggle(isOn: Bool, isEnabled: Bool, action: () -> Void)
    }

    let number: Int?
    let text: String
    let highlight: Color?
    var checkbox: Checkbox = .none
    /// The side's name, for the checkbox's accessibility label.
    var source: String = ""

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            switch checkbox {
            case .none:
                EmptyView()
            case .spacer:
                Color.clear.frame(width: 22)
            case .toggle(let isOn, let isEnabled, let action):
                StageCheckbox(state: isOn ? .staged : .unstaged, action: action)
                    .frame(width: 16)
                    .padding(.leading, 6)
                    .disabled(!isEnabled)
                    .accessibilityLabel("Use line \(number ?? 0) from \(source)")
            }
            Text(number.map(String.init) ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 10)
            Text(Self.display(text))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 16)
        }
        .padding(.vertical, 1)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(highlight ?? .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            // The whole line is the hit target, not just the checkbox.
            if case .toggle(_, let isEnabled, let action) = checkbox, isEnabled { action() }
        }
    }

    static func display(_ text: String) -> String {
        var text = text
        if text.hasSuffix("\r") { text.removeLast() }
        return text.replacingOccurrences(of: "\t", with: "    ")
    }
}

/// An unresolved block in the result: how many lines differ and a button per choice.
private struct ConflictBlockBar: View {
    let block: ConflictDocument.Block
    let oursLabel: String
    let theirsLabel: String
    let onResolve: (ConflictDocument.Resolution) -> Void

    private var lineCount: Int { max(block.ours.count, block.theirs.count) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color(Palette.deleted))
            Text(lineCount == 1 ? "1 line differs — pick a side for this block" : "\(lineCount) lines differ — pick a side for this block")
                .font(.system(size: 12))
                .fixedSize()
            Group {
                Button("Use \(oursLabel)") { onResolve(.ours) }
                Button("Use \(theirsLabel)") { onResolve(.theirs) }
                Button("Use Both") { onResolve(.both) }
            }
            .controlSize(.small)
            .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.leading, 50)
        .padding(.trailing, 12)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(Palette.diffRemovedBackground))
        .accessibilityElement(children: .contain)
    }
}

/// Rows of the result: numbered lines, and a bar for every block that's still open. Picked lines
/// are tinted with the color of the side they came from.
private struct ResultRow: Identifiable {
    enum Kind {
        case line(number: Int, text: String, origin: ConflictSide?)
        case block(index: Int, ConflictDocument.Block)
    }

    var id: Int
    var kind: Kind

    /// The original file with the picks applied.
    static func rows(for document: ConflictDocument, picks: [Int: LinePicks]) -> [ResultRow] {
        var rows: [ResultRow] = []
        var number = 1
        var blockIndex = 0
        for segment in document.segments {
            switch segment {
            case .common(let lines):
                for line in lines {
                    rows.append(ResultRow(id: rows.count, kind: .line(number: number, text: line, origin: nil)))
                    number += 1
                }
            case .conflict(let block):
                if let pick = picks[blockIndex] {
                    for line in pick.lines(of: block) {
                        rows.append(ResultRow(id: rows.count, kind: .line(number: number, text: line.text, origin: line.side)))
                        number += 1
                    }
                } else {
                    rows.append(ResultRow(id: rows.count, kind: .block(index: blockIndex, block)))
                    number += block.ours.count
                }
                blockIndex += 1
            }
        }
        return rows
    }

    /// A result edited as text: its lines, and bars for leftover markers.
    static func rows(for document: ConflictDocument) -> [ResultRow] {
        rows(for: document, picks: [:])
    }
}
