import AppKit
import KaernKit
import SwiftUI

/// What a right-click is on.
enum ContextTarget: Hashable {
    case commit(String)
    case branch(String)
    /// A remote-tracking branch by its short name ("origin/feature/x").
    case remoteBranch(String)
    case tag(String)
    /// A working-copy file in the Unstaged or Staged list.
    case file(path: String, staged: Bool)
    case stash(String)
    /// A file in a commit's details.
    case commitFile(path: String, commit: String)
    /// A block of lines in Blame (its commit).
    case blame(String)
}

/// Where the rows that have context menus are, in one window. Rows report their frames with
/// `.contextTarget(_:ring:)`; on a right-click (or ⌃-click) the window asks for the row under the
/// click and shows its menu. A label inside a row is smaller than the row, so the smallest frame
/// under the click wins. Each view registers on its own, so a branch shown both as a label and in
/// the sidebar keeps two frames.
@MainActor @Observable
final class ContextMenuTracker {
    struct Hit {
        let view: UUID
        let target: ContextTarget
    }

    @ObservationIgnored private var frames: [UUID: (target: ContextTarget, frame: CGRect, clip: UUID?)] = [:]
    /// The visible frames of scroll views: a row scrolled out of sight (under a header) doesn't count.
    @ObservationIgnored private var clips: [UUID: CGRect] = [:]
    /// The view whose menu is open: it draws the focus ring.
    var open: UUID?
    /// The menu on screen (the debug driver closes it after a snapshot).
    @ObservationIgnored weak var openMenu: NSMenu?
    /// What the last right-click opened a menu for (the debug driver checks it).
    @ObservationIgnored var lastTarget: ContextTarget?

    func setFrame(_ frame: CGRect?, for target: ContextTarget, view: UUID, clip: UUID?) {
        frames[view] = frame.map { (target, $0, clip) }
    }

    func setClip(_ frame: CGRect?, id: UUID) {
        clips[id] = frame
    }

    /// The most specific view at `point` (window coordinates, top-left origin).
    func hit(at point: CGPoint) -> Hit? {
        frames.filter { entry in
            guard entry.value.frame.contains(point) else { return false }
            guard let clip = entry.value.clip else { return true }
            return clips[clip]?.contains(point) ?? false
        }
            .min { $0.value.frame.width * $0.value.frame.height < $1.value.frame.width * $1.value.frame.height }
            .map { Hit(view: $0.key, target: $0.value.target) }
    }

    /// Where the smallest view showing `target` is (window points, top-left origin).
    func frame(of target: ContextTarget) -> CGRect? {
        view(for: target).flatMap { frames[$0]?.frame }
    }

    /// The smallest view showing `target` (a branch's label before its sidebar row), for menus
    /// opened by target (the commit details' ⋯, the debug driver).
    func view(for target: ContextTarget) -> UUID? {
        frames.filter { $0.value.target == target }
            .min { $0.value.frame.width * $0.value.frame.height < $1.value.frame.width * $1.value.frame.height }?
            .key
    }
}

/// How a row draws the ring while its context menu is open.
struct ContextRing {
    var radius: CGFloat = 0
    var inset: CGFloat = 1
}

extension View {
    /// Right-clicking this view opens the menu for `target`; `ring` draws the focus ring around
    /// it while the menu is open (macOS does this in lists).
    func contextTarget(_ target: ContextTarget, ring: ContextRing? = ContextRing()) -> some View {
        modifier(ContextTargetModifier(target: target, ring: ring))
    }

    /// Marks a scroll view: the targets inside count only where it shows them.
    func contextClip() -> some View {
        modifier(ContextClipModifier())
    }
}

private struct ContextClipKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    var contextClip: UUID? {
        get { self[ContextClipKey.self] }
        set { self[ContextClipKey.self] = newValue }
    }
}

private struct ContextClipModifier: ViewModifier {
    @State private var id = UUID()
    @Environment(ContextMenuTracker.self) private var tracker: ContextMenuTracker?

    func body(content: Content) -> some View {
        content
            .environment(\.contextClip, id)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                tracker?.setClip(frame, id: id)
            }
            .onDisappear { tracker?.setClip(nil, id: id) }
    }
}

