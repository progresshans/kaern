import AppKit
import KaernKit
import Observation
import SwiftUI

/// Window › Repositories (⇧⌘R, ScreenRepos): every open repository by tab group, plus recent ones
/// that aren't open — branch, changes, what's to push and pull, the last fetch and what needs
/// doing, with the fix in the row.
@MainActor
final class RepositoriesWindowController: NSWindowController, NSWindowDelegate {
    static let shared = RepositoriesWindowController()
    let state = RepositoriesState()
    private var lights: TrafficLights?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1260, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Repositories"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 420)
        window.backgroundColor = NSColor(name: nil) { $0.isDark ? K.hex(0x323232) : K.hex(0xececec) }
        let hosting = KaernHostingView(rootView: RepositoriesView(state: state).environment(AppModel.shared))
        hosting.sizingOptions = []
        window.contentView = hosting
        super.init(window: window)
        window.delegate = self
        // The traffic lights sit in the 64 pt bar.
        lights = TrafficLights(window: window, centerFromTop: 32)
        hosting.onLayout = { [weak self] in self?.lights?.apply() }
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        state.refreshRecent()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The window's filter, selection, and what Kaern read from recent repositories that aren't open.
@MainActor @Observable
final class RepositoriesState {
    var onlyAttention = false
    var filter = ""
    var selection: String?
    /// Light status of recent repositories that aren't open, by path.
    var recentFacts: [String: RecentFacts] = [:]
    var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    struct RecentFacts: Equatable {
        var missing = false
        /// The folder is there but isn't a repository (anymore).
        var notRepository = false
        /// Why git couldn't open it.
        var failure: String?
        var branch: String?
        var changes = 0
        var ahead = 0
        var behind = 0
        var lastFetch: Date?
        var hasUpstream = false
        var hasRemote = true
    }

    @ObservationIgnored private var recentTask: Task<Void, Never>?

