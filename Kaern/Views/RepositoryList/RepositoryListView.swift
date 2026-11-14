import AppKit
import KaernKit
import SwiftUI

// MARK: - What a list row shows

/// A repository in the Sidebar list, the icon rail and the Toolbar mode's popover: its avatar,
/// name, branch and what needs you (WindowRepoSidebar / WindowRepoToolbar).
@MainActor
struct RepoListItem: Identifiable {
    enum Mark { case none, changes, warning, error, missing }

    let tab: RepoTab
    let label: String
    let model: RepositoryModel

    var id: UUID { tab.id }

    var branch: String {
        switch model.phase {
        case .missing: return "folder not found"
        case .notRepository: return "not a repository"
        case .failed: return "couldn’t open"
        default: break
        }
        if let operation = model.operation, operation.kind == .rebase, let branch = operation.branch { return "rebasing \(branch)" }
        if let branch = model.status.branch { return branch }
        if case .detached(let id) = model.status.head, !id.isEmpty { return "detached at \(id.prefix(7))" }
        return model.repository == nil ? "…" : "no commits yet"
    }

    var ahead: Int { model.status.upstream == nil ? 0 : model.status.ahead }
    var behind: Int { model.status.upstream == nil ? 0 : model.status.behind }

    var mark: Mark {
        switch model.phase {
        case .missing: return .missing
        case .failed: return .error
        default: break
        }
        if let failure = model.fetchProblem?.failure {
            if case .signIn = failure { return .error }
            if case .sshKey = failure { return .error }
        }
        if model.operation != nil || model.status.conflictCount > 0 { return .warning }
        if model.status.ahead > 0, model.status.behind > 0, model.status.upstream != nil { return .warning }
        if !model.status.isClean { return .changes }
        return .none
    }

    /// Needs you: a stop, a turned-down sign-in, a missing folder, a diverged branch.
    var needsAttention: Bool { mark == .warning || mark == .error || mark == .missing }

    /// "powerlens — feature/x · ↑2 · uncommitted changes" (VoiceOver, the rail's tooltip).
    var summary: String {
        var parts = [branch]
        if ahead > 0 { parts.append("↑\(ahead)") }
        if behind > 0 { parts.append("↓\(behind)") }
        switch mark {
        case .changes: parts.append("uncommitted changes")
        case .warning: parts.append(model.operation != nil ? "stopped mid-operation" : "needs attention")
        case .error: parts.append(model.fetchProblem != nil ? "sign-in needed" : "couldn’t open")
        case .missing: break
        case .none: break
        }
        return parts.joined(separator: " · ")
    }

    static func items(_ window: WindowModel, app: AppModel) -> [UUID: RepoListItem] {
        let labels = StripModel.labels(window)
        var result: [UUID: RepoListItem] = [:]
        for tab in window.tabs {
            result[tab.id] = RepoListItem(tab: tab, label: labels[tab.id] ?? tab.name, model: app.repository(for: tab.path))
        }
        return result
    }
}

/// The square with a repository's initials, in its own color (`.av`).
struct RepoAvatar: View {
    let name: String
    var size: CGFloat = 26
    var radius: CGFloat = 7
    var fontSize: CGFloat = 10.5
    var dimmed = false

    var body: some View {
        Text(Self.initials(name))
            .font(.system(size: fontSize, weight: .bold))
            .tracking(0.2)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Self.color(for: name)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
            .saturation(dimmed ? 0 : 1)
            .opacity(dimmed ? 0.5 : 1)
            .accessibilityHidden(true)
    }

