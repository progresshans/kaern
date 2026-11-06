import KaernKit
import SwiftUI

struct RepositorySheetView: View {
    let sheet: RepositorySheet
    let model: RepositoryModel

    var body: some View {
        switch sheet {
        case .newBranch(let startPoint, let label):
            NewBranchSheet(model: model, startPoint: startPoint, startLabel: label)
        case .stash:
            StashSheet(model: model)
        case .switchWithChanges(let ref):
            SwitchWithChangesSheet(model: model, target: ref)
        case .pullThenPush:
            PullThenPushSheet(model: model)
        case .renameBranch(let ref):
            RenameBranchSheet(model: model, ref: ref)
        case .newTag(let commitID, let label):
            NewTagSheet(model: model, commitID: commitID, label: label)
        case .chooseBranch(let choice):
            BranchChooserSheet(model: model, choice: choice)
        case .signIn(let problem):
            SignInSheet(model: model, problem: problem)
        case .log(let title, let text):
            LogSheet(title: title, text: text)
        case .branchFromStash(let stash):
            StashBranchSheet(model: model, stash: stash)
        case .repositorySettings:
            RepositorySettingsSheet(model: model)
        case .interactiveRebase(let onto, let label):
            InteractiveRebaseSheet(model: model, onto: onto, ontoLabel: label)
        case .newWorktree:
            NewWorktreeSheet(model: model)
        case .addSigningKey(let commitID, let signer):
            AddSigningKeySheet(model: model, commitID: commitID, signer: signer)
        }
    }
}

/// Title, labeled rows and buttons — the layout of the New Branch and New Tag sheets.
struct FormSheet<Content: View, Buttons: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(2)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

enum FormMetrics {
    /// Text fields fill a FormSheet's second column. (A Grid doesn't stretch a flexible
    /// field, so it gets the width the column has.)
    static let fieldWidth: CGFloat = 340
}

/// A right-aligned "Name:" label for a FormSheet row.
struct FormLabel: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .gridColumnAlignment(.trailing)
    }
}

