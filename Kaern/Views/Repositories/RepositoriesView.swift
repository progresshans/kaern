import AppKit
import KaernKit
import SwiftUI

/// One repository in Window › Repositories. Not main-actor bound: rows are loaded off the main
/// actor, and the table sorts by key paths into it.
nonisolated struct RepositoryOverview: Identifiable, Hashable, Sendable {
    enum Tone: Hashable {
        case good
        case attention
        case problem
        case quiet
        case info
    }

    var id: String { path }
    var path: String
    var name: String
    var displayPath: String
    var url: URL
    var branch: String = "—"
    var changes: Int = 0
    var ahead: Int = 0
    var behind: Int = 0
    var hasUpstream = false
    var hasRemotes = false
    var lastFetch: Date?
    var operation: String?
    /// "Sign in to gitlab.com to fetch", "Couldn't reach github.com" after Fetch All.
    var problem: String?
    var isFetching = false
    var isLoaded = false
    var failedToOpen = false

    var status: (text: String, tone: Tone) {
        if failedToOpen { return (String(localized: "Couldn't open"), .problem) }
        if let operation { return (operation, .attention) }
        if let problem { return (problem, .problem) }
        if ahead > 0 && behind > 0 { return (String(localized: "Diverged — pull before pushing"), .attention) }
        if behind > 0 { return (behind == 1 ? String(localized: "1 commit to pull") : String(localized: "\(behind) commits to pull"), .info) }
        if ahead > 0 { return (ahead == 1 ? String(localized: "1 commit to push") : String(localized: "\(ahead) commits to push"), .good) }
        if hasRemotes && !hasUpstream { return (String(localized: "Not published"), .quiet) }
        if changes > 0 { return (String(localized: "Uncommitted changes"), .quiet) }
        return hasUpstream ? (String(localized: "Up to date"), .quiet) : (String(localized: "Clean"), .quiet)
    }

    var needsAttention: Bool {
        let tone = status.tone
        return tone == .attention || tone == .problem
    }
}

/// Status of every open and recent repository, for Window › Repositories.
@Observable
final class RepositoriesModel {
    private(set) var rows: [RepositoryOverview] = []
    private(set) var isFetchingAll = false
    private(set) var lastFetchAll: Date?

    func reload(from recents: [RecentRepository]) async {
        var byPath = Dictionary(uniqueKeysWithValues: rows.map { ($0.path, $0) })
        rows = recents.map { recent in
            byPath[recent.path] ?? RepositoryOverview(path: recent.path, name: recent.name, displayPath: recent.displayPath, url: recent.url)
        }
        let runner = AppModel.shared.makeRunner()
        await withTaskGroup(of: RepositoryOverview.self) { group in
            for row in rows {
                group.addTask { await Self.load(row, runner: runner) }
            }
            for await row in group {
                byPath[row.path] = row
                if let index = rows.firstIndex(where: { $0.path == row.path }) {
                    rows[index] = row
                }
            }
        }
    }

    private nonisolated static func load(_ row: RepositoryOverview, runner: GitRunner) async -> RepositoryOverview {
        var row = row
        guard let repository = try? await GitRepository.open(row.url, runner: runner),
              let status = try? await repository.status() else {
            row.failedToOpen = true
            row.isLoaded = true
            return row
        }
        row.failedToOpen = false
        switch status.head {
        case .branch(let name), .unborn(let name): row.branch = name
        case .detached(let id): row.branch = "HEAD (\(id.prefix(7)))"
        }
        let operation = repository.operationState()
        if operation?.kind == .rebase, let branch = operation?.branch {
            // A rebase detaches HEAD, but it's still that branch's work.
            row.branch = branch
        }
        row.changes = status.entries.count
        row.ahead = status.ahead
        row.behind = status.behind
        row.hasUpstream = status.upstream != nil
        row.hasRemotes = !((try? await repository.remotes()) ?? []).isEmpty
        row.lastFetch = repository.lastFetchDate
        if let operation {
            let conflicts = status.conflictCount
            var text: String
            switch operation.kind {
            case .rebase:
                text = String(localized: "Rebase in progress")
                if let step = operation.step, let total = operation.total {
                    text += " — " + String(localized: "\(step) of \(total)")
                }
            case .merge: text = String(localized: "Merge in progress")
            case .cherryPick: text = String(localized: "Cherry-pick in progress")
            case .revert: text = String(localized: "Revert in progress")
            }
            if conflicts > 0 {
                text += (operation.kind == .rebase && operation.step != nil ? ", " : " — ")
                    + (conflicts == 1 ? String(localized: "1 conflict") : String(localized: "\(conflicts) conflicts"))
            }
            row.operation = text
        } else {
            row.operation = nil
        }
        row.isLoaded = true
        return row
    }

