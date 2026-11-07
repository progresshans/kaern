import AppKit
import KaernKit
import SwiftUI

/// The sheet over the window (ScreenSheets `.sheet`, ScreenRebase `.rsheet`): drawn in the window
/// on a shade, 14 pt under the toolbar, like the alerts.
struct RepositorySheetHost: View {
    @Bindable var repository: RepositoryModel

    var body: some View {
        if let sheet = repository.sheet {
            ZStack(alignment: .top) {
                AlertShade()
                    .onTapGesture {}
                Group {
                    switch sheet {
                    case .branch(let request):
                        BranchSheet(repository: repository, request: request)
                    case .tag(let request):
                        TagSheet(repository: repository, request: request)
                    case .pick(let request):
                        PickSheet(repository: repository, request: request)
                    case .renameStash(let stash):
                        RenameStashSheet(repository: repository, stash: stash)
                    case .repositorySettings:
                        RepositorySettingsSheet(repository: repository)
                    case .interactiveRebase(let draft):
                        InteractiveRebaseSheet(repository: repository, draft: draft)
                    }
                }
                .id(sheet.id)
                .padding(.top, sheet.isAttached ? KMetric.toolbar : KMetric.toolbar + 14)
            }
            .transition(.opacity)
        }
    }
}

extension RepositorySheet {
    /// The interactive rebase sheet hangs from the toolbar (`.rsheet`, square top corners).
    var isAttached: Bool {
        if case .interactiveRebase = self { return true }
        return false
    }
}

// MARK: - Parts

/// `.sheet`: 470 pt (600 wide), the pop color, 12 pt corners.
struct SheetCard<Content: View>: View {
    var width: CGFloat = 470
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .foregroundStyle(K.label)
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
            .frame(width: width, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(K.pop)
                    .shadow(color: .black.opacity(0.28), radius: 32, y: 24)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5))
            )
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
    }
}

/// `.shT` and `.shsub`.
struct SheetTitle: View {
    let title: Text
    var subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = Text(title)
        self.subtitle = subtitle
    }

    init(text: Text, subtitle: String? = nil) {
        self.title = text
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            title.font(.system(size: 13.5, weight: .bold))
            if let subtitle {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(K.label2).lineLimit(2)
            }
        }
    }
}

/// `.sheet input`: the field color, a hairline, the accent ring when focused, red when wrong.
struct SheetField: View {
    let placeholder: String
    @Binding var text: String
    var isBad = false
    var monospaced = false
    var focus: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}

    var body: some View {
        let focused = focus.wrappedValue
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(monospaced ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
            .focused(focus)
            .onSubmit(onSubmit)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(K.field)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isBad ? K.err : (focused ? K.accent : K.sepStrong), lineWidth: isBad || focused ? 1 : 0.5))
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isBad ? K.err.opacity(0.16) : (focused ? K.accentSoft : .clear), lineWidth: 6))
            )
    }
}

/// `.fmsg`: the line under a field (gray, orange note, red error).
struct FieldMessage: View {
    let text: String
    var tone: BranchNameCheck.Tone = .plain

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(tone == .error ? K.err : tone == .note ? K.mod : K.label2)
            .frame(minHeight: 15, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// `.shacts`: Cancel and the action on the right (Return / Esc).
struct SheetButtons: View {
    var leading: String?
    let confirmTitle: String
    var isEnabled = true
    var destructive = false
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let leading {
                Text(leading).font(.system(size: 11.5)).foregroundStyle(K.label2)
            }
            Spacer(minLength: 0)
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
                .controlSize(.regular)
            Button(confirmTitle, action: confirm)
                .keyboardShortcut(.defaultAction)
                .controlSize(.regular)
                .tint(destructive ? K.err : nil)
                .disabled(!isEnabled)
        }
        .padding(.top, 16)
    }
}

/// Grid row: a right-aligned label (72 pt) and its control.
struct SheetFormRow<Content: View>: View {
    let label: String
    var topAligned = false
    @ViewBuilder let content: Content

