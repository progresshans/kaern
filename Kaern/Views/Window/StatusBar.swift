import KaernKit
import SwiftUI

/// The fetch state lives at the bottom of the window, where Finder shows its status bar:
/// Fetched · Fetching · Offline · Diverged.
struct StatusBar: View {
    let model: RepositoryModel
    @Environment(AppModel.self) private var appModel

    private var remoteName: String {
        model.upstreamRemote ?? (model.remotes.contains("origin") ? "origin" : model.remotes.first) ?? "origin"
    }

    private var isDiverged: Bool { model.status.ahead > 0 && model.status.behind > 0 }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 10) {
                PaneToggle(systemImage: "sidebar.left", label: "Sidebar", isShown: model.showSidebar,
                           help: model.showSidebar ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)") {
                    withAnimation(.snappy(duration: 0.2)) { model.showSidebar.toggle() }
                }
                if let hint = model.undoHint {
                    undoHint(hint)
                } else {
                    fetchState(now: context.date)
                }
                if model.status.upstream != nil {
                    separator
                    syncState
                } else if model.isDetached {
                    separator
                    Text("No upstream — not on a branch")
                } else if model.status.branch != nil && model.hasHead && !model.remotes.isEmpty {
                    separator
                    Text("Not published to \(remoteName)")
                }
                Spacer(minLength: 12)
                if let operation = model.operation {
                    Text(conflictSummary)
                    separator
                    Text(operationSummary(operation))
                } else {
                    Text(changesSummary)
                    if let searchSummary = model.searchSummary {
                        separator
                        Text(searchSummary)
                            .foregroundStyle(.primary)
                            .truncationMode(.middle)
                    } else if let commitsSummary {
                        separator
                        Text(commitsSummary)
                            .truncationMode(.middle)
                    }
                }
                PaneToggle(systemImage: "sidebar.right", label: "Inspector", isShown: model.isInspectorVisible,
                           help: model.isInspectorVisible ? "Hide Inspector (⌥⌘0)" : "Show Inspector (⌥⌘0)") {
                    withAnimation(.snappy(duration: 0.2)) { model.toggleInspector() }
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 5)
        .frame(height: 26)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
    }

    /// "Discarded changes to a.txt · Undo" for a few seconds after a change ⌘Z can take back.
    private func undoHint(_ hint: UndoHint) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10, weight: .semibold))
            Text(hint.text)
                .foregroundStyle(.primary)
                .truncationMode(.middle)
            Button("Undo (⌘Z)") { model.undoManager?.undo() }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .disabled(model.activity != nil)
        }
        .transition(.opacity)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: 12)
    }

    @ViewBuilder
    private func fetchState(now: Date) -> some View {
        if model.activity == .fetching {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Fetching from \(remoteName)…")
            }
        } else if model.remotes.isEmpty {
            Text("No remote")
        } else if model.isWorkingOffline {
            HStack(spacing: 6) {
                Circle().fill(Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                Text("Working offline")
                Button("Fetch to Reconnect") {
                    Task { await model.fetch() }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .disabled(model.activity != nil)
            }
        } else if model.fetchError != nil || !appModel.isOnline {
            HStack(spacing: 6) {
                Circle().fill(Color.orange).frame(width: 7, height: 7)
                if let lastFetch = model.lastFetch {
                    Text("\(remoteName) is unreachable · Last fetched \(Formatters.shortRelative(lastFetch, now: now))")
                } else {
                    Text("\(remoteName) is unreachable")
                }
                Button("Try Again") {
                    Task { await model.fetch() }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .disabled(model.activity != nil)
            }
        } else if let lastFetch = model.lastFetch {
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text("Fetched from \(remoteName) \(Formatters.shortRelative(lastFetch, now: now))")
            }
        } else {
            HStack(spacing: 6) {
                Circle().fill(Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                Text("Not fetched yet")
            }
        }
    }

    private var syncState: some View {
        HStack(spacing: 4) {
            Text("↑\(model.status.ahead) to push")
            Text("·")
            Text("↓\(model.status.behind) to pull")
                .foregroundStyle(isDiverged ? Color(Palette.deleted) : Color.secondary)
            if isDiverged {
                Text("— pull first, then push")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var changesSummary: String {
        let count = model.status.entries.count
        guard count > 0 else { return String(localized: "No changes") }
        let staged = model.status.stagedCount
        let changes = count == 1 ? String(localized: "1 change") : String(localized: "\(count) changes")
        return staged > 0 ? changes + " · " + String(localized: "\(staged) staged") : changes
    }

    private var commitsSummary: String? {
        if model.isDetached, let head = model.status.headID {
            return String(localized: "HEAD detached at \(String(head.prefix(7)))")
        }
        guard let count = model.headCommitCount, model.hasHead else { return nil }
        let where_ = model.status.branch ?? "HEAD"
        return count == 1
            ? String(localized: "1 commit on \(where_)")
            : String(localized: "\(count) commits on \(where_)")
    }

    /// "2 conflicted · 1 merged automatically"
    private var conflictSummary: String {
        let conflicts = model.status.conflictCount
        let merged = model.operationStagedEntries.count { !model.resolvedConflicts.contains($0.path) }
        var parts = [conflicts == 0
            ? String(localized: "All conflicts resolved")
            : String(localized: "\(conflicts) conflicted")]
        if merged > 0 {
            parts.append(String(localized: "\(merged) merged automatically"))
        }
        return parts.joined(separator: " · ")
    }

    private func operationSummary(_ operation: OperationState) -> String {
        switch operation.kind {
        case .rebase:
            if let step = operation.step, let total = operation.total {
                return String(localized: "Rebase in progress · commit \(step) of \(total)")
            }
            return String(localized: "Rebase in progress")
        case .merge: return String(localized: "Merge in progress")
        case .cherryPick: return String(localized: "Cherry-pick in progress")
        case .revert: return String(localized: "Revert in progress")
        }
    }
}

/// The sidebar and inspector toggles, at the ends of the status bar: out of the toolbar, in
/// the same corner whether the pane is showing or not.
private struct PaneToggle: View {
    let systemImage: String
    let label: LocalizedStringKey
    let isShown: Bool
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(width: 26, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(isHovered ? Color.primary.opacity(0.07) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(isShown ? Text("Shown") : Text("Hidden"))
    }
}
