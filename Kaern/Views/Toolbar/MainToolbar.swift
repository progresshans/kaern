import AppKit
import KaernKit
import SwiftUI

/// The compact toolbar (WindowBase, icon-only mode): 44 pt, icon buttons grouped in pills,
/// text only where it's information (the branch name, push/pull counts).
///
/// Sidebar · Branch · Undo Redo · Fetch Pull ▾ Push · New Branch Stash Pop — Review Focus ·
/// Search Details.
struct MainToolbar: View {
    let window: WindowModel
    let repository: RepositoryModel
    /// Sidebar and Toolbar switching: the toolbar is the title bar (room for the traffic lights).
    var inTitleBar = false

    @AppStorage("KaernPullStrategy", store: .kaern) private var pullStrategy = PullChoice.fastForwardIfPossible
    /// Icon Only or Icon and Text (right-click the toolbar).
    @AppStorage(SettingsKey.toolbarStyle, store: .kaern) private var style = ToolbarStyle.iconOnly
    @Environment(\.windowTier) private var tier
    @Environment(\.toolbarFoldsMake) private var narrowEnoughToFold
    @Environment(\.repositorySwitching) private var switching

    /// The traffic lights' room when the toolbar is the title bar (`.titlebar .lights`).
    static let lightsInset: CGFloat = 74

