import AppKit
import KaernKit
import SwiftUI

/// One result of the quick switcher.
struct QuickSwitcherItem: Identifiable {
    enum Kind {
        case ref(Ref)
        case commit(Commit)
        case file(String)
        case command(QuickCommand)
        case repository(RecentRepository)
    }

    let id: String
    var kind: Kind
    var title: String
    var offsets: [Int]
    var subtitle: String
    var systemImage: String
}

/// Something the quick switcher can run ("Fetch", "New Branch…").
struct QuickCommand {
    var title: String
    var shortcut: String?
    var systemImage = "command"
    var isEnabled = true
    var action: @MainActor () -> Void
}

struct QuickSwitcherSection: Identifiable {
    var id: String
    var title: LocalizedStringKey
    var items: [QuickSwitcherItem]
}

/// ⇧⌘O: branches, commits, files and commands by name (GitKraken's Fuzzy Finder). This
/// repository's results come first; other repositories are at the bottom. Commands run from
/// here, so you don't need to know where a menu item lives.
struct QuickSwitcher: View {
    let model: RepositoryModel
    let onSwitchRepository: (URL) -> Void

    @Environment(AppModel.self) private var appModel
    @State private var query = ""
    @State private var files: [String] = []
    /// "last changed Sep 26" for the files on screen, loaded as they appear.
    @State private var lastChanged: [String: Date] = [:]
    @State private var highlighted = 0
    @State private var contentHeight: CGFloat = 0
    /// Where the pointer last was, so rows sliding under a still pointer don't steal the highlight.
    @State private var pointer: CGPoint?
    @FocusState private var isFocused: Bool

    /// Headers and rows in one list; the index counts rows only (for ↑↓ and the highlight).
    private enum Line: Identifiable {
        case header(id: String, title: LocalizedStringKey)
        case item(QuickSwitcherItem, index: Int)

        var id: String {
            switch self {
            case .header(let id, _): "header-\(id)"
            case .item(let item, _): item.id
            }
        }
    }

    var body: some View {
        let sections = QuickSwitcherResults.sections(
            for: query, model: model, files: files, lastChanged: lastChanged, recents: appModel.recents, actions: actions
        )
        let items = sections.flatMap(\.items)
        let lines = Self.lines(for: sections)
        let visibleFiles = items.compactMap { item -> String? in
            if case .file(let path) = item.kind { return path }
            return nil
        }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                TextField("Quick Switcher", text: $query, prompt: Text("Go to a branch, commit, file or command"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($isFocused)
                    .onKeyPress(.downArrow) { move(1, count: items.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, count: items.count); return .handled }
                    .onKeyPress(.return, phases: .down) { press in
                        guard highlighted < items.count else { return .ignored }
                        activate(items[highlighted], modifiers: press.modifiers)
                        return .handled
                    }
                    .onExitCommand { close() }
                    .accessibilityLabel("Quick Switcher")
                Text("Branches, commits, files, commands")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Divider()

            if items.isEmpty {
                Text(query.isEmpty ? "Type to search" : "No matches for “\(query)”")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(lines) { line in
                                switch line {
                                case .header(_, let title):
                                    Text(title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.top, 8)
                                        .padding(.bottom, 3)
                                        .accessibilityAddTraits(.isHeader)
                                case .item(let item, let index):
                                    QuickSwitcherRow(item: item, isHighlighted: index == highlighted)
                                        .contentShape(Rectangle())
                                        .onTapGesture { activate(item, modifiers: EventModifiers(NSEvent.modifierFlags)) }
                                        .onContinuousHover(coordinateSpace: .global) { phase in
                                            if case .active(let location) = phase, location != pointer {
                                                pointer = location
                                                highlighted = index
                                            }
                                        }
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    }
                    .frame(height: min(max(contentHeight, 30), 400))
                    .scrollBounceBehavior(.basedOnSize)
                    .onChange(of: highlighted) { _, index in
                        if index < items.count { proxy.scrollTo(items[index].id) }
                    }
                }
            }

            Divider()
            HStack(spacing: 14) {
                hint("↑↓", "Move")
                hint("Return", "Open")
                hint("⌘Return", "New Window")
                hint("⌥Return", "Show in Sidebar")
                hint("Esc", "Close")
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 28)
        }
        .frame(width: 580)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        .onAppear {
            query = model.quickSwitcherQuery ?? ""
            isFocused = true
        }
        .task { files = await model.repository?.trackedFiles() ?? [] }
        .task(id: visibleFiles) { await loadLastChanged(visibleFiles) }
        .onChange(of: query) { highlighted = 0 }
    }

    private static func lines(for sections: [QuickSwitcherSection]) -> [Line] {
        var lines: [Line] = []
        var index = 0
        for section in sections {
            lines.append(.header(id: section.id, title: section.title))
            for item in section.items {
                lines.append(.item(item, index: index))
                index += 1
            }
        }
        return lines
    }

    private func hint(_ key: String, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Text(key).foregroundStyle(.primary.opacity(0.7))
            Text(label)
        }
    }

