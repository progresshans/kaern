import AppKit
import KaernKit
import SwiftUI

/// The bar across the top of a repository window: repository pop-up · branch pop-up ·
/// Fetch/Pull/Push · Stash · search. It's a band of its own (the columns start below it), and
/// the four git actions are taller than system toolbar items so their titles fit under the
/// icons, as in the design. The sidebar and inspector toggles live at the ends of the status bar.
struct RepositoryTitleBar: View {
    let model: RepositoryModel
    let onSwitchRepository: (URL) -> Void
    @AppStorage(PreferenceKey.repositorySwitcher) private var switcher = RepositorySwitcher.toolbar

    /// The traffic lights sit centered in the system's 52pt toolbar; the bar is about as tall.
    static let height: CGFloat = 54

    private var isBusy: Bool { model.activity != nil }

    var body: some View {
        HStack(spacing: 10) {
            if switcher == .toolbar {
                RepositoryButton(model: model, onSwitchRepository: onSwitchRepository)
                    .titleBarCapsule()
            }
            BranchMenu(model: model)
                .titleBarCapsule()
                .layoutPriority(1)

            HStack(spacing: 2) {
                actionButton("Fetch", systemImage: "arrow.clockwise", busy: model.activity == .fetching,
                             help: "Fetch from all remotes (⇧⌘F)") { Task { await model.fetch() } }
                    .disabled(isBusy || model.remotes.isEmpty)
                actionButton("Pull", systemImage: "arrow.down.to.line", busy: model.activity == .pulling, badge: model.status.behind,
                             help: model.status.upstream.map { "Pull from \($0) — \(model.pullDescription) (⇧⌘L). Right-click for the other ways." } ?? "This branch has no upstream") { Task { await model.pull() } }
                    .disabled(isBusy || model.operation != nil || model.status.upstream == nil)
                    .contextMenu { PullMenuItems(model: model) }
                actionButton("Push", systemImage: "arrow.up.to.line", busy: model.activity == .pushing, badge: model.status.ahead,
                             help: model.status.upstream == nil ? "Publish this branch (⇧⌘P)" : "Push to \(model.status.upstream ?? "") (⇧⌘P)") {
                    Task { await model.push() }
                }
                .disabled(isBusy || model.operation != nil || model.status.branch == nil || !model.hasHead || model.remotes.isEmpty)
                .contextMenu {
                    Button("Force Push (with Lease)…") {
                        if let branch = model.status.branch { model.confirmation = .forcePush(branch: branch) }
                    }
                    .disabled(model.status.upstream == nil || !model.canStartOperation)
                }
            }
            .padding(.horizontal, 4)
            .titleBarGroup()

            if model.isToolbarCompact {
                // Narrow window: Stash is the first to go, into a » menu.
                Menu {
                    Button("Stash Changes…") { model.sheet = .stash }
                        .disabled(isBusy || model.operation != nil || model.status.isClean)
                } label: {
                    Image(systemName: "chevron.right.2")
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 36, height: 36)
                .titleBarCircle()
                .help("More")
                .accessibilityLabel("More Toolbar Items")
            } else {
                actionButton("Stash", systemImage: "tray", busy: model.activity == .stashing, help: "Stash Changes… (⌥⌘S)") {
                    model.sheet = .stash
                }
                .disabled(isBusy || model.operation != nil || model.status.isClean)
                .padding(.horizontal, 4)
                .titleBarGroup()
            }

            Spacer(minLength: 8)

            CommitSearchItem(model: model)
        }
        .padding(.leading, 84)   // the traffic lights
        .padding(.trailing, 14)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background {
            // Drag the window by the bar's empty space; double-click zooms, like a title bar.
            Rectangle()
                .fill(Color(Palette.titleBar))
                .gesture(WindowDragGesture())
                .onTapGesture(count: 2) { NSApp.keyWindow?.performZoom(nil) }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
    }

    private func actionButton(_ title: LocalizedStringKey, systemImage: String, busy: Bool, badge: Int = 0,
                              help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                }
            }
        }
        .buttonStyle(TitleBarActionButtonStyle())
        .labelStyle(ToolbarActionLabelStyle(badge: badge))
        .help(help)
    }
}

/// A plain button that highlights on hover and darkens while pressed, inside a capsule group.
struct TitleBarActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.6))
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (isHovered && isEnabled ? 0.06 : 0)))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onHover { isHovered = $0 }
    }
}

