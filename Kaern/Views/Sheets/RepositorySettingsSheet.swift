import KaernKit
import SwiftUI

/// Keys Kaern keeps in a repository's `.git/config` (git ignores sections it doesn't know).
enum RepositorySettingKey {
    /// `false`: commit with `--no-verify`.
    static let runHooks = "kaern.runHooks"
}

/// Repository › Repository Settings… (⌥⌘,): only what differs per repository — remotes, the
/// name and email for this repository, hooks and how to pull. Everything is written to
/// `.git/config`, so git in Terminal behaves the same.
struct RepositorySettingsSheet: View {
    let model: RepositoryModel

    @Environment(\.dismiss) private var dismiss
    @State private var remotes: [RemoteInfo] = []
    @State private var selectedRemote: String?
    @State private var remoteEditor: RemoteEditor?
    @State private var removing: RemoteInfo?

    @State private var globalName: String?
    @State private var globalEmail: String?
    @State private var usesLocalIdentity = false
    @State private var localName = ""
    @State private var localEmail = ""

    @State private var hooks: [HookInfo] = []
    @State private var runHooks = true

    @State private var pull: PullChoice = .global
    @State private var globalPull: PullChoice = .merge
    @State private var error: String?

    enum PullChoice: Hashable {
        case global
        case merge
        case rebase
        case fastForwardOnly

        var title: String {
            switch self {
            case .global: String(localized: "Use Global Setting")
            case .merge: String(localized: "Merge")
            case .rebase: String(localized: "Rebase")
            case .fastForwardOnly: String(localized: "Fast-Forward Only")
            }
        }
    }

    struct RemoteEditor: Identifiable {
        var original: RemoteInfo?
        var id: String { original?.name ?? "new" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(model.displayName) — Repository Settings")
                .font(.system(size: 13, weight: .bold))

            section("Remotes") {
                remotesTable
                HStack(spacing: 8) {
                    Button("Add Remote…") { remoteEditor = RemoteEditor(original: nil) }
                    Button("Edit…") {
                        if let remote = remotes.first(where: { $0.name == selectedRemote }) { remoteEditor = RemoteEditor(original: remote) }
                    }
                    .disabled(selectedRemote == nil)
                    Button("Remove") { removing = remotes.first { $0.name == selectedRemote } }
                        .disabled(selectedRemote == nil)
                }
                .controlSize(.small)
            }

            section("Identity") {
                Picker("Identity", selection: $usesLocalIdentity) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use my global identity")
                        Text(globalIdentity)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .tag(false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use a different name and email for this repository")
                        Text("For work repositories that need a company address.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if usesLocalIdentity {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                        GridRow {
                            Text("Name:").foregroundStyle(.secondary)
                            TextField("Name", text: $localName, prompt: Text(globalName ?? "Your Name"))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                        }
                        GridRow {
                            Text("Email:").foregroundStyle(.secondary)
                            TextField("Email", text: $localEmail, prompt: Text("you@company.com"))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                        }
                    }
                    .padding(.leading, 20)
                    .frame(maxWidth: 380)
                }
            }