    private func move(_ offset: Int, count: Int) {
        guard count > 0 else { return }
        highlighted = min(max(highlighted + offset, 0), count - 1)
    }

    private func close() {
        model.quickSwitcherQuery = nil
    }

    private func loadLastChanged(_ paths: [String]) async {
        guard let repository = model.repository else { return }
        for path in paths where lastChanged[path] == nil {
            guard let date = await repository.lastChangeDate(of: path), !Task.isCancelled else { continue }
            lastChanged[path] = date
        }
    }

    /// Return opens, ⌘Return opens a repository in a new window, ⌥Return shows a branch in the
    /// sidebar (a file in the Finder).
    private func activate(_ item: QuickSwitcherItem, modifiers: EventModifiers) {
        close()
        switch item.kind {
        case .ref(let ref):
            if modifiers.contains(.option) || ref.kind == .tag || (ref.kind == .localBranch && ref.isHead) {
                model.reveal(ref)
            } else {
                model.requestSwitch(to: ref)
            }
        case .commit(let commit):
            model.selectedFile = nil
            model.selection = .commit(commit.id)
        case .file(let path):
            if modifiers.contains(.option) {
                model.revealInFinder(path)
            } else {
                model.showFile(path)
            }
        case .command(let command):
            command.action()
        case .repository(let recent):
            if modifiers.contains(.command) {
                AppModel.shared.open(recent.url)
            } else {
                onSwitchRepository(recent.url)
            }
        }
    }

    // MARK: Commands

    /// What applies to the selection first (the selected file, then the selected commit), then
    /// the rest in menu order.
    private var actions: [QuickCommand] {
        let model = model
        let current = model.currentBranchTitle
        var commands = selectionActions
        if let operation = model.operation {
            commands.append(QuickCommand(title: operation.kind == .merge ? String(localized: "Commit Merge") : String(localized: "Continue"),
                                         shortcut: "⌘↩", systemImage: "arrow.right.circle", isEnabled: model.status.conflictCount == 0) {
                Task { await model.continueOperation() }
            })
            commands.append(QuickCommand(title: String(localized: "Abort"), shortcut: nil, systemImage: "xmark.circle") { model.requestAbortOperation() })
        }
        commands += [
            QuickCommand(title: String(localized: "Fetch"), shortcut: "⇧⌘F", systemImage: "arrow.clockwise", isEnabled: !model.remotes.isEmpty) {
                Task { await model.fetch() }
            },
            QuickCommand(title: String(localized: "Pull"), shortcut: "⇧⌘L", systemImage: "arrow.down",
                         isEnabled: model.canStartOperation && model.status.upstream != nil) { Task { await model.pull() } },
            QuickCommand(title: String(localized: "Push"), shortcut: "⇧⌘P", systemImage: "arrow.up",
                         isEnabled: model.canStartOperation && model.status.branch != nil) { Task { await model.push() } },
            QuickCommand(title: String(localized: "Stash Changes…"), shortcut: "⌥⌘S", systemImage: "tray.and.arrow.down",
                         isEnabled: !model.status.isClean && model.operation == nil) { model.sheet = .stash },
            QuickCommand(title: String(localized: "New Branch…"), shortcut: "⇧⌘N", systemImage: "arrow.triangle.branch", isEnabled: model.hasHead) {
                model.sheet = .newBranch(startPoint: nil, label: model.headTitle)
            },
            QuickCommand(title: String(localized: "New Tag…"), shortcut: nil, systemImage: "tag", isEnabled: model.hasHead) {
                if let head = model.status.headID { model.sheet = .newTag(commitID: head, label: model.headTitle) }
            },
            QuickCommand(title: String(localized: "Merge into “\(current)”…"), shortcut: nil, systemImage: "arrow.triangle.merge",
                         isEnabled: model.canStartOperation && model.hasHead) { model.sheet = .chooseBranch(.merge) },
            QuickCommand(title: String(localized: "Rebase “\(current)” onto…"), shortcut: nil, systemImage: "arrow.triangle.branch",
                         isEnabled: model.canStartOperation && model.hasHead) { model.sheet = .chooseBranch(.rebase) },
            QuickCommand(title: String(localized: "Rename “\(current)”…"), shortcut: nil, systemImage: "pencil", isEnabled: model.refs.headBranch != nil) {
                if let ref = model.refs.headBranch { model.sheet = .renameBranch(ref) }
            },
            QuickCommand(title: String(localized: "Show History"), shortcut: "⌘1", systemImage: "clock") {
                if model.fileHistory != nil { model.closeFileHistory() } else { model.closeDiff() }
            },
            QuickCommand(title: String(localized: "Find Commits"), shortcut: "⌘F", systemImage: "magnifyingglass") { model.searchFocusRequest += 1 },
            QuickCommand(title: String(localized: "Refresh"), shortcut: "⌘R", systemImage: "arrow.clockwise") { Task { await model.refreshEverything() } },
            QuickCommand(title: String(localized: "Show in Finder"), shortcut: nil, systemImage: "folder") { model.openRepositoryInFinder() },
            QuickCommand(title: String(localized: "Open in Terminal"), shortcut: nil, systemImage: "terminal") { model.openInTerminal() },
            QuickCommand(title: String(localized: "Repository Settings…"), shortcut: "⌥⌘,", systemImage: "gearshape") { model.sheet = .repositorySettings },
            QuickCommand(title: String(localized: "Repositories"), shortcut: "⇧⌘R", systemImage: "square.stack") { AppModel.shared.showRepositories() },
        ]
        if let undo = model.undoManager, undo.canUndo {
            commands.append(QuickCommand(title: undo.undoMenuItemTitle, shortcut: "⌘Z", systemImage: "arrow.uturn.backward") { model.undoManager?.undo() })
        }
        return commands
    }