extension View {
    /// A pop-up button in the bar: 36pt capsule.
    func titleBarCapsule() -> some View {
        buttonStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .modifier(TitleBarSurface(shape: Capsule()))
    }

    /// Fetch/Pull/Push and Stash: a taller rounded group.
    func titleBarGroup() -> some View {
        frame(height: ToolbarMetrics.actionHeight + 4)
            .modifier(TitleBarSurface(shape: RoundedRectangle(cornerRadius: 14)))
    }

    func titleBarCircle() -> some View {
        modifier(TitleBarSurface(shape: Circle()))
    }
}

/// The white surface with a hairline border and a soft shadow that controls sit on.
struct TitleBarSurface<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content
            .background(shape.fill(Color(Palette.titleBarControl)))
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.06), radius: 1.5, y: 0.5)
    }
}

/// Keeps an empty native unified toolbar so the traffic lights sit centered in the bar, and
/// lets the bar show through the transparent title bar.
struct TitleBarConfigurator: NSViewRepresentable {
    static let toolbarID = NSToolbar.Identifier("KaernTitleBar")

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        if window.toolbar?.identifier != Self.toolbarID {
            let toolbar = NSToolbar(identifier: Self.toolbarID)
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
        }
        window.toolbarStyle = .unified
    }
}

/// Fetch, Pull, Push and Stash: the icon with a small title under it (the "Stacked" title
/// button in the design), and the count (to pull, to push) on the icon's corner.
struct ToolbarActionLabelStyle: LabelStyle {
    var badge: Int = 0

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 2) {
            configuration.icon
                .font(.system(size: 15))
                .frame(width: 22, height: 18)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 9.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3.5)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(Capsule().fill(Color(Palette.badge)))
                            .offset(x: 10, y: -5)
                            .accessibilityLabel("\(badge)")
                    }
                }
            configuration.title
                .font(.system(size: 10.5))
        }
        .frame(minWidth: 40)
        .padding(.horizontal, 4)
        .frame(height: ToolbarMetrics.actionHeight)
    }
}

enum ToolbarMetrics {
    /// The stacked buttons are taller than the system's 36pt capsule so the title has room.
    static let actionHeight: CGFloat = 40
}

// MARK: - Repository pop-up

struct RepositoryButton: View {
    let model: RepositoryModel
    let onSwitchRepository: (URL) -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(model.displayName)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .help("Switch Repository")
        .accessibilityLabel("Repository")
        .accessibilityValue(model.displayName)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            RepositoryPopover(currentURL: model.repository?.root ?? model.url) { url, inNewWindow in
                isPresented = false
                if inNewWindow {
                    AppModel.shared.open(url)
                } else {
                    onSwitchRepository(url)
                }
            }
        }
    }
}

/// Recent repositories with a search field. Return switches this window, ⌘Return (or ⌘-click)
/// opens a new window.
struct RepositoryPopover: View {
    let currentURL: URL
    let onChoose: (URL, Bool) -> Void

    @Environment(AppModel.self) private var appModel
    @State private var query = ""
    @State private var highlighted: String?
    @State private var summaries: [String: RepositorySummary] = [:]
    @FocusState private var isSearchFocused: Bool