    /// Fetch All: every repository with a remote, four at a time.
    func fetchAll() async {
        guard !isFetchingAll else { return }
        isFetchingAll = true
        defer { isFetchingAll = false }
        let runner = AppModel.shared.makeRunner()
        let targets = rows.filter { $0.hasRemotes && !$0.failedToOpen }
        for index in rows.indices where targets.contains(where: { $0.path == rows[index].path }) {
            rows[index].isFetching = true
        }
        await withTaskGroup(of: (String, String?).self) { group in
            var pending = targets.makeIterator()
            func startNext() {
                guard let row = pending.next() else { return }
                group.addTask { (row.path, await Self.fetch(row, runner: runner)) }
            }
            for _ in 0 ..< 4 { startNext() }
            for await (path, problem) in group {
                if let index = rows.firstIndex(where: { $0.path == path }) {
                    rows[index].problem = problem
                    rows[index].isFetching = false
                }
                startNext()
            }
        }
        lastFetchAll = .now
        await reload(from: AppModel.shared.recents)
    }

    /// `nil` when the fetch worked, otherwise what to tell the user.
    private nonisolated static func fetch(_ row: RepositoryOverview, runner: GitRunner) async -> String? {
        guard let repository = try? await GitRepository.open(row.url, runner: runner) else { return nil }
        do {
            try await repository.fetch()
            return nil
        } catch {
            let remote = (try? await repository.remotes())?.first ?? "origin"
            let host = await repository.remoteURL(remote).flatMap(RemoteURL.init)?.host ?? remote
            switch RemoteFailure.classify((error as? GitError)?.message ?? error.localizedDescription) {
            case .authentication: return String(localized: "Sign in to \(host) to fetch")
            case .unknownHostKey: return String(localized: "\(host) isn't a known SSH host")
            case .unreachable: return String(localized: "Couldn't reach \(host)")
            case .other: return String(localized: "Fetch failed")
            }
        }
    }
}

