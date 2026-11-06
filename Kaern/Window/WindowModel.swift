import Foundation
import Observation

/// One tab in a window's strip: a repository folder, optionally in a folder group.
struct RepoTab: Identifiable, Hashable {
    let id: UUID
    let path: String
    var group: UUID?

    var name: String { (path as NSString).lastPathComponent }
    /// The folder the repository sits in ("powerlens" in ~/Developer/powerlens → "Developer").
    var parentName: String { ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent }
}

/// A folder group of tabs (shown as a colored chip in the strip).
struct TabGroup: Identifiable, Hashable {
    let id: UUID
    var name: String
    var color: GroupColor
    var collapsed: Bool
}

/// The strip is a row of blocks: a lone tab, or a group (its chip and, when open, its tabs).
enum StripBlock: Identifiable {
    case tab(RepoTab)
    case group(TabGroup, [RepoTab])

    var id: UUID {
        switch self {
        case .tab(let tab): tab.id
        case .group(let group, _): group.id
        }
    }
}

/// The tabs, folder groups and selection of one window. Views read it; every change goes
/// through the methods below, which keep group members next to each other and tell the app
/// to save the session.
@MainActor @Observable
final class WindowModel: Identifiable {
    let id: UUID
    private(set) var tabs: [RepoTab] = []
    private(set) var groups: [TabGroup] = []
    private(set) var activeTabID: UUID?
    /// The window frame to save (updated by the controller as the window moves).
    var frame: CGRect? { didSet { if frame != oldValue { changed() } } }
    var isFullScreen = false { didSet { if isFullScreen != oldValue { changed() } } }
    var showsSidebar = true { didSet { if showsSidebar != oldValue { changed() } } }
    var showsDetails = true { didSet { if showsDetails != oldValue { changed() } } }
    /// The + popover (recent repositories and Open Repository…). Not saved.
    var showsNewTab = false
    /// Focus mode: both side panels hidden, the commit row inline, the drawer below the graph.
    /// Not saved.
    var isFocused = false
    /// Focus mode's bottom drawer (closed with its ×, opened again by picking a row).
    var showsDrawer = true

    /// Sidebar on the toolbar or ⌃⌘S. In Focus it leaves Focus and shows the sidebar.
    func toggleSidebar() {
        if isFocused {
            isFocused = false
            showsSidebar = true
        } else {
            showsSidebar.toggle()
        }
    }

    /// Details on the toolbar or ⌥⌘I. In Focus it leaves Focus and shows the panel.
    func toggleDetails() {
        if isFocused {
            isFocused = false
            showsDetails = true
        } else {
            showsDetails.toggle()
        }
    }

    /// Focus on the toolbar or ⌥⌘G (opens the drawer again).
    func toggleFocus() {
        isFocused.toggle()
        if isFocused { showsDrawer = true }
    }

    /// Called after every change that should reach the session file.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Called when the selected tab changes (to update which repositories are visible).
    @ObservationIgnored var onActiveTabChange: (() -> Void)?

    init(id: UUID = UUID()) {
        self.id = id
    }

    init(state: Session.WindowState) {
        id = state.id
        frame = state.frame
        isFullScreen = state.isFullScreen
        showsSidebar = state.showsSidebar
        showsDetails = state.showsDetails
        groups = state.groups.map { TabGroup(id: $0.id, name: $0.name, color: $0.color, collapsed: $0.collapsed) }
        let groupIDs = Set(groups.map(\.id))
        var seen = Set<String>()
        tabs = state.tabs.compactMap { tab in
            // One tab per repository per window; drop duplicates a hand-edited file might have.
            guard seen.insert(tab.path).inserted else { return nil }
            return RepoTab(id: tab.id, path: tab.path, group: tab.group.flatMap { groupIDs.contains($0) ? $0 : nil })
        }
        normalize()
        activeTabID = state.activeTab.flatMap { id in tabs.contains { $0.id == id } ? id : nil } ?? tabs.first?.id
    }

    var state: Session.WindowState {
        Session.WindowState(
            id: id,
            frame: frame,
            isFullScreen: isFullScreen,
            tabs: tabs.map { Session.TabState(id: $0.id, path: $0.path, group: $0.group) },
            groups: groups.map { Session.GroupState(id: $0.id, name: $0.name, color: $0.color, collapsed: $0.collapsed) },
            activeTab: activeTabID,
            showsSidebar: showsSidebar,
            showsDetails: showsDetails
        )
    }