    private var selectionActions: [QuickCommand] {
        let model = model
        var commands: [QuickCommand] = []
        if let entry = model.restorableEntry {
            let name = (entry.path as NSString).lastPathComponent
            commands.append(QuickCommand(title: model.restoreTitle(for: entry), shortcut: "⌥⌘Z", systemImage: "arrow.uturn.backward",
                                         isEnabled: model.activity == nil) {
                Task { await model.discard([entry]) }
            })
            if entry.hasUnstagedChanges || entry.isUntracked {
                commands.append(QuickCommand(title: String(localized: "Stage “\(name)”"), shortcut: nil, systemImage: "plus.circle") {
                    Task { await model.stage([entry]) }
                })
            }
            if entry.hasStagedChanges {
                commands.append(QuickCommand(title: String(localized: "Unstage “\(name)”"), shortcut: nil, systemImage: "minus.circle") {
                    Task { await model.unstage([entry]) }
                })
            }
        }
        if let commit = model.selectedCommit {
            let current = model.currentBranchTitle
            let canStart = model.canStartOperation
            let isHead = commit.id == model.status.headID
            // Already on this branch: cherry-picking it again would make an empty commit.
            let isOnCurrentBranch = model.status.branch.map { model.detailBranches.contains($0) } ?? false
            if model.hasHead, !isHead {
                commands.append(QuickCommand(title: String(localized: "Reset “\(current)” to \(commit.shortID)…"), shortcut: nil,
                                             systemImage: "arrow.triangle.branch", isEnabled: canStart) {
                    ChoiceMenu.show([
                        ChoiceMenu.Choice(title: String(localized: "Soft — Keep Changes Staged")) { model.requestReset(to: commit, mode: .soft) },
                        ChoiceMenu.Choice(title: String(localized: "Mixed — Keep Changes Unstaged")) { model.requestReset(to: commit, mode: .mixed) },
                        ChoiceMenu.Choice(title: String(localized: "Hard — Put Changes Aside…")) { model.requestReset(to: commit, mode: .hard) },
                    ])
                })
            }
            commands += [
                QuickCommand(title: String(localized: "Check Out \(commit.shortID)"), shortcut: nil, systemImage: "arrow.right.circle",
                             isEnabled: canStart && !isHead) { Task { await model.checkOut(commit: commit) } },
                QuickCommand(title: String(localized: "Cherry-Pick \(commit.shortID) onto “\(current)”"), shortcut: nil, systemImage: "arrow.turn.down.right",
                             isEnabled: canStart && !commit.isMerge && !isHead && !isOnCurrentBranch) { Task { await model.cherryPick(commit) } },
                QuickCommand(title: String(localized: "Revert \(commit.shortID)"), shortcut: nil, systemImage: "arrow.uturn.backward",
                             isEnabled: canStart) { Task { await model.revert(commit) } },
                QuickCommand(title: String(localized: "Create Branch at \(commit.shortID)…"), shortcut: nil, systemImage: "arrow.triangle.branch") {
                    model.sheet = .newBranch(startPoint: commit.id, label: commit.shortID)
                },
                QuickCommand(title: String(localized: "Create Tag at \(commit.shortID)…"), shortcut: nil, systemImage: "tag") {
                    model.sheet = .newTag(commitID: commit.id, label: commit.shortID)
                },
                QuickCommand(title: String(localized: "Copy Commit SHA"), shortcut: "⇧⌘C", systemImage: "doc.on.doc") { Pasteboard.copy(commit.id) },
            ]
        }
        return commands
    }
}

