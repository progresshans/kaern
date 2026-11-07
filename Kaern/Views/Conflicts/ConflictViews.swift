import AppKit
import KaernKit
import SwiftUI

// MARK: - Operation bar

/// `.opbar` under the toolbar while a merge, rebase, cherry-pick or revert waits, or a stash
/// stopped on conflicts: what's going on and Abort · Skip · Continue. Green for a moment after
/// it finishes.
struct OperationBar: View {
    let repository: RepositoryModel

    var body: some View {
        if let conflict = repository.stashConflict {
            bar(colors: .stopped) {
                Icon(Icons.warn, size: 14)
                Text("\(Text("\(conflict.wasPop ? "Pop" : "Apply") stopped: \(fileList(conflict.conflicted)) \(conflict.conflicted.count == 1 ? "has a conflict" : "have conflicts").").fontWeight(.semibold)) The stash stays in the list until \(conflict.conflicted.count == 1 ? "the conflict is" : "the conflicts are") resolved.")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                BarButton(title: "Undo \(conflict.wasPop ? "Pop" : "Apply")") { repository.from("Operation bar") { repository.takeBackStashConflict() } }
                if repository.screen != .conflicts {
                    BarButton(title: "Resolve Conflict", primary: true) { repository.openConflicts() }
                }
            }
        } else if let operation = repository.operation {
            let left = repository.conflictedPaths.count
            bar(colors: .stopped) {
                Icon(Icons.warn, size: 14)
                Text("\(Text(title(operation)).fontWeight(.semibold)) — \(progress(operation, left: left))")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if left > 0, repository.screen != .conflicts {
                    BarButton(title: "Resolve…") { repository.openConflicts() }
                }
                BarButton(title: "Abort \(operation.kind.title)") { repository.from("Operation bar") { repository.abortOperation() } }
                if operation.kind.canSkip {
                    BarButton(title: "Skip Commit") { repository.from("Operation bar") { repository.skipOperationCommit() } }
                }
                BarButton(title: "Continue", primary: true) { repository.from("Operation bar") { repository.continueOperation() } }
                    .disabled(left > 0)
            }
            .disabled(repository.activity != nil)
        } else if let finish = repository.operationFinish {
            bar(colors: .finished) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 14))
                Text("\(Text(finish.title).fontWeight(.semibold)) \(finish.detail)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button { repository.operationFinish = nil } label: {
                    Icon(Icons.close, size: 10).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(HoverPlateStyle(radius: 6))
                .accessibilityLabel("Close")
            }
        }
    }

    private enum BarColors {
        case stopped, finished
        var fill: Color { self == .stopped ? K.opBg : K.okBg }
        var text: Color { self == .stopped ? K.opText : K.okText }
    }

    private func bar<Content: View>(colors: BarColors, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 9) { content() }
            .font(.system(size: 12.5))
            .foregroundStyle(colors.text)
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .frame(height: 42)
            .frame(maxWidth: .infinity)
            .background(colors.fill)
            .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
            .accessibilityElement(children: .contain)
    }

    private func title(_ operation: OperationState) -> String {
        let branch = operation.branch ?? repository.status.branch ?? "HEAD"
        switch operation.kind {
        case .rebase:
            let onto = operation.onto.map { id in
                repository.refs.localBranches.first { $0.target == id }?.name ?? repository.refs.remoteBranches.first { $0.target == id }?.name ?? repository.short(id)
            }
            return "Rebasing \(branch)" + (onto.map { " onto \($0)" } ?? "")
        case .merge:
            return "Merging \(operation.incomingName ?? operation.incoming.map(repository.short) ?? "a branch") into \(branch)"
        case .cherryPick:
            return "Cherry-picking \(operation.incoming.map(repository.short) ?? "a commit") onto \(branch)"
        case .revert:
            return "Reverting \(operation.incoming.map(repository.short) ?? "a commit") on \(branch)"
        }
    }

    private func progress(_ operation: OperationState, left: Int) -> String {
        var parts: [String] = []
        if let step = operation.step, let total = operation.total {
            parts.append("stopped at commit \(step) of \(total)")
        } else {
            parts.append("stopped")
        }
        parts.append(left == 0 ? "ready to continue" : Formatters.count(left, "conflict left", "conflicts left"))
        return parts.joined(separator: " · ")
    }

    private func fileList(_ paths: [String]) -> String {
        paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) files"
    }
}