    var body: some View {
        let ready = repository.isReady
        // While a merge, rebase or stopped stash waits, Pull, Push, Stash and the like are locked.
        let busy = repository.activity != nil || repository.isMidOperation
        // ScreenNarrow: with names, New Branch · Stash · Pop go into » under 1,000 pt.
        let foldsMake = style == .iconAndText && narrowEnoughToFold
        // Under 860 pt the groups sit closer (ScreenNarrow's 760 still fits every button).
        HStack(spacing: tier >= .compact ? 2 : 6) {
            if inTitleBar {
                Color.clear.frame(width: Self.lightsInset - z(10), height: 1)
            }
            ToolbarCap {
                ToolbarButton(icon: Icons.sidebar, iconSize: 17, name: "Sidebar", shortcut: "⌃⌘S", tip: .leading,
                              accessibilityLabel: "Show or hide the sidebar") {
                    window.toggleSidebar()
                }
            }
            ToolbarGroupSeparator()
            ToolbarCap {
                if switching == .toolbar {
                    RepositoryButton(window: window, repository: repository)
                    if style != .iconAndText {
                        K.sepStrong.frame(width: 1).padding(.vertical, z(7)).padding(.horizontal, 1)
                    }
                }
                BranchButton(repository: repository, maxWidth: tier >= .compact ? 128 : tier >= .panelOverlay ? 160 : tier >= .sidebarRail ? 200 : 252,
                             onNewBranch: askNewBranch, onOtherBranches: { window.showsQuickOpen = true })
            }
            ToolbarGroupSeparator()
            ToolbarCap {
                // Their tooltips say what they'd take back ("Undo Checkout develop").
                ToolbarButton(icon: Icons.undo, name: repository.undoTitle, label: "Undo", shortcut: "⌘Z", accessibilityLabel: repository.undoTitle) {
                    repository.from("Toolbar") { repository.undo() }
                }
                .disabled(!repository.canUndo)
                ToolbarButton(icon: Icons.redo, name: repository.redoTitle, label: "Redo", shortcut: "⇧⌘Z", accessibilityLabel: repository.redoTitle) {
                    repository.from("Toolbar") { repository.redo() }
                }
                .disabled(!repository.canRedo)
            }
            ToolbarGroupSeparator()
            ToolbarCap {
                ToolbarButton(icon: Icons.fetch, name: "Fetch", shortcut: "⌥⌘F") { repository.from("Toolbar") { repository.fetch() } }
                    .disabled(!ready || busy || repository.remotes.isEmpty)
                ToolbarButton(icon: Icons.pull, name: "Pull", shortcut: "⌥⌘↓", badge: repository.status.behind) {
                    repository.from("Toolbar") { repository.pull(repository.pullChoice.strategy) }
                }
                .disabled(!ready || busy || repository.status.upstream == nil)
                PullMenu(repository: repository, choice: $pullStrategy)
                    .disabled(!ready || busy)
                ToolbarButton(icon: Icons.push, name: "Push", shortcut: "⌥⌘↑",
                              badge: repository.status.upstream == nil ? repository.unpublishedCount : repository.status.ahead) {
                    repository.from("Toolbar") { repository.push() }
                }
                .disabled(!ready || busy || repository.remotes.isEmpty || repository.status.branch == nil)
                .popover(isPresented: Binding(get: { repository.publishDraft != nil }, set: { if !$0 { repository.publishDraft = nil } }),
                         arrowEdge: .bottom) {
                    if let draft = repository.publishDraft {
                        PublishPopover(repository: repository, draft: draft)
                    }
                }
            }
            if !foldsMake {
                ToolbarGroupSeparator()
                ToolbarCap {
                    ToolbarButton(icon: Icons.newBranch, name: "New Branch", shortcut: "⇧⌘N") { askNewBranch() }
                        .disabled(!ready || busy)
                    ToolbarButton(icon: Icons.stash(1.35), name: "Stash", shortcut: "⌥⌘S") { repository.from("Toolbar") { repository.stash() } }
                        .disabled(!ready || busy || repository.status.isClean)
                    ToolbarButton(icon: Icons.pop, name: "Pop Stash", label: "Pop", shortcut: "⌥⇧⌘S") { repository.from("Toolbar") { repository.popStash() } }
                        .disabled(!ready || busy || repository.stashes.isEmpty)
                }
            }
            Spacer(minLength: z(6))
            ToolbarCap {
                ToolbarButton(icon: Icons.review, name: "Review", shortcut: "⌥⌘R", isOn: repository.review != nil) {
                    repository.toggleReview()
                }
                .disabled(!ready || !repository.canReview)
                ToolbarButton(icon: Icons.focus, name: "Focus", shortcut: "⌥⌘G", isOn: window.isFocused) {
                    window.toggleFocus()
                    repository.review = nil
                }
                .disabled(!ready)
            }
            ToolbarGroupSeparator()
            ToolbarCap {
                ToolbarButton(icon: Icons.search(1.3), name: "Search", shortcut: "⌘F", tip: .trailing, isOn: repository.search.isOpen) {
                    if repository.search.isOpen { repository.closeSearch() } else { repository.openSearch() }
                }
                .disabled(!ready)
                ToolbarButton(icon: Icons.details, iconSize: 17, name: "Details", shortcut: "⌥⌘I", tip: .trailing,
                              isOn: false, accessibilityLabel: "Show or hide the details panel") {
                    // A narrow window opens the panel over the graph instead.
                    if tier >= .panelOverlay, !window.isFocused { window.overlayPanelOpen.toggle() } else { window.toggleDetails() }
                }
            }
            if foldsMake {
                ToolbarGroupSeparator()
                MoreMenu(repository: repository, busy: busy, onNewBranch: askNewBranch)
            }
        }
        .environment(\.toolbarShowsText, style == .iconAndText)
        .padding(.horizontal, style == .iconAndText ? z(8) : z(10))
        .frame(height: inTitleBar ? style.titleBarHeight : style.height)
        .frame(maxWidth: .infinity)
        .background {
            ZStack(alignment: .bottom) {
                K.win
                K.sep.frame(height: 1)
            }
            // The bar is window chrome: its empty space moves the window, like a title bar.
            .windowDragArea()
            // Like any Mac app: right-click the toolbar to show names under the icons.
            .contextMenu {
                Picker("Toolbar", selection: $style) {
                    Text("Icon Only").tag(ToolbarStyle.iconOnly)
                    Text("Icon and Text").tag(ToolbarStyle.iconAndText)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kaernNewBranch)) { note in
            // The window's other tabs keep their toolbars: the one of the tab that shows answers.
            if (note.object as? UUID) == window.id, window.activeTab?.path == repository.path { askNewBranch() }
        }
    }

    private func askNewBranch() {
        repository.from("New Branch") { repository.askCreateBranch(at: nil) }
    }
}

extension Notification.Name {
    /// Asks the toolbar of the window whose id is the object to show New Branch.
    static let kaernNewBranch = Notification.Name("KaernNewBranch")
}

/// How the Pull button pulls (the ▾ menu's choice).
enum PullChoice: String, CaseIterable {
    case fastForwardIfPossible, fastForwardOnly, rebase

    var title: String {
        switch self {
        case .fastForwardIfPossible: "Pull (fast-forward if possible)"
        case .fastForwardOnly: "Pull (fast-forward only)"
        case .rebase: "Pull (rebase)"
        }
    }

