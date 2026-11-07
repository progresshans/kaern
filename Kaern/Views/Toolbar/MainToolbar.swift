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

    @AppStorage("KaernPullStrategy", store: .kaern) private var pullStrategy = PullChoice.fastForwardIfPossible

    var body: some View {
        let ready = repository.isReady
        // While a merge, rebase or stopped stash waits, Pull, Push, Stash and the like are locked.
        let busy = repository.activity != nil || repository.isMidOperation
        HStack(spacing: 6) {
            ToolbarCap {
                ToolbarButton(icon: Icons.sidebar, iconSize: 17, name: "Sidebar", shortcut: "⌃⌘S", tip: .leading,
                              accessibilityLabel: "Show or hide the sidebar") {
                    window.toggleSidebar()
                }
            }
            ToolbarCap {
                BranchButton(repository: repository, onNewBranch: askNewBranch)
            }
            ToolbarCap {
                // Their tooltips say what they'd take back ("Undo Checkout develop").
                ToolbarButton(icon: Icons.undo, name: repository.undoTitle, shortcut: "⌘Z", accessibilityLabel: repository.undoTitle) {
                    repository.from("Toolbar") { repository.undo() }
                }
                .disabled(!repository.canUndo)
                ToolbarButton(icon: Icons.redo, name: repository.redoTitle, shortcut: "⇧⌘Z", accessibilityLabel: repository.redoTitle) {
                    repository.from("Toolbar") { repository.redo() }
                }
                .disabled(!repository.canRedo)
            }
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
            ToolbarCap {
                ToolbarButton(icon: Icons.newBranch, name: "New Branch", shortcut: "⇧⌘N") { askNewBranch() }
                    .disabled(!ready || busy)
                ToolbarButton(icon: Icons.stash(1.35), name: "Stash", shortcut: "⌥⌘S") { repository.from("Toolbar") { repository.stash() } }
                    .disabled(!ready || busy || repository.status.isClean)
                ToolbarButton(icon: Icons.pop, name: "Pop Stash", shortcut: "⌥⇧⌘S") { repository.from("Toolbar") { repository.popStash() } }
                    .disabled(!ready || busy || repository.stashes.isEmpty)
            }
            Spacer(minLength: 6)
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
            ToolbarCap {
                ToolbarButton(icon: Icons.search(1.3), name: "Search", shortcut: "⌘F", tip: .trailing, isOn: repository.search.isOpen) {
                    if repository.search.isOpen { repository.closeSearch() } else { repository.openSearch() }
                }
                .disabled(!ready)
                ToolbarButton(icon: Icons.details, iconSize: 17, name: "Details", shortcut: "⌥⌘I", tip: .trailing,
                              isOn: false, accessibilityLabel: "Show or hide the details panel") {
                    window.toggleDetails()
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: KMetric.toolbar)
        .frame(maxWidth: .infinity)
        .background {
            ZStack(alignment: .bottom) {
                K.win
                K.sep.frame(height: 1)
            }
            // The bar is window chrome: its empty space moves the window, like a title bar.
            .windowDragArea()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kaernNewBranch)) { note in
            if (note.object as? UUID) == window.id { askNewBranch() }
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
                .frame(width: 14)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering && isEnabled ? K.hover : .clear))
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

/// The branch capsule: branch glyph, name, ⌃⌄. Opens the branch menu (ScreenSheets' 브랜치 메뉴):
/// recent branches, New Branch…, Merge into…, Rebase onto…, Rename…, Delete.
private struct BranchButton: View {
    let repository: RepositoryModel
    let onNewBranch: () -> Void
    @State private var hovering = false
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button {
            guard let view = anchor.view else { return }
            let menu = ContextMenus.toolbarBranchMenu(repository, onNewBranch: onNewBranch)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
        } label: {
            HStack(spacing: 6) {
                Icon(Icons.branchToolbar, size: 15)
                    .foregroundStyle(K.accent)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(K.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 252, alignment: .leading)
                Icon(Icons.upDown, size: 9, height: 12)
                    .foregroundStyle(K.label2)
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? K.hover : .clear))
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
            ContextMenus.toolbarBranchMenu(repository, onNewBranch: onNewBranch).popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
        }
    }

    private var title: String {
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
