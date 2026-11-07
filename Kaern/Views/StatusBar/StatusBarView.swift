import KaernKit
import SwiftUI

/// The status bar (ScreenStatusBar rules): on the left the one thing happening now — blocked
/// work first, then work in progress, then the usual "Fetched … ago"; on the right this
/// repository's change summary (changes · staged · ↑↓). Clicking the left side opens Activity.
struct StatusBarView: View {
    let repository: RepositoryModel
    @State private var showsActivity = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 7) {
                leading(now: context.date)
                Spacer(minLength: 12)
                Text(summary)
                    .foregroundStyle(K.label2)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 14)
        .frame(height: KMetric.statusBar)
        .frame(maxWidth: .infinity)
        .background {
            ZStack(alignment: .top) {
                K.win
                K.sep.frame(height: 1)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kaernShowActivity)) { note in
            if (note.object as? String) == repository.id { showsActivity = true }
        }
    }

    @ViewBuilder
    private func leading(now: Date) -> some View {
        let state = StatusState(repository: repository, now: now)
        HStack(spacing: 7) {
            Button { showsActivity.toggle() } label: {
                HStack(spacing: 7) {
                    switch state.icon {
                    case .ok: Circle().fill(K.ok).frame(width: 7, height: 7).frame(width: 14)
                    case .idle: Circle().strokeBorder(K.label3, lineWidth: 1.6).frame(width: 8, height: 8).frame(width: 14)
                    case .spinner: StatusSpinner().frame(width: 14)
                    case .warning: Icon(Icons.warn, size: 13).foregroundStyle(K.warn).frame(width: 14)
                    case .conflict: Icon(Icons.conflict, size: 13).foregroundStyle(K.err).frame(width: 14)
                    case .rebase: Icon(Icons.rebase, size: 13).foregroundStyle(K.accentText).frame(width: 14)
                    case .detached: Icon(Icons.detached, size: 13).foregroundStyle(K.accentText).frame(width: 14)
                    case .info: Icon(Icons.info, size: 13).foregroundStyle(K.label3).frame(width: 14)
                    }
                    Text(state.text)
                        .foregroundStyle(state.icon == .ok || state.icon == .idle ? K.label2 : K.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if state.isTaskCount {
                        Icon(Icons.chevronDown, size: 8).rotationEffect(.degrees(180)).foregroundStyle(K.label2)
                    }
                }
                .padding(.horizontal, state.isTaskCount ? 6 : 0)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(state.isTaskCount ? K.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Activity (⌥⌘A)")
            .popover(isPresented: $showsActivity, arrowEdge: .top) {
                ActivityPopover(repository: repository) { showsActivity = false }
            }
            if let action = state.action {
                StatusButton(title: action.title, accent: action.accent, action: action.run)
            }
            if repository.rewroteUpstream, repository.activity == nil, let upstream = repository.status.upstream {
                // Pushing now needs force (ScreenFlowPush's status bar).
                Text("·").foregroundStyle(K.label2)
                Text("↑\(repository.status.ahead) ↓\(repository.status.behind) — you rewrote commits that are on \(upstream.split(separator: "/").first.map(String.init) ?? upstream)")
                    .foregroundStyle(K.warn)
                    .lineLimit(1)
            }
        }
    }

    private var summary: String {
        guard repository.phase == .ready || repository.phase == .light || repository.phase == .loading else { return "" }
        if let explore = repository.exploreSummary { return explore }
        // During a rebase the right side says where it is (ScreenConflicts).
        if let operation = repository.operation, operation.kind == .rebase, let step = operation.step, let total = operation.total {
            return "Rebase in progress · commit \(step) of \(total)"
        }
        let status = repository.status
        var parts: [String] = []
        if status.isClean {
            parts.append("No changes")
        } else {
            parts.append(Formatters.count(status.entries.count, "change", "changes"))
            if repository.statusIsFull { parts.append("\(status.stagedCount) staged") }
        }
        if status.upstream != nil {
            // Offline: the counts are from the last fetch.
            if !AutoFetcher.shared.isOnline, let since = repository.lastFetch ?? AutoFetcher.shared.offlineSince {
                parts.append("↑\(status.ahead) (as of \(Formatters.time(since)))")
            } else {
                parts.append("↑\(status.ahead) to push")
            }
            if status.behind > 0 { parts.append("↓\(status.behind) to pull") }
        } else if let branch = status.branch, !repository.remotes.isEmpty {
            parts.append("\(branch) isn’t published yet")
        }
        return parts.joined(separator: " · ")
    }
}

extension Notification.Name {
    /// Opens Activity from the status bar of the repository whose id is the object (⌥⌘A).
    static let kaernShowActivity = Notification.Name("KaernShowActivity")
}

/// `.sbtn`: the one button that clears the state (Sign In…, Resolve…, Try Now).
private struct StatusButton: View {
    let title: String
    var accent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(accent ? K.accentText : K.label)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .controlSurface(radius: 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// What the left side shows, in priority order: blocked → in progress → usual.
@MainActor
private struct StatusState {
    enum IconKind { case ok, idle, spinner, warning, conflict, rebase, detached, info }

    struct Action {
        var title: String
        var accent = false
        var run: () -> Void
    }

    var icon: IconKind
    var text: String
    var action: Action?
    /// "3 tasks running" (a chip that opens Activity).
    var isTaskCount = false

    init(repository: RepositoryModel, now: Date) {
        switch repository.phase {
        case .missing:
            icon = .warning
            text = "Folder not found at \(Formatters.abbreviatedPath(repository.path))"
            return
        case .failed(let message):
            icon = .warning
            text = message
            return
        case .waiting, .opening:
            icon = .spinner
            text = "Opening \(repository.name)…"
            return
        case .loading:
            icon = .spinner
            text = "Loading history…"
            return
        case .light, .ready:
            break
        }
        let status = repository.status
        // Blocked work first.
        if status.conflictCount > 0 {
            icon = .conflict
            text = status.conflictCount == 1 ? "1 file has conflicts" : "\(status.conflictCount) files have conflicts"
            if repository.screen != .conflicts {
                action = Action(title: "Resolve…", accent: true) { repository.openConflicts() }
            }
            return
        }
        if let problem = repository.fetchProblem, let failure = problem.failure, repository.activity == nil {
            switch failure {
            case .signIn(let host):
                let service = FailureHelp.serviceName(host ?? repository.remoteHost)
                icon = .warning
                text = "Couldn’t fetch \(problem.remote) — your \(service) sign-in expired"
                action = Action(title: "Sign In…", accent: true) {
                    SettingsWindowController.shared.showSignIn(host: host ?? repository.remoteHost ?? "github.com")
                }
                return
            case .sshKey(let host):
                icon = .warning
                text = "Couldn’t fetch \(problem.remote) — \(host ?? "the server") didn’t accept your SSH key"
                return
            case .network(let host) where AutoFetcher.shared.isOnline:
                icon = .warning
                text = "Couldn’t reach \(host ?? problem.remote)"
                action = Action(title: "Try Again") { repository.from("Status bar") { repository.fetch() } }
                return
            default:
                break
            }
        }
        // Then work in progress.
        let running = ActivityCenter.shared.runningCount
        if running > 1 {
            icon = .spinner
            text = "\(running) tasks running"
            isTaskCount = true
            return
        }
        if let activity = repository.activity {
            icon = .spinner
            text = activity.statusText
            if activity.isNetwork {
                action = Action(title: "Cancel") { repository.activityTask?.cancel() }
            }
            return
        }
        if let operation = repository.operation {
            icon = .rebase
            text = Self.describe(operation, branch: status.branch)
            return
        }
        if case .detached(let id) = status.head, !id.isEmpty {
            icon = .detached
            text = "HEAD is detached at \(id.prefix(7)) — new commits won’t be on a branch"
            action = Action(title: "Create Branch…", accent: true) { repository.askCreateBranch(at: nil) }
            return
        }
        if repository.remotes.isEmpty, repository.phase == .ready {
            icon = .idle
            text = "No remote — this repository is only on this Mac"
            return
        }
        if !AutoFetcher.shared.isOnline {
            icon = .idle
            text = "Offline — auto-fetch is paused until you’re back online"
            action = Action(title: "Try Now") { repository.from("Status bar") { repository.fetch() } }
            return
        }
        // The usual.
        let remote = repository.defaultRemote ?? "origin"
        if let fetched = repository.lastFetch {
            icon = .ok
            text = "Fetched from \(remote) \(Formatters.shortRelative(fetched, now: now))"
        } else {
            icon = .idle
            text = "Not fetched from \(remote) yet"
        }
    }

    static func describe(_ operation: OperationState, branch: String?) -> String {
        switch operation.kind {
        case .rebase:
            var text = "Rebasing \(operation.branch ?? branch ?? "HEAD")"
            if let onto = operation.onto { text += " onto \(onto.prefix(7))" }
            if let step = operation.step, let total = operation.total { text += " — \(step) of \(total)" }
            return text
        case .merge:
            return "Merging \(operation.incomingName ?? operation.incoming.map { String($0.prefix(7)) } ?? "a branch") into \(branch ?? "HEAD")"
        case .cherryPick:
            return "Cherry-picking \(operation.incoming.map { String($0.prefix(7)) } ?? "a commit")"
        case .revert:
            return "Reverting \(operation.incoming.map { String($0.prefix(7)) } ?? "a commit")"
        }
    }
}

/// The status bar's small spinner (`.bspin`).
private struct StatusSpinner: View {
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle().stroke(K.label3, lineWidth: 1.6)
            Circle().trim(from: 0, to: 0.25).stroke(K.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
        }
        .frame(width: 9.4, height: 9.4)
        .onAppear {
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spinning = true }
        }
    }
}

// MARK: - Activity

/// ScreenStatusBar's Activity: what's running (with Cancel) and what finished lately (a
/// failure keeps its fix), then Show Command Log.
struct ActivityPopover: View {
    let repository: RepositoryModel
    let close: () -> Void
    private let center = ActivityCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Activity").font(.system(size: 13, weight: .bold))
                Spacer()
                Button(action: close) {
                    Icon(Icons.close, size: 10).foregroundStyle(K.label2).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(HoverPlateStyle(radius: 5))
                .accessibilityLabel("Close")
            }
            .padding(.bottom, 8)
            if center.running.isEmpty && center.recent.isEmpty {
                Text("Nothing running. What Kaern does — fetches, pushes, merges — shows here.")
                    .font(.system(size: 12))
                    .foregroundStyle(K.label2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            }
            ForEach(center.running) { item in
                RunningRow(item: item, title: title(item), canCancel: center.canCancel(item.id)) { center.cancel(item.id) }
            }
            if !center.recent.isEmpty {
                if !center.running.isEmpty { K.sep.frame(height: 1).padding(.vertical, 8) }
                Text("Recently")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(K.label2)
                    .padding(.bottom, 6)
                ForEach(center.recent) { item in
                    RecentRow(item: item, title: recentTitle(item), help: item.failure.map {
                        FailureHelp.make($0, repositoryPath: item.repositoryPath, repositoryName: item.repositoryName, auto: item.isAuto)
                    })
                }
            }
            K.sep.frame(height: 1).padding(.vertical, 8)
            HStack {
                Button("Show Command Log") {
                    close()
                    CommandLogWindowController.shared.show(repository: repository.path)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(K.accentText)
                Spacer()
                Text("⇧⌘L").font(.system(size: 11.5)).foregroundStyle(K.label2)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(width: 380)
    }

    private func title(_ item: ActivityCenter.Item) -> String {
        guard !item.repositoryName.isEmpty, item.repositoryPath != repository.path else { return item.title }
        return item.title + " in " + item.repositoryName
    }

    private func recentTitle(_ item: ActivityCenter.Item) -> String {
        let place = item.repositoryName.isEmpty || item.repositoryPath == repository.path ? "" : " in " + item.repositoryName
        if item.failed {
            let help = item.failure.map { FailureHelp.make($0, repositoryPath: item.repositoryPath, repositoryName: item.repositoryName, auto: item.isAuto) }
            return Self.failedTitle(item.title) + place + (help.map { " — " + $0.short } ?? "")
        }
        return (item.result ?? item.title) + place
    }

    /// "Fetching origin" → "Fetch failed".
    static func failedTitle(_ title: String) -> String {
        let verb = title.split(separator: " ").first.map(String.init) ?? title
        let base = verb.hasSuffix("ing") ? String(verb.dropLast(3)) : verb
        let fixed = ["Fetch": "Fetch", "Push": "Push", "Pull": "Pull", "Commit": "Commit", "Merg": "Merge", "Rebas": "Rebase",
                     "Switch": "Switch", "Stash": "Stash", "Creat": "Create", "Delet": "Delete", "Renam": "Rename",
                     "Applying": "Apply", "Popp": "Pop", "Revert": "Revert", "Cherry-pick": "Cherry-pick"][base] ?? base
        return fixed + " failed"
    }
}

private struct RunningRow: View {
    let item: ActivityCenter.Item
    let title: String
    let canCancel: Bool
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Spinner(size: 14)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                ProgressView().progressViewStyle(.linear).controlSize(.small)
                if let detail = item.detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(K.label2).lineLimit(1)
                }
            }
            if canCancel {
                GhostButton(title: "Cancel", action: cancel)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct RecentRow: View {
    let item: ActivityCenter.Item
    let title: String
    let help: FailureHelp?

    var body: some View {
        HStack(spacing: 9) {
            if item.failed {
                Icon(Icons.warn, size: 13).foregroundStyle(K.warn)
            } else {
                Circle().fill(K.ok).frame(width: 9, height: 9).frame(width: 13)
            }
            Text(title)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(item.failed ? (help?.message ?? item.result ?? "") : (item.result ?? ""))
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Formatters.shortRelative(item.finished ?? item.started, now: context.date))
                    .font(.system(size: 11.5))
                    .foregroundStyle(K.label2)
                    .fixedSize()
            }
            if let help, let fixTitle = help.fixTitle, let fix = help.fix {
                GhostButton(title: fixTitle.hasPrefix("Sign In") ? "Sign In…" : fixTitle, action: fix)
            }
        }
        .padding(.vertical, 4)
    }
}
