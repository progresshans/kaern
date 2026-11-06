import KaernKit
import SwiftUI

/// Interactive Rebase: what happens to each commit (P R E S F D), dragged into a new order,
/// with a new message right in the row for Reword. Warns before rewriting commits that are
/// already on the remote.
struct InteractiveRebaseSheet: View {
    let model: RepositoryModel
    /// The commit or branch the commits are replayed onto.
    @State var onto: String
    let ontoLabel: String

    @Environment(\.dismiss) private var dismiss
    @State private var steps: [RebaseStep] = []
    @State private var original: [String] = []
    @State private var unpushed: Set<String>?
    @State private var selection: String?
    @State private var autostash = true
    @State private var isLoading = true
    @State private var error: String?
    @FocusState private var isListFocused: Bool

    private var ontoChoices: [(value: String, title: String)] {
        var choices = [(onto, ontoLabel)]
        for ref in model.refs.localBranches where !ref.isHead && ref.name != onto {
            choices.append((ref.name, "\(ref.name) · \(String(ref.target.prefix(7)))"))
        }
        for ref in model.refs.remoteBranches where ref.name != onto && !ref.isSymbolic {
            choices.append((ref.name, "\(ref.name) · \(String(ref.target.prefix(7)))"))
        }
        return choices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Interactive Rebase")
                .font(.system(size: 13, weight: .bold))
            HStack(spacing: 10) {
                Text("Onto:")
                Picker("Onto", selection: $onto) {
                    ForEach(ontoChoices, id: \.value) { Text($0.title).tag($0.value) }
                }
                .labelsHidden()
                .fixedSize()
                Text(steps.count == 1
                     ? "1 commit of \(model.currentBranchTitle), oldest first"
                     : "\(steps.count) commits of \(model.currentBranchTitle), oldest first")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            table

            note
            if !model.status.isClean {
                Toggle(model.status.entries.count == 1
                       ? "Stash my 1 uncommitted change and put it back afterwards"
                       : "Stash my \(model.status.entries.count) uncommitted changes and put them back afterwards",
                       isOn: $autostash)
                    .toggleStyle(.checkbox)
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Color(Palette.deleted))
            }
            HStack {
                Text(resultText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Rebase", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || steps.isEmpty || isLoading || !isChanged)
            }
        }
        .padding(20)
        .frame(width: 600)
        .task(id: onto) { await load() }
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Action").frame(width: 118, alignment: .leading).padding(.leading, 24)
                Text("Commit").frame(width: 60, alignment: .leading)
                Text("Message")
                Spacer()
                Text("P R E S F D keys · drag rows to reorder").foregroundStyle(.tertiary)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            Divider()
            if isLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).frame(height: 80)
            } else if steps.isEmpty {
                Text("Nothing to rebase: \(model.currentBranchTitle) has no commits that \(onto) doesn't have.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } else {
                List(selection: $selection) {
                    ForEach($steps) { $step in
                        RebaseStepRow(step: $step, previous: previous(of: step), isPushed: isPushed(step.commit))
                            .tag(step.id)
                    }
                    .onMove { from, to in steps.move(fromOffsets: from, toOffset: to) }
                }
                .listStyle(.plain)
                .frame(height: min(CGFloat(steps.count) * 34 + 8, 300))
                .focused($isListFocused)
                .onKeyPress(characters: CharacterSet(charactersIn: "prsfdePRSFDE"), phases: .down) { press in
                    guard let selection, let index = steps.firstIndex(where: { $0.id == selection }),
                          let action = RebaseStep.Action.allCases.first(where: { $0.key == Character(press.characters.lowercased()) }) else { return .ignored }
                    steps[index].action = action
                    return .handled
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    // MARK: State

    private func load() async {
        guard let repository = model.repository else { return }
        isLoading = true
        error = nil
        do {
            let commits = try await repository.commitsToRebase(onto: onto)
            steps = commits.map { RebaseStep(commit: $0) }
            original = commits.map(\.id)
            unpushed = await repository.unpushedCommits()
            selection = steps.first?.id
        } catch {
            steps = []
            self.error = error.localizedDescription
        }
        isLoading = false
        isListFocused = true
    }

    private func previous(of step: RebaseStep) -> RebaseStep? {
        guard let index = steps.firstIndex(where: { $0.id == step.id }) else { return nil }
        return steps[..<index].last { $0.action != .drop }
    }

    /// Already on the upstream (the cloud in the row).
    private func isPushed(_ commit: Commit) -> Bool {
        guard let unpushed else { return false }
        return !unpushed.contains(commit.id)
    }

    private var isChanged: Bool {
        steps.map(\.id) != original || steps.contains { $0.action != .pick }
    }

    /// Pushed commits that would get new IDs: changed themselves, or after a change.
    private var rewrittenPushed: [RebaseStep] {
        guard let firstChange = steps.indices.first(where: { steps[$0].action != .pick || steps[$0].id != original[safe: $0] }) else { return [] }
        return steps[firstChange...].filter { isPushed($0.commit) }
    }

    private var problem: String? {
        if let first = steps.first(where: { $0.action != .drop }), first.action.joinsPrevious {
            return String(localized: "The first commit can't be squashed or fixed up: there's nothing above it to join.")
        }
        if steps.allSatisfy({ $0.action == .drop }) && !steps.isEmpty {
            return String(localized: "Every commit is dropped. Reset the branch instead if that's what you want.")
        }
        if steps.contains(where: { $0.action == .reword && ($0.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return String(localized: "A reworded commit needs a message.")
        }
        return nil
    }

    @ViewBuilder
    private var note: some View {
        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(Palette.deleted))
                .font(.system(size: 11))
        } else if let pushed = rewrittenPushed.first {
            Label("\(pushed.commit.shortID) is already on \(model.upstreamRemote ?? "the remote") — the next Push will be Force Push (with lease).",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
                .font(.system(size: 11))
        } else if let kept = steps.first(where: { isPushed($0.commit) }) {
            Label("\(kept.commit.shortID) stays as it is — only unpushed commits change, so a normal Push works afterwards.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color(Palette.added))
                .font(.system(size: 11))
        } else {
            Label("None of these commits are pushed yet, so a normal Push works afterwards.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color(Palette.added))
                .font(.system(size: 11))
        }
    }

    private var resultText: String {
        let count = steps.count { $0.action != .drop && !$0.action.joinsPrevious }
        return count == 1 ? String(localized: "Result: 1 commit") : String(localized: "Result: \(count) commits")
    }

    private func start() {
        guard problem == nil else { return }
        let steps = steps
        let onto = onto
        let label = ontoChoices.first { $0.value == onto }?.title ?? onto
        let stash = autostash || model.status.isClean
        dismiss()
        Task { await model.interactiveRebase(onto: onto, label: label, steps: steps, autostash: stash) }
    }
}

private struct RebaseStepRow: View {
    @Binding var step: RebaseStep
    let previous: RebaseStep?
    let isPushed: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
            Picker("Action", selection: $step.action) {
                ForEach(RebaseStep.Action.allCases, id: \.self) { action in
                    Text(action.rawValue.capitalized).tag(action)
                }
            }
            .labelsHidden()
            .frame(width: 96)
            .onChange(of: step.action) { _, action in
                if action == .reword, step.message == nil { step.message = step.commit.subject }
            }
            Text(step.commit.shortID)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            message
            Spacer(minLength: 4)
            if isPushed {
                Label("on origin", systemImage: "cloud")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .help("Already pushed: changing it rewrites what others may have")
            }
        }
        .frame(height: 30)
    }

    @ViewBuilder
    private var message: some View {
        switch step.action {
        case .reword:
            TextField("Message", text: Binding(get: { step.message ?? "" }, set: { step.message = $0 }))
                .textFieldStyle(.roundedBorder)
        case .squash, .fixup:
            HStack(spacing: 4) {
                Text("↳").foregroundStyle(.tertiary)
                Text(step.commit.subject).foregroundStyle(.secondary).lineLimit(1)
                if let previous {
                    Text("into \(previous.commit.shortID)").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        case .drop:
            Text(step.commit.subject).strikethrough().foregroundStyle(.tertiary).lineLimit(1)
        case .pick, .edit:
            Text(step.commit.subject).lineLimit(1)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
