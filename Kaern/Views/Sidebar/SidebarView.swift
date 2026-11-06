import AppKit
import KaernKit
import SwiftUI

/// One row of the sidebar source list.
struct SidebarNode: Identifiable, Hashable {
    enum Kind: Hashable {
        case folder
        case localBranch(Ref)
        case remote(String)
        case remoteBranch(Ref)
        case tag(Ref)
        case stash(Stash)
        /// Pull Requests, under Remotes when the host has an account in Settings › Accounts.
        case pullRequests
        case submodule(Submodule)
        case worktree(Worktree)
    }

    let id: String
    let title: String
    let kind: Kind
    var children: [SidebarNode]?

    var ref: Ref? {
        switch kind {
        case .localBranch(let ref), .remoteBranch(let ref), .tag(let ref): ref
        default: nil
        }
    }
}

enum SidebarTree {
    /// Branch names split on "/" into folders (`feature/x` → feature › x).
    static func branches(_ refs: [Ref], idPrefix: String, title: (Ref) -> String) -> [SidebarNode] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var order: [String] = []
            var leaves: [(String, Ref)] = []
        }
        let root = Folder()
        for ref in refs {
            let components = title(ref).split(separator: "/").map(String.init)
            var folder = root
            for component in components.dropLast() {
                if folder.folders[component] == nil {
                    folder.folders[component] = Folder()
                    folder.order.append(component)
                }
                folder = folder.folders[component]!
            }
            folder.leaves.append((components.last ?? title(ref), ref))
        }
        func build(_ folder: Folder, path: String) -> [SidebarNode] {
            var nodes: [SidebarNode] = []
            for (name, ref) in folder.leaves.sorted(by: { $0.0.localizedStandardCompare($1.0) == .orderedAscending }) {
                let kind: SidebarNode.Kind = ref.kind == .remoteBranch ? .remoteBranch(ref) : .localBranch(ref)
                nodes.append(SidebarNode(id: ref.fullName, title: name, kind: kind))
            }
            for name in folder.order.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                let id = path + "/" + name
                nodes.append(SidebarNode(id: id, title: name, kind: .folder, children: build(folder.folders[name]!, path: id)))
            }
            // Keep well-known branches first, like the design (main, develop, then folders).
            return nodes.sorted { lhs, rhs in
                rank(lhs) < rank(rhs)
            }
        }
        func rank(_ node: SidebarNode) -> Int {
            switch node.kind {
            case .folder: 2
            default: ["main", "master", "develop", "trunk"].contains(node.title) ? 0 : 1
            }
        }
        return build(root, path: idPrefix)
    }
}

struct SidebarView: View {
    @Bindable var model: RepositoryModel
    @State private var selection: String?
    @State private var filter = ""
    @State private var remotesExpanded = true
    @State private var branchesExpanded = true
    @State private var tagsExpanded = false
    @State private var stashesExpanded = true
    /// `nil` until toggled: open when the list is short, folded when it's long.
    @State private var submodulesExpanded: Bool?
    @State private var worktreesExpanded: Bool?
    @FocusState private var isFilterFocused: Bool