    // MARK: Reading

    var activeTab: RepoTab? { activeTabID.flatMap { id in tabs.first { $0.id == id } } }

    func tab(_ id: UUID) -> RepoTab? { tabs.first { $0.id == id } }
    func group(_ id: UUID) -> TabGroup? { groups.first { $0.id == id } }
    func members(of group: UUID) -> [RepoTab] { tabs.filter { $0.group == group } }

    var blocks: [StripBlock] {
        var result: [StripBlock] = []
        var seen = Set<UUID>()
        for tab in tabs {
            guard let groupID = tab.group, let group = group(groupID) else {
                result.append(.tab(tab))
                continue
            }
            guard seen.insert(groupID).inserted else { continue }
            result.append(.group(group, members(of: groupID)))
        }
        return result
    }

    /// Tabs in the order ⌃Tab walks them: lone tabs and tabs of open groups, plus the
    /// selected tab even when its group is folded.
    var cycleOrder: [RepoTab] {
        tabs.filter { tab in
            guard let groupID = tab.group, let group = group(groupID) else { return true }
            return !group.collapsed || tab.id == activeTabID
        }
    }

    // MARK: Tabs

    /// Opens repositories as tabs (one per repository: an open one is selected instead).
    func open(paths: [String], select: Bool = true) {
        var last: UUID?
        for path in paths {
            if let existing = tabs.first(where: { $0.path == path }) {
                last = existing.id
                continue
            }
            let tab = RepoTab(id: UUID(), path: path, group: nil)
            tabs.append(tab)
            last = tab.id
        }
        if select, let last { activate(last, notify: false) }
        changed()
    }

    func activate(_ id: UUID) {
        activate(id, notify: true)
    }

    private func activate(_ id: UUID, notify: Bool) {
        guard activeTabID != id, tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        onActiveTabChange?()
        if notify { changed() }
    }

    func activateNext(_ step: Int) {
        let order = cycleOrder
        guard order.count > 1, let index = order.firstIndex(where: { $0.id == activeTabID }) else {
            if let first = order.first { activate(first.id) }
            return
        }
        let next = (index + step + order.count) % order.count
        activate(order[next].id)
    }

    /// ⌘1…⌘8 select that tab; ⌘9 the last one.
    func activate(number: Int) {
        let order = cycleOrder
        guard !order.isEmpty else { return }
        let index = number >= 9 ? order.count - 1 : number - 1
        guard order.indices.contains(index) else { return }
        activate(order[index].id)
    }

    func close(_ id: UUID) {
        close([id])
    }

    func close(_ ids: [UUID]) {
        let closing = Set(ids)
        guard !closing.isEmpty else { return }
        let activeIndex = tabs.firstIndex { $0.id == activeTabID }
        tabs.removeAll { closing.contains($0.id) }
        dropEmptyGroups()
        if let active = activeTabID, closing.contains(active) {
            // The tab that slides into the closed tab's place, like Safari and the board.
            let index = min(activeIndex ?? 0, tabs.count - 1)
            activeTabID = index >= 0 ? tabs[index].id : nil
            onActiveTabChange?()
        }
        changed()
    }

    func closeOthers(than id: UUID) {
        close(tabs.filter { $0.id != id }.map(\.id))
        activate(id)
    }

    func closeToTheRight(of id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        close(tabs[(index + 1)...].map(\.id))
    }

    // MARK: Reordering

    /// Moves a whole block (a lone tab or a group with its tabs) to another block position.
    func moveBlock(from: Int, to: Int) {
        var blocks = self.blocks
        guard blocks.indices.contains(from), blocks.indices.contains(to), from != to else { return }
        let block = blocks.remove(at: from)
        blocks.insert(block, at: to)
        tabs = Self.flatten(blocks)
        changed()
    }

