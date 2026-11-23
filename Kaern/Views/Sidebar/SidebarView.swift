import KaernKit
import SwiftUI

/// The repository sidebar (WindowBase): Local, Remote, Tags, Stashes and Worktrees, each with a
/// colored tile, a bold title, a count pill and a collapse chevron. Only branch rows carry
/// icons; a row's icon sits in the tile column and its name lines up with the section title.
///
/// The headers stay where they are and each open section scrolls on its own, as GitKraken's left
/// panel does: with hundreds of branches, Remote and Tags are still a glance away. While all the
/// rows fit, each section is as tall as its rows. The line between two sections can be dragged
/// (`StackedLists`); Kaern keeps their heights for every window.
struct SidebarView: View {
    @Bindable var repository: RepositoryModel
    /// Sidebar and Toolbar switching: the repository's name and folder on top (no tab names it).
    var showsHeader = false
    /// Opened from the narrow window's rail: this section, unfolded.
    var focus: SidebarSection?

    /// How tall the column of sections is. It starts at the last one's, so a sidebar made again lays its sections
    /// out at once.
    @State private var columnHeight = Self.lastColumnHeight
    private static var lastColumnHeight: CGFloat = 0
    @State private var drag = StackedDrag()
    @AppStorage(StackedWeights.sidebarKey, store: .kaern) private var weights = StackedWeights()

    var body: some View {
        let column = column
        return VStack(spacing: 0) {
            if showsHeader {
                VStack(alignment: .leading, spacing: 1) {
                    Text(repository.name).font(.system(size: z(15), weight: .bold)).lineLimit(1)
                    Text(Formatters.abbreviatedPath(repository.path))
                        .font(.system(size: z(11)))
                        .foregroundStyle(K.label2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: z(12), leading: z(16), bottom: z(8), trailing: z(16)))
            }
            VStack(alignment: .leading, spacing: 0) {
                localSection(column)
                remoteSection(column)
                tagSection(column)
                stashSection(column)
                worktreeSection(column)
                submoduleSection(column)
            }
            .padding(.top, SidebarMetric.columnTop)
            .padding(.bottom, SidebarMetric.columnBottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                columnHeight = height
                Self.lastColumnHeight = height
            }
            filterField
                .padding(z(8))
        }
        .frame(maxWidth: .infinity)
        .background(K.sidebar)
        .overlay(alignment: .trailing) { K.sep.frame(width: 1) }
        // Outside the scroll views, which would cut it off at the sidebar's edge.
        .overlayPreferenceValue(WholeNameKey.self) { SidebarWholeName(shown: $0) }
        .onAppear { unfold(focus) }
        .onChange(of: focus) { _, section in
            withAnimation(.easeOut(duration: 0.15)) { unfold(section) }
        }
    }

    /// The rail's section: open (every header shows, so it's in view).
    private func unfold(_ section: SidebarSection?) {
        guard let section, repository.sidebar.collapsed.contains(section) else { return }
        repository.sidebar.collapsed.remove(section)
    }

    // MARK: Heights

    /// The sections shown (Submodules only in a repository that has some).
    private var shownSections: [SidebarSection] {
        SidebarSection.allCases.filter { $0 != .submodules || !repository.submoduleItems.isEmpty }
    }

    /// The open sections' heights, each scrolling on its own under its header.
    private var column: StackedColumn {
        let shown = shownSections
        let open = shown.filter(isOpen)
        let room = columnHeight - SidebarMetric.columnTop - SidebarMetric.columnBottom - CGFloat(shown.count) * SidebarMetric.sectionChrome
        let column = StackedColumn(ids: open.map(\.rawValue), items: open.map { section in
            StackedLists.Item(content: repository.sidebar.contentHeights[section] ?? 0, row: KMetric.sidebarRow,
                              weight: weights.weight(section.rawValue))
        }, room: room)
        #if DEBUG
        DebugStacks.record("sidebar \(repository.path)", column, shown: shown.map(\.rawValue))
        #endif
        return column
    }

    /// A section's place in the column: its rows' height, the edge above it, and where it says how tall its rows are.
    private func place(_ section: SidebarSection, _ column: StackedColumn) -> SectionPlace {
        SectionPlace(height: column.height(section.rawValue), edge: edge(above: section, in: column), scope: repository.path) { height in
            if repository.sidebar.contentHeights[section] != height { repository.sidebar.contentHeights[section] = height }
        }
    }

    /// The line above `section`, between the nearest open sections above and below it (it can be one of them).
    private func edge(above section: SidebarSection, in column: StackedColumn) -> StackedEdge? {
        let shown = shownSections
        guard let at = shown.firstIndex(of: section), at > 0,
              shown[..<at].contains(where: { column.ids.contains($0.rawValue) }),
              let next = shown[at...].first(where: { column.ids.contains($0.rawValue) }),
              let below = column.ids.firstIndex(of: next.rawValue) else { return nil }
        return StackedEdge(ways: StackedLists.ways(column.heights, items: column.items, edgeAbove: below),
                           label: "Height of \(section.title)", scope: repository.path) { change in
            guard let change else { drag.start = nil; return }
            let start = drag.heights(from: change.start, now: column.heights)
            weights = weights.keeping(column.weights(dragging: below, from: start, by: change.translation), for: column.ids)
        } reset: {
            weights = StackedWeights()
        }
    }