    private var filterText: String { filter.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        List(selection: $selection) {
            if filterText.isEmpty {
                fullTree
            } else {
                filteredRows
            }
        }
        .listStyle(.sidebar)
        .environment(\.sidebarRowSize, .small)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let node = node(withID: id) {
                SidebarContextMenu(node: node, model: model)
            }
        } primaryAction: { ids in
            if let id = ids.first, let node = node(withID: id) {
                activate(node)
            }
        }
        .onChange(of: selection) { _, id in
            guard let id, let node = node(withID: id) else { return }
            reveal(node)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            filterField
        }
        .onChange(of: model.filterFocusRequest) { isFilterFocused = true }
        .onChange(of: model.stashView?.stash.id) { _, id in
            // Back from the stash view: let the same stash be picked again.
            if id == nil, selection?.hasPrefix("stash/") == true { selection = nil }
        }
        .onChange(of: model.pullRequests == nil) { _, closed in
            if closed, selection == Self.pullRequestsNode.id { selection = nil }
        }
        .onChange(of: model.sidebarReveal) { _, id in
            guard let id else { return }
            if id.hasPrefix("refs/tags/") { tagsExpanded = true }
            if id.hasPrefix("refs/remotes/") { remotesExpanded = true }
            if id.hasPrefix("refs/heads/") { branchesExpanded = true }
            filter = ""
            selection = id
            model.sidebarReveal = nil
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var fullTree: some View {
        Section(isExpanded: $branchesExpanded) {
            SidebarTreeRows(nodes: branchNodes, model: model)
        } header: {
            Text("Branches")
        }

        if !model.refs.remoteNames.isEmpty {
            Section(isExpanded: $remotesExpanded) {
                SidebarTreeRows(nodes: remoteNodes, model: model)
                if model.pullRequestSource != nil {
                    SidebarRow(node: Self.pullRequestsNode, model: model)
                        .tag(Self.pullRequestsNode.id)
                }
            } header: {
                Text("Remotes")
            }
        }

        if !model.submodules.isEmpty {
            Section(isExpanded: expansion($submodulesExpanded, count: model.submodules.count)) {
                ForEach(model.submodules) { submodule in
                    let node = SidebarNode(id: "submodule/" + submodule.path, title: submodule.name, kind: .submodule(submodule))
                    SidebarRow(node: node, model: model).tag(node.id)
                }
            } header: {
                SectionHeader(title: "Submodules", count: model.submodules.count)
            }
        }

        if model.worktrees.count > 1 {
            Section(isExpanded: expansion($worktreesExpanded, count: model.worktrees.count)) {
                ForEach(model.worktrees) { worktree in
                    let node = SidebarNode(id: "worktree/" + worktree.path, title: model.title(of: worktree), kind: .worktree(worktree))
                    SidebarRow(node: node, model: model).tag(node.id)
                }
            } header: {
                SectionHeader(title: "Worktrees", count: model.worktrees.count)
            }
        }

        Section(isExpanded: $tagsExpanded) {
            ForEach(tagNodes) { node in
                SidebarRow(node: node, model: model).tag(node.id)
            }
        } header: {
            SectionHeader(title: "Tags", count: model.refs.tags.count)
        }

        Section(isExpanded: $stashesExpanded) {
            ForEach(stashNodes) { node in
                SidebarRow(node: node, model: model).tag(node.id)
            }
        } header: {
            SectionHeader(title: "Stashes", count: model.stashes.count)
        }
    }

    @ViewBuilder
    private var filteredRows: some View {
        let matches = allLeaves.filter { leafTitle($0).localizedCaseInsensitiveContains(filterText) }
        Section("Matches") {
            ForEach(matches) { node in
                SidebarRow(node: node, model: model, titleOverride: leafTitle(node)).tag(node.id)
            }
        }
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $filter)
                .textFieldStyle(.plain)
                .focused($isFilterFocused)
                .onExitCommand { filter = ""; isFilterFocused = false }
            if !filter.isEmpty {
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Filter")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
        .padding(10)
        // Opaque, so rows scrolling under the field don't show through its text.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.97))
        .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.5)).frame(height: 1) }
    }

    // MARK: Nodes

    /// Open by default for a few rows; a long list (tools that make a worktree per task) starts folded.
    private func expansion(_ state: Binding<Bool?>, count: Int) -> Binding<Bool> {
        Binding(
            get: { state.wrappedValue ?? (count <= 5) },
            set: { state.wrappedValue = $0 }
        )
    }

    static let pullRequestsNode = SidebarNode(id: "pull-requests", title: String(localized: "Pull Requests"), kind: .pullRequests)

    private var branchNodes: [SidebarNode] { Self.branchNodes(model) }
    private var remoteNodes: [SidebarNode] { Self.remoteNodes(model) }
    private var tagNodes: [SidebarNode] { Self.tagNodes(model) }

    static func branchNodes(_ model: RepositoryModel) -> [SidebarNode] {
        SidebarTree.branches(model.refs.localBranches, idPrefix: "local", title: \.name)
    }

    static func remoteNodes(_ model: RepositoryModel) -> [SidebarNode] {
        model.refs.remoteNames.map { remote in
            let branches = model.refs.remoteBranches.filter { $0.remoteName == remote }
            return SidebarNode(
                id: "remote/" + remote,
                title: remote,
                kind: .remote(remote),
                children: SidebarTree.branches(branches, idPrefix: "remote/" + remote, title: \.branchName)
            )
        }
    }

    static func tagNodes(_ model: RepositoryModel) -> [SidebarNode] {
        model.refs.tags
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
            .map { SidebarNode(id: $0.fullName, title: $0.name, kind: .tag($0)) }
    }

    /// Double-click on the sidebar's edge: wide enough for the longest branch, remote or tag
    /// name that's showing (folders that are open), with its ↑↓ counts.
    static func fittingWidth(for model: RepositoryModel) -> Double {
        let regular = NSFont.systemFont(ofSize: 13)
        let semibold = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let small = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        func measure(_ text: String, _ font: NSFont) -> Double {
            Double((text as NSString).size(withAttributes: [.font: font]).width.rounded(.up))
        }
        // Where a row's title starts at the top level, how far each folder level indents it, and
        // what a row needs after its text (the list's inset and the spacer before the counts).
        let leading = 47.0, indent = 12.0, trailingMargin = 21.0
        var widest = 0.0
        func visit(_ nodes: [SidebarNode], depth: Int) {
            for node in nodes {
                let isCurrent = node.ref.map { $0.kind == .localBranch && $0.isHead } ?? false
                var width = leading + indent * Double(depth) + measure(node.title, isCurrent ? semibold : regular) + trailingMargin
                if let trailing = SidebarRow.trailing(for: node, model: model) {
                    width += 4 + measure(trailing, small)
                }
                widest = max(widest, width)
                if let children = node.children, model.expandedSidebarFolders.contains(node.id) {
                    visit(children, depth: depth + 1)
                }
            }
        }
        visit(branchNodes(model), depth: 0)
        visit(remoteNodes(model), depth: 0)
        visit(tagNodes(model), depth: 0)
        return widest
    }

    private var stashNodes: [SidebarNode] {
        model.stashes.map { SidebarNode(id: "stash/" + $0.id, title: $0.message, kind: .stash($0)) }
    }

    private var allLeaves: [SidebarNode] {
        func leaves(_ nodes: [SidebarNode]) -> [SidebarNode] {
            nodes.flatMap { node in node.children.map(leaves) ?? [node] }
        }
        return leaves(branchNodes) + leaves(remoteNodes) + tagNodes + stashNodes
    }

    private func leafTitle(_ node: SidebarNode) -> String {
        node.ref?.name ?? node.title
    }

    private func node(withID id: String) -> SidebarNode? {
        func find(_ nodes: [SidebarNode]) -> SidebarNode? {
            for node in nodes {
                if node.id == id { return node }
                if let children = node.children, let found = find(children) { return found }
            }
            return nil
        }
        if id == Self.pullRequestsNode.id { return Self.pullRequestsNode }
        if let submodule = model.submodules.first(where: { "submodule/" + $0.path == id }) {
            return SidebarNode(id: id, title: submodule.name, kind: .submodule(submodule))
        }
        if let worktree = model.worktrees.first(where: { "worktree/" + $0.path == id }) {
            return SidebarNode(id: id, title: model.title(of: worktree), kind: .worktree(worktree))
        }
        return find(branchNodes + remoteNodes + tagNodes + stashNodes)
    }

    // MARK: Actions

    /// Selecting a ref selects its commit in the history; a stash shows its changes.
    private func reveal(_ node: SidebarNode) {
        if case .stash(let stash) = node.kind {
            model.showStash(stash)
            return
        }
        if case .pullRequests = node.kind {
            model.showPullRequests()
            return
        }
        model.closeStash()
        model.closePullRequests()
        model.closeFileHistory()
        if case .submodule(let submodule) = node.kind,
           model.status.entries.contains(where: { $0.path == submodule.path }) {
            // A moved or changed submodule: its row in Changes, with what moved.
            model.selection = .workingCopy
            model.selectedFile = .working(submodule.path)
            return
        }
        if let ref = node.ref, model.commit(withID: ref.target) != nil {
            model.selection = .commit(ref.target)
        }
    }

    /// Double-click / Return: check out branches, apply stashes.
    private func activate(_ node: SidebarNode) {
        switch node.kind {
        case .localBranch(let ref), .remoteBranch(let ref):
            if ref.kind == .localBranch, let other = model.worktree(using: ref.name) {
                // Checked out in another working tree: that's where to work on it.
                AppModel.shared.openInNewWindow(URL(filePath: other.path, directoryHint: .isDirectory))
                return
            }
            model.requestSwitch(to: ref)
        case .tag(let ref):
            if let commit = model.commit(withID: ref.target) {
                Task { await model.checkOut(commit: commit) }
            }
        case .stash(let stash):
            Task { await model.apply(stash, pop: false) }
        case .submodule(let submodule):
            if submodule.state == .notInitialized {
                Task { await model.updateSubmodule(submodule) }
            } else if let root = model.repository?.root {
                AppModel.shared.openInNewWindow(root.appending(path: submodule.path, directoryHint: .isDirectory))
            }
        case .worktree(let worktree):
            if !model.isCurrentWorktree(worktree) {
                AppModel.shared.openInNewWindow(URL(filePath: worktree.path, directoryHint: .isDirectory))
            }
        case .folder, .remote, .pullRequests:
            break
        }
    }
}