            section("Hooks") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(hooks) { hook in
                        GridRow {
                            Text(hook.name)
                                .font(.system(size: 11, design: .monospaced))
                            Text(hook.summary ?? String(localized: "none"))
                                .font(.system(size: 11, design: hook.isInstalled ? .monospaced : .default))
                                .foregroundStyle(hook.isInstalled ? .primary : .tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                Toggle("Run hooks when committing from Kaern", isOn: $runHooks)
                    .toggleStyle(.checkbox)
                    .disabled(!hooks.contains(where: \.isInstalled))
            }

            section("Pull") {
                HStack(spacing: 10) {
                    Picker("Pull", selection: $pull) {
                        Text("\(PullChoice.global.title) (\(globalPull.title))").tag(PullChoice.global)
                        Divider()
                        Text(PullChoice.merge.title).tag(PullChoice.merge)
                        Text(PullChoice.rebase.title).tag(PullChoice.rebase)
                        Text(PullChoice.fastForwardOnly.title).tag(PullChoice.fastForwardOnly)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text(pullNote)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(Palette.deleted))
            }

            HStack {
                Spacer()
                Button("Done", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        .task { await load() }
        .sheet(item: $remoteEditor) { editor in
            RemoteEditorSheet(model: model, original: editor.original, existing: remotes.map(\.name)) {
                Task { await loadRemotes() }
            }
        }
        .confirmationDialog(
            removing.map { String(localized: "Remove “\($0.name)”?") } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { remote in
            Button("Remove", role: .destructive) { Task { await remove(remote) } }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { remote in
            Text("Its remote branches leave the sidebar and branches that track \(remote.name) lose their upstream. The repository on the server isn't touched.")
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var remotesTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Name").frame(width: 80, alignment: .leading)
                Text("URL")
                Spacer()
                Text("Used for")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            Divider()
            if remotes.isEmpty {
                Text("No remotes. Add one to fetch and push.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            ForEach(remotes) { remote in
                let isSelected = remote.name == selectedRemote
                HStack(alignment: .firstTextBaseline) {
                    Text(remote.name)
                        .fontWeight(.semibold)
                        .frame(width: 80, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(remote.fetchURL)
                        if let push = remote.pushURL {
                            Text("push: \(push)").foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(remote.pushURL == nil ? String(localized: "fetch · push") : String(localized: "fetch"))
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                }
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
                .background(isSelected ? Color.accentColor : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { selectedRemote = remote.name }
                .onTapGesture(count: 2) { remoteEditor = RemoteEditor(original: remote) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private var globalIdentity: String {
        switch (globalName, globalEmail) {
        case (let name?, let email?): "\(name) · \(email)"
        case (let name?, nil): name
        case (nil, let email?): email
        case (nil, nil): String(localized: "Not set — git asks for user.name and user.email")
        }
    }

    private var pullNote: String {
        switch pull {
        case .global: String(localized: "Nothing stored for this repository")
        case .merge, .rebase: String(localized: "Stored in .git/config as pull.rebase")
        case .fastForwardOnly: String(localized: "Stored in .git/config as pull.ff")
        }
    }

    // MARK: Loading and saving

    private func load() async {
        guard let repository = model.repository else { return }
        await loadRemotes()
        let runner = repository.runner
        globalName = await runner.globalConfig("user.name")
        globalEmail = await runner.globalConfig("user.email")
        let name = await repository.localConfig("user.name")
        let email = await repository.localConfig("user.email")
        usesLocalIdentity = name != nil || email != nil
        localName = name ?? ""
        localEmail = email ?? ""
        hooks = await repository.commitHooks()
        runHooks = await repository.localConfig(RepositorySettingKey.runHooks) != "false"
        globalPull = Self.pullChoice(rebase: await runner.globalConfig("pull.rebase"), ff: await runner.globalConfig("pull.ff")) ?? .merge
        pull = Self.pullChoice(rebase: await repository.localConfig("pull.rebase"), ff: await repository.localConfig("pull.ff")) ?? .global
    }

    private func loadRemotes() async {
        guard let repository = model.repository else { return }
        remotes = await repository.remoteInfos()
        if selectedRemote == nil || !remotes.contains(where: { $0.name == selectedRemote }) {
            selectedRemote = remotes.first?.name
        }
    }

    private static func pullChoice(rebase: String?, ff: String?) -> PullChoice? {
        if ff == "only" { return .fastForwardOnly }
        switch rebase?.lowercased() {
        case "true", "merges", "interactive", "i", "m": return .rebase
        case "false": return .merge
        default: return nil
        }
    }

    private func remove(_ remote: RemoteInfo) async {
        guard let repository = model.repository else { return }
        do {
            try await repository.removeRemote(remote.name)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await loadRemotes()
        await model.refreshEverything()
    }

    private func save() {
        guard let repository = model.repository else { return dismiss() }
        let name = localName.trimmingCharacters(in: .whitespaces)
        let email = localEmail.trimmingCharacters(in: .whitespaces)
        let local = usesLocalIdentity
        let runHooks = runHooks
        let pull = pull
        Task {
            do {
                try await repository.setLocalConfig("user.name", local && !name.isEmpty ? name : nil)
                try await repository.setLocalConfig("user.email", local && !email.isEmpty ? email : nil)
                try await repository.setLocalConfig(RepositorySettingKey.runHooks, runHooks ? nil : "false")
                switch pull {
                case .global:
                    try await repository.setLocalConfig("pull.rebase", nil)
                    try await repository.setLocalConfig("pull.ff", nil)
                case .merge:
                    try await repository.setLocalConfig("pull.rebase", "false")
                    try await repository.setLocalConfig("pull.ff", nil)
                case .rebase:
                    try await repository.setLocalConfig("pull.rebase", "true")
                    try await repository.setLocalConfig("pull.ff", nil)
                case .fastForwardOnly:
                    try await repository.setLocalConfig("pull.rebase", nil)
                    try await repository.setLocalConfig("pull.ff", "only")
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Add Remote… / Edit…: a name and a URL.
private struct RemoteEditorSheet: View {
    let model: RepositoryModel
    let original: RemoteInfo?
    let existing: [String]
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var problem: String?
    @State private var isSaving = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedURL: String { url.trimmingCharacters(in: .whitespaces) }

    private var nameProblem: String? {
        if trimmedName.isEmpty { return "" }
        if trimmedName != original?.name, existing.contains(trimmedName) {
            return String(localized: "A remote named “\(trimmedName)” already exists.")
        }
        return nil
    }

    var body: some View {
        FormSheet(title: original == nil ? String(localized: "Add Remote") : String(localized: "Edit “\(original?.name ?? "")”")) {
            GridRow {
                FormLabel("Name:")
                TextField("Name", text: $name, prompt: Text("origin"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 300)
            }
            GridRow {
                FormLabel("URL:")
                TextField("URL", text: $url, prompt: Text("https://github.com/owner/repo.git"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 300)
                    .onSubmit(save)
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                if let message = problem ?? nameProblem, !message.isEmpty {
                    FormNote(text: message, isError: true)
                } else {
                    FormNote(text: String(localized: "HTTPS or SSH (git@host:owner/repo.git)."))
                }
            }
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(original == nil ? "Add Remote" : "Save", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(nameProblem != nil || trimmedURL.isEmpty || isSaving)
        }
        .onAppear {
            name = original?.name ?? (existing.contains("origin") ? "" : "origin")
            url = original?.fetchURL ?? ""
        }
    }

    private func save() {
        guard nameProblem == nil, !trimmedURL.isEmpty, !isSaving, let repository = model.repository else { return }
        isSaving = true
        let newName = trimmedName
        let newURL = trimmedURL
        Task {
            do {
                guard await repository.isValidRemoteName(newName) else {
                    problem = String(localized: "That isn't a valid remote name.")
                    isSaving = false
                    return
                }
                if let original {
                    if original.name != newName { try await repository.renameRemote(original.name, to: newName) }
                    if original.fetchURL != newURL { try await repository.setRemoteURL(newName, to: newURL) }
                } else {
                    try await repository.addRemote(newName, url: newURL)
                }
                onSave()
                await model.refreshEverything()
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
            isSaving = false
        }
    }
}