/// Window › Repositories (⇧⌘R): open and recent repositories in one table, so the ones that
/// need you (diverged, mid-rebase, signed out) stand out. Double-click goes to the repository's
/// window, or opens one.
struct RepositoriesView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model = RepositoriesModel()
    @State private var selection: Set<String> = []
    @State private var filter = ""
    @State private var sortOrder = [KeyPathComparator(\RepositoryOverview.name)]

    private var rows: [RepositoryOverview] {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        let filtered = trimmed.isEmpty ? model.rows : model.rows.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) || $0.branch.localizedCaseInsensitiveContains(trimmed)
                || $0.path.localizedCaseInsensitiveContains(trimmed)
        }
        return filtered.sorted(using: sortOrder)
    }

    private var subtitle: String {
        let count = model.rows.count
        let attention = model.rows.count(where: \.needsAttention)
        var text = count == 1 ? String(localized: "1 repository") : String(localized: "\(count) repositories")
        if attention > 0 {
            text += " · " + String(localized: "\(attention) need attention")
        }
        return text
    }

    var body: some View {
        VStack(spacing: 0) {
            table
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 360)
        .navigationTitle("Repositories")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.fetchAll() }
                } label: {
                    Label("Fetch All", systemImage: "arrow.clockwise")
                }
                .labelStyle(.titleAndIcon)
                .disabled(model.isFetchingAll)
                Button {
                    let urls = appModel.chooseRepositories()
                    Task {
                        for url in urls {
                            do {
                                let repository = try await GitRepository.open(url, runner: appModel.makeRunner())
                                appModel.noteOpened(repository.root)
                            } catch {
                                appModel.presentError(error, title: String(localized: "Couldn't Add Repository"))
                            }
                        }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .labelStyle(.titleAndIcon)
                .help("Add repositories to this list")
            }
        }
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter Repositories")
        .task(id: appModel.recents.map(\.path)) { await model.reload(from: appModel.recents) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.reload(from: appModel.recents) }
        }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Repository", value: \.name) { row in
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).fontWeight(.semibold)
                        Text(row.displayPath)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                    }
                    .lineLimit(1)
                }
                .padding(.vertical, 3)
            }
            .width(min: 180, ideal: 260)
            TableColumn("Branch", value: \.branch) { row in
                Text(row.branch).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 100, ideal: 190)
            TableColumn("Changes", value: \.changes) { row in number(row.changes, loaded: row.isLoaded) }
                .width(64)
            TableColumn("To Push", value: \.ahead) { row in number(row.ahead, loaded: row.isLoaded) }
                .width(64)
            TableColumn("To Pull", value: \.behind) { row in
                if row.hasUpstream { number(row.behind, loaded: row.isLoaded) } else { Text("—").foregroundStyle(.tertiary) }
            }
            .width(64)
            TableColumn("Last Fetch") { row in
                if row.isFetching {
                    ProgressView().controlSize(.small)
                } else if row.problem != nil {
                    Text("failed").foregroundStyle(Color(Palette.deleted))
                } else if let date = row.lastFetch {
                    Text(Formatters.shortRelative(date, now: .now))
                } else {
                    Text(row.hasRemotes ? "never" : "no remote").foregroundStyle(.tertiary)
                }
            }
            .width(min: 80, ideal: 100)
            TableColumn("Status") { row in
                let status = row.status
                HStack(spacing: 6) {
                    Circle().fill(color(status.tone)).frame(width: 7, height: 7)
                    Text(status.text).lineLimit(1)
                }
            }
            .width(min: 160, ideal: 260)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let row = model.rows.first(where: { $0.id == id }) {
                Button("Open") { appModel.open(row.url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
                Divider()
                Button("Remove from List") {
                    if let recent = appModel.recents.first(where: { $0.path == row.path }) { appModel.removeRecent(recent) }
                }
            }
        } primaryAction: { ids in
            for id in ids {
                if let row = model.rows.first(where: { $0.id == id }) { appModel.open(row.url) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if model.isFetchingAll {
                ProgressView().controlSize(.mini)
                Text("Fetching all…")
            } else if let last = model.lastFetchAll {
                Text("Fetched all \(Formatters.shortRelative(last, now: .now))")
            } else {
                Text("Open repositories fetch \(Preferences.fetchInterval.title.lowercased())")
            }
            Text("·")
            Text("Double-click to open its window")
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(.bar)
    }

    private func number(_ value: Int, loaded: Bool) -> some View {
        Text(loaded ? "\(value)" : "")
            .monospacedDigit()
            .foregroundStyle(value == 0 ? .tertiary : .primary)
    }

    private func color(_ tone: RepositoryOverview.Tone) -> Color {
        switch tone {
        case .good: Color(Palette.added)
        case .attention: Color.orange
        case .problem: Color(Palette.deleted)
        case .quiet: Color.secondary.opacity(0.6)
        case .info: Color.accentColor
        }
    }
}
