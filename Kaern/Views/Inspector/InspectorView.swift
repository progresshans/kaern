import KaernKit
import SwiftUI

/// Right column: Changes for the working copy, Commit details for a commit.
struct InspectorView: View {
    let model: RepositoryModel

    var body: some View {
        Group {
            if let pullRequests = model.pullRequests {
                PullRequestInspector(model: model, state: pullRequests)
            } else if let stashView = model.stashView {
                StashInspector(model: model, state: stashView)
            } else {
                selectionInspector
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(Palette.inspectorBackground))
    }

    @ViewBuilder
    private var selectionInspector: some View {
        Group {
            switch model.selection {
            case .workingCopy:
                if model.operation != nil {
                    ResolveConflictsInspector(model: model)
                } else {
                    ChangesInspector(model: model)
                }
            case .commit:
                CommitInspector(model: model)
            }
        }
    }
}

// MARK: - Changes

struct ChangesInspector: View {
    @Bindable var model: RepositoryModel

    private var entries: [StatusEntry] {
        model.status.entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private var allStaged: Bool {
        !entries.isEmpty && entries.allSatisfy { $0.stageState == .staged }
    }

    /// Everything Discard All throws away: not conflicts (resolve those), not submodules (their
    /// own window has their changes; "Check Out" in the diff moves them back).
    private var discardableEntries: [StatusEntry] { model.discardableEntries }

    private var selectedPath: Binding<String?> {
        Binding(
            get: {
                if case .working(let path) = model.selectedFile { return path }
                return nil
            },
            set: { model.selectedFile = $0.map { .working($0) } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.status.isClean {
                CleanInspectorContent(model: model)
            } else {
                fileList
                Divider()
                CommitComposer(model: model)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Changes")
                    .font(.system(size: 13, weight: .bold))
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.status.isClean {
                Button {
                    Task { await model.discard(discardableEntries) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(discardableEntries.isEmpty || model.activity != nil)
                .help("Discard All Changes — a copy goes to the stash list, and ⌘Z brings them back")
                .accessibilityLabel("Discard All Changes")
                Button(allStaged ? "Unstage All" : "Stage All") {
                    Task {
                        if allStaged { await model.unstageAll() } else { await model.stageAll() }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var summary: String {
        let count = model.status.entries.count
        guard count > 0 else { return String(localized: "No changes") }
        let files = count == 1 ? String(localized: "1 file") : String(localized: "\(count) files")
        return files + " · " + String(localized: "\(model.status.stagedCount) staged")
    }

    private var fileList: some View {
        List(selection: selectedPath) {
            ForEach(entries) { entry in
                ChangeRow(entry: entry, stat: model.lineStats[entry.path], annotation: model.annotation(for: entry)) {
                    Task { await model.toggleStaging(entry) }
                }
                .tag(entry.path)
                .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                .contextMenu { ChangeContextMenu(entry: entry, model: model) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 24)
        .onKeyPress(.space) {
            guard case .working(let path) = model.selectedFile,
                  let entry = model.status.entries.first(where: { $0.path == path }) else { return .ignored }
            Task { await model.toggleStaging(entry) }
            return .handled
        }
    }
}

struct ChangeRow: View {
    let entry: StatusEntry
    let stat: LineStat?
    var annotation: FileAnnotation?
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            StageCheckbox(state: entry.stageState, action: onToggle)
                .frame(width: 16)
            StatusLetter(kind: entry.kind)
            FileRowLabel(path: entry.path, oldPath: entry.originalPath, stat: stat, annotation: annotation)
        }
        .frame(height: 22)
    }
}

struct ChangeContextMenu: View {
    let entry: StatusEntry
    let model: RepositoryModel

    var body: some View {
        if entry.stageState == .staged {
            Button("Unstage") { Task { await model.unstage([entry]) } }
        } else {
            Button("Stage") { Task { await model.stage([entry]) } }
        }
        if entry.stageState == .partial {
            Button("Unstage") { Task { await model.unstage([entry]) } }
        }
        Divider()
        // A file that was never committed has no history yet.
        let isNew = entry.isUntracked || entry.kind == .added
        Button("Show File History") { model.showFileHistory(entry.originalPath ?? entry.path) }
            .disabled(isNew)
        Button("Blame") { model.showFileHistory(entry.path, mode: .blame) }
            .disabled(isNew || entry.kind == .deleted)
        Divider()
        Button("Open in \(Preferences.editor.title)") { model.openInEditor(entry.path) }
            .disabled(entry.kind == .deleted)
        Button("Reveal in Finder") { model.revealInFinder(entry.path) }
            .disabled(entry.kind == .deleted)
        Button("Copy Path") { Pasteboard.copy(entry.path) }
        Divider()
        Button("Discard Changes", role: .destructive) { Task { await model.discard([entry]) } }
    }
}

// MARK: - Commit composer

struct CommitComposer: View {
    @Bindable var model: RepositoryModel
    @FocusState private var summaryFocused: Bool

    private var summaryLength: Int { model.summary.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("Summary", text: $model.summary)
                    .textFieldStyle(.plain)
                    .focused($summaryFocused)
                    .onSubmit { Task { await model.commit(andPush: false) } }
                Text("\(summaryLength)/72")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(summaryLength > 72 ? Color(Palette.deleted) : Color(nsColor: .tertiaryLabelColor))
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(fieldBackground(focused: summaryFocused))

            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.messageBody)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 5)
                if model.messageBody.isEmpty {
                    Text("Description")
                        .font(.system(size: 12))
                        .foregroundStyle(.placeholder)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 64)
            .background(fieldBackground(focused: false))

            Toggle("Amend last commit", isOn: $model.amend)
                .toggleStyle(.checkbox)
                .disabled(!model.hasHead)

            CommitButton(model: model)
        }
        .padding(14)
    }

    private func fieldBackground(focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(focused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: focused ? 2 : 1)
            )
    }
}

/// Commit · Commit and Push (NSComboButton-style split button). ⌘↩ commits.
struct CommitButton: View {
    let model: RepositoryModel

    private var title: String {
        if model.amend { return String(localized: "Amend Last Commit") }
        let staged = model.status.stagedCount
        if staged == 0 { return String(localized: "Commit") }
        return staged == 1 ? String(localized: "Commit 1 File") : String(localized: "Commit \(staged) Files")
    }

    var body: some View {
        HStack(spacing: 1) {
            Button {
                Task { await model.commit(andPush: false) }
            } label: {
                if model.activity == .committing {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else {
                    Text(title).frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // ⌘Return belongs to the quick switcher while it's open (New Window).
            .keyboardShortcut(model.quickSwitcherQuery == nil ? KeyboardShortcut(.return, modifiers: .command) : nil)
            .help("Commit the staged changes (⌘↩)")

            Menu {
                Button("Commit and Push") {
                    Task { await model.commit(andPush: true) }
                }
                .disabled(model.remotes.isEmpty)
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .fixedSize()
        }
        .disabled(!model.canCommit)
    }
}

// MARK: - Clean

struct CleanInspectorContent: View {
    let model: RepositoryModel

    private var remote: String { model.upstreamRemote ?? "origin" }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color(Palette.added))
                Text("Working Tree Clean")
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)
                if model.status.ahead > 0 {
                    Button(model.status.ahead == 1 ? "Push 1 Commit" : "Push \(model.status.ahead) Commits") {
                        Task { await model.push() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.activity != nil)
                    .padding(.top, 4)
                }
            }
            Spacer()
            if let head = model.headCommit {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last commit")
                        .foregroundStyle(.tertiary)
                    Text("\(head.shortID) · \(head.subject) · \(Formatters.historyDate(head.author.date))")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
    }

    private var message: String {
        let ahead = model.status.ahead
        if ahead == 0 { return String(localized: "Everything is committed.") }
        return ahead == 1
            ? String(localized: "Everything is committed. 1 commit is waiting to be pushed to \(remote).")
            : String(localized: "Everything is committed. \(ahead) commits are waiting to be pushed to \(remote).")
    }
}

// MARK: - Commit

struct CommitInspector: View {
    let model: RepositoryModel

    private var selectedPath: Binding<String?> {
        Binding(
            get: {
                if case .commit(_, let path) = model.selectedFile { return path }
                return nil
            },
            set: { path in
                guard let commit = model.selectedCommit else { return }
                model.selectedFile = path.map { .commit(commitID: commit.id, path: $0) }
            }
        )
    }

    var body: some View {
        if let commit = model.selectedCommit {
            VStack(spacing: 0) {
                List(selection: selectedPath) {
                    Group {
                        if let base = model.comparisonBase {
                            ComparisonHeader(base: base, target: commit, model: model)
                        } else {
                            CommitHeader(commit: commit, model: model)
                        }
                    }
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 14, leading: 14, bottom: 6, trailing: 14))
                    Section {
                        ForEach(model.detailFiles) { file in
                            HStack(spacing: 6) {
                                StatusLetter(kind: file.kind)
                                FileRowLabel(path: file.path, oldPath: file.oldPath, stat: file.stat, annotation: model.annotation(for: file))
                            }
                            .frame(height: 22)
                            .tag(file.path)
                            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                            .contextMenu {
                                Button("Show File History") { model.showFileHistory(file.path, from: commit.id) }
                                Button("Blame") { model.showFileHistory(file.path, from: commit.id, mode: .blame) }
                                    .disabled(file.kind == .deleted)
                                Divider()
                                Button("Copy Path") { Pasteboard.copy(file.path) }
                                Button("Reveal in Finder") { model.revealInFinder(file.path) }
                                    .disabled(file.kind == .deleted)
                            }
                        }
                    } header: {
                        filesHeader
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 24)

                Divider()
                if model.comparisonBase != nil {
                    HStack {
                        Text("⌘-click another commit to compare it instead")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Done") { model.endComparison() }
                            .keyboardShortcut(model.selectedFile == nil ? KeyboardShortcut.cancelAction : nil)
                            .help("Back to \(commit.shortID) alone (Esc)")
                    }
                    .controlSize(.small)
                    .padding(12)
                } else {
                HStack(spacing: 8) {
                    Button("Revert") { Task { await model.revert(commit) } }
                        .disabled(!model.canStartOperation)
                        .help("Make a new commit that undoes this one (⌘Z takes it back)")
                    Button("Create Branch…") {
                        model.sheet = .newBranch(startPoint: commit.id, label: commit.shortID)
                    }
                    Menu {
                        Button("Copy SHA") { Pasteboard.copy(commit.id) }
                        Button("Copy Subject") { Pasteboard.copy(commit.subject) }
                        if let host = model.primaryRemote {
                            Button("Open Commit on \(host.hostName)") { model.openCommitOnHost(commit.id) }
                        }
                        Divider()
                        Button("Check Out This Commit") { Task { await model.checkOut(commit: commit) } }
                            .disabled(!model.canStartOperation)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Spacer()
                }
                .controlSize(.small)
                .padding(12)
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filesHeader: some View {
        let additions = model.detailFiles.compactMap { $0.stat?.additions }.reduce(0, +)
        let deletions = model.detailFiles.compactMap { $0.stat?.deletions }.reduce(0, +)
        return HStack {
            Text(model.detailFiles.count == 1 ? "1 File Changed" : "\(model.detailFiles.count) Files Changed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            LineStatLabel(stat: LineStat(additions: additions, deletions: deletions))
        }
    }
}

/// Two commits compared: From (older) and To (newer), how far apart, and Swap.
private struct ComparisonHeader: View {
    let base: String
    let target: Commit
    let model: RepositoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Comparing Two Commits")
                .font(.system(size: 13, weight: .bold))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    label("From")
                    commitLine(id: base, commit: model.commit(withID: base))
                }
                GridRow {
                    label("To")
                    commitLine(id: target.id, commit: target)
                }
            }
            HStack(spacing: 8) {
                if let distance = distanceText {
                    Text(distance)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button {
                    model.swapComparison()
                } label: {
                    Label("Swap", systemImage: "arrow.up.arrow.down")
                }
                .controlSize(.small)
                .help("Show the changes the other way round")
            }
        }
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
    }

    private func commitLine(id: String, commit: Commit?) -> some View {
        HStack(spacing: 6) {
            Text(String(id.prefix(7)))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            Text(commit?.subject ?? "")
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(commit.map { "\($0.shortID) · \($0.subject) — \($0.author.name)" } ?? id)
    }

    /// "3 commits apart", or how the two sides went separate ways.
    private var distanceText: String? {
        guard let distance = model.comparisonDistance else { return nil }
        switch (distance.ahead, distance.behind) {
        case (let ahead, 0):
            return ahead == 1 ? String(localized: "1 commit apart") : String(localized: "\(ahead) commits apart")
        case (0, let behind):
            return behind == 1 ? String(localized: "1 commit apart") : String(localized: "\(behind) commits apart")
        default:
            return String(localized: "On separate branches: \(distance.ahead) commits only in To, \(distance.behind) only in From")
        }
    }
}

private struct CommitHeader: View {
    let commit: Commit
    let model: RepositoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(commit.subject)
                .font(.system(size: 13, weight: .bold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                AuthorAvatar(name: commit.author.name, email: commit.author.email, commitID: commit.id, remote: model.primaryRemote)
                VStack(alignment: .leading, spacing: 1) {
                    Text(commit.author.name)
                        .font(.system(size: 13, weight: .semibold))
                    Text(Formatters.detailDate(commit.author.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .help(commit.author.email)

            if let body = model.details?.body, !body.isEmpty {
                Text(body)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    label("Commit")
                    HStack(spacing: 4) {
                        Text(commit.shortID)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            Pasteboard.copy(commit.id)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Copy SHA (⇧⌘C)")
                    }
                }
                if !commit.parents.isEmpty {
                    GridRow {
                        label(commit.parents.count > 1 ? "Parents" : "Parent")
                        HStack(spacing: 6) {
                            ForEach(commit.parents, id: \.self) { parent in
                                Button(String(parent.prefix(7))) {
                                    model.selection = .commit(parent)
                                }
                                .buttonStyle(.link)
                                .font(.system(size: 11, design: .monospaced))
                                .disabled(model.commit(withID: parent) == nil)
                            }
                        }
                    }
                }
                if let signature = model.detailSignature {
                    GridRow(alignment: .top) {
                        label("Signature")
                        SignatureLabel(signature: signature) {
                            model.sheet = .addSigningKey(commitID: commit.id, signer: model.details?.committer.email ?? commit.author.email)
                        }
                    }
                }
                if !model.detailBranches.isEmpty {
                    GridRow(alignment: .top) {
                        label("On")
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.detailBranches.prefix(3), id: \.self) { branch in
                                BranchChip(name: branch, isHead: branch == model.status.branch)
                            }
                            if model.detailBranches.count > 3 {
                                Text("and \(model.detailBranches.count - 3) more")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
    }
}


/// "Verified · SSH · Han Hyeonjin", or why git doesn't vouch for the key ("Add Key…" for an
/// SSH key that isn't in the allowed signers).
struct SignatureLabel: View {
    let signature: CommitSignature
    var onAddKey: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: Self.symbol(for: signature.status))
                    .foregroundStyle(color)
                Text(title).fontWeight(.semibold)
            }
            if canAddKey, let onAddKey {
                HStack(spacing: 4) {
                    Text("Key not in allowed signers ·")
                        .foregroundStyle(.secondary)
                    Button("Add Key…", action: onAddKey)
                        .buttonStyle(.link)
                        .help("Trust this key for \(signature.signer.isEmpty ? "its signer" : signature.signer) (gpg.ssh.allowedSignersFile)")
                }
            } else {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 11))
        .help(signature.key.isEmpty ? "" : "Key \(signature.key)")
    }

    /// A shield for good signatures, a warning for ones git can't vouch for (as in the Commit column).
    static func symbol(for status: CommitSignature.Status) -> String {
        switch status {
        case .verified: "lock.shield.fill"
        case .bad, .revoked: "xmark.shield.fill"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var canAddKey: Bool { signature.status == .unverified && signature.format == "SSH" }
    private var color: Color {
        switch signature.status {
        case .verified: Color(Palette.added)
        case .bad, .revoked: Color(Palette.deleted)
        default: .orange
        }
    }

    private var title: String {
        switch signature.status {
        case .verified: String(localized: "Verified")
        case .unverified: String(localized: "Unverified")
        case .bad: String(localized: "Bad Signature")
        case .expired: String(localized: "Expired Key")
        case .revoked: String(localized: "Revoked Key")
        case .missingKey: String(localized: "Can't Check")
        }
    }

    private var detail: String {
        let who = signature.signer.isEmpty ? signature.format : "\(signature.format) · \(signature.signer)"
        switch signature.status {
        case .verified: return who
        case .unverified:
            return signature.format == "SSH"
                ? String(localized: "\(who) · key not in allowed signers (gpg.ssh.allowedSignersFile)")
                : String(localized: "\(who) · key isn't trusted")
        case .bad: return String(localized: "The commit doesn't match its signature.")
        case .expired, .revoked: return who
        case .missingKey: return String(localized: "\(signature.format) key \(signature.key) isn't available here.")
        }
    }
}