/// `.ob`: the bar's buttons; Continue is filled.
private struct BarButton: View {
    let title: String
    var primary = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(primary ? Color.white : K.label)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background {
                    if primary {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(K.accent)
                    } else {
                        Color.clear.controlSurface(radius: 6)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .fixedSize()
    }
}

// MARK: - Conflict editor

/// The center while resolving (ScreenConflicts `.ce`): the file's two sides on top, the result
/// below with a bar on each open block (Use ours · Use theirs · Use Both), Keep … for the whole
/// file, and Mark Resolved.
struct ConflictEditor: View {
    @Bindable var repository: RepositoryModel

    var body: some View {
        let session = repository.conflictSession
        let names = repository.conflictSides
        VStack(spacing: 0) {
            header(session: session, names: names)
            if let session, let original = session.original {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        sides(original, names: names)
                            .frame(height: min(max(geometry.size.height * 0.42, 140), geometry.size.height - 120))
                        K.sep.frame(height: 1)
                        result(session, original: original, names: names)
                    }
                }
            } else if let path = session?.path {
                unreadable(path)
            } else {
                Text("No conflicts left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(K.label2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(K.content)
        .diffSettings()
    }

    // MARK: Header

    private func header(session: ConflictSession?, names: ConflictSideNames) -> some View {
        let path = session?.path ?? ""
        let blocks = session?.original?.conflictCount ?? 0
        let open = session?.openBlocks ?? 0
        let resolvedAlready = !path.isEmpty && !repository.conflictedPaths.contains(path)
        return HStack(spacing: 8) {
            Button { repository.closeConflicts() } label: {
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
            Icon(Icons.file, size: 15).foregroundStyle(K.label2)
            FilePathText(path: path, nameWeight: .semibold, size: 13)
                .layoutPriority(-1)
            Text(counter(blocks: blocks, open: open, resolved: resolvedAlready, editing: session?.editingText != nil))
                .font(.system(size: 11.5))
                .foregroundStyle(K.label2)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            if blocks > 0, session?.editingText == nil {
                GhostButton(title: "Keep \(names.oursShort)") { repository.keepAll(.ours) }
                GhostButton(title: "Keep \(names.theirsShort)") { repository.keepAll(.theirs) }
                GhostButton(title: "Keep Both") { repository.keepAll(.both) }
            }
            if !resolvedAlready {
                MarkResolvedButton(title: "Mark Resolved") { repository.from("Conflict editor") { repository.markResolved() } }
                    .disabled(!canMarkResolved(session) || repository.activity != nil)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: 44)
        .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
    }

    private func counter(blocks: Int, open: Int, resolved: Bool, editing: Bool) -> String {
        if resolved { return "Resolved" }
        if editing { return "Editing the result" }
        if blocks == 0 { return "No conflict markers left" }
        if open == 0 { return "All \(Formatters.count(blocks, "conflict", "conflicts")) picked" }
        let first = blocks - open + 1
        return "Conflict \(first) of \(blocks) in this file"
    }

    private func canMarkResolved(_ session: ConflictSession?) -> Bool {
        guard let session else { return false }
        if let text = session.editingText { return !ConflictDocument(text: text).hasConflicts }
        return session.openBlocks == 0 && session.original != nil
    }

    // MARK: Two sides

    private func sides(_ document: ConflictDocument, names: ConflictSideNames) -> some View {
        HStack(spacing: 0) {
            SideColumn(title: names.oursTitle, note: names.oursNote, marker: Color(nsColor: K.hex(0x28a745)),
                       lines: document.lines(for: .ours), tint: K.oursBg)
            K.sep.frame(width: 1)
            SideColumn(title: names.theirsTitle, note: names.theirsNote, marker: K.accent,
                       lines: document.lines(for: .theirs), tint: K.theirsBg)
        }
    }

    // MARK: Result

    @ViewBuilder
    private func result(_ session: ConflictSession, original: ConflictDocument, names: ConflictSideNames) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Result").fontWeight(.semibold).foregroundStyle(K.label)
                Text(session.editingText == nil ? "what the file will contain — you can also edit it directly" : "type the file as it should be; leftover markers keep it unresolved")
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(session.editingText == nil ? "Edit Directly" : "Done Editing") { repository.toggleDirectEdit() }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(K.label2)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(K.inspector)
            .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
            if let text = session.editingText {
                TextEditor(text: Binding(get: { text }, set: { repository.conflictSession?.editingText = $0 }))
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(K.content)
            } else {
                let rows = ResultRow.rows(original, choices: session.choices)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in
                                ResultRowView(row: row, names: names, repository: repository)
                                    .id(row.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    // The next block to pick comes into view (on opening a file and after each pick).
                    .onAppear { scrollToOpenBlock(rows, proxy) }
                    .onChange(of: session.choices) { scrollToOpenBlock(rows, proxy) }
                    .onChange(of: session.path) { scrollToOpenBlock(rows, proxy) }
                }
            }
        }
    }

    private func scrollToOpenBlock(_ rows: [ResultRow], _ proxy: ScrollViewProxy) {
        guard let block = rows.first(where: { if case .block = $0.kind { true } else { false } }) else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(max(0, block.id - 4), anchor: .top) }
    }

