import AppKit
import SwiftUI

/// The tab row in the title bar (board F, as wired into WindowBase): traffic lights, the strip
/// of repository tabs with folder-group chips, ‹ › only when the strip overflows, and +.
struct TabBar: View {
    let window: WindowModel
    @Environment(AppModel.self) private var app

    @State private var hovered: UUID?
    @State private var press: Press?
    @State private var drag: TabDrag?
    @State private var scrollPosition = ScrollPosition(x: 0)
    @State private var scrollX: CGFloat = 0
    @State private var viewport: CGFloat = 0
    @State private var groupPrompt: GroupPrompt?
    @State private var groupName = ""

    private struct Press: Equatable {
        var unit: UUID
        var dragging: Bool
    }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: window.isFullScreen ? 10 : 78)
                .contentShape(Rectangle())
                .windowDragArea()
            GeometryReader { geometry in
                strip(available: geometry.size.width)
            }
            NewTabButton(window: window)
                .padding(.leading, 4)
                .padding(.trailing, 6)
        }
        .frame(height: KMetric.tabRow)
        .background {
            ZStack(alignment: .bottom) {
                K.band
                K.sep.frame(height: 1)
            }
            .windowDragArea()
        }
        .alert(groupPrompt?.title ?? "", isPresented: Binding(get: { groupPrompt != nil }, set: { if !$0 { groupPrompt = nil } })) {
            TextField("Group name", text: $groupName)
            Button(groupPrompt?.confirm ?? "OK") { confirmGroupPrompt() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(groupPrompt?.message ?? "")
        }
    }

    // MARK: Strip

    @ViewBuilder
    private func strip(available: CGFloat) -> some View {
        let layout = StripModel(window: window, app: app, available: available)
        HStack(spacing: 0) {
            if layout.overflows {
                ArrowButton(icon: Icons.arrowLeft, label: "Scroll tabs left", disabled: scrollX <= 1) { page(-1) }
                    .padding(.horizontal, 2)
            }
            ScrollView(.horizontal) {
                ZStack(alignment: .bottomLeading) {
                    Color.clear
                        .frame(width: layout.contentWidth, height: KMetric.tabRow)
                        .contentShape(Rectangle())
                        .windowDragArea()
                    ForEach(layout.units) { unit in
                        unitView(unit, in: layout)
                            .offset(x: unit.x + offset(for: unit))
                            .zIndex(isDragged(unit) ? 10 : (isActive(unit) ? 1 : 0))
                    }
                }
                .frame(width: layout.contentWidth, height: KMetric.tabRow, alignment: .bottomLeading)
                .animation(drag == nil ? nil : .easeOut(duration: 0.16), value: drag?.to)
            }
            .scrollIndicators(.never)
            .scrollDisabled(!layout.overflows)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, new in scrollX = new }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.containerSize.width }) { _, new in viewport = new }
            .overlay(alignment: .leading) {
                if layout.overflows && scrollX > 1 { fade(.leading) }
            }
            .overlay(alignment: .trailing) {
                if layout.overflows && scrollX + viewport < layout.contentWidth - 1 { fade(.trailing) }
            }
            if layout.overflows {
                ArrowButton(icon: Icons.arrowRight, label: "Scroll tabs right",
                            disabled: scrollX + viewport >= layout.contentWidth - 1) { page(1) }
                    .padding(.horizontal, 2)
            }
        }
        .onChange(of: window.activeTabID) { reveal(in: layout) }
        .onChange(of: available) { reveal(in: layout) }
        .onAppear { reveal(in: layout) }
    }

    @ViewBuilder
    private func unitView(_ unit: StripModel.Unit, in layout: StripModel) -> some View {
        switch unit.kind {
        case .tab(let tab, let label, let group):
            let repository = app.repository(for: tab.path)
            TabItemView(
                label: label,
                isActive: tab.id == window.activeTabID,
                isHovered: hovered == tab.id,
                isDragged: isDragged(unit),
                showsSeparator: layout.showsSeparator(before: unit, active: window.activeTabID, hovered: hovered) && drag == nil,
                groupColor: group?.color.color,
                mark: repository.tabMark,
                width: unit.width,
                help: tooltip(for: tab, repository: repository),
                onClose: { app.close([tab.id], in: window) }
            )
            .onHover { inside in
                if inside { hovered = tab.id } else if hovered == tab.id { hovered = nil }
            }
            .gesture(pressAndDrag(unit, in: layout))
            .contextMenu { tabMenu(tab) }
        case .chip(let group, let members, let activeLabel, let attention):
            GroupChipView(
                group: group,
                count: members.count,
                activeLabel: activeLabel,
                attention: attention,
                isDragged: isDragged(unit)
            )
            .frame(width: unit.width, height: KMetric.tabRow, alignment: .bottomLeading)
            .gesture(pressAndDrag(unit, in: layout))
            .contextMenu { chipMenu(group, members: members) }
        }
    }

    private func fade(_ edge: Edge) -> some View {
        LinearGradient(
            stops: [.init(color: K.band, location: 0.2), .init(color: K.band.opacity(0), location: 1)],
            startPoint: edge == .leading ? .leading : .trailing,
            endPoint: edge == .leading ? .trailing : .leading
        )
        .frame(width: 28)
        .padding(.bottom, 1)
        .allowsHitTesting(false)
    }

    private func tooltip(for tab: RepoTab, repository: RepositoryModel) -> String {
        var text = tab.name
        if let branch = repository.currentBranch { text += " — \(branch)" }
        return text + " · " + Formatters.abbreviatedPath(tab.path)
    }

    // MARK: Scrolling

    private func page(_ direction: CGFloat) {
        let target = max(0, scrollX + direction * (viewport * 0.75).rounded())
        withAnimation(.easeInOut(duration: 0.25)) { scrollPosition.scrollTo(x: target) }
    }

    /// Scrolls so the selected tab (or the chip of its folded group) clears the fades.
    private func reveal(in layout: StripModel) {
        guard layout.overflows, let unit = layout.revealUnit(active: window.activeTabID) else { return }
        let pad: CGFloat = 32
        let visibleWidth = viewport > 0 ? viewport : layout.viewportEstimate
        if unit.x < scrollX + pad {
            withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(x: max(0, unit.x - pad)) }
        } else if unit.x + unit.width > scrollX + visibleWidth - pad {
            withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(x: unit.x + unit.width - visibleWidth + pad) }
        }
    }

    // MARK: Pressing and dragging

    private func isDragged(_ unit: StripModel.Unit) -> Bool {
        guard let drag else { return false }
        switch drag.level {
        case .block: return unit.block == drag.from
        case .member(let group): return unit.memberOf == group && unit.member == drag.from
        }
    }

    private func isActive(_ unit: StripModel.Unit) -> Bool {
        if case .tab(let tab, _, _) = unit.kind { return tab.id == window.activeTabID }
        return false
    }

    /// The shift a unit takes while another is dragged past it.
    private func offset(for unit: StripModel.Unit) -> CGFloat {
        guard let drag else { return 0 }
        let index: Int
        switch drag.level {
        case .block:
            index = unit.block
        case .member(let group):
            guard unit.memberOf == group, let member = unit.member else { return 0 }
            index = member
        }
        if index == drag.from { return drag.dx }
        if drag.to > drag.from, index > drag.from, index <= drag.to { return -drag.width }
        if drag.to < drag.from, index < drag.from, index >= drag.to { return drag.width }
        return 0
    }

    /// Pressing a tab selects it; moving 5 pt starts a drag. A lone tab or a whole group (by
    /// its chip) moves among the blocks; a tab inside a group moves within its group.
    private func pressAndDrag(_ unit: StripModel.Unit, in layout: StripModel) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if press?.unit != unit.id {
                    press = Press(unit: unit.id, dragging: false)
                    if case .tab(let tab, _, _) = unit.kind { window.activate(tab.id) }
                }
                guard press?.dragging == true || abs(value.translation.width) >= 5 else { return }
                press?.dragging = true
                updateDrag(unit, dx: value.translation.width, in: layout)
            }
            .onEnded { _ in
                let dragged = press?.dragging == true
                press = nil
                if dragged {
                    finishDrag()
                } else if case .chip(let group, _, _, _) = unit.kind {
                    withAnimation(.easeOut(duration: 0.18)) { window.toggleCollapsed(group.id) }
                }
            }
    }

    private func updateDrag(_ unit: StripModel.Unit, dx: CGFloat, in layout: StripModel) {
        let level: TabDrag.Level
        let from: Int
        let frames: [ClosedRange<CGFloat>]
        if let group = unit.memberOf, let member = unit.member {
            level = .member(group)
            from = member
            frames = layout.memberFrames(of: group)
        } else {
            level = .block
            from = unit.block
            frames = layout.blockFrames
        }
        guard frames.indices.contains(from), let first = frames.first, let last = frames.last else { return }
        let origin = frames[from]
        let clamped = min(max(dx, first.lowerBound - origin.lowerBound), last.upperBound - origin.upperBound)
        var to = from
        if clamped > 0 {
            let lead = origin.upperBound + clamped
            for index in (from + 1)..<frames.count where lead > (frames[index].lowerBound + frames[index].upperBound) / 2 {
                to = index
            }
        } else if clamped < 0 {
            let lead = origin.lowerBound + clamped
            for index in stride(from: from - 1, through: 0, by: -1) where lead < (frames[index].lowerBound + frames[index].upperBound) / 2 {
                to = index
            }
        }
        drag = TabDrag(level: level, from: from, to: to, dx: clamped, width: origin.upperBound - origin.lowerBound)
    }

    private func finishDrag() {
        guard let drag else { return }
        withAnimation(.easeOut(duration: 0.14)) {
            if drag.from != drag.to {
                switch drag.level {
                case .block: window.moveBlock(from: drag.from, to: drag.to)
                case .member(let group): window.moveMember(of: group, from: drag.from, to: drag.to)
                }
            }
            self.drag = nil
        }
    }

    // MARK: Menus

    @ViewBuilder
    private func tabMenu(_ tab: RepoTab) -> some View {
        let index = window.tabs.firstIndex { $0.id == tab.id } ?? 0
        Button("Close Tab") { app.close([tab.id], in: window) }
        Button("Close Other Tabs") { app.close(window.tabs.filter { $0.id != tab.id }.map(\.id), in: window) }
            .disabled(window.tabs.count < 2)
        Button("Close Tabs to the Right") { app.close(window.tabs[(index + 1)...].map(\.id), in: window) }
            .disabled(index >= window.tabs.count - 1)
        Divider()
        Menu("Add to Group") {
            ForEach(window.groups.filter { $0.id != tab.group }) { group in
                Button(group.name) { withAnimation { window.add(tab.id, to: group.id) } }
            }
            if window.groups.contains(where: { $0.id != tab.group }) { Divider() }
            Button("New Group…") {
                groupName = Self.suggestedGroupName(for: tab, in: window)
                groupPrompt = .new(tab.id)
            }
        }
        Button("Remove from Group") { withAnimation { window.removeFromGroup(tab.id) } }
            .disabled(tab.group == nil)
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: tab.path)]) }
        Button("Open in Terminal") { Self.openInTerminal(tab.path) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.path, forType: .string)
        }
        Divider()
        Button("Move Tab to New Window") { app.moveToNewWindow(tab.id, from: window) }
            .disabled(window.tabs.count < 2)
    }

    @ViewBuilder
    private func chipMenu(_ group: TabGroup, members: [RepoTab]) -> some View {
        Button(group.collapsed ? "Expand Group" : "Collapse Group") {
            withAnimation(.easeOut(duration: 0.18)) { window.toggleCollapsed(group.id) }
        }
        Button("Rename Group…") {
            groupName = group.name
            groupPrompt = .rename(group.id)
        }
        Menu("Color") {
            ForEach(GroupColor.allCases, id: \.self) { color in
                Toggle(color.title, isOn: Binding(get: { group.color == color }, set: { _ in window.setColor(group.id, color) }))
            }
        }
        Divider()
        Button("Ungroup") { withAnimation { window.ungroup(group.id) } }
        Button(members.count == 1 ? "Close Group (1 Tab)" : "Close Group (\(members.count) Tabs)") {
            app.close(members.map(\.id), in: window)
        }
    }

    private enum GroupPrompt: Equatable {
        case new(UUID)
        case rename(UUID)

        var title: String {
            switch self {
            case .new: "New Group"
            case .rename: "Rename Group"
            }
        }

        var message: String {
            switch self {
            case .new: "Tabs in a group sit together behind a colored chip. Click the chip to fold them."
            case .rename: "Enter a new name for the group."
            }
        }

        var confirm: String {
            switch self {
            case .new: "Create"
            case .rename: "Rename"
            }
        }
    }

    private func confirmGroupPrompt() {
        let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let prompt = groupPrompt else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            switch prompt {
            case .new(let tab): window.newGroup(named: name, color: window.nextGroupColor, with: [tab])
            case .rename(let group): window.rename(group, to: name)
            }
        }
        groupPrompt = nil
    }

    /// "godj" for "godj-web"; otherwise the folder the repository is in.
    static func suggestedGroupName(for tab: RepoTab, in window: WindowModel) -> String {
        let separators: Set<Character> = ["-", "_", "."]
        if let index = tab.name.firstIndex(where: { separators.contains($0) }), index != tab.name.startIndex {
            return String(tab.name[..<index])
        }
        return tab.parentName
    }

    static func openInTerminal(_ path: String) {
        let url = URL(filePath: path, directoryHint: .isDirectory)
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// What's being dragged in the strip.
struct TabDrag: Equatable {
    enum Level: Equatable {
        case block
        case member(UUID)
    }

    var level: Level
    var from: Int
    var to: Int
    var dx: CGFloat
    var width: CGFloat
}

/// The strip as laid out for one width: units (tabs and chips) with their widths and positions.
@MainActor
struct StripModel {
    enum Kind {
        case tab(RepoTab, label: String, group: TabGroup?)
        case chip(TabGroup, members: [RepoTab], activeLabel: String?, attention: TabMark)
    }

    struct Unit: Identifiable {
        var id: UUID
        var kind: Kind
        var width: CGFloat = 0
        var x: CGFloat = 0
        /// Index of the block (lone tab or group) in the strip.
        var block: Int
        /// For tabs inside a group: the group and the tab's index in it.
        var memberOf: UUID?
        var member: Int?

        var isTab: Bool {
            if case .tab = kind { return true }
            return false
        }
    }

    private(set) var units: [Unit] = []
    private(set) var overflows = false
    private(set) var contentWidth: CGFloat = 0
    private(set) var viewportEstimate: CGFloat = 0

    init(window: WindowModel, app: AppModel, available: CGFloat) {
        let labels = Self.labels(window)
        var units: [Unit] = []
        var items: [TabStripLayout.Item] = []
        for (blockIndex, block) in window.blocks.enumerated() {
            switch block {
            case .tab(let tab):
                let label = labels[tab.id] ?? tab.name
                units.append(Unit(id: tab.id, kind: .tab(tab, label: label, group: nil), block: blockIndex))
                items.append(.init(natural: TabStripLayout.naturalWidth(label: label, member: false),
                                   minimum: TabStripLayout.minWidth(label: label)))
            case .group(let group, let members):
                let activeInside = members.first { $0.id == window.activeTabID }
                let activeLabel = group.collapsed ? activeInside.map { labels[$0.id] ?? $0.name } : nil
                var attention = TabMark.none
                if group.collapsed {
                    for member in members {
                        let mark = app.repository(for: member.path).tabMark
                        attention = Self.moreUrgent(attention, mark)
                    }
                }
                let trailing: String? = group.collapsed ? (activeLabel.map { "› \($0)" } ?? "\(members.count)") : nil
                let width = TabStripLayout.chipWidth(name: group.name, trailing: trailing, trailingBold: activeLabel != nil,
                                                     attention: attention != .none)
                units.append(Unit(id: group.id, kind: .chip(group, members: members, activeLabel: activeLabel, attention: attention),
                                  block: blockIndex))
                items.append(.init(natural: width, minimum: width))
                guard !group.collapsed else { continue }
                for (memberIndex, tab) in members.enumerated() {
                    let label = labels[tab.id] ?? tab.name
                    units.append(Unit(id: tab.id, kind: .tab(tab, label: label, group: group), block: blockIndex,
                                      memberOf: group.id, member: memberIndex))
                    items.append(.init(natural: TabStripLayout.naturalWidth(label: label, member: true),
                                       minimum: TabStripLayout.minWidth(label: label)))
                }
            }
        }
        var solution = TabStripLayout.solve(items, available: available)
        if solution.overflows {
            solution = TabStripLayout.solve(items, available: available - TabStripLayout.arrows)
            solution.overflows = true
        }
        var x: CGFloat = 0
        for index in units.indices {
            units[index].width = solution.widths[index]
            units[index].x = x
            x += solution.widths[index]
        }
        self.units = units
        overflows = solution.overflows
        contentWidth = max(solution.contentWidth, overflows ? 0 : available)
        viewportEstimate = overflows ? available - TabStripLayout.arrows : available
    }

    var blockFrames: [ClosedRange<CGFloat>] {
        var frames: [Int: ClosedRange<CGFloat>] = [:]
        for unit in units {
            let range = unit.x...(unit.x + unit.width)
            if let existing = frames[unit.block] {
                frames[unit.block] = min(existing.lowerBound, range.lowerBound)...max(existing.upperBound, range.upperBound)
            } else {
                frames[unit.block] = range
            }
        }
        return frames.keys.sorted().compactMap { frames[$0] }
    }

    func memberFrames(of group: UUID) -> [ClosedRange<CGFloat>] {
        units.filter { $0.memberOf == group }.sorted { ($0.member ?? 0) < ($1.member ?? 0) }.map { $0.x...($0.x + $0.width) }
    }

    /// The unit to keep in view: the selected tab, or its folded group's chip.
    func revealUnit(active: UUID?) -> Unit? {
        guard let active else { return nil }
        if let tab = units.first(where: { $0.id == active }) { return tab }
        return units.first { unit in
            if case .chip(_, let members, _, _) = unit.kind { return members.contains { $0.id == active } }
            return false
        }
    }

    /// Separators sit between two tabs, except next to the selected or hovered tab.
    func showsSeparator(before unit: Unit, active: UUID?, hovered: UUID?) -> Bool {
        guard unit.isTab, let index = units.firstIndex(where: { $0.id == unit.id }), index > 0 else { return false }
        let previous = units[index - 1]
        guard previous.isTab else { return false }
        let quiet: Set<UUID?> = [active, hovered]
        return !quiet.contains(unit.id) && !quiet.contains(previous.id)
    }

    /// Labels: members drop the group name; lone tabs that share a name get their folder.
    static func labels(_ window: WindowModel) -> [UUID: String] {
        var counts: [String: Int] = [:]
        for tab in window.tabs where tab.group == nil { counts[tab.name, default: 0] += 1 }
        var result: [UUID: String] = [:]
        for tab in window.tabs {
            if let groupID = tab.group, let group = window.group(groupID) {
                result[tab.id] = TabStripLayout.shortName(tab.name, inGroup: group.name)
            } else {
                let clash = (counts[tab.name] ?? 0) > 1
                    || window.tabs.contains { $0.id != tab.id && $0.group != nil && $0.name == tab.name }
                result[tab.id] = clash ? "\(tab.name) — \(tab.parentName)" : tab.name
            }
        }
        return result
    }

    static func moreUrgent(_ a: TabMark, _ b: TabMark) -> TabMark {
        func rank(_ mark: TabMark) -> Int {
            switch mark {
            case .none: 0
            case .changes: 1
            case .busy: 2
            case .missing: 3
            case .warning: 4
            case .error: 5
            }
        }
        return rank(b) > rank(a) ? b : a
    }
}

extension View {
    /// Drags the window from this area; a double-click zooms or minimizes, per System Settings.
    func windowDragArea() -> some View {
        gesture(WindowDragGesture())
            .simultaneousGesture(TapGesture(count: 2).onEnded { TitleBarDoubleClick.perform() })
    }
}

enum TitleBarDoubleClick {
    static func perform() {
        guard let window = NSApp.keyWindow else { return }
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
        switch action {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.zoom(nil)
        }
    }
}
