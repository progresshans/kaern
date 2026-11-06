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

    @AppStorage("KaernPullStrategy") private var pullStrategy = PullChoice.fastForwardIfPossible
    @State private var newBranchName = ""
    @State private var asksNewBranch = false

    var body: some View {
        let ready = repository.isReady
        let busy = repository.activity != nil
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
                ToolbarButton(icon: Icons.undo, name: "Undo", shortcut: "⌘Z") {}
                    .disabled(true)
                ToolbarButton(icon: Icons.redo, name: "Redo", shortcut: "⇧⌘Z") {}
                    .disabled(true)
            }
            ToolbarCap {
                ToolbarButton(icon: Icons.fetch, name: "Fetch", shortcut: "⌥⌘F") { repository.fetch() }
                    .disabled(!ready || busy || repository.remotes.isEmpty)
                ToolbarButton(icon: Icons.pull, name: "Pull", shortcut: "⌥⌘↓", badge: repository.status.behind) {
                    repository.pull(pullStrategy.strategy)
                }
                .disabled(!ready || busy || repository.status.upstream == nil)
                PullMenu(repository: repository, choice: $pullStrategy)
                    .disabled(!ready || busy)
                ToolbarButton(icon: Icons.push, name: "Push", shortcut: "⌥⌘↑", badge: repository.status.ahead) {
                    repository.push()
                }
                .disabled(!ready || busy || repository.remotes.isEmpty || repository.status.branch == nil)
            }
            ToolbarCap {
                ToolbarButton(icon: Icons.newBranch, name: "New Branch", shortcut: "⇧⌘N") { askNewBranch() }
                    .disabled(!ready || busy)
                ToolbarButton(icon: Icons.stash(1.35), name: "Stash", shortcut: "⌥⌘S") { repository.stash() }
                    .disabled(!ready || busy || repository.status.isClean)
                ToolbarButton(icon: Icons.pop, name: "Pop Stash", shortcut: "⌥⇧⌘S") { repository.popStash() }
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
        .alert("New Branch", isPresented: $asksNewBranch) {
            TextField("Branch name", text: $newBranchName)
            Button("Create Branch") {
                let name = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { repository.createBranch(name) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(repository.currentBranch.map { "The branch starts at \($0) and is checked out." } ?? "The branch starts at the current commit and is checked out.")
        }
    }

    private func askNewBranch() {
        newBranchName = ""
        asksNewBranch = true
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

/// The branch capsule: branch glyph, name, ⌃⌄. Opens the list of local branches.
private struct BranchButton: View {
    let repository: RepositoryModel
    let onNewBranch: () -> Void
    @State private var hovering = false

    var body: some View {
        Menu {
            let locals = repository.refs.localBranches.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            ForEach(locals) { ref in
                Toggle(ref.name, isOn: Binding(get: { ref.isHead }, set: { _ in
                    if !ref.isHead { repository.switchBranch(ref.name) }
                }))
            }
            if !locals.isEmpty { Divider() }
            Button("New Branch…", action: onNewBranch)
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
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!repository.isReady)
        .toolbarTooltip(name: "Switch Branch", shortcut: "⇧⌘B", hovering: $hovering)
        .accessibilityLabel("Switch branch, current branch \(title)")
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