/// Recursive rows with folders as disclosure groups (expansion is remembered per window).
struct SidebarTreeRows: View {
    let nodes: [SidebarNode]
    let model: RepositoryModel

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: expansion(for: node.id)) {
                    SidebarTreeRows(nodes: children, model: model)
                } label: {
                    SidebarRow(node: node, model: model)
                }
                .tag(node.id)
            } else {
                SidebarRow(node: node, model: model)
                    .tag(node.id)
            }
        }
    }

    private func expansion(for id: String) -> Binding<Bool> {
        Binding(
            get: { model.expandedSidebarFolders.contains(id) },
            set: { expanded in
                if expanded {
                    model.expandedSidebarFolders.insert(id)
                } else {
                    model.expandedSidebarFolders.remove(id)
                }
            }
        )
    }
}

private struct SectionHeader: View {
    let title: LocalizedStringKey
    let count: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .fontWeight(.regular)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct SidebarRow: View {
    let node: SidebarNode
    let model: RepositoryModel
    var titleOverride: String?
    @Environment(\.backgroundProminence) private var prominence

    private var isCurrent: Bool {
        if case .localBranch(let ref) = node.kind { return ref.isHead }
        return false
    }

    /// A branch another working tree has checked out (double-click opens that one).
    private var isInOtherWorktree: Bool {
        if case .localBranch(let ref) = node.kind { return model.worktree(using: ref.name) != nil }
        return false
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(prominence == .increased ? Color.white : (isInOtherWorktree ? Color.secondary : Color.accentColor))
                .frame(width: 16)
            Text(titleOverride ?? node.title)
                .fontWeight(isCurrent ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let graphMark {
                Image(systemName: graphMark)
                    .font(.system(size: 10))
                    .foregroundStyle(prominence == .increased ? Color.white : Color.secondary)
                    .help(graphMark == "eye.slash" ? "Hidden in the graph" : "Shown alone in the graph")
            }
        }
        .opacity(graphMark == "eye.slash" && prominence != .increased ? 0.55 : 1)
        .help(help)
    }

    /// eye.slash: hidden in the graph; eye: the branch the graph shows alone.
    private var graphMark: String? {
        switch node.kind {
        case .localBranch(let ref), .remoteBranch(let ref):
            if model.soloRef == ref.fullName { return "eye" }
            return model.isHiddenInGraph(ref) ? "eye.slash" : nil
        case .remote(let name):
            return model.isRemoteHiddenInGraph(name) ? "eye.slash" : nil
        default:
            return nil
        }
    }

    private var icon: String {
        switch node.kind {
        case .folder: "folder"
        case .localBranch(let ref): ref.isHead ? "checkmark" : "arrow.triangle.branch"
        case .remote: "cloud"
        case .remoteBranch: "arrow.triangle.branch"
        case .tag: "tag"
        case .stash: "archivebox"
        case .pullRequests: "arrow.triangle.pull"
        case .submodule(let submodule): submodule.state == .notInitialized ? "icloud.and.arrow.down" : "folder"
        case .worktree(let worktree): model.isCurrentWorktree(worktree) ? "checkmark" : "folder"
        }
    }

    private var trailing: String? { Self.trailing(for: node, model: model) }

    /// "↑2 ↓1", "gone", or a remote's branch count.
    static func trailing(for node: SidebarNode, model: RepositoryModel) -> String? {
        switch node.kind {
        case .submodule(let submodule):
            switch submodule.state {
            case .notInitialized: return nil
            case .moved:
                // "↑3": commits checked out inside that this repository doesn't record yet.
                guard let distance = model.submoduleDistances[submodule.path] else { return String(localized: "moved") }
                var parts: [String] = []
                if distance.ahead > 0 { parts.append("↑\(distance.ahead)") }
                if distance.behind > 0 { parts.append("↓\(distance.behind)") }
                return parts.isEmpty ? nil : parts.joined(separator: " ")
            case .conflicted: return String(localized: "conflict")
            case .upToDate: return nil
            }
        case .worktree:
            // The branch is in the tooltip: next to a folder name it only got cut off.
            return nil
        case .localBranch(let ref):
            if ref.upstreamGone { return "gone" }
            var parts: [String] = []
            if ref.ahead > 0 { parts.append("↑\(ref.ahead)") }
            if ref.behind > 0 { parts.append("↓\(ref.behind)") }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        case .remote(let name):
            let count = model.refs.remoteBranches.count { $0.remoteName == name }
            return count > 0 ? "\(count)" : nil
        default:
            return nil
        }
    }

    private var help: String {
        switch node.kind {
        case .localBranch(let ref):
            var text = ref.name
            if let upstream = ref.upstream { text += " → \(upstream)" }
            if let other = model.worktree(using: ref.name) {
                text += " · " + String(localized: "checked out in \(model.title(of: other)) (double-click to open it)")
            }
            return text
        case .remoteBranch(let ref), .tag(let ref): return ref.name
        case .stash(let stash): return "\(stash.reference): \(stash.message)"
        case .submodule(let submodule):
            switch submodule.state {
            case .notInitialized: return String(localized: "\(submodule.path) isn't cloned — double-click to clone it")
            case .moved:
                let ahead = model.submoduleDistances[submodule.path]?.ahead ?? 0
                return ahead > 0
                    ? String(localized: "\(submodule.path) · \(ahead) new commits aren't recorded yet")
                    : String(localized: "\(submodule.path) · another commit is checked out than the recorded one")
            default: return String(localized: "\(submodule.path) — double-click to open it in a new window")
            }
        case .worktree(let worktree):
            let checkedOut = worktree.branch ?? worktree.head.map { String($0.prefix(7)) } ?? ""
            return checkedOut.isEmpty ? worktree.path : "\(worktree.path) · \(checkedOut)"
        default: return node.title
        }
    }
}

struct SidebarContextMenu: View {
    let node: SidebarNode
    let model: RepositoryModel