    private var items: [RecentRepository] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return appModel.recents }
        return appModel.recents.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) || $0.path.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Repositories", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.return, phases: .down) { press in
                        guard let item = currentItem else { return .ignored }
                        onChoose(item.url, press.modifiers.contains(.command))
                        return .handled
                    }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
            .padding(10)

            Text("Recent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(items) { item in
                        RepositoryPopoverRow(
                            item: item,
                            summary: summaries[item.path],
                            isCurrent: item.path == currentURL.plainPath,
                            isHighlighted: item.path == (highlighted ?? currentItem?.path)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onChoose(item.url, NSEvent.modifierFlags.contains(.command))
                        }
                        .onHover { if $0 { highlighted = item.path } }
                    }
                    if items.isEmpty {
                        Text(query.isEmpty ? "No recent repositories" : "No matches")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                MenuRowButton(title: "Open Repository…", shortcut: "⌘O") {
                    for url in appModel.chooseRepositories() { appModel.open(url) }
                }
                MenuRowButton(title: "Clone Repository…", shortcut: nil) {
                    appModel.showWelcome()
                    WelcomeActions.shared.request(.clone)
                }
            }
            .padding(6)

            Text("⌘Return or ⌘-click opens in a new window")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
        .frame(width: 320)
        .onAppear { isSearchFocused = true }
        .task { await loadSummaries() }
    }

    private var currentItem: RecentRepository? {
        if let highlighted, let item = items.first(where: { $0.path == highlighted }) { return item }
        return items.first { $0.path != currentURL.plainPath } ?? items.first
    }

    private func move(_ offset: Int) {
        guard !items.isEmpty else { return }
        let index = currentItem.flatMap { item in items.firstIndex(of: item) } ?? 0
        let next = min(max(index + offset, 0), items.count - 1)
        highlighted = items[next].path
    }

    private func loadSummaries() async {
        let runner = appModel.makeRunner()
        let targets = appModel.recents.prefix(12).map { ($0.path, $0.url) }
        await withTaskGroup(of: (String, WorkingTreeStatus?).self) { group in
            for (path, url) in targets {
                group.addTask {
                    guard let repository = try? await GitRepository.open(url, runner: runner) else { return (path, nil) }
                    return (path, try? await repository.status())
                }
            }
            for await (path, status) in group {
                if let status {
                    summaries[path] = RepositorySummary(status: status)
                }
            }
        }
    }
}

struct RepositorySummary {
    var branch: String
    var changes: Int
    var ahead: Int
    var behind: Int

    init(status: WorkingTreeStatus) {
        switch status.head {
        case .branch(let name), .unborn(let name): branch = name
        case .detached(let id): branch = "HEAD (\(id.prefix(7)))"
        }
        changes = status.entries.count
        ahead = status.ahead
        behind = status.behind
    }

    var detail: String {
        var parts: [String] = []
        if changes > 0 {
            parts.append(changes == 1 ? String(localized: "1 change") : String(localized: "\(changes) changes"))
        }
        var sync = ""
        if ahead > 0 { sync += "↑\(ahead)" }
        if behind > 0 { sync += (sync.isEmpty ? "" : " ") + "↓\(behind)" }
        if !sync.isEmpty { parts.append(sync) }
        return parts.joined(separator: " · ")
    }
}

private struct RepositoryPopoverRow: View {
    let item: RecentRepository
    let summary: RepositorySummary?
    let isCurrent: Bool
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .opacity(isCurrent ? 1 : 0)
                .frame(width: 12)
            Image(systemName: "folder")
                .foregroundStyle(isHighlighted ? Color.white : Color.accentColor)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(summary?.branch ?? item.displayPath)
                    .font(.system(size: 11))
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let detail = summary?.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isHighlighted ? Color.accentColor : .clear)
        )
    }
}

