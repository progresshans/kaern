import AppKit
import KaernKit
import SwiftUI

/// Interactive Rebase (ScreenRebase `.rsheet`): hangs from the toolbar, 760 pt. Each commit gets
/// Pick · Reword · Edit · Squash · Fixup · Drop (also by typing its first letter) and can move up
/// or down; the result and a warning about pushed commits update as you go.
struct InteractiveRebaseSheet: View {
    let repository: RepositoryModel
    let draft: RebaseDraft
    @State private var focusedRow: String?
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Interactive Rebase")
                .font(.system(size: z(14), weight: .bold))
                .padding(.bottom, z(12))
            HStack(spacing: z(10)) {
                Text("Onto:").font(.system(size: z(13)))
                Picker("Rebase onto", selection: Binding(get: { draft.base }, set: { repository.changeRebaseBase($0) })) {
                    ForEach(repository.rebaseOntoChoices(draft), id: \.id) { choice in Text(choice.title).tag(choice.id) }
                }
                .labelsHidden()
                .fixedSize()
                Text("\(Formatters.count(draft.steps.count, "commit", "commits")) of \(repository.status.branch ?? "HEAD"), oldest first")
                    .font(.system(size: z(12)))
                    .foregroundStyle(K.label2)
                    .lineLimit(1)
            }
            .padding(.bottom, z(12))
            table
            checkLine
                .padding(.top, z(10))
            if !repository.status.isClean {
                Toggle("Stash my \(Formatters.count(repository.status.entries.count, "uncommitted change", "uncommitted changes")) and put them back afterwards",
                       isOn: Binding(get: { draft.stashChanges }, set: { value in repository.updateRebaseDraft { $0.stashChanges = value } }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: z(12.5)))
                    .padding(.top, z(10))
                    .padding(.leading, z(2))
            }
            HStack(spacing: z(8)) {
                Text("Result: \(Formatters.count(draft.resultCount, "commit", "commits")) on top of \(draft.baseTitle)")
                    .font(.system(size: z(12)))
                    .foregroundStyle(K.label2)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Cancel") { repository.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button("Start Rebase") { repository.from("Interactive Rebase") { repository.startInteractiveRebase(draft) } }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(!draft.canStart)
            }
            .padding(.top, z(14))
        }
        .foregroundStyle(K.label)
        .padding(EdgeInsets(top: z(18), leading: z(20), bottom: z(16), trailing: z(20)))
        .frame(width: z(760), alignment: .leading)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous)
                .fill(K.inspector)
                .shadow(color: .black.opacity(0.3), radius: z(30), y: 22)
                .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous)
                    .strokeBorder(K.sepStrong, lineWidth: 0.5))
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    // MARK: Table

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: z(28))
                Text("Action").frame(width: z(112), alignment: .leading)
                Text("Commit").frame(width: z(78), alignment: .leading)
                Text("Message").frame(maxWidth: .infinity, alignment: .leading)
                Text("Focus an action and type P · R · E · S · F · D").fontWeight(.medium)
            }
            .font(.system(size: z(11), weight: .semibold))
            .foregroundStyle(K.label2)
            .padding(.leading, z(6))
            .padding(.trailing, z(10))
            .frame(height: z(28))
            .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
            if draft.isLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: z(60))
            } else if draft.steps.isEmpty {
                Text("No commits to rebase — \(repository.status.branch ?? "HEAD") is already on top of \(draft.baseTitle).")
                    .font(.system(size: z(12.5)))
                    .foregroundStyle(K.label2)
                    .frame(maxWidth: .infinity, minHeight: z(60))
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, step in
                            RebaseRow(repository: repository, draft: draft, index: index, step: step,
                                      isFocused: focusedRow == step.id && listFocused) {
                                focusedRow = step.id
                                listFocused = true
                            }
                            if index < draft.steps.count - 1 { K.sep.frame(height: 1).padding(.leading, z(6)) }
                        }
                    }
                }
                .frame(maxHeight: min(CGFloat(draft.steps.count) * 41, z(330)))
            }
        }
        .background(RoundedRectangle(cornerRadius: z(9), style: .continuous).fill(K.content))
        .clipShape(RoundedRectangle(cornerRadius: z(9), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: z(9), style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5))
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(characters: CharacterSet(charactersIn: "prsefdPRSEFD")) { press in
            guard let id = focusedRow ?? draft.steps.first?.id,
                  let action = RebaseStep.Action.allCases.first(where: { $0.key == Character(press.characters.lowercased()) }) else { return .ignored }
            setAction(action, for: id)
            return .handled
        }
        .onKeyPress(.upArrow) { moveFocus(-1) }
        .onKeyPress(.downArrow) { moveFocus(1) }
    }

    private func moveFocus(_ step: Int) -> KeyPress.Result {
        guard let current = focusedRow, let index = draft.steps.firstIndex(where: { $0.id == current }) else {
            focusedRow = draft.steps.first?.id
            return .handled
        }
        let next = min(max(index + step, 0), draft.steps.count - 1)
        focusedRow = draft.steps[next].id
        return .handled
    }

    private func setAction(_ action: RebaseStep.Action, for id: String) {
        repository.updateRebaseDraft { draft in
            guard let index = draft.steps.firstIndex(where: { $0.id == id }) else { return }
            draft.steps[index].action = action
            if action == .reword, draft.steps[index].message == nil { draft.steps[index].message = draft.steps[index].commit.subject }
        }
        if action == .reword { repository.loadRebaseBody(id) }
    }

    // MARK: The check under the table

    @ViewBuilder
    private var checkLine: some View {
        if let check = draft.check(remote: repository.defaultRemote) {
            CheckLine(check: check)
        }
    }
}