    /// "travel-blog" → "TB", "PowerLens" → "PL", "godj" → "GO".
    static func initials(_ name: String) -> String {
        var words: [String] = []
        var current = ""
        for character in name {
            if "-_. ".contains(character) {
                if !current.isEmpty { words.append(current); current = "" }
            } else if character.isUppercase, let last = current.last, last.isLowercase {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        if words.count >= 2 {
            return (words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String((words.first ?? name).prefix(2)).uppercased()
    }

    /// The boards' repository colors, picked by name.
    static func color(for name: String) -> Color {
        let colors: [UInt32] = [0x0a7cff, 0x8e5cd9, 0x30a46c, 0xe5484d, 0xf76b15, 0x8e8e93, 0x5856d6, 0x12a594, 0xd6409f, 0xe8a317, 0x00a2c7]
        var hash: UInt32 = 2_166_136_261
        for byte in name.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Color(nsColor: K.hex(colors[Int(hash % UInt32(colors.count))]))
    }
}

/// The right side of a row: ↑ ↓ pills, then a dot (changes) or a mark (! ?).
private struct RepoStatusMarks: View {
    let item: RepoListItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 4) {
            if item.ahead > 0 {
                pill("↑\(item.ahead)", fill: K.accentSoft, color: K.accentText)
            }
            if item.behind > 0 {
                pill("↓\(item.behind)", fill: K.modBg, color: K.mod)
            }
            switch item.mark {
            case .changes:
                Circle().fill(selected ? Color.white : K.warn).frame(width: 7, height: 7)
            case .warning: badge("!", K.warn)
            case .error: badge("!", K.err)
            case .missing: badge("?", K.label3)
            case .none: EmptyView()
            }
        }
        .fixedSize()
    }

    private func pill(_ text: String, fill: Color, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(selected ? .white : color)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(Capsule().fill(selected ? Color.white.opacity(0.22) : fill))
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(Circle().fill(color))
            .overlay(Circle().stroke(selected ? Color.white : .clear, lineWidth: 1.5))
    }
}

/// The C2 compact tree: a 2 pt line in the folder color down the left of a group's rows, with a
/// right-angle tick into each (`.rr.in::before` / `::after`).
private struct TreeLines: View {
    let color: Color
    let isFirst: Bool
    let isLast: Bool
    let isSelected: Bool
    var top: CGFloat = 2
    var firstTop: CGFloat = 10
    var tick: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let mid = geometry.size.height / 2
            ZStack(alignment: .topLeading) {
                Rectangle().fill(color)
                    .frame(width: 2, height: (isLast ? mid : geometry.size.height + top) + (isFirst ? firstTop : top))
                    .offset(x: -4, y: -(isFirst ? firstTop : top))
                UnevenRoundedRectangle(bottomTrailingRadius: 1, topTrailingRadius: 1)
                    .fill(color)
                    .frame(width: isSelected ? 4 : tick, height: 2)
                    .offset(x: -4, y: mid - 1)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Sidebar mode: the list

/// WindowRepoSidebar's named list (228 pt unless dragged): Repositories ‹, a filter, the repositories
/// in strip order with folder groups as a compact tree, and Add Repository….
struct RepositoryListView: View {
    static let width: CGFloat = 228

    let window: WindowModel
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.listShowsBranch, store: .kaern) private var showsBranch = true
    @State private var filter = ""
    @FocusState private var filterFocused: Bool

    var body: some View {
        let items = RepoListItem.items(window, app: app)
        let query = filter.trimmingCharacters(in: .whitespaces)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Repositories").font(.system(size: 12, weight: .bold)).foregroundStyle(K.label2)
                Text("\(window.tabs.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(K.label3)
                Spacer()
                ListIconButton(icon: Icons.arrowLeft, label: "Fold the sidebar into icons", tip: "Fold into Icons") {
                    withAnimation(.easeOut(duration: 0.18)) { window.listFolded = true }
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 36)
            HStack(spacing: 6) {
                Icon(Icons.search(1.4), size: 12).foregroundStyle(K.label2)
                TextField("Filter", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($filterFocused)
                    .onSubmit { openFirstMatch(items, query: query) }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(K.field)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(K.controlBorder, lineWidth: 0.5)))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let blocks = filtered(window.blocks, items: items, query: query)
                    ForEach(blocks) { block in
                        switch block {
                        case .tab(let tab):
                            if let item = items[tab.id] {
                                ListRow(item: item, window: window, showsBranch: showsBranch)
                            }
                        case .group(let group, let members):
                            groupRows(group, members: members, items: items, filtering: !query.isEmpty)
                        }
                    }
                    if blocks.isEmpty {
                        Text(query.isEmpty ? "Open a repository to list it here." : "No repository matches “\(query)”.")
                            .font(.system(size: 12))
                            .foregroundStyle(K.label2)
                            .padding(EdgeInsets(top: 12, leading: 8, bottom: 0, trailing: 8))
                    }
                }
                .padding(EdgeInsets(top: 2, leading: 8, bottom: 8, trailing: 8))
            }
            .scrollIndicators(.automatic)
            AddRepositoryButton(window: window)
                .padding(EdgeInsets(top: 6, leading: 8, bottom: 8, trailing: 8))
                .overlay(alignment: .top) { K.sep.frame(height: 1) }
        }
        .frame(maxWidth: .infinity)
        .background(K.band)
        .overlay(alignment: .trailing) { K.sep.frame(width: 1) }
        .onReceive(NotificationCenter.default.publisher(for: .kaernFocusRepositoryFilter)) { note in
            if (note.object as? UUID) == window.id { filterFocused = true }
        }
    }

    private func filtered(_ blocks: [StripBlock], items: [UUID: RepoListItem], query: String) -> [StripBlock] {
        guard !query.isEmpty else { return blocks }
        func matches(_ tab: RepoTab) -> Bool {
            guard let item = items[tab.id] else { return false }
            return item.label.localizedCaseInsensitiveContains(query) || tab.name.localizedCaseInsensitiveContains(query)
                || item.branch.localizedCaseInsensitiveContains(query)
        }
        return blocks.compactMap { block in
            switch block {
            case .tab(let tab): return matches(tab) ? block : nil
            case .group(let group, let members):
                let kept = members.filter(matches)
                return kept.isEmpty ? nil : .group(group, kept)
            }
        }
    }

    private func openFirstMatch(_ items: [UUID: RepoListItem], query: String) {
        guard !query.isEmpty else { return }
        for block in filtered(window.blocks, items: items, query: query) {
            switch block {
            case .tab(let tab): window.activate(tab.id); filter = ""; return
            case .group(_, let members):
                if let first = members.first { window.activate(first.id); filter = ""; return }
            }
        }
    }

    @ViewBuilder
    private func groupRows(_ group: TabGroup, members: [RepoTab], items: [UUID: RepoListItem], filtering: Bool) -> some View {
        let open = filtering || !group.collapsed
        let memberItems = members.compactMap { items[$0.id] }
        let attention = memberItems.contains { $0.mark == .error } ? K.err : (memberItems.contains { $0.needsAttention || $0.mark == .changes } ? K.warn : nil)
        GroupHeaderRow(group: group, count: members.count, isOpen: open, attention: attention, window: window)
        if open {
            ForEach(Array(memberItems.enumerated()), id: \.element.id) { index, item in
                ListRow(item: item, window: window, showsBranch: showsBranch,
                        tree: (group.color.color, index == 0, index == memberItems.count - 1))
            }
        } else if let active = memberItems.first(where: { $0.tab.id == window.activeTabID }) {
            // A folded group still shows its selected repository, with a short └.
            ListRow(item: active, window: window, showsBranch: showsBranch, tree: (group.color.color, true, true))
        }
    }
}

extension Notification.Name {
    /// Puts the cursor in the repository list's filter of the window whose id is the object.
    static let kaernFocusRepositoryFilter = Notification.Name("KaernFocusRepositoryFilter")
}

/// `.rlb`: a 24 pt icon button in the list's header.
private struct ListIconButton: View {
    let icon: SVGIcon
    let label: String
    let tip: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Icon(icon, size: 12)
                .foregroundStyle(hovering ? K.label : K.label2)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? K.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tip)
        .accessibilityLabel(label)
    }
}