/// A plain full-width row that looks like a menu item (used in the pop-ups' lower sections).
/// Dimmed and without the hover highlight while disabled.
struct MenuRowButton: View {
    let title: LocalizedStringKey
    let shortcut: String?
    /// An SF Symbol at the trailing edge (a chevron for a row that opens a list).
    var accessory: String?
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let highlighted = isHovered && isEnabled
        Button(action: action) {
            HStack {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(highlighted ? Color.white.opacity(0.8) : Color.secondary)
                }
                if let accessory {
                    Image(systemName: accessory)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(highlighted ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            .foregroundStyle(highlighted ? Color.white : (isEnabled ? Color.primary : Color.secondary.opacity(0.6)))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(highlighted ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Branch pop-up

/// The branch pop-up button. It opens a popover built like the repository pop-up next to it:
/// a search field, the recent branches, then what you can do with the current branch.
struct BranchMenu: View {
    let model: RepositoryModel
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.isDetached ? "exclamationmark.triangle" : "arrow.triangle.branch")
                Text(model.isToolbarCompact ? BranchName.shortened(model.headTitle) : model.headTitle)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: model.isToolbarCompact ? 150 : 240, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .help("Switch Branch")
        .accessibilityLabel("Branch")
        .accessibilityValue(model.headTitle)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            BranchPopover(model: model) { isPresented = false }
        }
    }
}

/// Recent branches (the current one checked) or, while typing, every branch that matches, local
/// first. Return switches to the highlighted one. Below: worktrees, then Merge and Rebase, which
/// spell out the direction with names.
struct BranchPopover: View {
    let model: RepositoryModel
    let close: () -> Void

    @State private var query = ""
    @State private var highlighted: String?
    @State private var showsAllWorktrees = false
    @FocusState private var isSearchFocused: Bool

    private var current: String { model.currentBranchTitle }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// The current branch, then the most recently checked-out ones (up to five in total).
    private var recentBranches: [Ref] {
        var names = model.recentBranches
        if let current = model.status.branch {
            names.removeAll { $0 == current }
            names.insert(current, at: 0)
        }
        var refs = names.compactMap { model.refs.localBranch(named: $0) }
        if refs.count < 3 {
            // A fresh clone has no reflog yet: fill up with the well-known branches.
            for ref in model.refs.localBranches where !refs.contains(ref) && ["main", "master", "develop"].contains(ref.name) {
                refs.append(ref)
            }
        }
        return Array(refs.prefix(5))
    }

    /// Local branches whose name matches, then remote branches nothing local is named after yet.
    private var items: [Ref] {
        guard !trimmedQuery.isEmpty else { return recentBranches }
        let locals = model.refs.localBranches.filter { $0.name.localizedCaseInsensitiveContains(trimmedQuery) }
        let localNames = Set(model.refs.localBranches.map(\.name))
        let remotes = model.refs.remoteBranches.filter {
            !localNames.contains($0.branchName) && $0.name.localizedCaseInsensitiveContains(trimmedQuery)
        }
        return Array((locals + remotes).prefix(40))
    }

    private var otherWorktrees: [Worktree] {
        model.worktrees.filter { URL(filePath: $0.path).plainPath != model.repository?.root.plainPath && !$0.isBare }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Branches", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.return) {
                        guard let ref = currentItem else { return .ignored }
                        choose(ref)
                        return .handled
                    }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
            .padding(10)

            Text(trimmedQuery.isEmpty ? "Recent Branches" : "Branches")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(items) { ref in
                        BranchPopoverRow(
                            ref: ref,
                            worktree: ref.kind == .localBranch ? model.worktree(using: ref.name).map { model.title(of: $0) } : nil,
                            isHighlighted: ref.id == currentItem?.id
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { choose(ref) }
                        .onHover { if $0 { highlighted = ref.id } }
                    }
                    if items.isEmpty {
                        Text(trimmedQuery.isEmpty ? "No branches yet" : "No matching branches")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                MenuRowButton(title: "New Worktree…", shortcut: nil) { run { model.sheet = .newWorktree } }
                    .disabled(!model.hasHead || model.activity != nil)
                worktreeRows
            }
            .padding(6)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                MenuRowButton(title: "New Branch…", shortcut: "⇧⌘N") {
                    run { model.sheet = .newBranch(startPoint: nil, label: model.headTitle) }
                }
                .disabled(!model.hasHead)
                MenuRowButton(title: "Merge into “\(current)”…", shortcut: nil) { run { model.sheet = .chooseBranch(.merge) } }
                    .disabled(!model.hasHead || !model.canStartOperation)
                MenuRowButton(title: "Rebase “\(current)” onto…", shortcut: nil) { run { model.sheet = .chooseBranch(.rebase) } }
                    .disabled(!model.hasHead || !model.canStartOperation)
            }
            .padding(6)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                MenuRowButton(title: "Rename “\(current)”…", shortcut: nil) {
                    run { if let ref = model.refs.headBranch { model.sheet = .renameBranch(ref) } }
                }
                .disabled(model.refs.headBranch == nil || model.activity != nil)
                // The branch you're on can't be deleted; the row says so by being there, dimmed.
                MenuRowButton(title: "Delete “\(current)”", shortcut: nil) {}
                    .disabled(true)
                    .help("Switch to another branch first")
            }
            .padding(6)
        }
        .frame(width: 340)
        .onAppear { isSearchFocused = true }
        .onChange(of: query) { highlighted = nil }
    }

    /// Up to three worktrees as rows; more fold into one row that opens the list here.
    @ViewBuilder
    private var worktreeRows: some View {
        let others = otherWorktrees
        if others.count <= 3 {
            ForEach(others) { worktree in
                MenuRowButton(title: "Open \(model.title(of: worktree)) in New Window", shortcut: nil) { open(worktree) }
            }
        } else {
            MenuRowButton(title: "Open Worktree in New Window", shortcut: nil, accessory: showsAllWorktrees ? "chevron.up" : "chevron.down") {
                withAnimation(.snappy(duration: 0.2)) { showsAllWorktrees.toggle() }
            }
            if showsAllWorktrees {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(others) { worktree in
                            MenuRowButton(title: "\(model.title(of: worktree))", shortcut: worktree.branch) { open(worktree) }
                                .padding(.leading, 12)
                        }
                    }
                }
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The highlighted row, or the first one that isn't the current branch.
    private var currentItem: Ref? {
        if let highlighted, let ref = items.first(where: { $0.id == highlighted }) { return ref }
        return items.first { !$0.isHead } ?? items.first
    }

    private func move(_ offset: Int) {
        guard !items.isEmpty else { return }
        let index = currentItem.flatMap { ref in items.firstIndex(of: ref) } ?? 0
        highlighted = items[min(max(index + offset, 0), items.count - 1)].id
    }

    /// Switch to it; a branch another worktree has checked out opens that worktree instead.
    private func choose(_ ref: Ref) {
        if ref.kind == .localBranch, let other = model.worktree(using: ref.name) {
            open(other)
            return
        }
        guard !(ref.kind == .localBranch && ref.isHead) else { close(); return }
        guard model.canStartOperation else { NSSound.beep(); return }
        run { model.requestSwitch(to: ref) }
    }

    private func open(_ worktree: Worktree) {
        run { AppModel.shared.openInNewWindow(URL(filePath: worktree.path, directoryHint: .isDirectory)) }
    }

    /// Closes the popover first, so a sheet the action opens isn't fighting it.
    private func run(_ action: @escaping @MainActor () -> Void) {
        close()
        Task { @MainActor in action() }
    }
}