private struct ContextTargetModifier: ViewModifier {
    let target: ContextTarget
    let ring: ContextRing?
    @State private var id = UUID()
    @Environment(ContextMenuTracker.self) private var tracker: ContextMenuTracker?
    @Environment(\.contextClip) private var clip

    func body(content: Content) -> some View {
        content
            .overlay {
                if let ring, let tracker, tracker.open == id {
                    RoundedRectangle(cornerRadius: ring.radius, style: .continuous)
                        .strokeBorder(K.accent, lineWidth: 2)
                        .padding(ring.inset)
                        .allowsHitTesting(false)
                }
            }
            // `.global` is the window's content view, which fills the window (top-left origin).
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                tracker?.setFrame(frame, for: target, view: id, clip: clip)
            }
            .onDisappear { tracker?.setFrame(nil, for: target, view: id, clip: clip) }
    }
}

// MARK: - Building the menus

/// The right-click menus (ScreenFlowMenus): commit rows, branch and tag labels, sidebar rows,
/// working-copy files and stashes. Items that don't apply stay in the menu, disabled, with the
/// reason on the right.
@MainActor
enum ContextMenus {
    static func menu(for target: ContextTarget, repository: RepositoryModel, window: WindowModel) -> NSMenu? {
        guard repository.isReady else { return nil }
        let menu: NSMenu?
        switch target {
        case .commit(let id): menu = commitMenu(id, repository)
        case .branch(let name): menu = branchMenu(name, repository)
        case .remoteBranch(let name): menu = remoteMenu(name, repository)
        case .tag(let name): menu = tagMenu(name, repository)
        case .file(let path, let staged): menu = fileMenu(path, staged: staged, repository)
        case .stash(let id): menu = stashMenu(id, repository)
        case .commitFile(let path, let commit): menu = commitFileMenu(path, commit: commit, repository)
        case .blame(let id): menu = blameMenu(id, repository)
        }
        return menu.map(fitHeader)
    }

    /// Stretches the header to the menu's width, so its hairline runs across the menu.
    static func fitHeader(_ menu: NSMenu) -> NSMenu {
        if let view = menu.items.first?.view {
            view.frame.size.width = max(view.frame.width, menu.size.width)
        }
        return menu
    }

    // MARK: Commit

    static func commitMenu(_ id: String, _ r: RepositoryModel) -> NSMenu? {
        guard let commit = r.commit(id) else { return nil }
        let menu = NSMenu(title: commit.subject)
        menu.autoenablesItems = false
        let source = "Commit menu"
        let idle = r.activity == nil
        let isHead = id == r.status.headID
        let onBranch = r.isOnCurrentBranch(id)
        let branch = r.status.branch
        let short = commit.shortID
        menu.addItem(header(commit.subject, "\(short) · \(commit.author.name) · \(Formatters.historyDate(commit.author.date))"))
        menu.addItem(item("Checkout \(short)", hint: isHead ? "You are here" : nil, enabled: idle && !isHead) {
            r.from(source) { r.checkout(commit: id) }
        })
        menu.addItem(item("Create Branch Here…", key: "n", modifiers: [.shift, .command], enabled: idle) {
            r.from(source) { r.askCreateBranch(at: id) }
        })
        menu.addItem(item("Create Tag Here…", enabled: idle) { r.from(source) { r.askCreateTag(at: id) } })
        menu.addItem(.separator())
        menu.addItem(item("Cherry-pick \(short)", hint: onBranch ? "Already on this branch" : nil, enabled: idle && !onBranch) {
            r.from(source) { r.cherryPick([id]) }
        })
        menu.addItem(item("Revert \(short)", hint: onBranch ? nil : "Not on this branch", enabled: idle && onBranch) {
            r.from(source) { r.revert([id]) }
        })
        let resetHint: String? = branch == nil ? "HEAD is detached" : isHead ? "Already here" : onBranch ? nil : "Not on this branch"
        let reset = submenu("Reset Branch to Here", hint: resetHint, enabled: idle && resetHint == nil, items: [
            subItem("Soft", note: "Keep the changes staged") { r.from(source) { r.reset(to: id, mode: .soft) } },
            subItem("Mixed", note: "Keep the changes, unstaged") { r.from(source) { r.reset(to: id, mode: .mixed) } },
            subItem("Hard…", note: "Throw the changes away (Kaern stashes them first)") { r.from(source) { r.reset(to: id, mode: .hard) } },
        ])
        menu.addItem(reset)
        let rebaseHint: String? = r.operation.map { "Finish the \($0.kind.title.lowercased()) first" }
            ?? (branch == nil ? "HEAD is detached" : isHead ? "Nothing above it" : onBranch ? nil : "Not on this branch")
        menu.addItem(item("Interactively Rebase from Here…", hint: rebaseHint, enabled: idle && rebaseHint == nil) {
            r.from(source) { r.askInteractiveRebase(onto: id) }
        })
        menu.addItem(.separator())
        menu.addItem(item("Compare with Working Copy", enabled: true) { r.compareWithWorkingCopy(id) })
        menu.addItem(item("Compare with HEAD", hint: isHead ? "This is HEAD" : nil, enabled: !isHead && r.status.headID != nil) {
            r.compareWithHead(id)
        })
        menu.addItem(.separator())
        menu.addItem(item("Copy SHA", key: "c") { r.copySHAs([id]) })
        menu.addItem(item("Copy Commit Message", key: "c", modifiers: [.option, .command]) { r.copyMessage(of: id) })
        if let host = r.hostName, let page = r.remoteURL?.commitPage(id) {
            menu.addItem(item("Open on \(host)") { NSWorkspace.shared.open(page) })
        } else {
            menu.addItem(item("Open on GitHub", hint: "No web remote", enabled: false) {})
        }
        return menu
    }

