import AppKit
import KaernKit
import SwiftUI

/// Repository › Repository Settings… (⌥⌘,), ScreenSheets' "레포 설정": remotes, the identity for
/// this repository, hooks and how Pull works here. Every change goes to .git/config right away.
struct RepositorySettingsSheet: View {
    let repository: RepositoryModel
    @State private var selectedRemote: String?
    @State private var adding = false
    @State private var editing: String?
    @State private var confirmingRemoval: String?
    @State private var newName = "origin"
    @State private var newURL = ""
    @State private var customIdentity = false
    @State private var idName = ""
    @State private var idEmail = ""
    @State private var globalName: String?
    @State private var globalEmail: String?
    @State private var hooks: [HookInfo] = []
    @State private var runsHooks = true
    @State private var pull = "global"
    @State private var failure: String?
    @State private var loaded = false

    var body: some View {
        SheetCard(width: 600) {
            SheetTitle("\(repository.name) — Repository Settings")
            heading("Remotes")
            remotesTable
            HStack(spacing: z(6)) {
                GhostButton(title: "Add Remote…") {
                    adding = true
                    editing = nil
                    newName = repository.remotes.isEmpty ? "origin" : ""
                    newURL = ""
                }
                GhostButton(title: "Edit…") {
                    guard let name = selectedRemote, let remote = repository.remotes.first(where: { $0.name == name }) else { return }
                    editing = name
                    adding = false
                    newName = name
                    newURL = remote.fetchURL
                }
                .disabled(selectedRemote == nil)
                GhostButton(title: "Remove") { confirmingRemoval = selectedRemote }
                    .disabled(selectedRemote == nil)
            }
            .padding(.top, z(8))
            if let name = confirmingRemoval {
                HStack(spacing: z(8)) {
                    Text("Remove \(name)? Its remote branches go too, and branches that tracked it stop tracking.")
                        .font(.system(size: z(11.5)))
                        .foregroundStyle(K.err)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Cancel") { confirmingRemoval = nil }.controlSize(.small)
                    Button("Remove") { remove(name) }.controlSize(.small)
                }
                .padding(.top, z(6))
            }
            heading("Identity")
            VStack(alignment: .leading, spacing: z(7)) {
                RadioRow(isOn: !customIdentity, title: "Use my global identity",
                         subtitle: [globalName, globalEmail].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "Not set in your global Git config") {
                    setCustomIdentity(false)
                }
                RadioRow(isOn: customIdentity, title: "Use a different name and email for this repository",
                         subtitle: "For work repositories that need a company address.") {
                    setCustomIdentity(true)
                }
                if customIdentity {
                    HStack(spacing: z(8)) {
                        TextField("Name", text: $idName).textFieldStyle(.roundedBorder)
                            .onSubmit { save("user.name", idName) }
                        TextField("Email", text: $idEmail).textFieldStyle(.roundedBorder)
                            .onSubmit { save("user.email", idEmail) }
                            .frame(minWidth: z(240))
                    }
                    .font(.system(size: z(12.5)))
                    .padding(.leading, z(21))
                    .onChange(of: idName) { if loaded { saveSoon("user.name", idName) } }
                    .onChange(of: idEmail) { if loaded { saveSoon("user.email", idEmail) } }
                }
            }
            heading("Hooks")
            Grid(alignment: .leading, horizontalSpacing: z(10), verticalSpacing: z(4)) {
                ForEach(hooks.filter { $0.name == "pre-commit" || $0.name == "commit-msg" || $0.isInstalled }) { hook in
                    GridRow {
                        Text(hook.name).font(.system(size: z(12), design: .monospaced)).frame(width: z(100), alignment: .leading)
                        Text(hook.summary ?? "none")
                            .font(.system(size: z(12), design: hook.isInstalled ? .monospaced : .default))
                            .foregroundStyle(hook.isInstalled ? K.label : K.label3)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .padding(.bottom, z(8))
            Toggle("Run hooks when committing from Kaern", isOn: Binding(get: { runsHooks }, set: { setRunsHooks($0) }))
                .toggleStyle(.checkbox)
                .font(.system(size: z(12.5)))
            heading("Pull")
            HStack(spacing: z(10)) {
                Picker("Pull behavior", selection: Binding(get: { pull }, set: { setPull($0) })) {
                    Text("Use Kaern’s Setting (\(PullChoice.app.shortTitle))").tag("global")
                    Text("Merge").tag("merge")
                    Text("Rebase").tag("rebase")
                    Text("Fast-forward Only").tag("ff")
                }
                .labelsHidden()
                .frame(width: z(250))
                Text(pullHint)
                    .font(.system(size: z(11.5)))
                    .foregroundStyle(K.label2)
                    .lineLimit(2)
            }
            if let failure {
                Text(failure).font(.system(size: z(11.5))).foregroundStyle(K.err).padding(.top, z(8))
            }
            HStack(spacing: z(8)) {
                Text("Saved to .git/config as you change it — the same as git config.")
                    .font(.system(size: z(11.5)))
                    .foregroundStyle(K.label2)
                Spacer(minLength: 0)
                Button("Done") { repository.sheet = nil }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.regular)
                Button("", action: { repository.sheet = nil }).keyboardShortcut(.cancelAction).hidden().frame(width: 0, height: 0)
            }
            .padding(.top, z(16))
        }
        .task { await load() }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: z(11.5), weight: .semibold))
            .foregroundStyle(K.label2)
            .padding(.top, z(16))
            .padding(.bottom, z(6))
    }