/// Secondary text under a field (hints and validation messages).
struct FormNote: View {
    let text: String
    var isError = false

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(isError ? Color(Palette.deleted) : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Shared sheet chrome: icon, title, message, content, then buttons on the trailing edge.
struct SheetScaffold<Content: View, Buttons: View>: View {
    let systemImage: String
    let title: LocalizedStringKey
    var message: LocalizedStringKey?
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                    if let message {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct NewBranchSheet: View {
    let model: RepositoryModel
    let startPoint: String?
    let startLabel: String

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    /// `nil` is HEAD.
    @State private var from: String?
    @State private var checkout = true
    @State private var problem: String?
    @State private var isValid = false
    @State private var isCreating = false

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    /// HEAD, the start point the sheet was opened with, then the other local branches.
    private var sources: [(value: String?, title: String)] {
        var items: [(String?, String)] = [(nil, "\(model.headTitle) (HEAD)")]
        if let startPoint {
            items.append((startPoint, startLabel))
        }
        for branch in model.refs.localBranches where !branch.isHead && branch.name != startPoint {
            items.append((branch.name, branch.name))
        }
        return items
    }

    var body: some View {
        FormSheet(title: String(localized: "New Branch")) {
            GridRow {
                FormLabel("Name:")
                TextField("Name", text: $name, prompt: Text("feature/my-change"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: FormMetrics.fieldWidth)
                    .accessibilityLabel("Branch name")
                    .onSubmit(create)
            }
            GridRow {
                FormLabel("From:")
                Picker("From", selection: $from) {
                    ForEach(sources, id: \.title) { source in
                        Text(source.title).tag(source.value)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Check out after creating", isOn: $checkout)
                        .toggleStyle(.checkbox)
                    FormNote(text: problem ?? String(localized: "Use / to group branches in the sidebar."), isError: problem != nil)
                }
            }
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create Branch", action: create)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isCreating)
        }
        .onAppear { from = startPoint }
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
        let start = from
        Task {
            if await model.createBranch(named: branch, startPoint: start, checkout: checkout) {
                dismiss()
            }
            isCreating = false
        }
    }
}

/// "New Tag on c92aa17": the name starts as the next version after the latest tag.
struct NewTagSheet: View {
    let model: RepositoryModel
    let commitID: String
    let label: String

    @Environment(\.dismiss) private var dismiss
    @AppStorage("pushNewTags") private var push = true
    @State private var name = ""
    @State private var message = ""
    @State private var problem: String?
    @State private var isValid = false
    @State private var isCreating = false

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        FormSheet(title: String(localized: "New Tag on \(label)")) {
            GridRow {
                FormLabel("Name:")
                TextField("Name", text: $name, prompt: Text("v1.0.0"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: FormMetrics.fieldWidth)
                    .accessibilityLabel("Tag name")
            }
            GridRow(alignment: .top) {
                FormLabel("Message:")
                    .padding(.top, 4)
                TextEditor(text: $message)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(width: FormMetrics.fieldWidth)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                    )
                    .accessibilityLabel("Message")
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                VStack(alignment: .leading, spacing: 8) {
                    if let remote = model.defaultRemote {
                        Toggle("Push to \(remote)", isOn: $push)
                            .toggleStyle(.checkbox)
                    }
                    FormNote(text: problem ?? String(localized: "Leave the message empty for a lightweight tag."), isError: problem != nil)
                }
            }
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create Tag", action: create)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isCreating)
        }
        .onAppear { name = model.suggestedTagName }
        .task(id: trimmed) {
            guard let repository = model.repository, !trimmed.isEmpty else {
                isValid = false
                problem = nil
                return
            }
            if model.refs.tags.contains(where: { $0.name == trimmed }) {
                isValid = false
                problem = String(localized: "A tag named “\(trimmed)” already exists.")
            } else if await repository.isValidTagName(trimmed) {
                isValid = true
                problem = nil
            } else {
                isValid = false
                problem = String(localized: "That isn't a valid tag name.")
            }
        }
    }

    private func create() {
        guard isValid, !isCreating else { return }
        isCreating = true
        let tag = trimmed
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let pushNow = push && model.defaultRemote != nil
        Task {
            if await model.createTag(named: tag, at: commitID, message: text.isEmpty ? nil : text, push: pushNow) {
                dismiss()
            }
            isCreating = false
        }
    }
}

struct RenameBranchSheet: View {
    let model: RepositoryModel
    let ref: Ref

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var problem: String?
    @State private var isValid = false
    @State private var isRenaming = false

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        FormSheet(title: String(localized: "Rename “\(ref.name)”")) {
            GridRow {
                FormLabel("Name:")
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: FormMetrics.fieldWidth)
                    .accessibilityLabel("New branch name")
                    .onSubmit(rename)
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                if let problem {
                    FormNote(text: problem, isError: true)
                } else if let upstream = ref.upstream {
                    FormNote(text: String(localized: "The branch keeps tracking \(upstream); the remote branch isn't renamed."))
                } else {
                    FormNote(text: String(localized: "Use / to group branches in the sidebar."))
                }
            }
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Rename", action: rename)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isRenaming)
        }
        .onAppear { name = ref.name }
        .task(id: trimmed) {
            guard let repository = model.repository, !trimmed.isEmpty, trimmed != ref.name else {
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

    private func rename() {
        guard isValid, !isRenaming else { return }
        isRenaming = true
        let newName = trimmed
        Task {
            if await model.renameBranch(ref, to: newName) {
                dismiss()
            }
            isRenaming = false
        }
    }
}

/// Branch › Merge into “current”… and Rebase “current” onto…: pick the other branch.
struct BranchChooserSheet: View {
    let model: RepositoryModel
    let choice: BranchChoice

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: String?
    @State private var noFastForward = false
    @FocusState private var isSearchFocused: Bool

    private var current: String { model.currentBranchTitle }

    /// Local branches first, then remote branches without a local counterpart.
    private var candidates: [Ref] {
        let locals = model.refs.localBranches.filter { !$0.isHead }
        // The current branch's own upstream is what Pull is for.
        let remotes = model.refs.remoteBranches.filter { $0.name != model.status.upstream }
        let all = locals.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            + remotes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var selectedRef: Ref? {
        candidates.first { $0.id == selection } ?? (candidates.count == 1 ? candidates.first : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(choice == .merge ? "Merge into “\(current)”" : "Rebase “\(current)” onto")
                .font(.system(size: 13, weight: .bold))
            Text(choice == .merge
                ? "Pick the branch whose commits come into “\(current)”."
                : "Pick the branch to replay “\(current)”’s commits on top of.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search Branches", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
            List(selection: $selection) {
                ForEach(candidates) { ref in
                    HStack(spacing: 6) {
                        Image(systemName: ref.kind == .remoteBranch ? "cloud" : "arrow.triangle.branch")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 16)
                        Text(ref.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if let commit = model.commit(withID: ref.target) {
                            Text(Formatters.historyDate(commit.author.date))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(ref.id)
                }
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds()
            .frame(height: 220)
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                if let id = ids.first { selection = id; run() }
            }
            if choice == .merge {
                Toggle("Create a merge commit even when a fast-forward is possible", isOn: $noFastForward)
                    .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(choice == .merge ? "Merge" : "Rebase", action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedRef == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { isSearchFocused = true }
    }

    private func run() {
        guard let ref = selectedRef else { return }
        dismiss()
        Task {
            switch choice {
            case .merge: await model.merge(ref, noFastForward: noFastForward)
            case .rebase: await model.rebase(onto: ref)
            }
        }
    }
}

struct StashSheet: View {
    let model: RepositoryModel

    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var includeUntracked = true
    @State private var keepStaged = false

    private var changeCount: Int { model.status.entries.count }

    var body: some View {
        SheetScaffold(
            systemImage: "tray.and.arrow.down",
            title: "Stash Changes",
            message: changeCount == 1 ? "1 change on \(model.headTitle)." : "\(changeCount) changes on \(model.headTitle)."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Message", text: $message, prompt: Text("Optional description"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(stash)
                Toggle("Include untracked files", isOn: $includeUntracked)
                    .toggleStyle(.checkbox)
                Toggle("Keep staged changes in the working tree", isOn: $keepStaged)
                    .toggleStyle(.checkbox)
            }
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Stash", action: stash)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func stash() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss()
        Task {
            await model.stash(message: text.isEmpty ? nil : text, includeUntracked: includeUntracked, keepIndex: keepStaged)
        }
    }
}

/// Settings › General › "When switching branches: Ask What to Do with Changes".
struct SwitchWithChangesSheet: View {
    let model: RepositoryModel
    let target: Ref

    @Environment(\.dismiss) private var dismiss
    /// Don't ask again: the choice becomes Settings › General › When switching branches
    /// (Settings › Advanced › Reset "Don't Ask Again" Choices brings the question back).
    @State private var remember = false
    @AppStorage(PreferenceKey.branchSwitch) private var branchSwitch = BranchSwitchPreference.ask

    private var targetName: String { target.kind == .remoteBranch ? target.branchName : target.name }
    private var changeCount: Int { model.status.entries.count }

    var body: some View {
        SheetScaffold(
            systemImage: "arrow.triangle.branch",
            title: "Switch to “\(targetName)”?",
            message: changeCount == 1
                ? "You have 1 uncommitted change. Stash it to keep it for later, or bring it along to “\(targetName)”."
                : "You have \(changeCount) uncommitted changes. Stash them to keep them for later, or bring them along to “\(targetName)”."
        ) {
            Toggle("Don't ask again", isOn: $remember)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Bring Changes") {
                if remember { branchSwitch = .bring }
                dismiss()
                Task { await model.switchBranch(to: target, stashingChanges: false) }
            }
            Button("Stash and Switch") {
                if remember { branchSwitch = .stash }
                dismiss()
                Task { await model.switchBranch(to: target, stashingChanges: true) }
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// Push when the remote has commits we don't: pull first, then push.
struct PullThenPushSheet: View {
    let model: RepositoryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(
            systemImage: "arrow.up.arrow.down",
            title: "Pull before pushing?",
            message: "\(model.status.upstream ?? "The remote") has ^[\(model.status.behind) commit](inflect: true) that \(model.headTitle) doesn't have yet. Pull first, then push your ^[\(model.status.ahead) commit](inflect: true)."
        ) {
            EmptyView()
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Pull, Then Push") {
                dismiss()
                Task { await model.pullThenPush() }
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}