    // MARK: Branches

    static func branchMenu(_ name: String, _ r: RepositoryModel) -> NSMenu? {
        guard let ref = r.refs.localBranch(named: name) else { return nil }
        let menu = NSMenu(title: name)
        menu.autoenablesItems = false
        let source = "Branch menu"
        let idle = r.activity == nil
        let current = r.status.branch
        let isCurrent = name == current
        let merged = !isCurrent && r.isOnCurrentBranch(ref.target)
        let cur = current ?? "HEAD"
        let tracked = ref.upstream.flatMap { r.refs.remoteBranch(named: $0) }
        let sub: String
        if isCurrent {
            sub = "Current branch" + (r.status.ahead > 0 ? " · ↑\(r.status.ahead) to push" : "")
        } else {
            sub = merged ? "Already part of \(cur)" : "Not merged into \(cur)"
        }
        menu.addItem(header(name, sub))
        menu.addItem(item("Checkout", hint: isCurrent ? "Current branch" : nil, enabled: idle && !isCurrent) {
            r.from(source) { r.checkout(branch: name) }
        })
        menu.addItem(.separator())
        let noBranch = current == nil
        menu.addItem(item("Merge into “\(cur)”", hint: merged ? "Already merged" : noBranch ? "Not on a branch" : nil,
                          enabled: idle && !isCurrent && !merged && !noBranch) {
            r.from(source) { r.merge(name) }
        })
        menu.addItem(item("Rebase “\(cur)” onto This", hint: merged ? "Already on it" : noBranch ? "Not on a branch" : nil,
                          enabled: idle && !isCurrent && !merged && !noBranch) {
            r.from(source) { r.rebase(onto: name) }
        })
        let canSync = isCurrent ? r.status.upstream != nil : tracked != nil
        menu.addItem(item("Pull", hint: canSync ? nil : "No upstream", enabled: idle && canSync) {
            r.from(source) { r.pull(branch: name) }
        })
        menu.addItem(item("Push", hint: canSync || isCurrent ? nil : "No upstream", enabled: idle && (canSync || isCurrent) && !r.remotes.isEmpty) {
            r.from(source) { r.push(branch: name) }
        })
        menu.addItem(.separator())
        menu.addItem(item("Rename…", enabled: idle) { r.from(source) { r.askRename(branch: name) } })
        menu.addItem(item("Delete", hint: isCurrent ? "Switch to another branch first" : nil, key: "\u{8}", enabled: idle && !isCurrent) {
            r.from(source) { r.deleteBranch(name) }
        })
        menu.addItem(item("Delete Here and on \(tracked?.remoteName ?? "origin")…",
                          hint: isCurrent ? nil : tracked == nil ? "Not on a remote" : nil,
                          enabled: idle && !isCurrent && tracked != nil) {
            if let tracked { r.from(source) { r.deleteOnRemote(branch: name, remoteBranch: tracked, alsoLocal: true) } }
        })
        menu.addItem(.separator())
        menu.addItem(item("Compare with “\(cur)”", enabled: !isCurrent) { r.compare(branch: name) })
        let page = tracked.flatMap { tracked in r.remoteURL?.pullRequestPage(branch: tracked.branchName) }
        menu.addItem(item("Create Pull Request…", hint: tracked == nil ? "Publish it first" : page == nil ? "No web remote" : nil,
                          enabled: page != nil) {
            if let page { NSWorkspace.shared.open(page) }
        })
        menu.addItem(item("Copy Branch Name") { r.copy(name, toast: "Copied \(name)") })
        return menu
    }