    var body: some View {
        GridRow(alignment: topAligned ? .top : .center) {
            Text(label)
                .font(.system(size: 12.5))
                .frame(width: 72, alignment: .trailing)
                .padding(.top, topAligned ? 5 : 0)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - New Branch, Rename Branch, Branch from Stash

private struct BranchSheet: View {
    let repository: RepositoryModel
    let request: BranchSheetRequest
    @State private var name = ""
    @State private var from = "HEAD"
    @State private var checkout = true
    @State private var alsoRemote = false
    @FocusState private var focused: Bool

    var body: some View {
        let except: String? = if case .rename(let old) = request.kind { old } else { nil }
        let check = repository.checkBranchName(name, except: except)
        let unchanged = except != nil && check.name == except
        SheetCard {
            SheetTitle(title, subtitle: subtitle)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                SheetFormRow(label: "Name") {
                    SheetField(placeholder: "feature/name", text: $name, isBad: check.tone == .error, focus: $focused, onSubmit: submit)
                }
                GridRow {
                    Color.clear.frame(width: 72, height: 1)
                    FieldMessage(text: unchanged ? "Type a new name for \(except ?? "")." : check.message, tone: unchanged ? .plain : check.tone)
                }
                if case .new = request.kind {
                    SheetFormRow(label: "From") {
                        Picker("From", selection: $from) {
                            ForEach(fromChoices, id: \.id) { choice in Text(choice.title).tag(choice.id) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    }
                    GridRow {
                        Color.clear.frame(width: 72, height: 1)
                        Toggle("Check out after creating", isOn: $checkout)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12.5))
                    }
                }
                if case .rename(let old) = request.kind, let remote = renameRemote(old) {
                    GridRow {
                        Color.clear.frame(width: 72, height: 1)
                        Toggle("Also rename \(remote)/\(old)", isOn: $alsoRemote)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12.5))
                    }
                }
            }
            .padding(.top, 14)
            SheetButtons(confirmTitle: confirmTitle, isEnabled: check.isValid && !unchanged,
                         cancel: { repository.sheet = nil }, confirm: submit)
        }
        .onAppear {
            name = request.name
            if case .new(let at) = request.kind, let at { from = at }
            DispatchQueue.main.async { focused = true }
        }
    }

    private var title: String {
        switch request.kind {
        case .new: "New Branch"
        case .rename: "Rename Branch"
        case .fromStash: "Create Branch from Stash"
        }
    }

    private var subtitle: String? {
        switch request.kind {
        case .new: nil
        case .rename(let old): "Renames \(old). Its upstream setting moves with it."
        case .fromStash(let stash):
            "Starts where \(stash.reference) was made, applies it and drops it from the list."
        }
    }

    private var confirmTitle: String {
        if case .rename = request.kind { return "Rename" }
        return "Create Branch"
    }

    private var fromChoices: [(id: String, title: String)] {
        var choices: [(String, String)] = [("HEAD", (repository.status.branch ?? repository.status.headID.map(repository.short) ?? "HEAD") + " (HEAD)")]
        if case .new(let at?) = request.kind, at != repository.status.headID {
            let subject = repository.commit(at)?.subject
            choices.append((at, repository.short(at) + (subject.map { " · " + $0 } ?? "")))
        }
        for branch in repository.refs.localBranches.map(\.name).sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        where branch != repository.status.branch {
            choices.append((branch, branch))
        }
        return choices
    }

    /// The remote of the branch's upstream, when it has one.
    private func renameRemote(_ branch: String) -> String? {
        guard let upstream = repository.refs.localBranch(named: branch)?.upstream,
              let tracked = repository.refs.remoteBranch(named: upstream) else { return nil }
        return tracked.remoteName
    }