    /// Reads the recent repositories that aren't open (`git status`, read-only). A read that's
    /// still going gives way to the new one.
    func refreshRecent() {
        let app = AppModel.shared
        let open = Set(app.windows.flatMap { $0.model.tabs.map(\.path) })
        let paths = app.recent.map(\.path).filter { !open.contains($0) }
        recentTask?.cancel()
        recentTask = Task {
            guard let runner = await app.waitForGit() else { return }
            for path in paths {
                guard !Task.isCancelled else { return }
                var facts = RecentFacts()
                guard FileManager.default.fileExists(atPath: path) else {
                    facts.missing = true
                    recentFacts[path] = facts
                    continue
                }
                let repository: GitRepository
                do {
                    repository = try await GitCommandTrigger.$current.withValue(.background("Repositories window")) {
                        try await GitRepository.open(URL(filePath: path, directoryHint: .isDirectory), runner: runner)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // The row says why, instead of staying on "Reading…".
                    if error is NotARepositoryError { facts.notRepository = true } else { facts.failure = error.localizedDescription }
                    recentFacts[path] = facts
                    continue
                }
                let status = try? await GitCommandTrigger.$current.withValue(.background("Repositories window")) {
                    try await repository.status(untrackedFiles: .normal)
                }
                facts.branch = status?.branch
                facts.changes = status?.entries.count ?? 0
                facts.ahead = status?.ahead ?? 0
                facts.behind = status?.behind ?? 0
                facts.hasUpstream = status?.upstream != nil
                facts.lastFetch = repository.lastFetchDate
                facts.hasRemote = !(await repository.remoteInfos()).isEmpty
                recentFacts[path] = facts
            }
        }
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}

// MARK: - Rows

/// One repository in the table.
struct RepositoryRow: Identifiable {
    enum Tone { case ok, warn, error, clean, pull }
    enum Fix { case pull, signIn(String), resolve, locate, open }

    var id: String { path }
    var path: String
    var name: String
    var branch: String
    var changes: Int?
    var toPush: Int?
    var toPull: Int?
    var lastFetch: Date?
    var fetchFailed = false
    var isFetching = false
    var isMissing = false
    var tone: Tone
    var status: String
    var fix: Fix?
    /// The open repository's model (`nil`: a recent one that isn't open).
    var model: RepositoryModel?

    var needsAttention: Bool { tone == .warn || tone == .error }

    var fixTitle: String? {
        switch fix {
        case .pull: "Pull"
        case .signIn: "Sign In…"
        case .resolve: "Resolve"
        case .locate: "Locate…"
        case .open: "Open"
        case nil: nil
        }
    }

    /// An open repository's row: the state that needs you first, then sync, then changes.
    @MainActor
    init(model: RepositoryModel) {
        self.model = model
        path = model.path
        name = model.name
        let working = model.status
        branch = working.branch ?? model.operation?.branch ?? (working.headID.map { "detached at \($0.prefix(7))" } ?? "—")
        let loaded = model.repository != nil
        changes = loaded ? working.entries.count : nil
        toPush = loaded ? (working.upstream == nil ? model.unpublishedCount : working.ahead) : nil
        toPull = loaded && working.upstream != nil ? working.behind : nil
        lastFetch = model.lastFetch
        isFetching = { if case .fetching = model.activity { return true } else { return false } }()
        switch model.phase {
        case .missing:
            isMissing = true
            changes = nil; toPush = nil; toPull = nil
            tone = .warn; status = "Folder not found"; fix = .locate
            return
        case .failed(let message):
            tone = .error; status = "Couldn’t open — \(message)"; fix = .open
            return
        case .notRepository:
            tone = .clean; status = "Not a Git repository yet"; fix = .open
            return
        case .waiting, .opening:
            tone = .clean; status = "Opening…"
            return
        default:
            break
        }
        if let problem = model.fetchProblem, let failure = problem.failure {
            fetchFailed = true
            switch failure {
            case .signIn(let host):
                let host = host ?? model.remoteHost ?? "the server"
                tone = .error; status = "Sign in to \(host)"; fix = .signIn(host)
                return
            case .sshKey(let host):
                tone = .error; status = "\(host ?? "The server") didn’t accept your SSH key"
                return
            case .network(let host):
                tone = .warn; status = "Couldn’t reach \(host ?? problem.remote)"
                return
            default:
                break
            }
        }
        if let operation = model.operation {
            let verb = switch operation.kind {
            case .rebase: "Rebasing"
            case .merge: "Merging"
            case .cherryPick: "Cherry-picking"
            case .revert: "Reverting"
            }
            let conflicts = working.conflictCount
            tone = .warn
            status = conflicts > 0 ? "\(verb) — \(Formatters.count(conflicts, "conflict", "conflicts")) to resolve" : "\(verb) — ready to continue"
            fix = .resolve
            return
        }
        if working.conflictCount > 0 {
            tone = .warn; status = "\(Formatters.count(working.conflictCount, "file has", "files have")) conflicts"; fix = .resolve
            return
        }
        if working.upstream != nil, working.ahead > 0, working.behind > 0 {
            tone = .warn; status = "Diverged — pull before you push"; fix = .pull
            return
        }
        if working.upstream != nil, working.behind > 0 {
            tone = .pull; status = Formatters.count(working.behind, "commit to pull", "commits to pull")
            return
        }
        if working.upstream != nil, working.ahead > 0 {
            tone = .ok; status = Formatters.count(working.ahead, "commit to push", "commits to push")
            return
        }
        if model.remotes.isEmpty, model.isReady {
            tone = .clean; status = "Only on this Mac"
            return
        }
        if working.upstream == nil, working.branch != nil, !model.remotes.isEmpty {
            tone = .clean; status = "Not published yet"
            return
        }
        tone = .clean
        status = working.isClean ? "Clean" : "Up to date"
    }

    /// A recent repository that isn't open, from the light status the window read.
    init(recent: Session.RecentRepository, facts: RepositoriesState.RecentFacts?) {
        path = recent.path
        name = recent.name
        guard let facts else {
            branch = "—"
            tone = .clean
            status = "Reading…"
            return
        }
        if facts.missing {
            branch = "—"
            isMissing = true
            tone = .clean
            status = "Folder not found"
            return
        }
        if facts.notRepository {
            branch = "—"
            tone = .clean
            status = "Not a Git repository yet"
            return
        }
        if let failure = facts.failure {
            branch = "—"
            tone = .error
            status = "Couldn’t open — \(failure)"
            return
        }
        branch = facts.branch ?? "—"
        changes = facts.changes
        toPush = facts.hasUpstream ? facts.ahead : nil
        toPull = facts.hasUpstream ? facts.behind : nil
        lastFetch = facts.lastFetch
        if facts.hasUpstream, facts.ahead > 0, facts.behind > 0 {
            tone = .warn; status = "Diverged — pull before you push"
        } else if facts.hasUpstream, facts.behind > 0 {
            tone = .pull; status = Formatters.count(facts.behind, "commit to pull", "commits to pull")
        } else if facts.hasUpstream, facts.ahead > 0 {
            tone = .ok; status = Formatters.count(facts.ahead, "commit to push", "commits to push")
        } else if !facts.hasRemote {
            tone = .clean; status = "Only on this Mac"
        } else {
            tone = .clean; status = facts.changes == 0 ? "Clean" : "Up to date"
        }
    }
}

/// A section of the table: loose tabs, a tab group, or recent repositories.
struct RepositorySection: Identifiable {
    var id: String
    var name: String
    var color: Color
    /// "open in tabs", "tab group", "not open".
    var note: String
    var rows: [RepositoryRow]
}

@MainActor
enum RepositoryTable {
    /// Every window's loose tabs, then each tab group, then recent repositories that aren't open.
    static func sections(app: AppModel, state: RepositoriesState) -> [RepositorySection] {
        var loose: [RepositoryRow] = []
        var groups: [RepositorySection] = []
        var seen = Set<String>()
        for controller in app.windows {
            let window = controller.model
            for block in window.blocks {
                switch block {
                case .tab(let tab):
                    guard seen.insert(tab.path).inserted else { continue }
                    loose.append(RepositoryRow(model: app.repository(for: tab.path)))
                case .group(let group, let members):
                    let rows = members.filter { seen.insert($0.path).inserted }.map { RepositoryRow(model: app.repository(for: $0.path)) }
                    guard !rows.isEmpty else { continue }
                    if let index = groups.firstIndex(where: { $0.name == group.name }) {
                        groups[index].rows += rows
                    } else {
                        groups.append(RepositorySection(id: "group:" + group.id.uuidString, name: group.name, color: group.color.color,
                                                        note: "tab group", rows: rows))
                    }
                }
            }
        }
        var result: [RepositorySection] = []
        if !loose.isEmpty {
            result.append(RepositorySection(id: "loose", name: groups.isEmpty ? "Open in tabs" : "Tabs without a group", color: K.accent,
                                            note: "open in tabs", rows: loose))
        }
        result += groups
        let recent = app.recent.filter { !seen.contains($0.path) }.map { RepositoryRow(recent: $0, facts: state.recentFacts[$0.path]) }
        if !recent.isEmpty {
            result.append(RepositorySection(id: "recent", name: "Recent", color: K.label3, note: "not open", rows: recent))
        }
        return result
    }

    /// What the filter field and Needs Attention leave.
    static func filtered(_ sections: [RepositorySection], state: RepositoriesState) -> [RepositorySection] {
        let query = state.filter.trimmingCharacters(in: .whitespaces).lowercased()
        return sections.compactMap { section in
            var copy = section
            copy.rows = section.rows.filter { row in
                (!state.onlyAttention || row.needsAttention)
                    && (query.isEmpty || "\(row.name) \(row.branch) \(row.path)".lowercased().contains(query))
            }
            return copy.rows.isEmpty ? nil : copy
        }
    }
}

// MARK: - View

/// ScreenRepos's window.
struct RepositoriesView: View {
    @Bindable var state: RepositoriesState
    @Environment(AppModel.self) private var app
    private let fetcher = AutoFetcher.shared

    var body: some View {
        let all = RepositoryTable.sections(app: app, state: state)
        let rowCount = all.reduce(0) { $0 + $1.rows.count }
        let attention = all.reduce(0) { $0 + $1.rows.filter(\.needsAttention).count }
        let shown = RepositoryTable.filtered(all, state: state)
        VStack(spacing: 0) {
            bar(total: rowCount, attention: attention)
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { section in
                        SectionHeader(section: section)
                        ForEach(section.rows) { row in
                            RepositoryRowView(row: row, isAlternate: rowIndex(of: row, in: shown) % 2 == 1,
                                              isSelected: state.selection == row.path, state: state)
                        }
                    }
                    if shown.isEmpty {
                        Text(state.filter.isEmpty ? "Nothing needs attention." : "No repository matches “\(state.filter)”.")
                            .font(.system(size: 13))
                            .foregroundStyle(K.label2)
                            .padding(EdgeInsets(top: 24, leading: 16, bottom: 0, trailing: 16))
                    }
                }
                .padding(.bottom, 8)
            }
            .background(K.content)
            footer
        }
        .background(K.content)
        .ignoresSafeArea()
        .frame(minWidth: 980, minHeight: 420)
        .overlay(alignment: .bottom) {
            if let toast = state.toast {
                Text(toast)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.85)))
                    .padding(.bottom, 44)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: state.toast)
        .onChange(of: fetcher.isFetchingAll) { _, fetching in
            if !fetching { state.refreshRecent() }
        }
    }

    private func rowIndex(of row: RepositoryRow, in sections: [RepositorySection]) -> Int {
        var index = 0
        for section in sections {
            for item in section.rows {
                if item.path == row.path { return index }
                index += 1
            }
        }
        return index
    }

    // MARK: Bar

    private func bar(total: Int, attention: Int) -> some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 70, height: 1)
            VStack(alignment: .leading, spacing: 1) {
                Text("Repositories").font(.system(size: 13.5, weight: .bold))
                Text("\(Formatters.count(total, "repository", "repositories")) · " + (attention == 0 ? "all healthy" : "\(attention) need attention"))
                    .font(.system(size: 11))
                    .foregroundStyle(K.label2)
                    .lineLimit(1)
            }
            AttentionSegment(onlyAttention: $state.onlyAttention, count: attention)
                .padding(.leading, 14)
            Spacer(minLength: 12)
            HStack(spacing: 0) {
                LabeledBarButton(title: fetcher.isFetchingAll ? "Fetching" : "Fetch All", icon: Icons.fetch, busy: fetcher.isFetchingAll) {
                    fetcher.fetchAll(auto: false)
                }
                .disabled(fetcher.isFetchingAll)
                AddMenuButton(state: state)
            }
            .padding(.horizontal, 2)
            .frame(height: 28)
            .controlSurface(radius: 9)
            HStack(spacing: 6) {
                Icon(Icons.search(1.4), size: 12).foregroundStyle(K.label2)
                TextField("Filter repositories", text: $state.filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
            }
            .padding(.horizontal, 9)
            .frame(width: 220, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(K.field)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(K.controlBorder, lineWidth: 0.5)))
        }
        .padding(.trailing, 14)
        .frame(height: 64)
        .background {
            ZStack(alignment: .bottom) {
                K.win
                K.sep.frame(height: 1)
            }
            .windowDragArea()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Repository").frame(width: 250, alignment: .leading)
            Text("Branch").frame(width: 210, alignment: .leading)
            Text("Changes").frame(width: 62, alignment: .leading)
            Text("To Push").frame(width: 62, alignment: .leading)
            Text("To Pull").frame(width: 62, alignment: .leading)
            Text("Last Fetch").frame(width: 96, alignment: .leading)
            Text("Status").frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 92, height: 1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(K.label2)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(K.content)
        .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(footerText(now: context.date))
            }
            Spacer()
            Text("Double-click a row to open it in its tab")
        }
        .font(.system(size: 11))
        .foregroundStyle(K.label2)
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background {
            ZStack(alignment: .top) {
                K.win
                K.sep.frame(height: 1)
            }
        }
    }

    private func footerText(now: Date) -> String {
        if fetcher.isFetchingAll {
            return "Fetching \(Formatters.count(app.openRepositories.filter { !$0.remotes.isEmpty }.count, "repository", "repositories"))…"
        }
        let auto = AppSettings.autoFetch ? "automatically every \(Formatters.count(AppSettings.autoFetchMinutes, "minute", "minutes"))" : "automatic fetch is off"
        guard let last = fetcher.lastFetchAll else { return "Not fetched all yet · \(auto)" }
        return "Fetched all \(Formatters.shortRelative(last, now: now)) · \(auto)"
    }
}

