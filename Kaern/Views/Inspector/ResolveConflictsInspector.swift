import KaernKit
import SwiftUI

/// The Changes inspector while an operation waits: conflicted files first, what git merged on its
/// own, and the message for the commit Continue makes.
struct ResolveConflictsInspector: View {
    @Bindable var model: RepositoryModel

    private var selectedPath: Binding<String?> {
        Binding(
            get: {
                if case .working(let path) = model.selectedFile { return path }
                return nil
            },
            set: { model.selectedFile = $0.map { .working($0) } }
        )
    }

    private var selectedConflict: StatusEntry? {
        guard case .working(let path) = model.selectedFile else { return nil }
        return model.conflictedEntries.first { $0.path == path }
    }

    private var resolved: [StatusEntry] {
        model.operationStagedEntries.filter { model.resolvedConflicts.contains($0.path) }
    }

    private var mergedAutomatically: [StatusEntry] {
        model.operationStagedEntries.filter { !model.resolvedConflicts.contains($0.path) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            List(selection: selectedPath) {
                if !model.conflictedEntries.isEmpty {
                    Section {
                        ForEach(model.conflictedEntries) { entry in
                            HStack(spacing: 6) {
                                StatusLetter(kind: .conflicted)
                                PathLabel(path: entry.path)
                                Spacer(minLength: 4)
                                Text(Self.conflictDescription(entry))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .frame(height: 22)
                            .tag(entry.path)
                            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                            .contextMenu { conflictMenu(entry) }
                        }
                        resolveButtons
                            .selectionDisabled()
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                    } header: {
                        sectionTitle("Conflicted")
                    }
                }
                if !resolved.isEmpty {
                    Section {
                        ForEach(resolved) { entry in
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color(Palette.added))
                                    .frame(width: 12)
                                PathLabel(path: entry.path)
                                Spacer(minLength: 4)
                                LineStatLabel(stat: model.lineStats[entry.path])
                            }
                            .frame(height: 22)
                            .tag(entry.path)
                            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                        }
                    } header: {
                        sectionTitle("Resolved")
                    }
                }
                if !mergedAutomatically.isEmpty {
                    Section {
                        ForEach(mergedAutomatically) { entry in
                            HStack(spacing: 6) {
                                StatusLetter(kind: entry.kind)
                                PathLabel(path: entry.path, oldPath: entry.originalPath)
                                Spacer(minLength: 4)
                                LineStatLabel(stat: model.lineStats[entry.path])
                            }
                            .frame(height: 22)
                            .tag(entry.path)
                            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                        }
                    } header: {
                        sectionTitle("Merged Automatically")
                    }
                }
                if !model.operationUnstagedEntries.isEmpty {
                    Section {
                        ForEach(model.operationUnstagedEntries) { entry in
                            ChangeRow(entry: entry, stat: model.lineStats[entry.path]) {
                                Task { await model.toggleStaging(entry) }
                            }
                            .tag(entry.path)
                            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                        }
                    } header: {
                        sectionTitle("Not Staged")
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 24)

            Divider()
            messageEditor
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.status.conflictCount > 0 ? "Resolve Conflicts" : "Ready to Continue")
                .font(.system(size: 13, weight: .bold))
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var summary: String {
        var parts: [String] = []
        if let operation = model.operation, operation.kind == .rebase, let step = operation.step, let total = operation.total {
            parts.append(String(localized: "Commit \(step) of \(total)"))
        }
        let conflicts = model.status.conflictCount
        parts.append(conflicts == 1 ? String(localized: "1 conflicted") : String(localized: "\(conflicts) conflicted"))
        let merged = mergedAutomatically.count
        if merged > 0 {
            parts.append(String(localized: "\(merged) merged automatically"))
        }
        return parts.joined(separator: " · ")
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    static func conflictDescription(_ entry: StatusEntry) -> String {
        switch (entry.indexStatus, entry.worktreeStatus) {
        case ("D", "D"): String(localized: "both deleted")
        case ("A", "U"): String(localized: "added by us")
        case ("U", "D"): String(localized: "deleted by them")
        case ("U", "A"): String(localized: "added by them")
        case ("D", "U"): String(localized: "deleted by us")
        case ("A", "A"): String(localized: "both added")
        default: ""
        }
    }

    // MARK: Resolving

    @ViewBuilder
    private var resolveButtons: some View {
        if let entry = selectedConflict {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button("Keep \(model.oursLabel)") {
                        Task { await model.resolveConflict(entry.path, taking: .ours) }
                    }
                    .help("Use \(model.oursLabel)’s version of the whole file")
                    Button("Keep \(model.theirsLabel)") {
                        Task { await model.resolveConflict(entry.path, taking: .theirs) }
                    }
                    .help("Use \(model.theirsLabel)’s version of the whole file")
                }
                .controlSize(.small)
                .lineLimit(1)
                Button("Open in FileMerge") {
                    Task { await model.openInFileMerge(entry.path) }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            .disabled(model.activity != nil)
        } else {
            Text("Select a file to resolve it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func conflictMenu(_ entry: StatusEntry) -> some View {
        Button("Keep \(model.oursLabel)") { Task { await model.resolveConflict(entry.path, taking: .ours) } }
        Button("Keep \(model.theirsLabel)") { Task { await model.resolveConflict(entry.path, taking: .theirs) } }
        Button("Mark as Resolved") { Task { await model.markResolved(entry.path) } }
        Button("Open in FileMerge") { Task { await model.openInFileMerge(entry.path) } }
        Divider()
        Button("Open in \(Preferences.editor.title)") { model.openInEditor(entry.path) }
        Button("Reveal in Finder") { model.revealInFinder(entry.path) }
        Button("Copy Path") { Pasteboard.copy(entry.path) }
    }

    // MARK: Message

    private var messageTitle: String {
        guard let operation = model.operation else { return "" }
        switch operation.kind {
        case .rebase:
            if let step = operation.step, let total = operation.total {
                return String(localized: "Message for commit \(step) of \(total)")
            }
            return String(localized: "Message for this commit")
        case .merge: return String(localized: "Merge commit message")
        case .cherryPick: return String(localized: "Message for the picked commit")
        case .revert: return String(localized: "Message for the revert")
        }
    }

    private var footnote: String {
        let conflicts = model.status.conflictCount
        let action = model.operation?.kind == .merge ? String(localized: "Commit Merge") : String(localized: "Continue")
        switch conflicts {
        case 0: return String(localized: "Press \(action) in the bar above. The message is kept.")
        case 1: return String(localized: "Resolve the file, then press \(action) in the bar above. The message is kept.")
        case 2: return String(localized: "Resolve both files, then press \(action) in the bar above. The message is kept.")
        default: return String(localized: "Resolve all \(conflicts) files, then press \(action) in the bar above. The message is kept.")
        }
    }

    private var messageEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(messageTitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextEditor(text: $model.operationMessage)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 3)
                .padding(.vertical, 5)
                .frame(height: 90)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
                )
                .disabled(model.operation?.canEditMessage != true)
                .accessibilityLabel(messageTitle)
            Text(footnote)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }
}