    private func submit() {
        let except: String? = if case .rename(let old) = request.kind { old } else { nil }
        let check = repository.checkBranchName(name, except: except)
        guard check.isValid, check.name != except else { return }
        repository.sheet = nil
        repository.from("New Branch sheet") {
            switch request.kind {
            case .new:
                repository.createBranch(check.name, from: from == "HEAD" ? nil : from, checkout: checkout)
            case .rename(let old):
                repository.renameBranch(old, to: check.name, alsoOn: alsoRemote ? renameRemote(old) : nil)
            case .fromStash(let stash):
                repository.createBranch(check.name, from: stash)
            }
        }
    }
}

// MARK: - New Tag

private struct TagSheet: View {
    let repository: RepositoryModel
    let request: TagSheetRequest
    @State private var name = ""
    @State private var message = ""
    @State private var push = false
    @State private var suggestion: String?
    @FocusState private var focused: Bool

    var body: some View {
        let check = repository.checkTagName(name)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        SheetCard {
            SheetTitle(text: Text("New Tag on \(Text(repository.short(request.commit)).font(.system(size: 13, weight: .bold, design: .monospaced)))"),
                       subtitle: subtitle)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                SheetFormRow(label: "Name") {
                    SheetField(placeholder: "v1.0.0", text: $name, isBad: !trimmed.isEmpty && !check.isValid, focus: $focused, onSubmit: submit)
                }
                GridRow {
                    Color.clear.frame(width: 72, height: 1)
                    FieldMessage(text: nameMessage(check), tone: !trimmed.isEmpty && !check.isValid ? .error : .plain)
                }
                SheetFormRow(label: "Message", topAligned: true) {
                    TextEditor(text: $message)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                        .frame(height: 62)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(K.field)
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5)))
                }
                GridRow {
                    Color.clear.frame(width: 72, height: 1)
                    Text(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "Lightweight tag — it points at the commit with no message."
                         : "Annotated tag — it records you as the tagger. Leave the message empty for a lightweight tag.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(K.label2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let remote = repository.defaultRemote {
                    GridRow {
                        Color.clear.frame(width: 72, height: 1)
                        Toggle("Push to \(remote)", isOn: $push)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12.5))
                    }
                }
            }
            .padding(.top, 14)
            SheetButtons(confirmTitle: "Create Tag", isEnabled: check.isValid, cancel: { repository.sheet = nil }, confirm: submit)
        }
        .onAppear {
            let names = repository.tags.map(\.name)
            suggestion = TagNaming.suggestion(after: names)
            name = suggestion ?? ""
            DispatchQueue.main.async { focused = true }
        }
    }

    private var subtitle: String? {
        guard let commit = repository.commit(request.commit) else { return nil }
        return "\(commit.subject) · \(commit.author.name) · \(Formatters.historyDate(commit.author.date))"
    }

    private func nameMessage(_ check: (isValid: Bool, message: String?)) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Name the tag, e.g. \(suggestion ?? "v1.0.0")." }
        if let message = check.message { return message }
        if trimmed == suggestion, let last = repository.tags.first?.name { return "Suggested from the last tag, \(last)." }
        return ""
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard repository.checkTagName(trimmed).isValid else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        repository.sheet = nil
        repository.from("New Tag sheet") {
            repository.createTag(trimmed, at: request.commit, message: text.isEmpty ? nil : text, push: push)
        }
    }
}

// MARK: - Merge into…, Rebase onto…, Delete Branch…

private struct PickSheet: View {
    let repository: RepositoryModel
    let request: PickSheetRequest
    @State private var selection: String?
    @State private var option = false
    @State private var notes: [String: String] = [:]

