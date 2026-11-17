import AppKit
import KaernKit
import SwiftUI

/// Quick Open (⇧⌘O, ScreenSwitcher): one field finds branches, remote branches, commits, files,
/// commands and other open repositories by name. This repository's results come first.
struct QuickOpenItem: Identifiable {
    enum Kind { case branch, remote, commit, file, command, repository }

    let id: String
    let kind: Kind
    let label: String
    /// Characters of `label` that matched (bold).
    let offsets: [Int]
    let meta: String
    let score: Int
    let run: () -> Void
}

struct QuickOpenGroup: Identifiable {
    let title: String
    let items: [QuickOpenItem]
    var id: String { title }
}

@MainActor
enum QuickOpenSource {
    /// The groups for `query` (empty: a couple of recent things per group).
    static func groups(_ query: String, repository: RepositoryModel, window: WindowModel, files: [String]) -> [QuickOpenGroup] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let limit = q.isEmpty ? 2 : 4
        func ranked(_ items: [QuickOpenItem]) -> [QuickOpenItem] {
            Array(items.sorted { $0.score > $1.score }.prefix(limit))
        }
        func match(_ text: String) -> FuzzyMatch? {
            q.isEmpty ? .everything : FuzzyMatch.match(q, in: text)
        }
        var groups: [QuickOpenGroup] = []

        // Branches.
        let recent = repository.recentBranches
        let branches = repository.refs.localBranches.compactMap { ref -> QuickOpenItem? in
            guard let m = match(ref.name) else { return nil }
            let counts = [ref.ahead > 0 ? "↑\(ref.ahead)" : nil, ref.behind > 0 ? "↓\(ref.behind)" : nil].compactMap { $0 }.joined(separator: " ")
            let rank = recent.firstIndex(of: ref.name).map { 100 - $0 } ?? 0
            return QuickOpenItem(id: "b:" + ref.name, kind: .branch, label: ref.name, offsets: m.offsets,
                                 meta: ref.isHead ? "current branch" : counts, score: q.isEmpty ? rank : m.score) {
                if !ref.isHead { repository.from("Quick Open") { repository.checkout(branch: ref.name) } }
            }
        }
        if !branches.isEmpty { groups.append(QuickOpenGroup(title: "Branches", items: ranked(branches))) }

        // Remote branches.
        if !q.isEmpty {
            let remotes = repository.refs.remoteBranches.filter { !$0.name.hasSuffix("/HEAD") }.compactMap { ref -> QuickOpenItem? in
                guard let m = match(ref.name) else { return nil }
                return QuickOpenItem(id: "r:" + ref.name, kind: .remote, label: ref.name, offsets: m.offsets,
                                     meta: ref.remoteName ?? "", score: m.score) {
                    repository.from("Quick Open") { repository.checkoutRemoteBranch(ref) }
                }
            }
            if !remotes.isEmpty { groups.append(QuickOpenGroup(title: "Remote Branches", items: ranked(remotes))) }
        }

        // Commits (the loaded history): by subject, or by hash.
        let commits = repository.commits.prefix(q.isEmpty ? 2 : 3000).compactMap { commit -> QuickOpenItem? in
            let bySubject = match(commit.subject)
            let byHash = !q.isEmpty && commit.id.hasPrefix(q.lowercased()) ? FuzzyMatch(score: 1000, offsets: []) : nil
            guard let m = byHash ?? bySubject else { return nil }
            return QuickOpenItem(id: "c:" + commit.id, kind: .commit, label: commit.subject, offsets: byHash == nil ? m.offsets : [],
                                 meta: "\(commit.shortID) · \(commit.author.name) · \(Formatters.historyDate(commit.author.date))",
                                 score: m.score) {
                repository.screen = nil
                repository.review = nil
                repository.selection = .commit(commit.id)
                repository.scrollRequest = ScrollRequest(id: commit.id)
            }
        }
        if !commits.isEmpty { groups.append(QuickOpenGroup(title: "Commits", items: ranked(commits))) }

        // Files: their history.
        if !q.isEmpty {
            let matched = files.compactMap { path -> QuickOpenItem? in
                guard let m = match(path) else { return nil }
                return QuickOpenItem(id: "f:" + path, kind: .file, label: path, offsets: m.offsets, meta: "file history", score: m.score) {
                    repository.showFileHistory(path)
                }
            }
            if !matched.isEmpty { groups.append(QuickOpenGroup(title: "Files", items: ranked(matched))) }
        }

        // Commands.
        let commands = commandList(repository: repository, window: window).compactMap { command -> QuickOpenItem? in
            guard let m = match(command.title), command.enabled else { return nil }
            return QuickOpenItem(id: "x:" + command.title, kind: .command, label: command.title, offsets: m.offsets,
                                 meta: command.shortcut, score: m.score, run: command.run)
        }
        if !commands.isEmpty, !q.isEmpty { groups.append(QuickOpenGroup(title: "Commands", items: ranked(commands))) }