    private var current: String { model.currentBranchTitle }

    var body: some View {
        switch node.kind {
        case .localBranch(let ref):
            if !ref.isHead {
                Button("Check Out “\(ref.name)”") { model.requestSwitch(to: ref) }
                    .disabled(!model.canStartOperation)
                Divider()
                mergeAndRebase(ref)
                Divider()
            }
            Button("New Branch from “\(ref.name)”…") {
                model.sheet = .newBranch(startPoint: ref.name, label: ref.name)
            }
            Button("New Tag on “\(ref.name)”…") {
                model.sheet = .newTag(commitID: ref.target, label: ref.name)
            }
            Button("Rename “\(ref.name)”…") { model.sheet = .renameBranch(ref) }
            Divider()
            Button("Compare with “\(current)”") { Task { await model.compare(ref: ref) } }
                .disabled(ref.isHead || !model.hasHead)
            graphItems(ref, name: ref.name)
            Divider()
            Button("Copy Branch Name") { Pasteboard.copy(ref.name) }
            Divider()
            Button("Delete “\(ref.name)”", role: .destructive) { model.requestDeleteBranch(ref) }
                .disabled(ref.isHead || model.activity != nil)
        case .remoteBranch(let ref):
            Button("Check Out “\(ref.branchName)”") { model.requestSwitch(to: ref) }
                .disabled(!model.canStartOperation)
            Divider()
            mergeAndRebase(ref)
            Divider()
            Button("New Branch from “\(ref.name)”…") {
                model.sheet = .newBranch(startPoint: ref.name, label: ref.name)
            }
            Divider()
            Button("Compare with “\(current)”") { Task { await model.compare(ref: ref) } }
                .disabled(!model.hasHead)
            graphItems(ref, name: ref.name)
            Divider()
            Button("Copy Branch Name") { Pasteboard.copy(ref.name) }
            Divider()
            Button("Delete “\(ref.branchName)” from \(ref.remoteName ?? "Remote")…", role: .destructive) {
                model.confirmation = .deleteRemoteBranch(ref)
            }
            .disabled(model.activity != nil)
        case .tag(let ref):
            Button("Check Out “\(ref.name)”") {
                if let commit = model.commit(withID: ref.target) {
                    Task { await model.checkOut(commit: commit) }
                }
            }
            .disabled(!model.canStartOperation)
            Button("New Branch from “\(ref.name)”…") {
                model.sheet = .newBranch(startPoint: ref.name, label: ref.name)
            }
            if let remote = model.defaultRemote {
                Button("Push “\(ref.name)” to \(remote)") { Task { await model.pushTag(ref) } }
                    .disabled(model.activity != nil)
            }
            Divider()
            Button("Copy Tag Name") { Pasteboard.copy(ref.name) }
            Divider()
            Button("Delete Tag “\(ref.name)”", role: .destructive) { Task { await model.deleteTag(ref) } }
                .disabled(model.activity != nil)
        case .stash(let stash):
            Button("Apply Stash") { Task { await model.apply(stash, pop: false) } }
                .disabled(model.activity != nil || model.operation != nil)
            Button("Pop Stash") { Task { await model.apply(stash, pop: true) } }
                .disabled(model.activity != nil || model.operation != nil)
            Button("Create Branch from Stash…") { model.sheet = .branchFromStash(stash) }
                .disabled(!model.canStartOperation)
            Divider()
            Button("Drop Stash", role: .destructive) { Task { await model.drop(stash) } }
                .disabled(model.activity != nil)
        case .remote(let name):
            Button("Fetch “\(name)”") { Task { await model.fetch() } }
            Divider()
            let hidden = model.isRemoteHiddenInGraph(name)
            Button(hidden ? "Show Branches of “\(name)” in Graph" : "Hide Branches of “\(name)” in Graph") {
                model.setRemoteHiddenInGraph(name, !hidden)
            }
        case .pullRequests:
            Button("Refresh Pull Requests") { model.showPullRequests() }
        case .submodule(let submodule):
            if submodule.state == .notInitialized {
                Button("Clone Submodule") { Task { await model.updateSubmodule(submodule) } }
            } else {
                Button("Open in New Window") {
                    if let root = model.repository?.root { AppModel.shared.openInNewWindow(root.appending(path: submodule.path, directoryHint: .isDirectory)) }
                }
                if submodule.state == .moved {
                    Button("Check Out the Recorded Commit") { Task { await model.updateSubmodule(submodule) } }
                }
            }
            Button("Copy Path") { Pasteboard.copy(submodule.path) }
        case .worktree(let worktree):
            Button("Open in New Window") { AppModel.shared.openInNewWindow(URL(filePath: worktree.path, directoryHint: .isDirectory)) }
                .disabled(model.isCurrentWorktree(worktree))
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: worktree.path)]) }
            Divider()
            // The main working tree (listed first) can't be removed; nor can one that's open.
            let isOpen = AppModel.shared.openWindows.keys.contains { $0.plainPath == URL(filePath: worktree.path).plainPath }
            Button("Remove Worktree") { Task { await model.removeWorktree(worktree) } }
                .disabled(isOpen || worktree.id == model.worktrees.first?.id || model.activity != nil)
                .help(isOpen ? "Close its window first" : "Deletes the folder (git refuses while it has uncommitted changes). The branch stays.")
        case .folder:
            EmptyView()
        }
    }

    /// Show Only in Graph / Hide in Graph (the checked-out branch can't be hidden: HEAD always shows).
    @ViewBuilder
    private func graphItems(_ ref: Ref, name: String) -> some View {
        if model.soloRef == ref.fullName {
            Button("Show All Branches in Graph") { model.showAllBranchesInGraph() }
        } else {
            Button("Show Only “\(name)” in Graph") { model.showOnlyInGraph(ref) }
        }
        let hidden = model.isHiddenInGraph(ref)
        Button(hidden ? "Show “\(name)” in Graph" : "Hide “\(name)” in Graph") { model.setHiddenInGraph(ref, !hidden) }
            .disabled(ref.kind == .localBranch && ref.isHead)
    }

    @ViewBuilder
    private func mergeAndRebase(_ ref: Ref) -> some View {
        Button("Merge “\(ref.name)” into “\(current)”") { Task { await model.merge(ref) } }
            .disabled(!model.canStartOperation || !model.hasHead)
        Button("Rebase “\(current)” onto “\(ref.name)”") { Task { await model.rebase(onto: ref) } }
            .disabled(!model.canStartOperation || !model.hasHead)
    }
}