/// `.seg.rseg`: All · Needs Attention (orange count).
private struct AttentionSegment: View {
    @Binding var onlyAttention: Bool
    let count: Int

    var body: some View {
        HStack(spacing: 0) {
            segment("All", on: !onlyAttention) { onlyAttention = false }
            segment("Needs Attention", on: onlyAttention, count: count) { onlyAttention = true }
        }
        .padding(2)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(K.hover))
        .fixedSize()
    }

    private func segment(_ title: String, on: Bool, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? K.label : K.label2)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 15)
                        .background(Capsule().fill(K.warn))
                }
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(K.control).shadow(color: K.shadowCtl, radius: 0.75, y: 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// `.cap.lbl .cb`: a toolbar button that keeps its name next to the icon.
private struct LabeledBarButton: View {
    let title: String
    let icon: SVGIcon
    var busy = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy { Spinner(size: 15) } else { Icon(icon, size: 16) }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(K.label)
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering && isEnabled ? K.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Add ▾: open a folder, clone, or create — in the front window.
private struct AddMenuButton: View {
    let state: RepositoriesState
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        Menu {
            Button("Open Repository…") { inFrontWindow { app.showOpenPanel(for: $0) } }
            Button("Clone Repository…") { inFrontWindow { app.showClone(in: $0) } }
            Button("Create New Repository…") { inFrontWindow { app.showCreate(in: $0) } }
        } label: {
            HStack(spacing: 6) {
                Icon(Icons.plus, size: 14)
                Text("Add").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(K.label)
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? K.hover : .clear))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
    }

    private func inFrontWindow(_ action: @escaping (WindowModel) -> Void) {
        let controller = app.activeWindow ?? app.windows.first
        // No main window: Clone and Create show their sheets in the start window.
        let model = controller?.model ?? app.showWelcome()
        controller?.window?.makeKeyAndOrderFront(nil)
        action(model)
    }
}

private struct SectionHeader: View {
    let section: RepositorySection

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(section.color).frame(width: 8, height: 8)
            Text(section.name).foregroundStyle(K.label)
            Text("\(section.rows.count)")
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 16)
                .background(Capsule().fill(K.hover))
            Text(section.note).fontWeight(.medium).foregroundStyle(K.label3)
        }
        .font(KFont.weighted(11.5, 0.35))
        .foregroundStyle(K.label2)
        .padding(.horizontal, 16)
        .frame(height: 28)
        .padding(.top, 4)
    }
}