        // Other open repositories, and their branches.
        var others: [QuickOpenItem] = []
        for model in AppModel.shared.openRepositories where model.path != repository.path {
            let open = { activate(model, in: window) }
            if let m = match(model.name) {
                others.append(QuickOpenItem(id: "o:" + model.path, kind: .repository, label: model.name, offsets: m.offsets,
                                            meta: model.currentBranch.map { "on \($0) · open tab" } ?? "open tab", score: m.score + 5, run: open))
            }
            guard !q.isEmpty else { continue }
            for ref in model.refs.localBranches {
                let label = "\(model.name) › \(ref.name)"
                guard let m = FuzzyMatch.match(q, in: ref.name) else { continue }
                let shift = model.name.count + 3
                others.append(QuickOpenItem(id: "ob:" + model.path + ref.name, kind: .repository, label: label,
                                            offsets: m.offsets.map { $0 + shift }, meta: "branch · open tab", score: m.score, run: open))
            }
        }
        if !others.isEmpty { groups.append(QuickOpenGroup(title: "Other Repositories", items: ranked(others))) }
        return groups
    }

    private static func activate(_ model: RepositoryModel, in window: WindowModel) {
        if let tab = window.tabs.first(where: { $0.path == model.path }) {
            window.activate(tab.id)
        } else {
            FailureHelp.reveal(model)
        }
    }

    struct Command {
        var title: String
        var shortcut: String
        var enabled = true
        var run: () -> Void
    }

    /// What Quick Open can run (the menu bar's everyday commands).
    static func commandList(repository r: RepositoryModel, window: WindowModel) -> [Command] {
        let idle = r.activity == nil && r.isReady && !r.isMidOperation
        let hasRemote = !r.remotes.isEmpty
        return [
            Command(title: "Fetch", shortcut: "⌥⌘F", enabled: idle && hasRemote) { r.from("Quick Open") { r.fetch() } },
            Command(title: "Fetch All Repositories", shortcut: "⌥⇧⌘F") { AutoFetcher.shared.fetchAll(auto: false) },
            Command(title: "Pull", shortcut: "⌥⌘↓", enabled: idle && r.status.upstream != nil) { r.from("Quick Open") { r.pull(r.pullChoice.strategy) } },
            Command(title: "Push", shortcut: "⌥⌘↑", enabled: idle && hasRemote && r.status.branch != nil) { r.from("Quick Open") { r.push() } },
            Command(title: "Stash Changes", shortcut: "⌥⌘S", enabled: idle && !r.status.isClean) { r.from("Quick Open") { r.stash() } },
            Command(title: "Pop Stash", shortcut: "⌥⇧⌘S", enabled: idle && !r.stashes.isEmpty) { r.from("Quick Open") { r.popStash() } },
            Command(title: "New Branch…", shortcut: "⇧⌘N", enabled: idle) { r.askCreateBranch(at: nil) },
            Command(title: "Merge into “\(r.status.branch ?? "HEAD")”…", shortcut: "", enabled: idle && r.status.branch != nil) { r.askMerge() },
            Command(title: "Rebase “\(r.status.branch ?? "HEAD")” onto…", shortcut: "", enabled: idle && r.status.branch != nil) { r.askRebase() },
            Command(title: "Delete Branch…", shortcut: "⌘⌫", enabled: idle) { r.askDeleteBranch() },
            Command(title: "Rename Branch…", shortcut: "", enabled: idle && r.status.branch != nil) {
                if let branch = r.status.branch { r.askRename(branch: branch) }
            },
            Command(title: "File History…", shortcut: "") { r.askFileToExplore(.history) },
            Command(title: "Blame…", shortcut: "") { r.askFileToExplore(.blame) },
            Command(title: "Review", shortcut: "⌥⌘R", enabled: r.isReady) { r.toggleReview() },
            Command(title: "Focus", shortcut: "⌥⌘G", enabled: r.isReady) { window.toggleFocus() },
            Command(title: "Repository Settings…", shortcut: "⌥⌘,", enabled: r.isReady) { r.sheet = .repositorySettings },
            Command(title: "Command Log", shortcut: "⇧⌘L") { CommandLogWindowController.shared.show(repository: r.path) },
            Command(title: "Activity", shortcut: "⌥⌘A") { NotificationCenter.default.post(name: .kaernShowActivity, object: r.id) },
            Command(title: "Settings…", shortcut: "⌘,") { SettingsWindowController.shared.show() },
        ]
    }
}

/// The Quick Open panel (`.qs`): field, grouped results, keys.
struct QuickOpenPanel: View {
    let repository: RepositoryModel
    let window: WindowModel
    @State private var query = ""
    @State private var selection = QuickOpenSelection()
    @State private var files: [String] = []

