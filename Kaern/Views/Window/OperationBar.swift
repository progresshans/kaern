import KaernKit
import SwiftUI

/// Full-width bar under the toolbar while a rebase, merge, cherry-pick or revert waits, or while
/// HEAD is detached ("Kaern C / Operation Bar"). The toolbar stays usable; commands that would
/// conflict are disabled.
struct OperationBar: View {
    let model: RepositoryModel

    private enum Style {
        case conflicts
        case ready
        case detached

        var tint: Color {
            switch self {
            case .conflicts: Color(Palette.modified)
            case .ready: Color(Palette.added)
            case .detached: Color.accentColor
            }
        }

        var systemImage: String {
            switch self {
            case .conflicts: "exclamationmark.triangle"
            case .ready: "checkmark"
            case .detached: "arrow.triangle.branch"
            }
        }
    }

    var body: some View {
        if let operation = model.operation {
            bar(style: model.status.conflictCount > 0 ? .conflicts : .ready,
                title: title(for: operation), detail: detail(for: operation)) {
                operationButtons(operation)
            }
        } else if model.isDetached, let head = model.status.headID {
            bar(style: .detached,
                title: String(localized: "HEAD is detached at \(String(head.prefix(7)))"),
                detail: String(localized: "new commits won’t belong to any branch")) {
                detachedButtons
            }
        }
    }

    private func bar(style: Style, title: String, detail: String, @ViewBuilder buttons: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: style.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(style.tint)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(2)
            Text("— \(detail)")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                buttons()
            }
            .controlSize(.small)
            .disabled(model.activity != nil)
            .fixedSize()
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                style.tint.opacity(0.1)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) — \(detail)")
    }

    // MARK: Operation

    private var conflictsLeft: String {
        let count = model.status.conflictCount
        return count == 1 ? String(localized: "1 conflict left") : String(localized: "\(count) conflicts left")
    }

    private func title(for operation: OperationState) -> String {
        let conflicts = model.status.conflictCount
        // Staged changes with no conflicts left: resolved (maybe in an earlier session). Nothing
        // staged: the operation paused on purpose (an "edit" stop).
        if conflicts == 0 && (!model.resolvedConflicts.isEmpty || !model.operationStagedEntries.isEmpty) {
            return String(localized: "All conflicts resolved")
        }
        let sha = String((operation.incoming ?? "").prefix(7))
        switch operation.kind {
        case .rebase:
            if conflicts == 0 { return String(localized: "Rebase paused at \(sha)") }
            return String(localized: "Rebasing \(model.headTitle) onto \(model.oursLabel)")
        case .merge:
            return String(localized: "Merging \(model.theirsLabel) into \(model.oursLabel)")
        case .cherryPick:
            return String(localized: "Cherry-picking \(sha) onto \(model.oursLabel)")
        case .revert:
            return String(localized: "Reverting \(sha) on \(model.oursLabel)")
        }
    }

    private func detail(for operation: OperationState) -> String {
        let conflicts = model.status.conflictCount
        if conflicts > 0 {
            if operation.kind == .rebase, let step = operation.step, let total = operation.total {
                return String(localized: "stopped at commit \(step) of \(total) · \(conflictsLeft)")
            }
            return conflictsLeft
        }
        switch operation.kind {
        case .rebase:
            if let step = operation.step, let total = operation.total, step < total {
                return String(localized: "press Continue to replay commit \(step + 1) of \(total)")
            }
            return String(localized: "press Continue to finish the rebase")
        case .merge:
            return String(localized: "press Commit Merge to finish the merge")
        case .cherryPick:
            return String(localized: "press Continue to finish the cherry-pick")
        case .revert:
            return String(localized: "press Continue to finish the revert")
        }
    }

    @ViewBuilder
    private func operationButtons(_ operation: OperationState) -> some View {
        let conflicts = model.status.conflictCount
        Button(abortTitle(operation.kind)) { model.requestAbortOperation() }
        if operation.kind.canSkip {
            Button("Skip Commit") { Task { await model.skipOperationStep() } }
                .help("Leave this commit out and go on")
        }
        Button(operation.kind == .merge ? "Commit Merge" : "Continue") {
            Task { await model.continueOperation() }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(model.quickSwitcherQuery == nil ? KeyboardShortcut(.return, modifiers: .command) : nil)
        .disabled(conflicts > 0)
        .help(conflicts > 0 ? "Resolve the conflicts first" : "⌘↩")
    }

    private func abortTitle(_ kind: OperationState.Kind) -> LocalizedStringKey {
        switch kind {
        case .merge: "Abort Merge"
        case .rebase: "Abort Rebase"
        case .cherryPick: "Abort Cherry-Pick"
        case .revert: "Abort Revert"
        }
    }

    // MARK: Detached HEAD

    @ViewBuilder
    private var detachedButtons: some View {
        if let previous = model.previousBranch, let ref = model.refs.localBranch(named: previous) {
            Button("Switch to \(previous)") { model.requestSwitch(to: ref) }
        }
        Button("Create Branch Here…") {
            model.sheet = .newBranch(startPoint: nil, label: model.headTitle)
        }
        .buttonStyle(.borderedProminent)
    }
}