    private func unreadable(_ path: String) -> some View {
        VStack(spacing: 10) {
            Text("Kaern can’t show this file side by side")
                .font(.system(size: 13, weight: .semibold))
            Text("It’s binary, deleted on one side or too large. Take one side whole, or open it in FileMerge.")
                .font(.system(size: 12))
                .foregroundStyle(K.label2)
            HStack(spacing: 8) {
                GhostButton(title: "Take \(repository.conflictSides.oursShort)") { repository.resolveWholeFile(path, side: .ours) }
                GhostButton(title: "Take \(repository.conflictSides.theirsShort)") { repository.resolveWholeFile(path, side: .theirs) }
                GhostButton(title: "Open in FileMerge") { repository.openInFileMerge(path) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `.ghost.primaryg`: Mark Resolved.
private struct MarkResolvedButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(K.accent))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .fixedSize()
    }
}

/// `.side2`: one side's header (`.sh2`) and the whole file as that side has it, its conflict
/// lines tinted.
private struct SideColumn: View {
    let title: String
    let note: String
    let marker: Color
    let lines: [ConflictDocument.SideLine]
    let tint: Color
    @Environment(\.diffStyle) private var style

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2).fill(marker).frame(width: 3, height: 14)
                Text(title).fontWeight(.semibold).foregroundStyle(K.label).lineLimit(1).truncationMode(.tail)
                Text(note).lineLimit(1).layoutPriority(-1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(K.label2)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(K.inspector)
            .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 0) {
                            Text("\(index + 1)")
                                .foregroundStyle(K.label2)
                                .frame(width: 42, alignment: .trailing)
                                .padding(.trailing, 10)
                            Text(displayText(line.text))
                                .foregroundStyle(K.code)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.trailing, 10)
                        }
                        .frame(height: 20)
                        .background(line.conflict != nil ? tint : .clear)
                        .id(index)
                    }
                }
                .font(style.font)
                .padding(.vertical, 4)
            }
            .onAppear { scrollToFirstConflict(proxy) }
            .onChange(of: lines) { scrollToFirstConflict(proxy) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The first conflicting line shows a few lines below the top.
    private func scrollToFirstConflict(_ proxy: ScrollViewProxy) {
        guard let first = lines.firstIndex(where: { $0.conflict != nil }), first > 3 else { return }
        proxy.scrollTo(first - 3, anchor: .top)
    }
}