    var strategy: GitRepository.PullStrategy {
        switch self {
        case .fastForwardIfPossible: .merge
        case .fastForwardOnly: .fastForwardOnly
        case .rebase: .rebase
        }
    }
}

/// ▾ next to Pull.
private struct PullMenu: View {
    let repository: RepositoryModel
    @Binding var choice: PullChoice
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Menu {
            Button("Fetch All") { repository.fetch() }
                .disabled(repository.remotes.isEmpty)
            Divider()
            ForEach(PullChoice.allCases, id: \.self) { option in
                Toggle(option.title, isOn: Binding(get: { choice == option }, set: { _ in
                    choice = option
                    repository.pull(option.strategy)
                }))
                .disabled(repository.status.upstream == nil)
            }
        } label: {
            Icon(Icons.chevronDown, size: 9)
                .foregroundStyle(K.label2)
                .frame(width: z(14))
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: z(6), style: .continuous).fill(hovering && isEnabled ? K.hover : .clear))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.35)
        .toolbarTooltip(name: "Pull Options", shortcut: nil, hovering: $hovering)
        .accessibilityLabel("Pull options")
    }
}

/// » (ScreenNarrow, Icon and Text under 1,000 pt): New Branch, Stash and Pop in a menu.
private struct MoreMenu: View {
    let repository: RepositoryModel
    let busy: Bool
    let onNewBranch: () -> Void
    @State private var hovering = false

    var body: some View {
        let ready = repository.isReady
        Menu {
            Button("New Branch…") { onNewBranch() }
                .disabled(!ready || busy)
            Button("Stash Changes") { repository.from("Toolbar » menu") { repository.stash() } }
                .disabled(!ready || busy || repository.status.isClean)
            Button("Pop Stash") { repository.from("Toolbar » menu") { repository.popStash() } }
                .disabled(!ready || busy || repository.stashes.isEmpty)
        } label: {
            VStack(spacing: z(4)) {
                Image(systemName: "chevron.right.2").font(.system(size: z(14), weight: .medium))
                Text("More").font(.system(size: z(10))).lineLimit(1).fixedSize()
            }
            .foregroundStyle(K.label)
            .padding(.horizontal, z(6))
            .frame(minWidth: z(46))
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: z(7), style: .continuous).fill(hovering ? K.hover : .clear))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(height: z(46))
        .onHover { hovering = $0 }
        .toolbarTooltip(name: "More", shortcut: nil, placement: .trailing, hovering: $hovering)
        .accessibilityLabel("More: New Branch, Stash, Pop")
    }
}

/// Toolbar switching (WindowRepoToolbar): the repository in front of the branch — its initials,
/// name and ⌄, a count when other repositories need you. Opens the repository list (⌘T).
private struct RepositoryButton: View {
    let window: WindowModel
    let repository: RepositoryModel
    @Environment(AppModel.self) private var app
    @Environment(\.toolbarShowsText) private var showsText
    @AppStorage(SettingsKey.toolbarMarksAttention, store: .kaern) private var marksAttention = true
    @State private var hovering = false