/// `.rg`: a folder group — disclosure, folder in the group color, name, count, attention dot.
private struct GroupHeaderRow: View {
    let group: TabGroup
    let count: Int
    let isOpen: Bool
    let attention: Color?
    let window: WindowModel
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { window.toggleCollapsed(group.id) }
        } label: {
            HStack(spacing: 6) {
                Icon(Icons.chevronDown, size: 9)
                    .foregroundStyle(K.label2)
                    .rotationEffect(.degrees(isOpen ? 0 : -90))
                Icon(Icons.folderFilled, size: 15).foregroundStyle(group.color.color)
                Text(group.name)
                    .font(KFont.weighted(12.5, 0.35))
                    .foregroundStyle(K.label)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(count)")
                    .font(KFont.weighted(10.5, 0.35))
                    .foregroundStyle(K.label2)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 16)
                    .background(Capsule().fill(K.chip2))
                if let attention {
                    Circle().fill(attention).frame(width: 7, height: 7)
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 6)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? K.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        .onHover { hovering = $0 }
        .contextMenu { RepoListMenus.group(group, window: window) }
        .accessibilityLabel("\(group.name), \(count) repositories")
        .accessibilityValue(isOpen ? "expanded" : "collapsed")
    }
}

/// `.rr`: one repository — avatar, name, branch, ↑↓ and its mark; blue when it's the one shown.
private struct ListRow: View {
    let item: RepoListItem
    let window: WindowModel
    let showsBranch: Bool
    var tree: (color: Color, first: Bool, last: Bool)?
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        let selected = item.tab.id == window.activeTabID
        let missing = item.mark == .missing
        Button {
            window.activate(item.tab.id)
        } label: {
            HStack(spacing: 9) {
                RepoAvatar(name: item.tab.name, dimmed: missing)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(selected ? Color.white.opacity(0.75) : .clear, lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? .white : (missing ? K.label3 : K.label))
                    if showsBranch {
                        Text(item.branch)
                            .font(.system(size: 11))
                            .foregroundStyle(selected ? .white.opacity(0.82) : (missing ? K.label3 : K.label2))
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                RepoStatusMarks(item: item, selected: selected)
            }
            .padding(.horizontal, 8)
            .frame(height: showsBranch ? 42 : 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? K.sel : (hovering ? K.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, tree == nil ? 0 : 12)
        .overlay(alignment: .leading) {
            if let tree {
                TreeLines(color: tree.color, isFirst: tree.first, isLast: tree.last, isSelected: selected)
                    .frame(width: 14)
                    .padding(.leading, 12)
                    .padding(.vertical, 0)
            }
        }
        .padding(.top, 2)
        .onHover { hovering = $0 }
        .contextMenu { RepoListMenus.repository(item.tab, window: window, app: app) }
        .help("\(item.tab.name) — \(Formatters.abbreviatedPath(item.tab.path))")
        .accessibilityLabel("\(item.tab.name), \(item.summary)")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// `.rladd`: Add Repository… — recent repositories and Open / Clone / Create (⌘T).
private struct AddRepositoryButton: View {
    let window: WindowModel
    var compact = false
    @State private var hovering = false

    var body: some View {
        @Bindable var window = window
        Button {
            window.showsNewTab = true
        } label: {
            Group {
                if compact {
                    Icon(Icons.plus, size: 13)
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 1))
                } else {
                    HStack(spacing: 7) {
                        Icon(Icons.plus, size: 12)
                        Text("Add Repository…").font(.system(size: 12.5))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                }
            }
            .foregroundStyle(hovering ? K.label : K.label2)
            .background(RoundedRectangle(cornerRadius: compact ? 10 : 7, style: .continuous).fill(hovering ? K.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $window.showsNewTab, arrowEdge: compact ? .trailing : .top) {
            NewTabPopover(window: window, showsMore: true)
        }
        .help("Add Repository (⌘T)")
        .accessibilityLabel("Add Repository")
    }
}

// MARK: - Sidebar mode: the icon rail

/// The list folded with ‹ (or automatically under 1,100 pt): 60 pt of avatars, with the group
/// folders as small tiles over a bar in their color (`.rlist.rail`).
struct RepositoryRailView: View {
    let window: WindowModel
    /// Folded only because the window is narrow: › isn't offered (it would unfold into a cramped list).
    var isAutomatic = false
    @Environment(AppModel.self) private var app

    var body: some View {
        let items = RepoListItem.items(window, app: app)
        VStack(spacing: 0) {
            ListIconButton(icon: Icons.arrowRight, label: "Unfold the sidebar to show names", tip: "Show Names") {
                withAnimation(.easeOut(duration: 0.18)) { window.listFolded = false }
            }
            .padding(.top, 6)
            .padding(.bottom, 2)
            .disabled(isAutomatic)
            .opacity(isAutomatic ? 0.35 : 1)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(window.blocks) { block in
                        switch block {
                        case .tab(let tab):
                            if let item = items[tab.id] { RailTile(item: item, window: window) }
                        case .group(let group, let members):
                            RailGroup(group: group, members: members.compactMap { items[$0.id] }, window: window)
                        }
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            AddRepositoryButton(window: window, compact: true)
                .padding(.top, 6)
                .padding(.bottom, 10)
        }
        .frame(width: 60)
        .background(K.band)
        .overlay(alignment: .trailing) { K.sep.frame(width: 1) }
    }
}

/// `.rt`: one repository's avatar (32 pt) with a status dot; the shown one has an accent ring
/// and a bar on the left.
private struct RailTile: View {
    let item: RepoListItem
    let window: WindowModel
    @Environment(AppModel.self) private var app

    var body: some View {
        let selected = item.tab.id == window.activeTabID
        Button { window.activate(item.tab.id) } label: {
            RepoAvatar(name: item.tab.name, size: 32, radius: 9, fontSize: 11.5, dimmed: item.mark == .missing)
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(K.accent, lineWidth: 2).padding(-4)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let color = dotColor {
                        Circle().fill(color).frame(width: 10, height: 10)
                            .overlay(Circle().stroke(K.band, lineWidth: 2))
                            .offset(x: 2, y: -2)
                    }
                }
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 2).fill(K.label).frame(width: 4, height: 20).offset(x: -10)
            }
        }
        .contextMenu { RepoListMenus.repository(item.tab, window: window, app: app) }
        .help("\(item.label)\n\(item.summary)")
        .accessibilityLabel("\(item.tab.name), \(item.summary)")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private var dotColor: Color? {
        switch item.mark {
        case .changes, .warning: K.warn
        case .error: K.err
        case .missing: K.label3
        case .none: nil
        }
    }
}

/// `.rgrp`: a folder group in the rail — a small folder tile with its count, the members under it
/// while open, and a bar in the group color.
private struct RailGroup: View {
    let group: TabGroup
    let members: [RepoListItem]
    let window: WindowModel
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { window.toggleCollapsed(group.id) }
            } label: {
                HStack(spacing: 3) {
                    Icon(Icons.folderFilled, size: 16).foregroundStyle(group.color.color)
                    Text("\(members.count)").font(.system(size: 10, weight: .bold)).foregroundStyle(K.label2)
                }
                .frame(width: 40, height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? K.hover : .clear))
                .overlay(alignment: .topTrailing) {
                    if members.contains(where: { $0.needsAttention || $0.mark == .changes }) {
                        Circle().fill(members.contains { $0.mark == .error } ? K.err : K.warn).frame(width: 7, height: 7).offset(x: -3, y: 2)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("\(group.name) — \(Formatters.count(members.count, "repository", "repositories"))")
            .contextMenu { RepoListMenus.group(group, window: window) }
            if !group.collapsed {
                ForEach(members) { item in RailTile(item: item, window: window) }
            } else if let active = members.first(where: { $0.tab.id == window.activeTabID }) {
                RailTile(item: active, window: window)
            }
        }
        .padding(.vertical, 2)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(group.color.color).frame(width: 3).padding(.vertical, 4).offset(x: -7)
        }
    }
}

// MARK: - Menus

/// The list's context menus: the tab bar's choices, worded for a list.
@MainActor
enum RepoListMenus {
    @ViewBuilder
    static func repository(_ tab: RepoTab, window: WindowModel, app: AppModel) -> some View {
        Button("Remove from Sidebar") { app.close([tab.id], in: window) }
        Button("Remove Others") { app.close(window.tabs.filter { $0.id != tab.id }.map(\.id), in: window) }
            .disabled(window.tabs.count < 2)
        Divider()
        Menu("Move to Group") {
            ForEach(window.groups) { group in
                Button(group.name) { window.add(tab.id, to: group.id) }
                    .disabled(tab.group == group.id)
            }
            if !window.groups.isEmpty { Divider() }
            Button("New Group…") {
                window.newGroup(named: tab.parentName, color: window.nextGroupColor, with: [tab.id])
            }
        }
        Button("Remove from Group") { window.removeFromGroup(tab.id) }
            .disabled(tab.group == nil)
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: tab.path)]) }
        Button("Open in Terminal") { TabBar.openInTerminal(tab.path) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.path, forType: .string)
        }
        Divider()
        Button("Move to New Window") { app.moveToNewWindow(tab.id, from: window) }
            .disabled(window.tabs.count < 2)
    }

    @ViewBuilder
    static func group(_ group: TabGroup, window: WindowModel) -> some View {
        Button(group.collapsed ? "Expand Group" : "Collapse Group") { window.toggleCollapsed(group.id) }
        Menu("Color") {
            ForEach(GroupColor.allCases, id: \.self) { color in
                Button(color.title) { window.setColor(group.id, color) }
            }
        }
        Button("Ungroup") { window.ungroup(group.id) }
        Divider()
        Button("Remove Group from Sidebar") { AppModel.shared.close(window.members(of: group.id).map(\.id), in: window) }
    }
}