    static func remoteMenu(_ name: String, _ r: RepositoryModel) -> NSMenu? {
        guard let ref = r.refs.remoteBranch(named: name) else { return nil }
        let menu = NSMenu(title: name)
        menu.autoenablesItems = false
        let source = "Remote branch menu"
        let idle = r.activity == nil
        let local = ref.branchName
        let hasLocal = r.refs.localBranch(named: local) != nil
        let cur = r.status.branch ?? "HEAD"
        menu.addItem(header(name, "Remote branch on \(ref.remoteName ?? "the remote")"))
        menu.addItem(item(hasLocal ? "Checkout \(local)" : "Checkout as a Local Branch", enabled: idle) {
            r.from(source) { r.checkoutRemoteBranch(ref) }
        })
        let merged = r.isOnCurrentBranch(ref.target)
        menu.addItem(item("Merge into “\(cur)”", hint: merged ? "Already merged" : nil, enabled: idle && !merged && r.status.branch != nil) {
            r.from(source) { r.merge(name) }
        })
        menu.addItem(item("Compare with “\(cur)”") { r.compare(branch: name) })
        menu.addItem(.separator())
        menu.addItem(item("Copy Branch Name") { r.copy(name, toast: "Copied \(name)") })
        menu.addItem(item("Delete from \(ref.remoteName ?? "origin")…", enabled: idle) {
            r.from(source) { r.deleteOnRemote(branch: local, remoteBranch: ref, alsoLocal: false) }
        })
        return menu
    }

    static func tagMenu(_ name: String, _ r: RepositoryModel) -> NSMenu? {
        let menu = NSMenu(title: name)
        menu.autoenablesItems = false
        let idle = r.activity == nil
        let remote = r.defaultRemote
        menu.addItem(header(name, "Tag"))
        menu.addItem(item("Push Tag to \(remote ?? "origin")", hint: remote == nil ? "No remote" : nil, enabled: idle && remote != nil) {
            r.from("Tag menu") { r.pushTag(name) }
        })
        let release = r.hostName == "GitHub" ? r.remoteURL?.newReleasePage(tag: name) : nil
        menu.addItem(item("Draft a GitHub Release…", hint: release == nil ? "Not on GitHub" : nil, enabled: release != nil) {
            if let release { NSWorkspace.shared.open(release) }
        })
        menu.addItem(.separator())
        menu.addItem(item("Copy Tag Name") { r.copy(name, toast: "Copied \(name)") })
        return menu
    }

    // MARK: Files