/// `.rrow`: 38 pt, the folder in the accent color, name over path, the numbers, the status dot and
/// text, and the fix.
private struct RepositoryRowView: View {
    let row: RepositoryRow
    let isAlternate: Bool
    let isSelected: Bool
    let state: RepositoriesState
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Icon(Icons.folderFilled, size: 17)
                    .foregroundStyle(isSelected ? .white : (row.isMissing ? K.label3 : K.accent))
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.name).font(KFont.weighted(13, 0.35))
                    Text(Formatters.abbreviatedPath(row.path))
                        .font(.system(size: 11))
                        .foregroundStyle(secondary)
                        .truncationMode(.middle)
                }
                .lineLimit(1)
            }
            .frame(width: 250, alignment: .leading)
            Text(row.branch).lineLimit(1).truncationMode(.tail).frame(width: 210, alignment: .leading)
            number(row.changes)
            number(row.toPush)
            number(row.toPull)
            HStack(spacing: 6) {
                if row.isFetching { Spinner(size: 11, lineWidth: 1.6) }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(fetchText(now: context.date))
                        .fontWeight(row.fetchFailed ? .semibold : .regular)
                        .foregroundStyle(row.fetchFailed ? (isSelected ? .white : K.err) : secondary)
                }
            }
            .lineLimit(1)
            .frame(width: 96, alignment: .leading)
            HStack(spacing: 7) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                    .overlay(Circle().stroke(isSelected ? Color.white : .clear, lineWidth: 1.5))
                Text(row.status).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer(minLength: 0)
                if let title = row.fixTitle {
                    Button(action: fix) {
                        Text(title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(isSelected ? Color(nsColor: K.hex(0x0b3d91)) : K.label)
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.95))
                                } else {
                                    Color.clear.controlSurface(radius: 7)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
            .frame(width: 92)
        }
        .font(.system(size: 13))
        .foregroundStyle(isSelected ? .white : K.label)
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? K.sel : (hovering ? K.hover : (isAlternate ? K.alt : .clear))))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // The first click selects at once (it doesn't wait to see whether a second one follows).
        .onTapGesture { state.selection = row.path }
        .simultaneousGesture(TapGesture(count: 2).onEnded { open() })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var secondary: Color { isSelected ? .white.opacity(0.8) : K.label2 }

    private var dotColor: Color {
        switch row.tone {
        case .ok: K.ok
        case .warn: K.warn
        case .error: K.err
        case .clean: K.label3
        case .pull: K.accent
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "—")
            .monospacedDigit()
            .foregroundStyle((value ?? 0) > 0 ? (isSelected ? .white : K.label) : (isSelected ? .white.opacity(0.8) : K.label3))
            .frame(width: 62, alignment: .leading)
    }

    private func fetchText(now: Date) -> String {
        if row.isFetching { return "Fetching…" }
        if row.fetchFailed { return "failed" }
        guard let date = row.lastFetch else { return "—" }
        return Formatters.shortRelative(date, now: now)
    }

    /// Double-click: the repository's tab (a recent one opens in the front window).
    private func open() {
        state.selection = row.path
        if let model = row.model {
            FailureHelp.reveal(model)
        } else if !row.isMissing {
            let controller = app.activeWindow ?? app.windows.first
            let window = controller?.model ?? app.pendingWindowModel()
            app.open([URL(filePath: row.path, directoryHint: .isDirectory)], in: window)
            controller?.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func fix() {
        state.selection = row.path
        guard let model = row.model else { return }
        switch row.fix {
        case .pull:
            model.pullWithItsSetting(from: "Repositories window")
        case .signIn(let host):
            SettingsWindowController.shared.showSignIn(host: host)
        case .resolve:
            FailureHelp.reveal(model)
            model.openConflicts()
        case .locate:
            locate(model)
        case .open:
            FailureHelp.reveal(model)
        case nil:
            break
        }
    }

    /// Locate…: the folder moved; point the tab at its new place.
    private func locate(_ model: RepositoryModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use This Folder"
        panel.message = "Where is \(model.name) now? Choose its folder."
        panel.directoryURL = URL(filePath: (model.path as NSString).deletingLastPathComponent, directoryHint: .isDirectory)
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                if let found = await app.relocate(model.path, to: url) {
                    state.showToast("Found \(model.name) at \(Formatters.abbreviatedPath(found))")
                } else {
                    state.showToast("\(url.lastPathComponent) isn’t a repository’s own folder · choose the folder with .git in it")
                }
            }
        }
        if let window = RepositoriesWindowController.shared.window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }
}