/// One row of the result: a line, an open block's bar, or the note on a picked block.
private struct ResultRow: Identifiable {
    enum Kind {
        case line(number: Int, text: String, picked: Bool)
        case block(index: Int, lines: Int)
        case picked(index: Int, resolution: ConflictDocument.Resolution)
    }

    let id: Int
    let kind: Kind

    static func rows(_ document: ConflictDocument, choices: [Int: ConflictDocument.Resolution]) -> [ResultRow] {
        var rows: [ResultRow] = []
        var number = 1
        var conflict = 0
        func add(_ kind: Kind) { rows.append(ResultRow(id: rows.count, kind: kind)) }
        for segment in document.segments {
            switch segment {
            case .common(let lines):
                for line in lines {
                    add(.line(number: number, text: line, picked: false))
                    number += 1
                }
            case .conflict(let block):
                if let choice = choices[conflict] {
                    add(.picked(index: conflict, resolution: choice))
                    let chosen: [String] = switch choice {
                    case .ours: block.ours
                    case .theirs: block.theirs
                    case .both: block.ours + block.theirs
                    }
                    for line in chosen {
                        add(.line(number: number, text: line, picked: true))
                        number += 1
                    }
                } else {
                    add(.block(index: conflict, lines: max(block.ours.count, block.theirs.count)))
                }
                conflict += 1
            }
        }
        return rows
    }
}

private struct ResultRowView: View {
    let row: ResultRow
    let names: ConflictSideNames
    let repository: RepositoryModel
    @Environment(\.diffStyle) private var style

