import KaernKit
import SwiftUI

/// The repository sidebar (WindowBase): Local, Remote, Tags, Stashes and Worktrees, each with a
/// colored tile, a bold title, a count pill and a collapse chevron. Only branch rows carry
/// icons; a row's icon sits in the tile column and its name lines up with the section title.
struct SidebarView: View {
    @Bindable var repository: RepositoryModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    localSection
                    remoteSection
                    tagSection
                    stashSection
                    worktreeSection
                }
                .padding(EdgeInsets(top: 6, leading: 8, bottom: 4, trailing: 8))
            }
            .scrollIndicators(.automatic)
            .contextClip()
            filterField
                .padding(8)
        }
        .frame(width: KMetric.sidebarWidth)
        .background(K.sidebar)
        .overlay(alignment: .trailing) { K.sep.frame(width: 1) }
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

    private var localSection: some View {
        let locals = repository.refs.localBranches
        let current = repository.currentBranch
        let others = locals.filter { $0.name != current }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let loose = others.filter { !$0.name.contains("/") }
        let folders = Dictionary(grouping: others.filter { $0.name.contains("/") }) { String($0.name.split(separator: "/", maxSplits: 1)[0]) }
        return SidebarSectionView(
            title: "Local", tile: Icons.tileLocal, tileSize: 12, color: Color(nsColor: K.hex(0x2f74e8)),
            count: locals.count, isOpen: isOpen(.local), isFirst: true, toggle: { toggle(.local) }
        ) {
            if let current, matches(current) {
                SidebarRow(icon: Icons.check, iconColor: K.accent, title: current, isCurrent: true,
                           ahead: repository.status.ahead, behind: repository.status.behind)
                    .contextTarget(.branch(current), ring: ContextRing(radius: 6, inset: 0))
            }
            ForEach(loose.filter { matches($0.name) }) { ref in
                branchRow(ref, title: ref.name, nested: false)
            }
            ForEach(folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { folder in
                let members = (folders[folder] ?? []).filter { matches($0.name) }
                if !members.isEmpty {
                    let folded = filter.isEmpty && repository.sidebar.foldedFolders.contains(folder)
                    SidebarRow(icon: Icons.folder, title: folder, meta: "\(members.count)")
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

    private func branchRow(_ ref: Ref, title: String, nested: Bool) -> some View {
        SidebarRow(icon: Icons.rowBranch, title: title, nested: nested, ahead: ref.ahead, behind: ref.behind)
            .help(ref.upstream.map { "\(ref.name) — tracks \($0). Double-click to switch." } ?? "\(ref.name) — double-click to switch.")
            .onTapGesture(count: 2) { repository.from("Sidebar › double-click branch") { repository.switchBranch(ref.name) } }
            .contextTarget(.branch(ref.name), ring: ContextRing(radius: 6, inset: 0))
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

    private var remoteSection: some View {
        let branches = repository.refs.remoteBranches
        let names = Array(Set(repository.remotes.map(\.name) + repository.refs.remoteNames)).sorted { a, b in
            a == "origin" ? true : (b == "origin" ? false : a < b)
        }
        return SidebarSectionView(
            title: "Remote", tile: Icons.tileRemote, tileSize: 13, color: Color(nsColor: K.hex(0x0f8f84)),
            count: branches.count, isOpen: isOpen(.remote), toggle: { toggle(.remote) }
        ) {
            ForEach(names, id: \.self) { remote in
                let members = branches.filter { $0.remoteName == remote && matches($0.name) }
                let open = !filter.isEmpty || repository.sidebar.openRemotes.contains(remote)
                if filter.isEmpty || !members.isEmpty {
                    SidebarRow(chevron: open, title: remote, strong: true, meta: host(of: remote))
                        .onTapGesture { toggleRemote(remote) }
                    if open {
                        ForEach(members.sorted { $0.branchName.localizedStandardCompare($1.branchName) == .orderedAscending }) { ref in
                            SidebarRow(icon: Icons.rowBranch, title: ref.branchName, nested: true)
                                .help("\(ref.name) — double-click to check out a local branch that tracks it.")
                                .onTapGesture(count: 2) { repository.from("Sidebar › double-click remote branch") { repository.checkoutRemoteBranch(ref) } }
                                .contextTarget(.remoteBranch(ref.name), ring: ContextRing(radius: 6, inset: 0))
                        }
                    }
                }
            }
            if names.isEmpty, repository.isReady {
                SidebarRow(title: "No remotes", isPlaceholder: true)
            }
        }
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

    private var tagSection: some View {
        let tags = repository.tags.filter { matches($0.name) }
        let limit = 5
        let shown = repository.sidebar.showsAllTags || !filter.isEmpty ? tags : Array(tags.prefix(limit))
        return SidebarSectionView(
            title: "Tags", tile: Icons.tileTag, tileSize: 12, color: Color(nsColor: K.hex(0xc8620a)),
            count: repository.tags.count, isOpen: isOpen(.tags), toggle: { toggle(.tags) }
        ) {
            ForEach(shown) { tag in
                SidebarRow(title: tag.name, flat: true, meta: tag.date.map { Formatters.shortDate($0) })
                    .contextTarget(.tag(tag.name), ring: ContextRing(radius: 6, inset: 0))
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

    private var stashSection: some View {
        let stashes = repository.stashes.filter { matches($0.message) }
        return SidebarSectionView(
            title: "Stashes", tile: Icons.tileStash, tileSize: 13, color: Color(nsColor: K.hex(0x8a4fd6)),
            count: repository.stashes.count, isOpen: isOpen(.stashes), toggle: { toggle(.stashes) }
        ) {
            ForEach(stashes) { stash in
                // Kaern's own copies (before Discard, Reset Hard, a pick over local changes) go by what
                // they were made for, marked "auto".
                let copy = RepositoryModel.isKaernCopy(stash)
                SidebarRow(title: copy ? RepositoryModel.stashTitle(stash) : stash.message, flat: true,
                           isCurrent: repository.screen == .stash(stash.id),
                           subtitle: ([stash.reference] + (copy ? ["auto"] : []) + [stashDate(stash.date)]).joined(separator: " · "))
                    .contextTarget(.stash(stash.id), ring: ContextRing(radius: 6, inset: 0))
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

    private var worktreeSection: some View {
        let root = repository.repository?.root.path(percentEncoded: false).trimmingTrailingSlash ?? repository.path
        let trees = repository.worktrees.filter { !$0.isBare && (matches($0.name) || matches($0.branch ?? "")) }
        return SidebarSectionView(
            title: "Worktrees", tile: Icons.tileWorktree, tileSize: 13, color: Color(nsColor: K.hex(0x2e8f4a)),
            count: repository.worktrees.filter { !$0.isBare }.count, isOpen: isOpen(.worktrees), toggle: { toggle(.worktrees) }
        ) {
            ForEach(Array(trees.enumerated()), id: \.element.id) { index, tree in
                let path = Formatters.abbreviatedPath(tree.path)
                let isCurrent = canonicalPath(tree.path).trimmingTrailingSlash == canonicalPath(root).trimmingTrailingSlash
                SidebarRow(title: tree.name, flat: true, isCurrent: isCurrent,
                           subtitle: index == 0 || tree.branch == nil ? path : "\(tree.branch ?? "") · \(path)",
                           trailingCheck: isCurrent)
            }
        }
    }

    // MARK: Filter

    private var filterField: some View {
        HStack(spacing: 6) {
            Icon(Icons.search(1.4), size: 13)
                .foregroundStyle(K.label2)
            TextField("Filter branches, tags, stashes", text: $repository.sidebar.filter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(K.label)
            if !repository.sidebar.filter.isEmpty {
                Button {
                    repository.sidebar.filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(K.label3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(K.hover))
    }
}

/// A section (`.ssec`): hairline on top (not the first), header button, rows when open.
private struct SidebarSectionView<Rows: View>: View {
    let title: String
    let tile: SVGIcon
    let tileSize: CGFloat
    let color: Color
    let count: Int
    let isOpen: Bool
    var isFirst = false
    let toggle: () -> Void
    @ViewBuilder var rows: Rows

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 9) {
                    Icon(tile, size: tileSize)
                        .foregroundStyle(.white)
                        .frame(width: 21, height: 21)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color))
                    Text(title)
                        .font(KFont.body650)
                        .foregroundStyle(K.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(count)")
                        .font(KFont.weighted(11, 0.35))
                        .monospacedDigit()
                        .foregroundStyle(K.label2)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 18)
                        .background(Capsule().fill(K.chip2))
                    Icon(Icons.chevronDown, size: 10)
                        .foregroundStyle(K.label2)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                }
                .padding(.leading, 6)
                .padding(.trailing, 8)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? K.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel("\(title), \(count)")
            .accessibilityValue(isOpen ? "expanded" : "collapsed")
            if isOpen {
                rows
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
        .overlay(alignment: .top) {
            if !isFirst { K.sep.frame(height: 1) }
        }
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

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            if let chevron {
                Icon(Icons.chevronDown, size: 9)
                    .foregroundStyle(K.label2)
                    .rotationEffect(.degrees(chevron ? 0 : -90))
                    .frame(width: 13)
                    .padding(.leading, 10 + (nested ? 20 : 0))
                    .padding(.trailing, 13)
            } else if let icon {
                Icon(icon, size: 13)
                    .foregroundStyle(iconColor)
                    .padding(.leading, 10 + (nested ? 20 : 0))
                    .padding(.trailing, 13)
            } else {
                Color.clear.frame(width: flat ? 10 : 36 + (nested ? 20 : 0), height: 1)
            }
            HStack(spacing: 7) {
                if let subtitle {
                    VStack(alignment: .leading, spacing: 2) {
                        titleText
                        Text(subtitle)
                            .font(.system(size: 11))
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
                        .font(.system(size: 11.5))
                        .foregroundStyle(K.label2)
                        .lineLimit(1)
                        .frame(maxWidth: 120, alignment: .trailing)
                        .fixedSize()
                }
                if ahead > 0 { Pill(text: "↑\(ahead)", fill: K.accentSoft, color: K.accentText) }
                if behind > 0 { Pill(text: "↓\(behind)", fill: K.modBg, color: K.mod) }
                if trailingCheck {
                    Icon(Icons.check, size: 13).foregroundStyle(K.accent)
                }
            }
            .padding(.trailing, 8)
        }
        .frame(height: subtitle == nil ? KMetric.sidebarRow : 42)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isCurrent ? K.accentSoft : (hovering && !isPlaceholder ? K.hover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var titleText: some View {
        Text(title)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var font: Font {
        if isLink { return .system(size: 12, weight: .semibold) }
        if isCurrent { return KFont.body650 }
        if strong { return .system(size: 13, weight: .semibold) }
        return .system(size: 13)
    }

    private var color: Color {
        if isLink || isCurrent { return K.accentText }
        if isPlaceholder { return K.label2 }
        return K.label
    }
}

/// Ahead/behind pills (`.pa`, `.pb`).
struct Pill: View {
    let text: String
    let fill: Color
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Capsule().fill(fill))
            .fixedSize()
    }
}