    static func fileMenu(_ path: String, staged: Bool, _ r: RepositoryModel) -> NSMenu? {
        guard let entry = r.status.entries.first(where: { $0.path == path }) else { return nil }
        let menu = NSMenu(title: path)
        menu.autoenablesItems = false
        let source = "File menu"
        let idle = r.activity == nil && r.canChangeIndex
        let name = (path as NSString).lastPathComponent
        let directory = (path as NSString).deletingLastPathComponent
        let partial = entry.stageState == .partial
        let state = partial ? "partly staged" : entry.hasStagedChanges ? "staged" : entry.isUntracked ? "new" : "unstaged"
        menu.addItem(header(name, (directory.isEmpty ? "" : directory + "/ · ") + state))
        menu.addItem(item(staged ? "Unstage" : "Stage", enabled: idle && !entry.isConflicted) {
            r.from(source) { if staged { r.unstage([path]) } else { r.stage([path]) } }
        })
        let keepsStaged = !staged && partial
        menu.addItem(item(keepsStaged ? "Discard Unstaged Changes" : "Discard Changes", key: "\u{8}",
                          enabled: idle && !entry.isConflicted) {
            r.from(source) { r.discard([entry], keepingStaged: keepsStaged) }
        })
        let patterns = IgnorePatterns(path: path)
        var ignoreItems: [NSMenuItem] = [
            subItem("Ignore “\(name)”", note: entry.isUntracked ? "Only this file" : "Git keeps listing tracked files",
                    enabled: entry.isUntracked) { r.from(source) { r.ignore(pattern: patterns.file) } },
        ]
        if let ext = patterns.fileExtension {
            ignoreItems.append(subItem("Ignore All “\(ext.dropFirst())” Files", note: "Everywhere in the repository") {
                r.from(source) { r.ignore(pattern: ext) }
            })
        }
        if let folder = patterns.folder {
            ignoreItems.append(subItem("Ignore “\(directory)/”", note: "The whole folder") {
                r.from(source) { r.ignore(pattern: folder) }
            })
        }
        menu.addItem(submenu("Ignore", enabled: idle, items: ignoreItems))
        menu.addItem(.separator())
        let app = r.defaultAppName(for: path)
        let exists = r.fileURL(path).map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
        menu.addItem(item("Open in \(app ?? "Default App")", key: String(Character(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)),
                          enabled: exists && app != nil) { r.open(path: path) })
        menu.addItem(item("Show in Finder", enabled: exists) {
            if let url = r.fileURL(path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        })
        menu.addItem(item("Copy Path") { r.copy(path, toast: "Copied \(path)") })
        menu.addItem(.separator())
        menu.addItem(item("Show File History", hint: entry.isUntracked ? "Not committed yet" : nil, enabled: !entry.isUntracked) {
            r.showFileHistory(path)
        })
        menu.addItem(item("Blame", hint: entry.isUntracked ? "Not committed yet" : nil, enabled: !entry.isUntracked) {
            r.showBlame(path)
        })
        return menu
    }

    /// A blame block (ScreenExplore's ⋯): the commit in the graph, blame before it, copy, web.
    static func blameMenu(_ id: String, _ r: RepositoryModel) -> NSMenu? {
        guard let blame = r.currentBlame, let commit = blame.commits[id], !commit.isUncommitted else { return nil }
        let menu = NSMenu(title: commit.shortID)
        menu.autoenablesItems = false
        menu.addItem(header(commit.summary, "\(commit.shortID) · \(commit.author) · \(Formatters.historyDate(commit.date))"))
        menu.addItem(item("Show Commit in History") { r.showCommitInHistory(id) })
        menu.addItem(item("Blame Before This Commit", hint: commit.previousID == nil ? "It added these lines" : nil,
                          enabled: commit.previousID != nil) { r.blameBefore(id) })
        menu.addItem(.separator())
        menu.addItem(item("Copy SHA", key: "c", modifiers: [.shift, .command]) { r.copySHAs([id]) })
        menu.addItem(item("Copy Commit Message") { r.copyMessage(of: id) })
        menu.addItem(.separator())
        if let host = r.hostName, let page = r.remoteURL?.commitPage(id) {
            menu.addItem(item("Open Commit on \(host)") { NSWorkspace.shared.open(page) })
        } else {
            menu.addItem(item("Open Commit on GitHub", hint: "No web remote", enabled: false) {})
        }
        return menu
    }

    /// A file in a commit's details: its history from there, blame as of that commit.
    static func commitFileMenu(_ path: String, commit: String, _ r: RepositoryModel) -> NSMenu? {
        let menu = NSMenu(title: path)
        menu.autoenablesItems = false
        let name = (path as NSString).lastPathComponent
        let directory = (path as NSString).deletingLastPathComponent
        menu.addItem(header(name, (directory.isEmpty ? "" : directory + "/ · ") + "in \(String(commit.prefix(7)))"))
        menu.addItem(item("Show File History") { r.showFileHistory(path, at: commit) })
        menu.addItem(item("Blame at \(String(commit.prefix(7)))") { r.showBlame(path, at: commit) })
        menu.addItem(.separator())
        let exists = r.fileURL(path).map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
        menu.addItem(item("Show in Finder", enabled: exists) {
            if let url = r.fileURL(path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        })
        menu.addItem(item("Copy Path") { r.copy(path, toast: "Copied \(path)") })
        return menu
    }

    // MARK: Stashes

    static func stashMenu(_ id: String, _ r: RepositoryModel) -> NSMenu? {
        guard let stash = r.stashes.first(where: { $0.id == id }) else { return nil }
        let menu = NSMenu(title: stash.reference)
        menu.autoenablesItems = false
        let source = "Stash menu"
        let idle = r.activity == nil
        menu.addItem(header(RepositoryModel.stashTitle(stash), "\(stash.reference) · \(Formatters.shortDate(stash.date))"))
        menu.addItem(item("Show Stash") { r.openStash(stash.id) })
        menu.addItem(.separator())
        menu.addItem(item("Apply", enabled: idle) { r.from(source) { r.applyStash(stash, pop: false) } })
        menu.addItem(item("Pop", enabled: idle) { r.from(source) { r.applyStash(stash, pop: true) } })
        menu.addItem(item("Create Branch from Stash…", enabled: idle) { r.askBranchFromStash(stash) })
        menu.addItem(item("Rename…", enabled: idle) { r.sheet = .renameStash(stash) })
        menu.addItem(item("Drop", key: "\u{8}", enabled: idle) { r.from(source) { r.dropStash(stash) } })
        menu.addItem(.separator())
        menu.addItem(item("Copy Stash Name") { r.copyStashName(stash) })
        return menu
    }

    // MARK: Toolbar branch menu

    /// The toolbar's branch button (ScreenSheets 브랜치 메뉴): recent branches with ↑↓, Other
    /// Branches ▸, New Branch…, Merge into…, Rebase onto…, Rename…, Delete.
    /// The bar's Graph: menu (ScreenBigRepo): what the graph draws, each with a second line. The board
    /// has Local branches and main and Current branch only; All branches goes back to every branch.
    static func graphScopeMenu(_ r: RepositoryModel) -> NSMenu {
        let menu = NSMenu(title: "Graph")
        menu.autoenablesItems = false
        let choices: [(GraphScope, String, String)] = [
            (.all, "All branches", "Every remote branch (\(r.refs.remoteBranches.count.formatted())) and tag too"),
            (.local, "Local branches and main", "Remote-only branches appear when you pick them"),
            (.current, "Current branch only", "\(r.currentBranch ?? "HEAD") and what it contains"),
        ]
        for (scope, title, note) in choices {
            let menuItem = item(title, enabled: r.isReady) { r.from("Graph menu") { r.setGraphScope(scope) } }
            menuItem.subtitle = note
            menuItem.state = r.graphScope == scope ? .on : .off
            menu.addItem(menuItem)
        }
        return menu
    }

    static func toolbarBranchMenu(_ r: RepositoryModel, onNewBranch: @escaping () -> Void, onOtherBranches: (() -> Void)? = nil) -> NSMenu {
        let menu = NSMenu(title: "Branches")
        menu.autoenablesItems = false
        let source = "Toolbar › Branch menu"
        let idle = r.activity == nil && !r.isMidOperation
        let current = r.status.branch
        let cur = current ?? "HEAD"
        let locals = r.refs.localBranches
        let recent = r.recentBranches.compactMap { name in locals.first { $0.name == name } }
        let others = locals.filter { ref in !recent.contains(where: { $0.name == ref.name }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        menu.addItem(.sectionHeader(title: "Recent Branches"))
        for ref in recent {
            let counts = [ref.ahead > 0 ? "↑\(ref.ahead)" : nil, ref.behind > 0 ? "↓\(ref.behind)" : nil].compactMap { $0 }.joined(separator: " ")
            let menuItem = item(ref.name, hint: counts.isEmpty ? nil : counts, enabled: idle || ref.isHead) {
                if !ref.isHead { r.from(source) { r.checkout(branch: ref.name) } }
            }
            menuItem.state = ref.isHead ? .on : .off
            menu.addItem(menuItem)
        }
        if let onOtherBranches {
            // Quick Open finds any branch by name (ScreenSheets' Other Branches…).
            menu.addItem(item("Other Branches…", key: "o", modifiers: [.shift, .command], enabled: true, run: onOtherBranches))
        } else if !others.isEmpty || !r.refs.remoteBranches.isEmpty {
            var otherItems: [NSMenuItem] = others.map { ref in
                item(ref.name, enabled: idle) { r.from(source) { r.checkout(branch: ref.name) } }
            }
            let remotes = r.refs.remoteBranches.filter { !$0.name.hasSuffix("/HEAD") }
            if !remotes.isEmpty {
                if !otherItems.isEmpty { otherItems.append(.separator()) }
                otherItems += remotes.map { ref in
                    item(ref.name, enabled: idle) { r.from(source) { r.checkoutRemoteBranch(ref) } }
                }
            }
            menu.addItem(submenu("Other Branches", enabled: true, items: otherItems))
        }
        menu.addItem(.separator())
        menu.addItem(item("New Branch…", key: "n", modifiers: [.shift, .command], enabled: idle) { onNewBranch() })
        let noBranch = current == nil
        menu.addItem(item("Merge into “\(cur)”…", hint: noBranch ? "Not on a branch" : nil, enabled: idle && !noBranch) {
            r.from(source) { r.askMerge() }
        })
        menu.addItem(item("Rebase “\(cur)” onto…", hint: noBranch ? "Not on a branch" : nil, enabled: idle && !noBranch) {
            r.from(source) { r.askRebase() }
        })
        menu.addItem(.separator())
        menu.addItem(item("Rename “\(cur)”…", enabled: idle && !noBranch) { if let current { r.askRename(branch: current) } })
        let delete = item("Delete “\(cur)”", enabled: false) {}
        delete.subtitle = noBranch ? "HEAD is detached." : "The checked-out branch can’t be deleted. Switch first."
        menu.addItem(delete)
        return menu
    }

    // MARK: Items

    /// Keeps an item's closure alive and runs it.
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func invoke(_ sender: Any?) { run() }
    }

    static func item(_ title: String, hint: String? = nil, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
                     enabled: Bool = true, run: @escaping () -> Void) -> NSMenuItem {
        let action = Action(run)
        let item = NSMenuItem(title: title, action: #selector(Action.invoke(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = action
        item.representedObject = action
        item.isEnabled = enabled
        if let hint { item.attributedTitle = titled(title, hint: hint) }
        return item
    }

    /// The reason an item doesn't apply, in small secondary text at the right of its title
    /// (`.mh`), like the board.
    static func titled(_ title: String, hint: String) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let result = NSMutableAttributedString(string: title, attributes: [.font: font])
        let width = (title as NSString).size(withAttributes: [.font: font]).width
        let hintFont = NSFont.systemFont(ofSize: 11)
        let hintWidth = (hint as NSString).size(withAttributes: [.font: hintFont]).width
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: max(280, width + 28 + hintWidth))]
        result.append(NSAttributedString(string: "\t" + hint, attributes: [
            .font: hintFont, .foregroundColor: NSColor.tertiaryLabelColor, .baselineOffset: 1,
        ]))
        result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// A submenu item (Reset Branch to Here ▸, Ignore ▸).
    static func submenu(_ title: String, hint: String? = nil, enabled: Bool, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        item.submenu = menu
        item.isEnabled = enabled
        if let hint { item.attributedTitle = titled(title, hint: hint) }
        return item
    }

    /// A submenu choice with what it does under its title (`.smt`: label and note).
    static func subItem(_ title: String, note: String, enabled: Bool = true, run: @escaping () -> Void) -> NSMenuItem {
        let menuItem = item(title, enabled: enabled, run: run)
        menuItem.subtitle = note
        return menuItem
    }

    /// `.cmh`: what the menu is about — the commit's summary, branch or file — and a second line.
    static func header(_ title: String, _ subtitle: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let view = NSHostingView(rootView: MenuHeader(title: title, subtitle: subtitle))
        let size = view.fittingSize
        // A fixed width: a wider menu leaves the header at the left, a long summary is cut.
        view.frame = NSRect(x: 0, y: 0, width: min(max(size.width, 220), 320), height: size.height)
        item.view = view
        return item
    }
}

/// The menu header's look: the summary in bold, then hash · author · date in secondary text,
/// a hairline under it.
private struct MenuHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 4, leading: 16, bottom: 7, trailing: 14))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 1).padding(.horizontal, 10)
        }
        .padding(.bottom, 4)
        .fixedSize(horizontal: false, vertical: true)
    }
}