    var body: some View {
        @Bindable var window = window
        let attention = marksAttention ? otherAttention : 0
        Button { window.showsRepositoryPopover.toggle() } label: {
            VStack(spacing: z(3)) {
                HStack(spacing: z(7)) {
                    RepoAvatar(name: repository.name, size: 18, radius: z(5), fontSize: 8.5)
                    Text(repository.name)
                        .font(KFont.weighted(12.5, 0.35))
                        .foregroundStyle(K.label)
                        .lineLimit(1)
                        .frame(maxWidth: z(180), alignment: .leading)
                    Icon(Icons.chevronDown, size: 9).foregroundStyle(K.label2)
                }
                if showsText {
                    Text("Repository").font(.system(size: z(10))).foregroundStyle(K.label2)
                }
            }
            .padding(.horizontal, z(10))
            .frame(maxHeight: showsText ? z(40) : .infinity)
            .background {
                if showsText {
                    Color.clear.controlSurface(radius: z(9))
                } else {
                    RoundedRectangle(cornerRadius: z(7), style: .continuous).fill(hovering || window.showsRepositoryPopover ? K.hover : .clear)
                }
            }
            .overlay(alignment: .topLeading) {
                if attention > 0 {
                    Text("\(attention)")
                        .font(.system(size: z(9.5), weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, z(4))
                        .frame(minWidth: z(14), minHeight: z(14))
                        .background(Capsule().fill(K.badge))
                        .background(Capsule().stroke(K.control, lineWidth: 3))
                        .offset(x: z(16), y: showsText ? -z(2) : 1)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .padding(.trailing, showsText ? z(6) : 0)
        .toolbarTooltip(name: "Switch Repository", shortcut: "⌘T", placement: .leading, hovering: $hovering)
        .popover(isPresented: $window.showsRepositoryPopover, arrowEdge: .bottom) {
            RepositoryPopover(window: window) { window.showsRepositoryPopover = false }
        }
        .accessibilityLabel("Switch repository, current repository \(repository.name)" + (attention > 0 ? ", \(attention) need attention" : ""))
    }

    /// Other open repositories in this window that need you.
    private var otherAttention: Int {
        RepoListItem.items(window, app: app).values.filter { $0.tab.path != repository.path && $0.needsAttention }.count
    }
}

/// The branch capsule: branch glyph, name, ⌃⌄. Opens the branch menu (ScreenSheets' 브랜치 메뉴):
/// recent branches, New Branch…, Merge into…, Rebase onto…, Rename…, Delete.
private struct BranchButton: View {
    let repository: RepositoryModel
    /// Narrow windows give the name less room (ScreenNarrow).
    var maxWidth: CGFloat = 252
    let onNewBranch: () -> Void
    let onOtherBranches: () -> Void
    @State private var hovering = false
    @State private var anchor = MenuAnchor()
    @Environment(\.toolbarShowsText) private var showsText

    var body: some View {
        Button {
            guard let view = anchor.view else { return }
            let menu = ContextMenus.toolbarBranchMenu(repository, onNewBranch: onNewBranch, onOtherBranches: onOtherBranches)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
        } label: {
            VStack(spacing: z(3)) {
                HStack(spacing: z(6)) {
                    Icon(Icons.branchToolbar, size: 15)
                        .foregroundStyle(K.accent)
                    Text(title)
                        .font(.system(size: z(12.5), weight: .semibold))
                        .foregroundStyle(K.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: z(maxWidth), alignment: .leading)
                    Icon(Icons.upDown, size: 9, height: 12)
                        .foregroundStyle(K.label2)
                }
                if showsText {
                    Text("Branch").font(.system(size: z(10))).foregroundStyle(K.label2)
                }
            }
            .padding(.horizontal, z(10))
            .frame(maxHeight: showsText ? z(40) : .infinity)
            .background {
                // `.tb-text .cb.wide`: the branch keeps its pill when names show.
                if showsText {
                    Color.clear.controlSurface(radius: z(9))
                } else {
                    RoundedRectangle(cornerRadius: z(7), style: .continuous).fill(hovering ? K.hover : .clear)
                }
            }
            .contentShape(Rectangle())
            .background(MenuAnchorView(anchor: anchor))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!repository.isReady)
        .toolbarTooltip(name: "Switch Branch", shortcut: "⇧⌘B", hovering: $hovering)
        .accessibilityLabel("Switch branch, current branch \(title)")
        .onReceive(NotificationCenter.default.publisher(for: .kaernShowBranchMenu)) { note in
            guard (note.object as? String) == repository.id, let view = anchor.view else { return }
            ContextMenus.toolbarBranchMenu(repository, onNewBranch: onNewBranch, onOtherBranches: onOtherBranches)
                .popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
        }
    }

    private var title: String {
        if repository.phase == .notRepository { return "No Repository" }
        guard repository.hasContent else { return repository.name }
        switch repository.status.head {
        case .branch(let name), .unborn(let name):
            return name
        case .detached(let id):
            // A rebase detaches HEAD; show the branch being rebased.
            if repository.operation?.kind == .rebase, let branch = repository.operation?.branch { return branch }
            return id.isEmpty ? "No commits" : "Detached at \(id.prefix(7))"
        }
    }
}

extension Notification.Name {
    /// Opens the toolbar's branch menu of the repository whose id is the object (Branch › Switch Branch…).
    static let kaernShowBranchMenu = Notification.Name("KaernShowBranchMenu")
}

/// Holds the AppKit view a menu pops up from.
@MainActor
final class MenuAnchor {
    weak var view: NSView?
}

/// An empty AppKit view that tells its anchor where it is.
struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