// MARK: - Toolbar mode: the repository popover

/// WindowRepoToolbar's list under the repository button: a filter (↑↓ Return, Esc), the
/// repositories by folder group, then Open / Clone / Repositories Window.
struct RepositoryPopover: View {
    let window: WindowModel
    let close: () -> Void
    @Environment(AppModel.self) private var app
    @State private var filter = ""
    @State private var highlighted: UUID?
    @FocusState private var focused: Bool

    var body: some View {
        let items = RepoListItem.items(window, app: app)
        let rows = visibleRows(items)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Icon(Icons.search(1.4), size: 12).foregroundStyle(K.label2)
                TextField("Filter repositories", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { pick(highlighted ?? rows.compactMap(\.item).first?.id) }
                    .onKeyPress(.downArrow) { step(1, rows); return .handled }
                    .onKeyPress(.upArrow) { step(-1, rows); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                Text("↑↓ Return").font(.system(size: 10.5)).foregroundStyle(K.label3)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(K.field)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(K.controlBorder, lineWidth: 0.5)))
            .padding(EdgeInsets(top: 2, leading: 2, bottom: 6, trailing: 2))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        if let group = row.group {
                            HStack(spacing: 6) {
                                Icon(Icons.folderFilled, size: 13).foregroundStyle(group.color.color)
                                Text(group.name)
                                Text("\(row.count)")
                                    .font(KFont.weighted(10.5, 0.35))
                                    .padding(.horizontal, 5)
                                    .frame(minWidth: 18, minHeight: 16)
                                    .background(Capsule().fill(K.chip2))
                            }
                            .font(KFont.weighted(11.5, 0.35))
                            .foregroundStyle(K.label2)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .padding(.top, 4)
                        } else if let item = row.item {
                            PopoverRow(item: item, isHighlighted: item.id == (highlighted ?? window.activeTabID),
                                       isCurrent: item.id == window.activeTabID, tree: row.tree) { pick(item.id) }
                                .onHover { if $0 { highlighted = item.id } }
                        }
                    }
                    if rows.isEmpty {
                        Text("No repository matches “\(filter)”.").font(.system(size: 12)).foregroundStyle(K.label2).padding(12)
                    }
                }
            }
            .frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                MenuLikeButton(title: "Open Repository…", shortcut: "⌘O") { close(); app.showOpenPanel(for: window) }
                MenuLikeButton(title: "Clone Repository…", shortcut: "⇧⌘C") { close(); app.showClone(in: window) }
                MenuLikeButton(title: "Repositories Window", shortcut: "⇧⌘R") { close(); RepositoriesWindowController.shared.show() }
            }
            .padding(.top, 4)
            .overlay(alignment: .top) { K.sep.frame(height: 1) }
            .padding(.top, 4)
        }
        .padding(6)
        .frame(width: 356)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: filter) { highlighted = rows.compactMap(\.item).first?.id }
    }

    struct Row: Identifiable {
        var id: String
        var group: TabGroup?
        var count = 0
        var item: RepoListItem?
        var tree: (color: Color, first: Bool, last: Bool)?
    }

    private func visibleRows(_ items: [UUID: RepoListItem]) -> [Row] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        func matches(_ item: RepoListItem) -> Bool {
            query.isEmpty || item.label.localizedCaseInsensitiveContains(query) || item.tab.name.localizedCaseInsensitiveContains(query)
                || item.branch.localizedCaseInsensitiveContains(query)
        }
        var rows: [Row] = []
        for block in window.blocks {
            switch block {
            case .tab(let tab):
                if let item = items[tab.id], matches(item) { rows.append(Row(id: tab.id.uuidString, item: item)) }
            case .group(let group, let members):
                let kept = members.compactMap { items[$0.id] }.filter(matches)
                guard !kept.isEmpty else { continue }
                rows.append(Row(id: "g" + group.id.uuidString, group: group, count: kept.count))
                for (index, item) in kept.enumerated() {
                    rows.append(Row(id: item.id.uuidString, item: item, tree: (group.color.color, index == 0, index == kept.count - 1)))
                }
            }
        }
        return rows
    }

    private func step(_ delta: Int, _ rows: [Row]) {
        let ids = rows.compactMap(\.item?.id)
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex(of: highlighted ?? window.activeTabID ?? ids[0]) ?? 0
        highlighted = ids[min(max(current + delta, 0), ids.count - 1)]
    }

    private func pick(_ id: UUID?) {
        guard let id else { return }
        window.activate(id)
        close()
    }
}