/// `.rcheck`: ✓ when only unpushed commits change, ⚠ when Push will need force, red when it can't run
/// (`RebaseDraft.check`).
private struct CheckLine: View {
    let check: RebaseDraft.Check

    var body: some View {
        HStack(spacing: z(7)) {
            Image(systemName: check.kind == .ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: z(13)))
                .foregroundStyle(check.kind == .ok ? K.ok : check.kind == .warning ? K.warn : K.err)
            Text(check.text)
                .font(.system(size: z(12.5)))
                .foregroundStyle(check.kind == .error ? K.err : K.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, z(2))
    }
}

/// `.rrow2`: grip, action, hash, message (a field for Reword), what happens, ↑ ↓.
private struct RebaseRow: View {
    let repository: RepositoryModel
    let draft: RebaseDraft
    let index: Int
    let step: RebaseStep
    let isFocused: Bool
    let focus: () -> Void

    var body: some View {
        let meta = draft.meta(at: index)
        HStack(spacing: 0) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: z(10)))
                .foregroundStyle(K.label3)
                .frame(width: z(28))
            Picker("Action for \(step.commit.shortID)", selection: Binding(get: { step.action }, set: { set($0) })) {
                ForEach(RebaseStep.Action.allCases, id: \.self) { action in Text(action.title).tag(action) }
            }
            .labelsHidden()
            .frame(width: z(100))
            .padding(.trailing, z(12))
            Text(step.commit.shortID)
                .font(.system(size: z(11.5), design: .monospaced))
                .foregroundStyle(K.label2)
                .frame(width: z(78), alignment: .leading)
            message
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: z(4)) {
                if meta == "on origin" || draft.pushed.contains(step.commit.id) && step.action == .pick {
                    Icon(Icons.labelRemote, size: 13)
                }
                Text(meta == "on origin" ? "on \(repository.defaultRemote ?? "origin")" : meta)
            }
            .font(.system(size: z(11.5)))
            .foregroundStyle(meta == "nothing above to join" ? K.err : K.label2)
            .lineLimit(1)
            .padding(.horizontal, z(8))
            .fixedSize()
            HStack(spacing: z(2)) {
                MoveButton(up: true, label: "Move \(step.commit.shortID) up") { move(-1) }.disabled(index == 0)
                MoveButton(up: false, label: "Move \(step.commit.shortID) down") { move(1) }.disabled(index == draft.steps.count - 1)
            }
        }
        .padding(.leading, z(6))
        .padding(.trailing, z(10))
        .frame(height: z(40))
        .background(step.action == .drop ? K.hover : (isFocused ? K.accentSoft : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: focus)
    }

    @ViewBuilder
    private var message: some View {
        if step.action == .reword {
            TextField("New message for \(step.commit.shortID)", text: Binding(
                get: { step.message ?? step.commit.subject },
                set: { value in repository.updateRebaseDraft { $0.steps[index].message = value } }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: z(13)))
            .padding(.horizontal, z(8))
            .frame(height: z(28))
            .background(RoundedRectangle(cornerRadius: z(7), style: .continuous).fill(K.field)
                .overlay(RoundedRectangle(cornerRadius: z(7), style: .continuous).strokeBorder(K.accent, lineWidth: 2)))
            .padding(.trailing, z(8))
        } else if step.action.joinsPrevious {
            Text((step.action == .fixup ? "↳ " : "↳ + message: ") + step.commit.subject)
                .font(.system(size: z(13)))
                .foregroundStyle(K.label2)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text(step.commit.subject)
                .font(.system(size: z(13)))
                .strikethrough(step.action == .drop)
                .foregroundStyle(step.action == .drop ? K.label2 : K.label)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func set(_ action: RebaseStep.Action) {
        repository.updateRebaseDraft { draft in
            draft.steps[index].action = action
            if action == .reword, draft.steps[index].message == nil { draft.steps[index].message = draft.steps[index].commit.subject }
        }
        if action == .reword { repository.loadRebaseBody(step.id) }
    }

    private func move(_ offset: Int) {
        repository.updateRebaseDraft { draft in
            let target = index + offset
            guard draft.steps.indices.contains(target) else { return }
            draft.steps.swapAt(index, target)
        }
    }
}

/// `.rmove button`: ⌃ or ⌄.
private struct MoveButton: View {
    let up: Bool
    let label: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Icon(Icons.chevronDown, size: 10)
                .rotationEffect(.degrees(up ? 180 : 0))
                .foregroundStyle(K.label2)
                .frame(width: z(22), height: z(22))
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverPlateStyle(radius: z(6)))
        .opacity(isEnabled ? 1 : 0.25)
        .accessibilityLabel(label)
    }
}

extension RebaseStep.Action {
    var title: String { rawValue.capitalized }
}