    // MARK: Remotes

    private var remotesTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: z(10)) {
                Text("Name").frame(width: z(90), alignment: .leading)
                Text("URL").frame(maxWidth: .infinity, alignment: .leading)
                Text("Used for").frame(width: z(92), alignment: .leading)
            }
            .font(.system(size: z(11), weight: .semibold))
            .foregroundStyle(K.label2)
            .padding(.horizontal, z(10))
            .frame(height: z(24))
            .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
            ForEach(repository.remotes) { remote in
                if editing == remote.name {
                    editRow(isNew: false)
                } else {
                    let isOn = selectedRemote == remote.name
                    HStack(spacing: z(10)) {
                        Text(remote.name).frame(width: z(90), alignment: .leading)
                        Text(remote.fetchURL)
                            .font(.system(size: z(12), design: .monospaced))
                            .foregroundStyle(isOn ? .white.opacity(0.88) : K.label2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(remote.pushURL == nil ? "fetch · push" : "fetch · push elsewhere")
                            .foregroundStyle(isOn ? .white.opacity(0.88) : K.label2)
                            .frame(width: z(92), alignment: .leading)
                    }
                    .font(.system(size: z(12.5)))
                    .foregroundStyle(isOn ? .white : K.label)
                    .padding(.horizontal, z(10))
                    .frame(height: z(30))
                    .background(isOn ? K.sel : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedRemote = remote.name }
                }
            }
            if repository.remotes.isEmpty, !adding {
                Text("No remotes — this repository is only on this Mac.")
                    .font(.system(size: z(12)))
                    .foregroundStyle(K.label2)
                    .frame(maxWidth: .infinity, minHeight: z(30))
            }
            if adding { editRow(isNew: true) }
        }
        .background(RoundedRectangle(cornerRadius: z(8), style: .continuous).fill(K.field))
        .clipShape(RoundedRectangle(cornerRadius: z(8), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: z(8), style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5))
    }

    private func editRow(isNew: Bool) -> some View {
        HStack(spacing: z(10)) {
            TextField("Remote name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(width: z(90))
                .disabled(!isNew)
            TextField("https://github.com/owner/repo.git", text: $newURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: z(12), design: .monospaced))
                .onSubmit { commitRemote(isNew: isNew) }
            Button("Cancel") { adding = false; editing = nil }.controlSize(.small)
            Button(isNew ? "Add" : "Save") { commitRemote(isNew: isNew) }
                .controlSize(.small)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newURL.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .font(.system(size: z(12.5)))
        .padding(.horizontal, z(10))
        .frame(height: z(36))
        .overlay(alignment: .top) { K.sep.frame(height: 1) }
    }

    private func commitRemote(isNew: Bool) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let url = newURL.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !url.isEmpty, let git = repository.repository else { return }
        Task {
            do {
                try await GitCommandTrigger.$current.withValue(GitCommandTrigger("Repository Settings › \(isNew ? "Add" : "Edit") Remote \(name)")) {
                    if isNew {
                        guard await git.isValidRemoteName(name) else {
                            throw UndoRefusal(message: "“\(name)” can’t be a remote name.")
                        }
                        try await git.addRemote(name, url: url)
                    } else {
                        try await git.setRemoteURL(name, url: url)
                    }
                }
                failure = nil
                adding = false
                editing = nil
                selectedRemote = name
                await repository.refreshRemotes()
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func remove(_ name: String) {
        guard let git = repository.repository else { return }
        confirmingRemoval = nil
        Task {
            do {
                try await GitCommandTrigger.$current.withValue(GitCommandTrigger("Repository Settings › Remove Remote \(name)")) {
                    try await git.removeRemote(name)
                }
                selectedRemote = nil
                await repository.refreshRemotes()
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    // MARK: Identity, hooks, pull

    private func load() async {
        guard let git = repository.repository, let runner = AppModel.shared.runner else { return }
        async let name = git.localConfig("user.name")
        async let email = git.localConfig("user.email")
        async let gName = runner.globalConfig("user.name")
        async let gEmail = runner.globalConfig("user.email")
        async let hookList = git.commitHooks()
        async let hooksSetting = git.localConfig("kaern.runHooks")
        async let rebase = git.localConfig("pull.rebase")
        async let ff = git.localConfig("pull.ff")
        let localName = await name, localEmail = await email
        customIdentity = localName != nil || localEmail != nil
        idName = localName ?? ""
        idEmail = localEmail ?? ""
        globalName = await gName
        globalEmail = await gEmail
        hooks = await hookList
        runsHooks = (await hooksSetting)?.lowercased() != "false"
        let ffValue = await ff, rebaseValue = await rebase
        pull = ffValue == "only" ? "ff" : rebaseValue.map { $0 == "false" ? "merge" : "rebase" } ?? "global"
        selectedRemote = repository.remotes.first?.name
        try? await Task.sleep(for: .milliseconds(50))
        loaded = true
    }

    /// A save waiting for the typing to pause, per key: the name's doesn't go when the email
    /// is typed right after it.
    @State private var pendingSaves: [String: Task<Void, Never>] = [:]
    @State private var lastSave: Task<Void, Never>?

    private func saveSoon(_ key: String, _ value: String) {
        pendingSaves[key]?.cancel()
        pendingSaves[key] = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            save(key, value)
        }
    }

    /// One write after the other: two `git config` at once fight over the config file's lock.
    private func save(_ key: String, _ value: String?) {
        guard let git = repository.repository else { return }
        let trimmed = value?.trimmingCharacters(in: .whitespaces)
        let previous = lastSave
        lastSave = Task {
            await previous?.value
            do {
                try await git.setLocalConfig(key, trimmed?.isEmpty == true ? nil : trimmed)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func setCustomIdentity(_ on: Bool) {
        customIdentity = on
        if on {
            if idName.isEmpty { idName = globalName ?? "" }
            if idEmail.isEmpty { idEmail = globalEmail ?? "" }
            save("user.name", idName)
            save("user.email", idEmail)
        } else {
            save("user.name", nil)
            save("user.email", nil)
        }
    }

    private func setRunsHooks(_ on: Bool) {
        runsHooks = on
        repository.runsHooks = on
        save("kaern.runHooks", on ? nil : "false")
    }

    private func setPull(_ value: String) {
        pull = value
        guard let git = repository.repository else { return }
        Task {
            switch value {
            case "merge":
                try? await git.setLocalConfig("pull.ff", nil)
                try? await git.setLocalConfig("pull.rebase", "false")
            case "rebase":
                try? await git.setLocalConfig("pull.ff", nil)
                try? await git.setLocalConfig("pull.rebase", "true")
            case "ff":
                try? await git.setLocalConfig("pull.rebase", nil)
                try? await git.setLocalConfig("pull.ff", "only")
            default:
                try? await git.setLocalConfig("pull.rebase", nil)
                try? await git.setLocalConfig("pull.ff", nil)
            }
            await repository.refreshPullOverride()
        }
    }

    private var pullHint: String {
        switch pull {
        case "merge": "Stored in .git/config as pull.rebase = false"
        case "rebase": "Stored in .git/config as pull.rebase = true"
        case "ff": "Stored in .git/config as pull.ff = only"
        default: "Pull here follows Settings › General › Pull."
        }
    }
}

/// `.rad`: a radio button with a title and a second line.
private struct RadioRow: View {
    let isOn: Bool
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: z(7)) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: z(13)))
                    .foregroundStyle(isOn ? K.accent : K.label3)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: z(12.5)))
                    Text(subtitle).font(.system(size: z(11.5))).foregroundStyle(K.label2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension PullChoice {
    /// What Settings › General › Pull is set to.
    static var app: PullChoice {
        PullChoice(rawValue: UserDefaults.kaern.string(forKey: "KaernPullStrategy") ?? "") ?? .fastForwardIfPossible
    }

    var shortTitle: String {
        switch self {
        case .fastForwardIfPossible: "Fast-forward if possible"
        case .fastForwardOnly: "Fast-forward only"
        case .rebase: "Rebase"
        }
    }
}
