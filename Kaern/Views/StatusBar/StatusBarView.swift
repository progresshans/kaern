import KaernKit
import SwiftUI

/// The status bar (ScreenStatusBar rules): on the left the one thing happening now — blocked
/// work first, then work in progress, then the usual "Fetched … ago"; on the right this
/// repository's change summary (changes · staged · ↑↓).
struct StatusBarView: View {
    let repository: RepositoryModel

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
    }

    @ViewBuilder
    private func leading(now: Date) -> some View {
        let state = StatusState(repository: repository, now: now)
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
        }
    }

    private var summary: String {
        guard repository.phase == .ready || repository.phase == .light || repository.phase == .loading else { return "" }
        let status = repository.status
        var parts: [String] = []
        if status.isClean {
            parts.append("No changes")
        } else {
            parts.append(Formatters.count(status.entries.count, "change", "changes"))
            if repository.statusIsFull { parts.append("\(status.stagedCount) staged") }
        }
        if status.upstream != nil {
            parts.append("↑\(status.ahead) to push")
            if status.behind > 0 { parts.append("↓\(status.behind) to pull") }
        }
        return parts.joined(separator: " · ")
    }
}

/// What the left side shows, in priority order.
private struct StatusState {
    enum IconKind { case ok, idle, spinner, warning, conflict, rebase, detached, info }

    var icon: IconKind
    var text: String

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
        if status.conflictCount > 0 {
            icon = .conflict
            text = status.conflictCount == 1 ? "1 file has conflicts" : "\(status.conflictCount) files have conflicts"
            return
        }
        if let activity = repository.activity {
            icon = .spinner
            text = activity.statusText
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
            return
        }
        if repository.remotes.isEmpty, repository.phase == .ready {
            icon = .idle
            text = "No remote — this repository is only on this Mac"
            return
        }
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