    private var filter: String { repository.sidebar.filter.trimmingCharacters(in: .whitespaces) }

    private func matches(_ text: String) -> Bool {
        filter.isEmpty || text.localizedCaseInsensitiveContains(filter)
    }

    private func isOpen(_ section: SidebarSection) -> Bool {
        !filter.isEmpty || !repository.sidebar.collapsed.contains(section)
    }

    private func toggle(_ section: SidebarSection) {
        withAnimation(.easeOut(duration: 0.15)) {
            if repository.sidebar.collapsed.contains(section) {
                repository.sidebar.collapsed.remove(section)
            } else {
                repository.sidebar.collapsed.insert(section)
            }
        }
    }

    // MARK: Local

    /// The branches by name, loose ones first, then a folder per prefix. The checked-out branch stays
    /// where it sorts (a check and a tint), so checking out another one doesn't move the rows.
    private func localSection(_ column: StackedColumn) -> some View {
        let locals = repository.refs.localBranches.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let current = repository.currentBranch
        let loose = locals.filter { !$0.name.contains("/") }
        let folders = Dictionary(grouping: locals.filter { $0.name.contains("/") }) { String($0.name.split(separator: "/", maxSplits: 1)[0]) }
        return SidebarSectionView(
            title: "Local", tile: Icons.tileLocal, tileSize: 12, color: Color(nsColor: K.hex(0x2f74e8)),
            count: locals.count, isOpen: isOpen(.local), isFirst: true, place: place(.local, column), toggle: { toggle(.local) }
        ) {
            if let current, !locals.contains(where: { $0.name == current }), matches(current) {
                // A branch with no commits yet has no ref to sort with: it goes first.
                currentRow(current, title: current, nested: false)
            }
            ForEach(loose.filter { matches($0.name) }) { ref in
                branchRow(ref, title: ref.name, nested: false)
            }
            ForEach(folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { folder in
                let members = (folders[folder] ?? []).filter { matches($0.name) }
                if !members.isEmpty {
                    let folded = filter.isEmpty && repository.sidebar.foldedFolders.contains(folder)
                    // Folded over the checked-out branch: a check says it's in there.
                    SidebarRow(icon: Icons.folder, title: folder, meta: "\(members.count)",
                               trailingCheck: folded && members.contains { $0.name == current })
                        .onTapGesture { toggleFolder(folder) }
                    if !folded {
                        ForEach(members) { ref in
                            branchRow(ref, title: String(ref.name.dropFirst(folder.count + 1)), nested: true)
                        }
                    }
                }
            }
            if locals.isEmpty, repository.isReady {
                SidebarRow(title: "No branches yet", isPlaceholder: true)
            }
        }
    }

    /// The checked-out branch: ahead and behind come from git status, the freshest count.
    private func currentRow(_ name: String, title: String, nested: Bool) -> some View {
        SidebarRow(icon: Icons.check, iconColor: K.accent, title: title, nested: nested, isCurrent: true,
                   ahead: repository.upstreamDistance.ahead, behind: repository.upstreamDistance.behind)
            .help("\(name) — checked out")
            .contextTarget(.branch(name), ring: ContextRing(radius: z(6), inset: 0))
    }

    @ViewBuilder
    private func branchRow(_ ref: Ref, title: String, nested: Bool) -> some View {
        if ref.name == repository.currentBranch {
            currentRow(ref.name, title: title, nested: nested)
        } else if let tree = repository.otherWorktree(checkingOut: ref.name) {
            // ScreenMarks › 워크트리: checked out in another worktree; a click shows that worktree, a
            // double-click opens it in a tab of its own (the click beside it still shows the page at once).
            SidebarRow(icon: Icons.rowBranch, title: title, nested: nested, ahead: ref.ahead, behind: ref.behind,
                       trailingIcon: Icons.worktreeMark, isOn: repository.selectedWorktree == tree.path)
                .help("\(ref.name) — checked out in the worktree \(tree.name). Click to see it, double-click to open it in its own tab.")
                .onTapGesture { repository.showWorktree(tree) }
                .simultaneousGesture(TapGesture(count: 2).onEnded { repository.openWorktree(tree.path) })
                .contextTarget(.branch(ref.name), ring: ContextRing(radius: z(6), inset: 0))
        } else {
            SidebarRow(icon: Icons.rowBranch, title: title, nested: nested, ahead: ref.ahead, behind: ref.behind)
                .help(ref.upstream.map { "\(ref.name) — tracks \($0). Double-click to switch." } ?? "\(ref.name) — double-click to switch.")
                .onTapGesture(count: 2) { repository.from("Sidebar › double-click branch") { repository.switchBranch(ref.name) } }
                .contextTarget(.branch(ref.name), ring: ContextRing(radius: z(6), inset: 0))
        }
    }

    private func toggleFolder(_ folder: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            if repository.sidebar.foldedFolders.contains(folder) {
                repository.sidebar.foldedFolders.remove(folder)
            } else {
                repository.sidebar.foldedFolders.insert(folder)
            }
        }
    }

    // MARK: Remote