private struct BranchPopoverRow: View {
    let ref: Ref
    /// The worktree that has this branch checked out, when it's not this one.
    let worktree: String?
    let isHighlighted: Bool

    private var isCurrent: Bool { ref.kind == .localBranch && ref.isHead }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .opacity(isCurrent ? 1 : 0)
                .frame(width: 12)
            Image(systemName: ref.kind == .remoteBranch ? "cloud" : "arrow.triangle.branch")
                .foregroundStyle(isHighlighted ? Color.white : (worktree == nil ? Color.accentColor : Color.secondary))
                .frame(width: 16)
            Text(ref.name)
                .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(isHighlighted ? Color.white : (worktree == nil ? Color.primary : Color.secondary))
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(isHighlighted ? Color.accentColor : .clear))
        .help(worktree.map { "Checked out in \($0): opens that worktree" } ?? ref.name)
    }

    /// "in powerlens-hotfix", "↑2 ↓1", or the remote for a branch that's only there.
    private var trailing: String? {
        if let worktree { return String(localized: "in \(worktree)") }
        if ref.kind == .remoteBranch { return ref.remoteName }
        var parts: [String] = []
        if ref.ahead > 0 { parts.append("↑\(ref.ahead)") }
        if ref.behind > 0 { parts.append("↓\(ref.behind)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}


enum BranchName {
    /// "feature/restore-automatic-alpha" → "feature/…alpha": the folder and the last word stay,
    /// which tell branches apart better than a cut in the middle of a word.
    static func shortened(_ name: String, limit: Int = 18) -> String {
        guard name.count > limit else { return name }
        let components = name.split(separator: "/")
        guard components.count > 1, let last = components.last else { return name }
        let word = last.split(separator: "-").last.map(String.init) ?? String(last)
        let short = "\(components[0])/…\(word)"
        return short.count < name.count ? short : name
    }
}

/// Pull once in a particular way (the Pull button's right-click menu, Repository › Pull Using).
/// Settings › Git decides what a plain Pull does.
struct PullMenuItems: View {
    let model: RepositoryModel

    private var canPull: Bool { model.canStartOperation && model.status.upstream != nil }

    var body: some View {
        Button("Pull, Merging") { Task { await model.pull(using: .merge) } }
            .disabled(!canPull)
        Button("Pull, Rebasing") { Task { await model.pull(using: .rebase) } }
            .disabled(!canPull)
        Button("Pull, Fast-Forward Only") { Task { await model.pull(using: .fastForwardOnly) } }
            .disabled(!canPull)
    }
}