/// `.rpr`: a repository in the popover (38 pt), ✓ on the current one.
private struct PopoverRow: View {
    let item: RepoListItem
    let isHighlighted: Bool
    let isCurrent: Bool
    let tree: (color: Color, first: Bool, last: Bool)?
    let action: () -> Void

    var body: some View {
        let missing = item.mark == .missing
        Button(action: action) {
            HStack(spacing: 9) {
                RepoAvatar(name: item.tab.name, dimmed: missing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.label).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isHighlighted ? .white : (missing ? K.label3 : K.label))
                    Text(item.branch).font(.system(size: 11))
                        .foregroundStyle(isHighlighted ? .white.opacity(0.82) : (missing ? K.label3 : K.label2))
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                RepoStatusMarks(item: item, selected: isHighlighted)
                Text(isCurrent ? "✓" : "")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isHighlighted ? .white : K.accent)
                    .frame(width: 14)
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isHighlighted ? K.sel : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, tree == nil ? 0 : 18)
        .overlay(alignment: .leading) {
            if let tree {
                TreeLines(color: tree.color, isFirst: tree.first, isLast: tree.last, isSelected: isHighlighted, top: 0, firstTop: 4)
                    .frame(width: 14)
                    .padding(.leading, 18)
            }
        }
        .accessibilityLabel("\(item.tab.name), \(item.summary)")
    }
}

/// `.mi` in the popover's footer: a title and its shortcut.
private struct MenuLikeButton: View {
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                Text(shortcut).font(.system(size: 12)).foregroundStyle(hovering ? .white.opacity(0.85) : K.label3)
            }
            .foregroundStyle(hovering ? .white : K.label)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering ? K.accent : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