    var body: some View {
        switch row.kind {
        case .line(let number, let text, let picked):
            HStack(alignment: .top, spacing: 0) {
                Text("\(number)")
                    .foregroundStyle(K.label2)
                    .frame(width: 42, alignment: .trailing)
                    .padding(.trailing, 10)
                Text(displayText(text))
                    .foregroundStyle(K.code)
                    .lineLimit(style.wraps ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 10)
            }
            .font(style.font)
            .frame(minHeight: 20)
            .background(picked ? K.accentSoft.opacity(0.5) : .clear)
        case .block(let index, let lines):
            HStack(spacing: 8) {
                Icon(Icons.warn, size: 14)
                Text("\(Formatters.count(lines, "line differs", "lines differ")) — pick a side for this block")
                    .padding(.trailing, 6)
                BlockButton(title: "Use \(names.oursShort)") { repository.pickConflict(index, .ours) }
                BlockButton(title: "Use \(names.theirsShort)") { repository.pickConflict(index, .theirs) }
                BlockButton(title: "Use Both") { repository.pickConflict(index, .both) }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(K.cbText)
            .padding(EdgeInsets(top: 7, leading: 52, bottom: 7, trailing: 12))
            .background(K.cbBg)
            .padding(.vertical, 2)
        case .picked(let index, let resolution):
            HStack(spacing: 8) {
                Text(pickedText(resolution))
                Button("Change") { repository.unpickConflict(index) }
                    .buttonStyle(.plain)
                    .foregroundStyle(K.accentText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(K.accentSoft.opacity(0.0001)))
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(K.accentText)
            .padding(EdgeInsets(top: 3, leading: 52, bottom: 3, trailing: 12))
        }
    }

    private func pickedText(_ resolution: ConflictDocument.Resolution) -> String {
        switch resolution {
        case .ours: "Using \(names.oursShort) for this block ·"
        case .theirs: "Using \(names.theirsShort) for this block ·"
        case .both: "Using both, \(names.oursShort) first ·"
        }
    }
}

/// `.cblock .ob`.
private struct BlockButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(K.label)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .controlSurface(radius: 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

// MARK: - Resolve Conflicts panel

/// The right panel while resolving (`.rcpanel`, 330 pt): the conflicted files (✓ when resolved),
/// FileMerge, what merged on its own, and the message for the commit that comes next.
struct ResolveConflictsPanel: View {
    @Bindable var repository: RepositoryModel

    var body: some View {
        let session = repository.conflictSession
        let files = session?.files ?? repository.conflictedPaths
        let open = Set(repository.conflictedPaths)
        let merged = repository.mergedAutomatically
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Resolve Conflicts")
                        .font(.system(size: 15, weight: .bold))
                        .padding(.horizontal, 4)
                    Text(summary(files: files, open: open, merged: merged.count))
                        .font(.system(size: 12))
                        .foregroundStyle(K.label2)
                        .padding(.horizontal, 4)
                        .padding(.top, 3)
                    sectionTitle("Conflicted")
                    ForEach(files, id: \.self) { path in
                        ConflictFileRow(path: path, isOpen: open.contains(path), isShown: session?.path == path) {
                            repository.showConflict(path)
                        }
                    }
                    if let path = session?.path, open.contains(path) {
                        Button("Open in FileMerge") { repository.openInFileMerge(path) }
                            .buttonStyle(.link)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.leading, 7)
                            .padding(.top, 6)
                    }
                    if !merged.isEmpty {
                        sectionTitle("Merged automatically")
                        ForEach(merged, id: \.path) { entry in
                            HStack(spacing: 7) {
                                StatusTile(letter: entry.kind.letter)
                                FilePathText(path: entry.path)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                LineCounts(additions: repository.lineStats.staged[entry.path]?.additions,
                                           deletions: repository.lineStats.staged[entry.path]?.deletions)
                            }
                            .padding(.horizontal, 6)
                            .frame(height: KMetric.fileRow)
                        }
                    }
                }
                .padding(EdgeInsets(top: 14, leading: 12, bottom: 10, trailing: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            messageBox
        }
        .frame(width: 330)
        .frame(maxHeight: .infinity)
        .background(K.inspector)
        .overlay(alignment: .leading) { K.sep.frame(width: 1) }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(K.label2)
            .padding(.horizontal, 4)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    private func summary(files: [String], open: Set<String>, merged: Int) -> String {
        var parts: [String] = []
        if let operation = repository.operation, let step = operation.step, let total = operation.total {
            parts.append("Commit \(step) of \(total)")
        } else if let conflict = repository.stashConflict {
            parts.append(conflict.stash.reference)
        }
        parts.append("\(open.count) of \(files.count) conflicted")
        if merged > 0 { parts.append("\(merged) merged automatically") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var messageBox: some View {
        if let operation = repository.operation, operation.canEditMessage {
            VStack(alignment: .leading, spacing: 7) {
                Text(messageTitle(operation))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(K.label2)
                TextEditor(text: Binding(
                    get: { repository.conflictSession?.message ?? operation.message },
                    set: { value in
                        repository.conflictSession?.message = value
                        repository.conflictSession?.messageEdited = true
                    }
                ))
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 5)
                .padding(.vertical, 5)
                .frame(height: 96)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(K.field)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5)))
                Text("Resolve \(repository.conflictSession?.files.count == 1 ? "the file" : "the files"), then press Continue in the bar above. The message is kept.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(K.label2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .overlay(alignment: .top) { K.sep.frame(height: 1) }
        } else if repository.stashConflict != nil {
            Text("Mark each file resolved. The stash stays in Stashes until you drop it.")
                .font(.system(size: 11.5))
                .foregroundStyle(K.label2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { K.sep.frame(height: 1) }
        }
    }

    private func messageTitle(_ operation: OperationState) -> String {
        if let step = operation.step, let total = operation.total { return "Message for commit \(step) of \(total)" }
        switch operation.kind {
        case .merge: return "Merge commit message"
        default: return "Commit message"
        }
    }
}

/// `.file` in the conflicted list: red ! while open, green ✓ once resolved.
private struct ConflictFileRow: View {
    let path: String
    let isOpen: Bool
    let isShown: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(isOpen ? "!" : "✓")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(isOpen ? K.err : K.ok))
                FilePathText(path: path, selected: isShown)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(isOpen ? "conflict" : "resolved")
                    .font(.system(size: 11))
                    .foregroundStyle(isShown ? .white.opacity(0.85) : K.label2)
            }
            .padding(.horizontal, 6)
            .frame(height: KMetric.fileRow)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isShown ? K.sel : (hovering ? K.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(path)
    }
}