    var body: some View {
        // The search runs when what is searched changes (the text, the files, the repository),
        // not when the picked row does: that is read by the rows, not here.
        let groups = QuickOpenSource.groups(query, repository: repository, window: window, files: files)
        let flat = groups.flatMap(\.items)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Icon(Icons.search(1.6), size: 17).foregroundStyle(K.label2)
                QuickOpenField(text: $query, placeholder: "Branches, commits, files, commands",
                               move: { step in
                                   guard !flat.isEmpty else { return }
                                   selection.index = (selection.index + step + flat.count) % flat.count
                               },
                               submit: {
                                   guard flat.indices.contains(selection.index) else { return }
                                   let item = flat[selection.index]
                                   window.showsQuickOpen = false
                                   item.run()
                               },
                               cancel: { window.showsQuickOpen = false })
                Text("⇧⌘O").font(.system(size: 11.5)).foregroundStyle(K.label2)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if flat.isEmpty {
                            Text(query.isEmpty ? "Type to find a branch, commit, file or command." : "Nothing matches “\(query)”.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(K.label2)
                                .frame(maxWidth: .infinity, minHeight: 60)
                        }
                        ForEach(groups) { group in
                            Text(group.title)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(K.label2)
                                .padding(.horizontal, 14)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                            ForEach(group.items) { item in
                                let position = flat.firstIndex { $0.id == item.id } ?? 0
                                QuickOpenPickedRow(item: item, position: position, selection: selection)
                                    .id(item.id)
                                    .onTapGesture {
                                        window.showsQuickOpen = false
                                        item.run()
                                    }
                                    .onHover { if $0 { selection.index = position } }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 460)
                .background(QuickOpenScroller(selection: selection, ids: flat.map(\.id), proxy: proxy))
            }
            HStack(spacing: 14) {
                key("↑ ↓", "Move")
                key("Return", "Open")
                key("Esc", "Close")
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(K.alt)
            .overlay(alignment: .top) { K.sep.frame(height: 1) }
        }
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(K.pop))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 18)
        .onChange(of: query) { selection.index = 0 }
        .task {
            guard let git = repository.repository else { return }
            files = await GitCommandTrigger.$current.withValue(.background("Quick Open")) { await git.trackedFiles() }
        }
    }

    private func key(_ caps: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Text(caps)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 5)
                .frame(height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(K.chip2))
            Text(text).font(.system(size: 12))
        }
        .foregroundStyle(K.label2)
    }
}

/// Which result is picked. Its own object: moving through the results (the arrow keys, the
/// pointer) redraws the row left and the row reached, and the panel doesn't search again.
@MainActor @Observable
private final class QuickOpenSelection {
    var index = 0
}

/// A result's row, drawn as picked when it is.
private struct QuickOpenPickedRow: View {
    let item: QuickOpenItem
    let position: Int
    let selection: QuickOpenSelection

    var body: some View {
        QuickOpenRow(item: item, isOn: selection.index == position)
    }
}

/// Keeps the picked row in view.
private struct QuickOpenScroller: View {
    let selection: QuickOpenSelection
    let ids: [QuickOpenItem.ID]
    let proxy: ScrollViewProxy

    var body: some View {
        Color.clear
            .onChange(of: selection.index) { _, index in
                if ids.indices.contains(index) { proxy.scrollTo(ids[index]) }
            }
    }
}

/// `.qsr`: icon, label with the matched characters in bold, meta on the right.
private struct QuickOpenRow: View {
    let item: QuickOpenItem
    let isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
                .foregroundStyle(isOn ? .white : K.accentText)
                .frame(width: 18)
            highlighted
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.meta)
                .font(.system(size: 11.5))
                .foregroundStyle(isOn ? .white.opacity(0.85) : K.label2)
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(isOn ? .white : K.label)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isOn ? K.sel : .clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        switch item.kind {
        case .branch: Icon(Icons.branch(1.4), size: 14)
        case .remote: Icon(Icons.labelRemote, size: 14)
        case .commit: Image(systemName: "smallcircle.filled.circle").font(.system(size: 12))
        case .file: Icon(Icons.file, size: 14)
        case .command: Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
        case .repository: Icon(Icons.folder, size: 14)
        }
    }

    private var highlighted: Text {
        var attributed = AttributedString(item.label)
        let characters = Array(item.label)
        for offset in item.offsets where offset < characters.count {
            let start = attributed.index(attributed.startIndex, offsetByCharacters: offset)
            let end = attributed.index(start, offsetByCharacters: 1)
            attributed[start..<end].font = .system(size: 13, weight: .bold)
        }
        return Text(attributed)
    }
}

/// The field: types like any field, and hands ↑ ↓ Return Esc to the list.
private struct QuickOpenField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusingField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        return field
    }

    /// Takes the keyboard as soon as it's in the window.
    final class FocusingField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QuickOpenField
        init(parent: QuickOpenField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.move(-1); return true
            case #selector(NSResponder.moveDown(_:)): parent.move(1); return true
            case #selector(NSResponder.insertNewline(_:)): parent.submit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel(); return true
            default: return false
            }
        }
    }
}
