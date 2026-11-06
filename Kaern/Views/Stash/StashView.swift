import KaernKit
import SwiftUI

/// A stash picked in the sidebar: every file's changes one after another ("‹ History" or Esc
/// goes back).
struct StashView: View {
    let model: RepositoryModel
    let state: StashViewState
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onExitCommand { model.closeStash() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                model.closeStash()
            } label: {
                Label("History", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .help("Back to History (Esc)")

            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1, height: 14)

            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
            Text(state.stash.reference)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(state.stash.message)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let author = state.details?.author {
                Text("\(author.name) · \(Formatters.detailDate(author.date))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    @ViewBuilder
    private var content: some View {
        if let error = state.error {
            ContentUnavailableView {
                Label("Couldn't Read Stash", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
        } else if let details = state.details {
            if details.files.isEmpty {
                ContentUnavailableView("No Changes", systemImage: "archivebox", description: Text("This stash doesn't change any files."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(details.files, id: \.path) { file in
                                Section {
                                    StashFileDiff(file: file, isUntracked: details.untrackedPaths.contains(file.path))
                                } header: {
                                    StashFileHeader(file: file)
                                }
                                .id(file.path)
                            }
                        }
                        .padding(.bottom, 16)
                    }
                    .onChange(of: state.scrollRequest) {
                        if let target = state.scrollTarget {
                            withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(target, anchor: .top) }
                        }
                    }
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension FileDiff {
    /// M, A, D or R for the stash and commit file lists.
    var changeKind: ChangeKind {
        if isNewFile { return .added }
        if isDeletedFile { return .deleted }
        if oldPath != nil, oldPath != path { return .renamed }
        return .modified
    }
}

/// "M  docs/CHANGELOG.md  +6", pinned while its changes scroll by.
private struct StashFileHeader: View {
    let file: FileDiff

    var body: some View {
        HStack(spacing: 8) {
            StatusLetter(kind: file.changeKind)
            PathLabel(path: file.path, oldPath: file.oldPath)
            Spacer(minLength: 8)
            LineStatLabel(stat: file.lineStat)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color(Palette.diffGutter))
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct StashFileDiff: View {
    let file: FileDiff
    let isUntracked: Bool

    var body: some View {
        if file.isBinary {
            note("Binary file — no text changes to show")
        } else if file.hunks.isEmpty {
            note(file.isNewFile ? "Empty file" : "No content changes (mode or rename only)")
        } else {
            // Hunk and line numbers restart in every file; the lazy stack needs IDs unique across files.
            ForEach(file.hunks.indices.map { Keyed(id: "\(file.path)#\($0)", value: $0) }) { keyedHunk in
                let index = keyedHunk.value
                let hunk = file.hunks[index]
                if index > 0 {
                    let previous = file.hunks[index - 1]
                    let gap = hunk.oldStart - (previous.oldStart + previous.oldCount)
                    if gap > 0 { UnchangedLinesRow(count: gap) }
                }
                HStack(spacing: 8) {
                    Text(hunk.rangeDescription)
                    Text(isUntracked && index == 0 ? String(localized: "New file · untracked when stashed") : hunk.section)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Color(Palette.diffHunkBackground))
                ForEach(hunk.lines.map { Keyed(id: "\(file.path)#\(index)-\($0.id)", value: $0) }) { keyed in
                    UnifiedLineRow(line: keyed.value, isSelected: false, isSelectable: false)
                }
            }
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }
}

// MARK: - Inspector

/// The stash like a commit: who and when, where it came from, its files, and Apply · Pop · ….
struct StashInspector: View {
    let model: RepositoryModel
    let state: StashViewState

    private var stash: Stash { state.stash }

    var body: some View {
        VStack(spacing: 0) {
            List {
                header
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 14, leading: 14, bottom: 6, trailing: 14))
                if let details = state.details {
                    Section {
                        ForEach(details.files, id: \.path) { file in
                            HStack(spacing: 6) {
                                StatusLetter(kind: file.changeKind)
                                PathLabel(path: file.path, oldPath: file.oldPath)
                                Spacer(minLength: 4)
                                LineStatLabel(stat: file.lineStat)
                            }
                            .frame(height: 22)
                            .contentShape(Rectangle())
                            .onTapGesture { model.scrollStash(to: file.path) }
                            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                            .contextMenu {
                                Button("Copy Path") { Pasteboard.copy(file.path) }
                            }
                        }
                    } header: {
                        filesHeader(details)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 24)

            Divider()
            HStack(spacing: 8) {
                Button("Apply") { Task { await model.apply(stash, pop: false) } }
                    .help("Put these changes into the working tree and keep the stash (⌘Z takes it back)")
                Button("Pop") { Task { await model.apply(stash, pop: true) } }
                    .help("Apply, then remove the stash from the list — it stays if applying conflicts (⌘Z takes it back)")
                Menu {
                    Button("Create Branch from Stash…") { model.sheet = .branchFromStash(stash) }
                        .disabled(!model.canStartOperation)
                    Button("Copy Stash Message") { Pasteboard.copy(stash.message) }
                    Divider()
                    Button("Drop Stash", role: .destructive) { Task { await model.drop(stash) } }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
                Spacer()
            }
            .disabled(model.activity != nil || model.operation != nil)
            .padding(12)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(stash.message)
                .font(.system(size: 13, weight: .bold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let details = state.details {
                HStack(spacing: 8) {
                    AuthorAvatar(name: details.author.name, email: details.author.email)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(details.author.name)
                            .font(.system(size: 13, weight: .semibold))
                        Text(Formatters.detailDate(details.author.date))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .help(details.author.email)

                Text(origin(details))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        label("Stash")
                        HStack(spacing: 4) {
                            Text(stash.reference)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                            Button {
                                Pasteboard.copy(stash.id)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .help("Copy the stash's SHA")
                        }
                    }
                    GridRow {
                        label("Based on")
                        Button(String(details.baseID.prefix(7))) { model.showStashBase(details.baseID) }
                            .buttonStyle(.link)
                            .font(.system(size: 11, design: .monospaced))
                            .help("Show the commit the changes were made on")
                    }
                    if let branch = details.branch {
                        GridRow {
                            label("On")
                            BranchChip(name: branch, isHead: branch == model.status.branch)
                        }
                    }
                }
            } else if state.error == nil {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// "Stashed from develop, including untracked files."
    private func origin(_ details: StashDetails) -> String {
        switch (details.branch, details.includesUntracked) {
        case (let branch?, true): String(localized: "Stashed from \(branch), including untracked files.")
        case (let branch?, false): String(localized: "Stashed from \(branch).")
        case (nil, true): String(localized: "Stashed by Kaern, including untracked files.")
        case (nil, false): String(localized: "Stashed by Kaern.")
        }
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    private func filesHeader(_ details: StashDetails) -> some View {
        let total = details.files.reduce(into: (0, 0)) { sum, file in
            let stat = file.lineStat
            sum.0 += stat.additions ?? 0
            sum.1 += stat.deletions ?? 0
        }
        return HStack {
            Text(details.files.count == 1 ? "1 File Changed" : "\(details.files.count) Files Changed")
            Spacer()
            LineStatLabel(stat: LineStat(additions: total.0, deletions: total.1))
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
    }
}

/// Create Branch from Stash…: a name for the branch made at the stash's base commit.
struct StashBranchSheet: View {
    let model: RepositoryModel
    let stash: Stash

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var problem: String?
    @State private var isValid = false
    @State private var isCreating = false

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        FormSheet(title: String(localized: "Create Branch from “\(stash.message)”")) {
            GridRow {
                FormLabel("Name:")
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Branch name")
                    .onSubmit(create)
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                if let problem {
                    FormNote(text: problem, isError: true)
                } else {
                    FormNote(text: String(localized: "The branch starts at the commit the stash was made on and gets its changes. The stash leaves the list."))
                }
            }
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create Branch", action: create)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isCreating)
        }
        .onAppear {
            // "On develop: release notes draft" → "release-notes-draft"
            let text = stash.message.split(separator: ":", maxSplits: 1).last.map(String.init) ?? stash.message
            name = text.trimmingCharacters(in: .whitespaces).lowercased()
                .map { $0.isLetter || $0.isNumber ? $0 : "-" }
                .reduce(into: "") { result, character in
                    if character == "-", result.hasSuffix("-") || result.isEmpty { return }
                    result.append(character)
                }
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        .task(id: trimmed) {
            guard let repository = model.repository, !trimmed.isEmpty else {
                isValid = false
                problem = nil
                return
            }
            if model.refs.localBranch(named: trimmed) != nil {
                isValid = false
                problem = String(localized: "A branch named “\(trimmed)” already exists.")
            } else if await repository.isValidBranchName(trimmed) {
                isValid = true
                problem = nil
            } else {
                isValid = false
                problem = String(localized: "That isn't a valid branch name.")
            }
        }
    }

    private func create() {
        guard isValid, !isCreating else { return }
        isCreating = true
        let branch = trimmed
        Task {
            await model.createBranch(branch, from: stash)
            isCreating = false
            dismiss()
        }
    }
}