    /// A remote's branches the way ScreenBigRepo lists 1,243 of them: names with a prefix
    /// ("release/2026.11") in a folder per prefix, folded, each showing its first six names and
    /// "N more"; the rest loose. While filtering, folders with matches open and say "1 of 812".
    private func remoteSection(_ column: StackedColumn) -> some View {
        let branches = repository.refs.remoteBranches
        let names = Array(Set(repository.remotes.map(\.name) + repository.refs.remoteNames)).sorted { a, b in
            a == "origin" ? true : (b == "origin" ? false : a < b)
        }
        return SidebarSectionView(
            title: "Remote", tile: Icons.tileRemote, tileSize: 13, color: Color(nsColor: K.hex(0x0f8f84)),
            count: branches.count, isOpen: isOpen(.remote), place: place(.remote, column), toggle: { toggle(.remote) }
        ) {
            ForEach(names, id: \.self) { remote in
                let all = branches.filter { $0.remoteName == remote }
                let members = filter.isEmpty ? all : all.filter { matches($0.name) }
                let open = !filter.isEmpty || repository.sidebar.openRemotes.contains(remote)
                if filter.isEmpty || !members.isEmpty {
                    SidebarRow(chevron: open, title: remote, strong: true, meta: host(of: remote))
                        .onTapGesture { toggleRemote(remote) }
                    if open {
                        remoteRows(remote: remote, all: all, members: members)
                    }
                }
            }
            if names.isEmpty, repository.isReady {
                // ScreenInit: a repository that's only on this Mac.
                SidebarRow(title: "No remotes yet", flat: true, isPlaceholder: true)
                SidebarRow(title: "Add Remote…", flat: true, isLink: true)
                    .onTapGesture { repository.sheet = .repositorySettings }
                    .accessibilityAddTraits(.isButton)
            }
        }
    }