    var body: some View {
        let current = repository.status.branch ?? "HEAD"
        let candidates = repository.pickCandidates(request.kind)
        SheetCard {
            SheetTitle(title(current), subtitle: subtitle(current))
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(candidates, id: \.self) { branch in
                        PickRow(name: branch, note: notes[branch], isOn: selection == branch) { selection = branch }
                    }
                    if candidates.isEmpty {
                        Text("No other branches")
                            .font(.system(size: 12.5))
                            .foregroundStyle(K.label2)
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: min(CGFloat(max(candidates.count, 1)) * 30 + 8, 300))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(K.field)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5)))
            .padding(.top, 12)
            if let label = optionLabel {
                Toggle(label, isOn: $option)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5))
                    .disabled(!optionAvailable)
                    .padding(.top, 10)
            }
            SheetButtons(confirmTitle: confirmTitle, isEnabled: selection != nil, destructive: request.kind == .delete,
                         cancel: { repository.sheet = nil }) {
                guard let selection else { return }
                repository.sheet = nil
                repository.from("Branch menu") { repository.confirmPick(request.kind, branch: selection, option: option && optionAvailable) }
            }
        }
        .onAppear {
            // The usual base first (develop, main…), as on the board.
            let bases = ["develop", "main", "master", "trunk"].filter { candidates.contains($0) }
            selection = request.selection ?? (request.kind == .delete ? nil : bases.first) ?? candidates.first
        }
        .task {
            for branch in candidates.prefix(60) {
                let note = await repository.pickNote(request.kind, branch: branch)
                notes[branch] = note
            }
        }
    }

    private func title(_ current: String) -> String {
        switch request.kind {
        case .merge: "Merge into “\(current)”"
        case .rebase: "Rebase “\(current)” onto"
        case .delete: "Delete a Branch"
        }
    }

    private func subtitle(_ current: String) -> String {
        switch request.kind {
        case .merge:
            return "Choose the branch whose commits come into \(current)."
        case .rebase:
            let unpushed = repository.status.upstream != nil ? repository.status.ahead : repository.unpublishedCount
            return unpushed > 0
                ? "Your \(Formatters.count(unpushed, "unpushed commit is", "unpushed commits are")) replayed on the branch you choose."
                : "Your commits are replayed on the branch you choose."
        case .delete:
            return "⌘Z brings a deleted branch back. A branch deleted on a remote can’t be brought back."
        }
    }

    private var optionLabel: String? {
        switch request.kind {
        case .merge: "Always create a merge commit (no fast-forward)"
        case .rebase: "Interactive — choose what to keep, squash or reword"
        case .delete: selection.flatMap { deleteRemoteName($0) }.map { "Also delete it on \($0)" } ?? "Also delete it on the remote"
        }
    }

    private var optionAvailable: Bool {
        guard request.kind == .delete else { return true }
        return selection.flatMap { deleteRemoteName($0) } != nil
    }

    private func deleteRemoteName(_ branch: String) -> String? {
        guard let upstream = repository.refs.localBranch(named: branch)?.upstream else { return nil }
        return repository.refs.remoteBranch(named: upstream)?.remoteName
    }

    private var confirmTitle: String {
        switch request.kind {
        case .merge: "Merge"
        case .rebase: option ? "Start Interactive Rebase…" : "Rebase"
        case .delete: option && optionAvailable ? "Delete…" : "Delete Branch"
        }
    }
}

/// `.pkr`: a radio row with the branch and what picking it does.
private struct PickRow: View {
    let name: String
    let note: String?
    let isOn: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isOn ? K.accent : K.label3)
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(note ?? "…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(K.label2)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isOn ? K.accentSoft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Rename Stash

private struct RenameStashSheet: View {
    let repository: RepositoryModel
    let stash: Stash
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        SheetCard {
            SheetTitle("Rename \(stash.reference)", subtitle: "It keeps its place in the list. ⌘Z gives it the old name back.")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                SheetFormRow(label: "Name") {
                    SheetField(placeholder: "What the changes are", text: $name, focus: $focused, onSubmit: submit)
                }
            }
            .padding(.top, 14)
            SheetButtons(confirmTitle: "Rename", isEnabled: !trimmed.isEmpty && trimmed != RepositoryModel.stashTitle(stash),
                         cancel: { repository.sheet = nil }, confirm: submit)
        }
        .onAppear {
            name = RepositoryModel.stashTitle(stash)
            DispatchQueue.main.async { focused = true }
        }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        repository.sheet = nil
        repository.from("Stash view") { repository.renameStash(stash, to: trimmed) }
    }
}