private struct QuickSwitcherRow: View {
    let item: QuickSwitcherItem
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(isHighlighted ? Color.white : Color.accentColor)
                .frame(width: 18)
            Text(QuickSwitcherResults.highlighted(item.title, offsets: item.offsets))
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Text(item.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Color.secondary)
                .lineLimit(1)
        }
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(isHighlighted ? Color.accentColor : .clear))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }
}

/// Matching and ranking, kept apart from the view.
enum QuickSwitcherResults {
    static let perSection = 5

    static func sections(
        for rawQuery: String,
        model: RepositoryModel,
        files: [String],
        lastChanged: [String: Date],
        recents: [RecentRepository],
        actions: [QuickCommand]
    ) -> [QuickSwitcherSection] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        var sections: [QuickSwitcherSection] = []

        // Branches (and tags): the current branch and recent ones when there's no query.
        let refItems: [QuickSwitcherItem]
        if query.isEmpty {
            let recent = model.recentBranches.compactMap { model.refs.localBranch(named: $0) }
            refItems = recent.prefix(perSection).map { refItem($0, match: .everything) }
        } else {
            refItems = model.refs.refs.filter { !$0.isSymbolic }
                .compactMap { ref in FuzzyMatch.match(query, in: ref.name).map { (ref, $0) } }
                .sorted { $0.1.score > $1.1.score }
                .prefix(perSection)
                .map { refItem($0.0, match: $0.1) }
        }
        if !refItems.isEmpty { sections.append(QuickSwitcherSection(id: "branches", title: "Branches", items: refItems)) }

        if !query.isEmpty {
            // Commits: the loaded history, newest first; subjects contain the text, or the SHA starts with it.
            let lowercased = query.lowercased()
            var commitItems: [QuickSwitcherItem] = []
            for commit in model.commits {
                let bySHA = commit.id.hasPrefix(lowercased) && lowercased.count >= 4
                guard bySHA || commit.subject.localizedCaseInsensitiveContains(query) else { continue }
                let match = bySHA ? .everything : (FuzzyMatch.match(query, in: commit.subject) ?? .everything)
                commitItems.append(QuickSwitcherItem(
                    id: "commit-\(commit.id)",
                    kind: .commit(commit),
                    title: commit.subject,
                    offsets: match.offsets,
                    subtitle: "\(commit.shortID) · \(commit.author.name) · \(Formatters.historyDate(commit.author.date))",
                    systemImage: "smallcircle.filled.circle"
                ))
                if commitItems.count == perSection { break }
            }
            if !commitItems.isEmpty { sections.append(QuickSwitcherSection(id: "commits", title: "Commits", items: commitItems)) }

            // Files: tracked paths plus changed ones.
            let changed = Set(model.status.entries.map(\.path))
            let paths = Set(files).union(changed)
            var fileMatches: [(path: String, match: FuzzyMatch)] = []
            for path in paths {
                if let match = FuzzyMatch.match(query, in: path) { fileMatches.append((path, match)) }
            }
            fileMatches.sort { lhs, rhs in
                lhs.match.score == rhs.match.score ? lhs.path < rhs.path : lhs.match.score > rhs.match.score
            }
            let fileItems: [QuickSwitcherItem] = fileMatches.prefix(perSection).map { path, match in
                QuickSwitcherItem(id: "file-\(path)", kind: .file(path), title: path, offsets: match.offsets,
                                  subtitle: fileSubtitle(path, changed: changed, lastChanged: lastChanged), systemImage: "doc")
            }
            if !fileItems.isEmpty { sections.append(QuickSwitcherSection(id: "files", title: "Files", items: fileItems)) }
        }