    /// Folders first (by prefix), then the loose names, like Local.
    @ViewBuilder
    private func remoteRows(remote: String, all: [Ref], members: [Ref]) -> some View {
        let groups = RemoteFolders(members)
        let totals = RemoteFolders.counts(all)
        ForEach(groups.folders, id: \.name) { folder in
            let key = "\(remote)/\(folder.name)"
            let total = totals[folder.name] ?? folder.branches.count
            let open = !filter.isEmpty || repository.sidebar.openRemoteFolders.contains(key)
            RemoteFolderRow(title: folder.name, open: open,
                            count: filter.isEmpty || folder.branches.count == total
                                ? total.formatted() : "\(folder.branches.count.formatted()) of \(total.formatted())")
                .onTapGesture { toggleRemoteFolder(key) }
            if open {
                let limit = RemoteFolders.firstNames + (repository.sidebar.remoteFolderExtra[key] ?? 0)
                ForEach(folder.branches.prefix(limit)) { ref in
                    remoteBranchRow(ref, title: String(ref.branchName.dropFirst(folder.name.count + 1)), depth: 2)
                }
                let rest = folder.branches.count - limit
                if rest > 0 {
                    // "35 more — type to filter": a click shows more, then more as the list scrolls to them.
                    // (Scrolled into view, not `onAppear`: the rows aren't lazy, so that ran whenever
                    // the sidebar was made again, a tab switch included, and never on scrolling.)
                    SidebarRow(title: rest.formatted() + " more" + (filter.isEmpty ? " — type to filter" : ""),
                               depth: 2, isLink: true)
                        .onTapGesture { showMore(key) }
                        .onScrollVisibilityChange(threshold: 0.5) { visible in
                            if visible, repository.sidebar.remoteFolderExtra[key] != nil { showMore(key) }
                        }
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
        ForEach(groups.loose) { ref in
            remoteBranchRow(ref, title: ref.branchName, depth: 1)
        }
    }

    private func remoteBranchRow(_ ref: Ref, title: String, depth: Int) -> some View {
        SidebarRow(icon: Icons.rowBranch, title: title, depth: depth)
            .help("\(ref.name) — click to show it in the graph, double-click to check out a local branch that tracks it.")
            .onTapGesture(count: 2) { repository.from("Sidebar › double-click remote branch") { repository.checkoutRemoteBranch(ref) } }
            .onTapGesture { repository.showRemoteBranch(ref) }
            .contextTarget(.remoteBranch(ref.name), ring: ContextRing(radius: z(6), inset: 0))
    }

    private func toggleRemoteFolder(_ key: String) {
        guard filter.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            if repository.sidebar.openRemoteFolders.contains(key) {
                repository.sidebar.openRemoteFolders.remove(key)
            } else {
                repository.sidebar.openRemoteFolders.insert(key)
            }
        }
    }

    private func showMore(_ key: String) {
        repository.sidebar.remoteFolderExtra[key, default: 0] += RemoteFolders.batch
    }

    private func toggleRemote(_ remote: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            if repository.sidebar.openRemotes.contains(remote) {
                repository.sidebar.openRemotes.remove(remote)
            } else {
                repository.sidebar.openRemotes.insert(remote)
            }
        }
    }

    /// "GitHub", "GitLab", "Bitbucket" or the host name.
    private func host(of remote: String) -> String? {
        guard let info = repository.remotes.first(where: { $0.name == remote }), let url = RemoteURL(info.fetchURL) else { return nil }
        let host = url.host.lowercased()
        if host.contains("github") { return "GitHub" }
        if host.contains("gitlab") { return "GitLab" }
        if host.contains("bitbucket") { return "Bitbucket" }
        return url.host
    }

    // MARK: Tags

    private func tagSection(_ column: StackedColumn) -> some View {
        let tags = repository.tags.filter { matches($0.name) }
        let limit = 5
        let shown = repository.sidebar.showsAllTags || !filter.isEmpty ? tags : Array(tags.prefix(limit))
        return SidebarSectionView(
            title: "Tags", tile: Icons.tileTag, tileSize: 12, color: Color(nsColor: K.hex(0xc8620a)),
            count: repository.tags.count, isOpen: isOpen(.tags), place: place(.tags, column), toggle: { toggle(.tags) }
        ) {
            ForEach(shown) { tag in
                SidebarRow(title: tag.name, flat: true, meta: tag.date.map { Formatters.shortDate($0) })
                    .contextTarget(.tag(tag.name), ring: ContextRing(radius: z(6), inset: 0))
            }
            if tags.count > limit, filter.isEmpty {
                SidebarRow(title: repository.sidebar.showsAllTags ? "Show Fewer" : "Show \(tags.count - limit) More", flat: true, isLink: true)
                    .onTapGesture { repository.sidebar.showsAllTags.toggle() }
            }
            if repository.tags.isEmpty, repository.isReady {
                SidebarRow(title: "No tags", flat: true, isPlaceholder: true)
            }
        }
    }

    // MARK: Stashes

    private func stashSection(_ column: StackedColumn) -> some View {
        let stashes = repository.stashes.filter { matches($0.message) }
        return SidebarSectionView(
            title: "Stashes", tile: Icons.tileStash, tileSize: 13, color: Color(nsColor: K.hex(0x8a4fd6)),
            count: repository.stashes.count, isOpen: isOpen(.stashes), place: place(.stashes, column), toggle: { toggle(.stashes) }
        ) {
            ForEach(stashes) { stash in
                // Kaern's own copies (before Discard, Reset Hard, a pick over local changes) go by what
                // they were made for, marked "auto".
                let copy = RepositoryModel.isKaernCopy(stash)
                SidebarRow(title: copy ? RepositoryModel.stashTitle(stash) : stash.message, flat: true,
                           isCurrent: repository.screen == .stash(stash.id),
                           subtitle: ([stash.reference] + (copy ? ["auto"] : []) + [stashDate(stash.date)]).joined(separator: " · "))
                    .contextTarget(.stash(stash.id), ring: ContextRing(radius: z(6), inset: 0))
                    .onTapGesture { repository.openStash(stash.id) }
                    .accessibilityAddTraits(.isButton)
            }
            if repository.stashes.isEmpty, repository.isReady {
                SidebarRow(title: "No stashes", flat: true, isPlaceholder: true)
            }
        }
    }

    /// "just now", "3 hours ago" within a day, then "Sep 26".
    private func stashDate(_ date: Date) -> String {
        Date.now.timeIntervalSince(date) < 86_400 ? Formatters.shortRelative(date) : Formatters.shortDate(date)
    }

    // MARK: Worktrees

    /// ScreenMarks › 워크트리: this window's working tree ("This window · ~/Developer/powerlens"),
    /// the others with their branch and changes (a dot when there are some), then Add Worktree….
    private func worktreeSection(_ column: StackedColumn) -> some View {
        let trees = repository.worktrees.filter { !$0.isBare && (matches($0.name) || matches($0.branch ?? "")) }
        return SidebarSectionView(
            title: "Worktrees", tile: Icons.tileWorktree, tileSize: 13, color: Color(nsColor: K.hex(0x2e8f4a)),
            count: repository.worktrees.filter { !$0.isBare }.count, isOpen: isOpen(.worktrees), place: place(.worktrees, column),
            toggle: { toggle(.worktrees) }
        ) {
            ForEach(trees) { tree in
                WorktreeSidebarRow(repository: repository, tree: tree)
            }
            if filter.isEmpty, repository.isReady {
                SidebarRow(title: "Add Worktree…", flat: true, isLink: true)
                    .onTapGesture { repository.sheet = .addWorktree(nil) }
                    .accessibilityAddTraits(.isButton)
            }
        }
    }

    // MARK: Submodules

    @ViewBuilder
    private func submoduleSection(_ column: StackedColumn) -> some View {
        if !repository.submoduleItems.isEmpty {
            let tile = SidebarSection.submodules.tile
            SidebarSectionView(
                title: "Submodules", tile: tile.icon, tileSize: tile.size, color: tile.color,
                count: repository.submoduleItems.count, isOpen: isOpen(.submodules), place: place(.submodules, column),
                toggle: { toggle(.submodules) }
            ) {
                ForEach(repository.submoduleItems.filter { matches($0.path) }) { item in
                    SubmoduleSidebarRow(item: item, repository: repository)
                }
            }
        }
    }

    // MARK: Filter

    /// Everything the filter finds, in every section.
    private var matchCount: Int {
        repository.refs.localBranches.count { matches($0.name) }
            + repository.refs.remoteBranches.count { matches($0.name) }
            + repository.tags.count { matches($0.name) }
            + repository.stashes.count { matches($0.message) }
            + repository.worktrees.count { !$0.isBare && (matches($0.name) || matches($0.branch ?? "")) }
            + repository.submoduleItems.count { matches($0.path) }
    }

    private var filterField: some View {
        HStack(spacing: z(6)) {
            Icon(Icons.search(1.4), size: 13)
                .foregroundStyle(K.label2)
            TextField("Filter branches, tags, stashes", text: $repository.sidebar.filter)
                .textFieldStyle(.plain)
                .font(.system(size: z(12)))
                .foregroundStyle(K.label)
            if !repository.sidebar.filter.isEmpty {
                // ScreenBigRepo: "43 matches".
                Text(Formatters.count(matchCount, "match", "matches"))
                    .font(.system(size: z(11.5)))
                    .foregroundStyle(K.label2)
                    .lineLimit(1)
                    .fixedSize()
                Button {
                    repository.sidebar.filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(K.label3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, z(9))
        .frame(height: z(28))
        .background(RoundedRectangle(cornerRadius: z(8), style: .continuous).fill(K.hover))
    }
}

/// `.si.two`: a worktree — its folder's name, then "This window · ~/Developer/powerlens" for this
/// tab's, or "hotfix/0.9.3.1 · 2 changes" with an orange dot. A click shows the worktree's page.
private struct WorktreeSidebarRow: View {
    let repository: RepositoryModel
    let tree: Worktree
    @State private var hovering = false

    var body: some View {
        let isCurrent = repository.isCurrent(tree)
        let isOn = repository.selectedWorktree == tree.path
        let changes = repository.worktreeChanges[tree.path] ?? 0
        let highlighted = isCurrent && !showsOther
        HStack(spacing: z(8)) {
            VStack(alignment: .leading, spacing: z(2)) {
                Text(tree.name)
                    .font(highlighted ? KFont.body650 : .system(size: z(13)))
                    .foregroundStyle(highlighted ? K.accentText : K.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle(isCurrent: isCurrent, changes: changes))
                    .font(.system(size: z(11)))
                    .foregroundStyle(K.label2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !isCurrent, changes > 0 {
                Circle().fill(K.warn).frame(width: z(7), height: z(7)).help("Uncommitted changes")
            }
            if isCurrent {
                Icon(Icons.check, size: 13).foregroundStyle(K.accent)
            }
        }
        .padding(.leading, SidebarMetric.flatLeading)
        .padding(.trailing, z(8))
        .frame(height: z(42))
        .background(
            RoundedRectangle(cornerRadius: z(6), style: .continuous)
                .fill(highlighted ? K.accentSoft : (isOn || hovering ? K.hover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { repository.showWorktree(isCurrent ? nil : tree) }
        // Beside the click: its page shows at once, and a second click opens it in its own tab.
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !isCurrent { repository.openWorktree(tree.path) } })
        .contextTarget(.worktree(tree.path), ring: ContextRing(radius: z(6), inset: 0))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .help(isCurrent ? tree.path : "\(tree.path) — double-click to open it in its own tab")
    }

    /// Another worktree's page is open: this tab's row isn't highlighted (the board's 워크트리 state).
    private var showsOther: Bool { repository.selectedWorktree != nil }

    private func subtitle(isCurrent: Bool, changes: Int) -> String {
        if isCurrent { return "This window · " + Formatters.abbreviatedPath(tree.path) }
        let place = tree.branch ?? tree.head.map { "detached at \($0.prefix(7))" } ?? Formatters.abbreviatedPath(tree.path)
        return changes > 0 ? "\(place) · \(Formatters.count(changes, "change", "changes"))" : place
    }
}

/// `.si.subrow`: a submodule, where it points ("2.6.4 → 2.7.0 · 3 new commits"), Initialize when it isn't
/// cloned, and a dot: orange moved, green up to date, hollow not initialized. A moved one opens its page in
/// Review.
private struct SubmoduleSidebarRow: View {
    let item: SubmoduleItem
    let repository: RepositoryModel
    @State private var hovering = false

    private var isOn: Bool {
        repository.selection == .workingCopy && repository.review.map { !$0.showsAllFiles && $0.path == item.path } == true
    }

    var body: some View {
        HStack(spacing: z(8)) {
            VStack(alignment: .leading, spacing: z(2)) {
                Text(item.path)
                    .font(.system(size: z(13)))
                    .foregroundStyle(K.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.detail)
                    .font(.system(size: z(11)))
                    .foregroundStyle(K.label2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if item.state == .notInitialized {
                GhostButton(title: "Initialize") {
                    repository.from("Sidebar") { repository.initializeSubmodule(item.path) }
                }
                .disabled(repository.activity != nil)
            }
            dot
        }
        .padding(.leading, SidebarMetric.flatLeading)
        .padding(.trailing, z(8))
        .frame(height: z(42))
        .background(
            RoundedRectangle(cornerRadius: z(6), style: .continuous)
                .fill(isOn ? K.accentSoft : (hovering ? K.hover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard item.state == .moved else { return }
            repository.clearPicks()
            repository.selection = .workingCopy
            repository.review = ReviewState(showsAllFiles: false, path: item.path)
        }
        .help(item.path)
    }

    @ViewBuilder
    private var dot: some View {
        switch item.state {
        case .notInitialized:
            Circle().strokeBorder(K.label3, lineWidth: 1.2).frame(width: z(7), height: z(7))
        case .moved:
            Circle().fill(K.mod).frame(width: z(7), height: z(7))
        case .conflicted:
            Circle().fill(K.err).frame(width: z(7), height: z(7))
        case .upToDate:
            Circle().fill(K.ok).frame(width: z(7), height: z(7))
        }
    }
}

/// Where sidebar rows put their icon and title. Every title sits `gap` after its icon, and each level in (a branch in a
/// folder, a remote's folders and branches, a branch in a remote's folder) moves its icon `step` right of its parent's.
private enum SidebarMetric {
    /// Left of a section's tile (21 pt).
    static var tileLeading: CGFloat { z(4) }
    /// From a tile or an icon to its title.
    static var gap: CGFloat { z(3) }
    /// Left of a top-level row's 13 pt icon or chevron: centered under the section's tile.
    static let iconLeading: CGFloat = tileLeading + (21 - 13) / 2
    /// Where a top-level row's title starts.
    static let rowTitleX: CGFloat = iconLeading + 13 + gap
    /// Rows without an icon (Tags, Stashes, Worktrees) start where the icons do.
    static let flatLeading: CGFloat = iconLeading
    /// One level in.
    static var step: CGFloat { z(10) }
    /// Above the first section and below the last one.
    static var columnTop: CGFloat { z(6) }
    static var columnBottom: CGFloat { z(4) }
    /// What a section takes besides its rows: its header and the space above and below.
    static var sectionChrome: CGFloat { z(4) + z(32) + z(6) }
    /// The sidebar's sides: the headers and rows sit this far in.
    static var inset: CGFloat { z(8) }
}

/// Where a section is in the sidebar's column (`SidebarView.place`).
private struct SectionPlace {
    /// Its rows' height when it's open.
    let height: CGFloat
    /// The line above it, when it can be dragged.
    let edge: StackedEdge?
    /// Debug builds: whose section it is (the repository's folder), for `DebugStacks.frames`.
    let scope: String
    /// Told how tall all its rows are.
    let content: (CGFloat) -> Void
}

/// A section (`.ssec`): hairline on top (not the first), header button, rows when open, in a scroll
/// view of their own as tall as the column gives them (`SectionPlace`).
private struct SidebarSectionView<Rows: View>: View {
    let title: String
    let tile: SVGIcon
    let tileSize: CGFloat
    let color: Color
    let count: Int
    let isOpen: Bool
    var isFirst = false
    let place: SectionPlace
    let toggle: () -> Void
    @ViewBuilder var rows: Rows

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: SidebarMetric.gap) {
                    Icon(tile, size: tileSize)
                        .foregroundStyle(.white)
                        .frame(width: z(21), height: z(21))
                        .background(RoundedRectangle(cornerRadius: z(6), style: .continuous).fill(color))
                    Text(title)
                        .font(KFont.body650)
                        .foregroundStyle(K.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(count)")
                        .font(KFont.weighted(11, 0.35))
                        .monospacedDigit()
                        .foregroundStyle(K.label2)
                        .padding(.horizontal, z(6))
                        .frame(minWidth: z(20), minHeight: z(18))
                        .background(Capsule().fill(K.chip2))
                    Icon(Icons.chevronDown, size: 10)
                        .foregroundStyle(K.label2)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                }
                .padding(.leading, SidebarMetric.tileLeading)
                .padding(.trailing, z(8))
                .frame(height: z(32))
                .background(RoundedRectangle(cornerRadius: z(7), style: .continuous).fill(hovering ? K.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel("\(title), \(count)")
            .accessibilityValue(isOpen ? "expanded" : "collapsed")
            .padding(.horizontal, SidebarMetric.inset)
            if isOpen {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        rows
                    }
                    .padding(.horizontal, SidebarMetric.inset)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { place.content($0) }
                }
                // Rows that all fit don't move under the wheel.
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: place.height)
                .contextClip()
                .debugStackFrame("\(place.scope) sidebar \(title)")
            }
        }
        .padding(.top, z(4))
        .padding(.bottom, z(6))
        .overlay(alignment: .top) {
            if !isFirst { K.sep.frame(height: 1).padding(.horizontal, SidebarMetric.inset) }
        }
        .overlay(alignment: .top) { place.edge }
    }
}

/// A sidebar row (`.si`): 28 pt (42 with a second line), 6 pt hover plate.
private struct SidebarRow: View {
    var icon: SVGIcon?
    var iconColor: Color = K.label2
    /// A disclosure chevron in the icon column instead of an icon (remotes).
    var chevron: Bool?
    let title: String
    var nested = false
    /// 1 is `nested`; 2 sits inside a remote branch folder (under its folder icon).
    var depth = 0
    /// Rows without an icon start in the icon column (Tags, Stashes, Worktrees).
    var flat = false
    var strong = false
    var isCurrent = false
    var isLink = false
    var isPlaceholder = false
    var meta: String?
    var subtitle: String?
    var ahead = 0
    var behind = 0
    var trailingCheck = false
    /// `.wtin`: a mark at the end (a branch checked out in another worktree).
    var trailingIcon: SVGIcon?
    /// `.si.on`: the row whose page the right panel shows.
    var isOn = false
    /// The row drawn again as wide as its whole name (`SidebarWholeName`): a picture, the pointer never reaches it.
    var isWholeName = false

    @State private var hovering = false
    /// The name is cut short ("…") and the whole row is in view, both looked at only while the pointer is on the row.
    @State private var nameIsCut = false
    @State private var isInView = false
    /// The pointer has rested on the row.
    @State private var hasRested = false
    @State private var restTimer: Task<Void, Never>?

    /// How long the pointer rests on a row before a cut name unfolds: longer than it takes to pass over the row
    /// on the way down the list.
    private static let rest = Duration.milliseconds(400)

    var body: some View {
        HStack(spacing: 0) {
            if let chevron {
                Icon(Icons.chevronDown, size: 9)
                    .foregroundStyle(K.label2)
                    .rotationEffect(.degrees(chevron ? 0 : -90))
                    .frame(width: z(13))
                    .padding(.leading, SidebarMetric.iconLeading + indent)
                    .padding(.trailing, SidebarMetric.gap)
            } else if let icon {
                Icon(icon, size: 13)
                    .foregroundStyle(iconColor)
                    .padding(.leading, SidebarMetric.iconLeading + indent)
                    .padding(.trailing, SidebarMetric.gap)
            } else {
                Color.clear.frame(width: flat ? SidebarMetric.flatLeading : SidebarMetric.rowTitleX + indent, height: 1)
            }
            HStack(spacing: z(7)) {
                if let subtitle {
                    VStack(alignment: .leading, spacing: z(2)) {
                        titleText
                        Text(subtitle)
                            .font(.system(size: z(11)))
                            .foregroundStyle(K.label2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    titleText
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let meta {
                    Text(meta)
                        .font(.system(size: z(11.5)))
                        .foregroundStyle(K.label2)
                        .lineLimit(1)
                        .frame(maxWidth: z(120), alignment: .trailing)
                        .fixedSize()
                }
                if ahead > 0 { Pill(text: "↑\(ahead)", fill: K.accentSoft, color: K.accentText) }
                if behind > 0 { Pill(text: "↓\(behind)", fill: K.modBg, color: K.mod) }
                if let trailingIcon {
                    Icon(trailingIcon, size: 12).foregroundStyle(K.accentText)
                }
                if trailingCheck {
                    Icon(Icons.check, size: 13).foregroundStyle(K.accent)
                }
            }
            .padding(.trailing, z(8))
        }
        .frame(height: subtitle == nil ? KMetric.sidebarRow : z(42))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: z(6), style: .continuous)
                .fill(isCurrent ? K.accentSoft : (isOn || (hovering && !isPlaceholder) ? K.hover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            rest(inside)
        }
        .background {
            if measuresName {
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: Self.isInView(proxy), initial: true) { _, inView in isInView = inView }
                        // Scrolled under the pointer: the name folds, and unfolds after another rest.
                        .onChange(of: proxy.frame(in: .global).minY) { if hovering { rest(true) } }
                }
            }
        }
        .background {
            if showsWholeName {
                Color.clear.anchorPreference(key: WholeNameKey.self, value: .bounds) {
                    WholeNameRow(row: whole, bounds: $0)
                }
            }
        }
    }

    /// The driver unfolded this row's name (debug builds: `wholeName <row title>`).
    private var driverOpened: Bool {
        #if DEBUG
        DebugWholeName.shared.open == title
        #else
        false
        #endif
    }

    private var measuresName: Bool { !isWholeName && (hovering || driverOpened) }
    private var showsWholeName: Bool { !isWholeName && nameIsCut && isInView && (hasRested || driverOpened) }

    private var whole: SidebarRow {
        var row = self
        row.isWholeName = true
        return row
    }

    /// The name unfolds once the pointer has rested on the row and folds when it leaves.
    private func rest(_ inside: Bool) {
        restTimer?.cancel()
        if hasRested { hasRested = false }
        guard inside, !isWholeName else { return }
        #if DEBUG
        // A test instance's window lies wherever the real pointer happens to be: there only the driver
        // unfolds a name (`wholeName`).
        if TestSession.stem != nil { return }
        #endif
        restTimer = Task {
            try? await Task.sleep(for: Self.rest)
            guard !Task.isCancelled else { return }
            hasRested = true
        }
    }

    /// All of the row is inside what its scroll view shows.
    private static func isInView(_ proxy: GeometryProxy) -> Bool {
        guard let visible = proxy.bounds(of: .scrollView) else { return true }
        return visible.minY <= 0.5 && visible.maxY >= proxy.size.height - 0.5
    }

    private var indent: CGFloat {
        switch max(depth, nested ? 1 : 0) {
        case 0: 0
        case 1: SidebarMetric.step
        default: RemoteFolderRow.childIndent
        }
    }

    private var titleText: some View {
        Text(title)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .background {
                if measuresName { CutReader(whole: Text(title).font(font)) { nameIsCut = $0 } }
            }
    }

    private var font: Font {
        if isLink { return .system(size: z(12), weight: .semibold) }
        if isCurrent { return KFont.body650 }
        if strong { return .system(size: z(13), weight: .semibold) }
        return .system(size: z(13))
    }

    private var color: Color {
        if isLink || isCurrent { return K.accentText }
        if isPlaceholder { return K.label2 }
        return K.label
    }
}

/// The row whose name is shown whole, and where it is.
private struct WholeNameRow {
    let row: SidebarRow
    let bounds: Anchor<CGRect>
}

/// Set by the one row the pointer rests on, while its name is cut short (`SidebarRow.showsWholeName`).
private struct WholeNameKey: PreferenceKey {
    static var defaultValue: WholeNameRow? { nil }

    static func reduce(value: inout WholeNameRow?, nextValue: () -> WholeNameRow?) {
        value = nextValue() ?? value
    }
}

/// A name the sidebar cuts short, whole: the row again, as wide as it needs, lying on the row and on over
/// what is right of the sidebar, on the plate the history's list of labels has. The way Finder shows a cut
/// name. It's a picture: the pointer and clicks go to what is under it, so the row stays the row.
private struct SidebarWholeName: View {
    let shown: WholeNameRow?

    var body: some View {
        GeometryReader { proxy in
            if let shown {
                let frame = proxy[shown.bounds]
                shown.row
                    // As wide as the whole name needs, and never narrower than the row it lies on. (The other
                    // way round, the frame would take only the sidebar's width and the plate with it.)
                    .frame(minWidth: frame.width, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    // Solid: what is under it doesn't show through.
                    .background {
                        RoundedRectangle(cornerRadius: z(6), style: .continuous)
                            .fill(K.popSolid)
                            .shadow(color: K.shadowPop, radius: z(8), y: 6)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: z(6), style: .continuous)
                            .strokeBorder(K.popRing, lineWidth: 0.5)
                    }
                    .debugWholeNameFrame()
                    .offset(x: frame.minX, y: frame.minY)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        // The row itself is what VoiceOver reads.
        .accessibilityHidden(true)
        .animation(.easeOut(duration: 0.12), value: shown != nil)
    }
}

#if DEBUG
/// Debug builds: the title of the row whose name the driver unfolded (`wholeName <row title>|off`; a test window
/// in the background gets no hover), and where the unfolded row is, in window points (top-left origin), for the
/// driver's `targetFrame wholeName row`.
@Observable
final class DebugWholeName {
    static let shared = DebugWholeName()
    var open: String?
    @ObservationIgnored var frame: CGRect?
}

extension View {
    /// Debug builds: tells the driver where the unfolded row is (`DebugWholeName.frame`).
    func debugWholeNameFrame() -> some View {
        modifier(DebugFrameReport(key: "wholeName") { DebugWholeName.shared.frame = $0 })
    }
}
#else
extension View {
    func debugWholeNameFrame() -> some View { self }
}
#endif

/// A remote branch prefix folder (`.si.ind.rdir`): chevron, folder icon, name and how many
/// branches it holds ("41", or "1 of 812" while filtering).
private struct RemoteFolderRow: View {
    let title: String
    let open: Bool
    let count: String
    @State private var hovering = false

    /// The chevron, one level in from the remote's.
    static let chevronLeading = SidebarMetric.iconLeading + SidebarMetric.step
    /// Where the rows inside start their icon: one level in from this row's folder icon, as in a local folder.
    static let childIndent = chevronLeading + 13 + 4 + SidebarMetric.step - SidebarMetric.iconLeading

    var body: some View {
        HStack(spacing: 0) {
            Icon(Icons.chevronDown, size: 9)
                .foregroundStyle(K.label2)
                .rotationEffect(.degrees(open ? 0 : -90))
                .frame(width: z(13))
                .padding(.leading, Self.chevronLeading)
                .padding(.trailing, z(4))
            Icon(Icons.folder, size: 13)
                .foregroundStyle(K.label2)
                .padding(.trailing, SidebarMetric.gap)
            Text(title)
                .font(.system(size: z(13)))
                .foregroundStyle(K.label)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(count)
                .font(.system(size: z(11.5)))
                .monospacedDigit()
                .foregroundStyle(K.label2)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, z(8))
        }
        .frame(height: KMetric.sidebarRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: z(6), style: .continuous).fill(hovering ? K.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(open ? "expanded" : "collapsed")
    }
}

/// One remote's branches split into prefix folders ("release/…") and loose names, sorted the
/// way Finder sorts.
struct RemoteFolders {
    struct Folder {
        let name: String
        let branches: [Ref]
    }

    /// Names a folder shows before "N more".
    static let firstNames = 6
    /// How many more each "N more" (or scrolling to it) shows.
    static let batch = 100

    let folders: [Folder]
    let loose: [Ref]

    init(_ refs: [Ref]) {
        let sorted = refs.sorted { $0.branchName.localizedStandardCompare($1.branchName) == .orderedAscending }
        var byPrefix: [String: [Ref]] = [:]
        var loose: [Ref] = []
        for ref in sorted {
            if let prefix = Self.prefix(of: ref) { byPrefix[prefix, default: []].append(ref) } else { loose.append(ref) }
        }
        folders = byPrefix.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { Folder(name: $0, branches: byPrefix[$0] ?? []) }
        self.loose = loose
    }

    /// Branches per prefix (the folder's count when the filter shows only some).
    static func counts(_ refs: [Ref]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for ref in refs {
            if let prefix = prefix(of: ref) { counts[prefix, default: 0] += 1 }
        }
        return counts
    }

    private static func prefix(of ref: Ref) -> String? {
        let name = ref.branchName
        guard let slash = name.firstIndex(of: "/"), slash != name.startIndex else { return nil }
        return String(name[..<slash])
    }
}

/// Ahead/behind pills (`.pa`, `.pb`).
struct Pill: View {
    let text: String
    let fill: Color
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: z(10.5), weight: .bold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, z(6))
            .frame(height: z(17))
            .background(Capsule().fill(fill))
            .fixedSize()
    }
}