    /// Moves a tab within its group.
    func moveMember(of groupID: UUID, from: Int, to: Int) {
        var members = members(of: groupID)
        guard members.indices.contains(from), members.indices.contains(to), from != to else { return }
        let tab = members.remove(at: from)
        members.insert(tab, at: to)
        var blocks = self.blocks
        guard let index = blocks.firstIndex(where: { $0.id == groupID }), case .group(let group, _) = blocks[index] else { return }
        blocks[index] = .group(group, members)
        tabs = Self.flatten(blocks)
        changed()
    }

    // MARK: Groups

    /// Puts tabs into a new group where the first of them was.
    @discardableResult
    func newGroup(named name: String, color: GroupColor, with ids: [UUID]) -> UUID {
        let group = TabGroup(id: UUID(), name: name, color: color, collapsed: false)
        groups.append(group)
        let moving = tabs.filter { ids.contains($0.id) }
        guard let anchor = tabs.firstIndex(where: { ids.contains($0.id) }) else {
            changed()
            return group.id
        }
        var rest = tabs
        rest.removeAll { ids.contains($0.id) }
        let insertAt = rest.prefix(anchor).count
        rest.insert(contentsOf: moving.map { RepoTab(id: $0.id, path: $0.path, group: group.id) }, at: min(insertAt, rest.count))
        tabs = rest
        dropEmptyGroups()
        normalize()
        changed()
        return group.id
    }

    /// Adds a tab to the end of a group.
    func add(_ id: UUID, to groupID: UUID) {
        guard var tab = tab(id), tab.group != groupID, group(groupID) != nil else { return }
        tabs.removeAll { $0.id == id }
        tab.group = groupID
        let lastMember = tabs.lastIndex { $0.group == groupID }
        tabs.insert(tab, at: lastMember.map { $0 + 1 } ?? tabs.count)
        setCollapsed(groupID, false, notify: false)
        dropEmptyGroups()
        normalize()
        changed()
    }

    /// Takes a tab out of its group and puts it right after the group.
    func removeFromGroup(_ id: UUID) {
        guard var tab = tab(id), let groupID = tab.group else { return }
        tabs.removeAll { $0.id == id }
        tab.group = nil
        let lastMember = tabs.lastIndex { $0.group == groupID }
        tabs.insert(tab, at: lastMember.map { $0 + 1 } ?? tabs.count)
        dropEmptyGroups()
        changed()
    }

    /// Dissolves a group; its tabs stay where they are.
    func ungroup(_ groupID: UUID) {
        tabs = tabs.map { RepoTab(id: $0.id, path: $0.path, group: $0.group == groupID ? nil : $0.group) }
        groups.removeAll { $0.id == groupID }
        changed()
    }

    func closeGroup(_ groupID: UUID) {
        close(members(of: groupID).map(\.id))
    }

    func rename(_ groupID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].name = trimmed
        changed()
    }

    func setColor(_ groupID: UUID, _ color: GroupColor) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].color = color
        changed()
    }

    func toggleCollapsed(_ groupID: UUID) {
        guard let group = group(groupID) else { return }
        setCollapsed(groupID, !group.collapsed, notify: true)
    }

    private func setCollapsed(_ groupID: UUID, _ collapsed: Bool, notify: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }), groups[index].collapsed != collapsed else { return }
        groups[index].collapsed = collapsed
        if notify { changed() }
    }

    /// A color the window's groups don't use yet.
    var nextGroupColor: GroupColor {
        let used = Set(groups.map(\.color))
        return GroupColor.allCases.first { !used.contains($0) } ?? .blue
    }

    /// Takes over another model's strip (used to bring back a closed window's tabs).
    func restoreContents(of other: WindowModel) {
        tabs = other.tabs
        groups = other.groups
        activeTabID = other.activeTabID
        onActiveTabChange?()
        changed()
    }

    // MARK: Helpers

    private func changed() {
        onChange?()
    }

    private func dropEmptyGroups() {
        let used = Set(tabs.compactMap(\.group))
        groups.removeAll { !used.contains($0.id) }
    }

    /// Keeps each group's tabs together, at the position of its first tab.
    private func normalize() {
        tabs = Self.flatten(blocks)
    }

    private static func flatten(_ blocks: [StripBlock]) -> [RepoTab] {
        blocks.flatMap { block -> [RepoTab] in
            switch block {
            case .tab(let tab): [tab]
            case .group(_, let members): members
            }
        }
    }
}