        // Commands.
        let commandItems = actions.enumerated()
            .filter(\.element.isEnabled)
            .compactMap { index, command -> (Int, QuickCommand, FuzzyMatch)? in
                guard let match = FuzzyMatch.match(query, in: command.title) else { return nil }
                return (index, command, match)
            }
            .sorted { query.isEmpty || $0.2.score == $1.2.score ? $0.0 < $1.0 : $0.2.score > $1.2.score }
            .prefix(query.isEmpty ? 4 : perSection)
            .map { index, command, match in
                QuickSwitcherItem(
                    id: "command-\(index)-\(command.title)", kind: .command(command), title: command.title,
                    offsets: match.offsets, subtitle: command.shortcut ?? "", systemImage: command.systemImage
                )
            }
        if !commandItems.isEmpty { sections.append(QuickSwitcherSection(id: "commands", title: "Commands", items: Array(commandItems))) }

        // Other repositories.
        let current = model.repository?.root.plainPath
        let repositoryItems = recents.filter { $0.path != current }
            .compactMap { recent in FuzzyMatch.match(query, in: recent.name).map { (recent, $0) } }
            .enumerated()
            .sorted { query.isEmpty || $0.element.1.score == $1.element.1.score ? $0.offset < $1.offset : $0.element.1.score > $1.element.1.score }
            .prefix(3)
            .map { _, pair in
                let (recent, match) = pair
                return QuickSwitcherItem(
                    id: "repository-\(recent.path)", kind: .repository(recent), title: recent.name,
                    offsets: match.offsets, subtitle: recent.displayPath, systemImage: "folder"
                )
            }
        if !repositoryItems.isEmpty { sections.append(QuickSwitcherSection(id: "repositories", title: "Repositories", items: Array(repositoryItems))) }
        return sections
    }

    /// "uncommitted changes", "last changed Sep 26", or nothing until the date has loaded.
    private static func fileSubtitle(_ path: String, changed: Set<String>, lastChanged: [String: Date]) -> String {
        if changed.contains(path) { return String(localized: "uncommitted changes") }
        if let date = lastChanged[path] { return String(localized: "last changed \(Formatters.historyDate(date))") }
        return ""
    }

    private static func refItem(_ ref: Ref, match: FuzzyMatch) -> QuickSwitcherItem {
        let subtitle: String
        let image: String
        switch ref.kind {
        case .localBranch:
            subtitle = ref.isHead ? String(localized: "current branch") : String(localized: "branch")
            image = ref.isHead ? "checkmark" : "arrow.triangle.branch"
        case .remoteBranch:
            subtitle = String(localized: "remote")
            image = "cloud"
        case .tag:
            subtitle = String(localized: "tag")
            image = "tag"
        }
        return QuickSwitcherItem(id: ref.fullName, kind: .ref(ref), title: ref.name, offsets: match.offsets, subtitle: subtitle, systemImage: image)
    }

    /// The title with the matched characters in bold.
    static func highlighted(_ text: String, offsets: [Int]) -> AttributedString {
        guard !offsets.isEmpty else { return AttributedString(text) }
        let marked = Set(offsets)
        var result = AttributedString()
        for (offset, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            if marked.contains(offset) {
                piece.font = .system(size: 13, weight: .bold)
            }
            result += piece
        }
        return result
    }
}

/// A pop-up menu for a quick-switcher command that needs one more choice ("Reset … to c92aa17…").
enum ChoiceMenu {
    struct Choice {
        var title: String
        var action: @MainActor () -> Void
    }

    static func show(_ choices: [Choice]) {
        // After the switcher is gone, so the menu doesn't open over it.
        DispatchQueue.main.async {
            guard let view = NSApp.keyWindow?.contentView else { return }
            let target = Target(actions: choices.map(\.action))
            let menu = NSMenu()
            for (index, choice) in choices.enumerated() {
                let item = NSMenuItem(title: choice.title, action: #selector(Target.run(_:)), keyEquivalent: "")
                item.target = target
                item.tag = index
                menu.addItem(item)
            }
            let point = NSPoint(x: view.bounds.midX - 150, y: view.isFlipped ? 90 : view.bounds.maxY - 90)
            withExtendedLifetime(target) {
                _ = menu.popUp(positioning: menu.items.first, at: point, in: view)
            }
        }
    }

    private final class Target: NSObject {
        let actions: [@MainActor () -> Void]

        init(actions: [@MainActor () -> Void]) {
            self.actions = actions
        }

        @objc func run(_ sender: NSMenuItem) {
            actions[sender.tag]()
        }
    }
}

extension EventModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        self = modifiers
    }
}
