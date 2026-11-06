import KaernKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab("Accounts", systemImage: "person.crop.circle") {
                AccountsSettingsView()
            }
            Tab("Advanced", systemImage: "slider.horizontal.3") {
                AdvancedSettingsView()
            }
        }
        .scenePadding()
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @AppStorage(PreferenceKey.repositorySwitcher) private var switcher = RepositorySwitcher.toolbar
    @AppStorage(PreferenceKey.fetchAutomatically) private var fetchAutomatically = true
    @AppStorage(PreferenceKey.fetchInterval) private var fetchInterval = FetchInterval.fiveMinutes
    @AppStorage(PreferenceKey.pull) private var pull = PullPreference.gitConfig
    @AppStorage(PreferenceKey.branchSwitch) private var branchSwitch = BranchSwitchPreference.ask
    @AppStorage(PreferenceKey.defaultBranch) private var defaultBranch = "main"
    @AppStorage(PreferenceKey.editor) private var editor = EditorChoice.xcode
    @AppStorage(PreferenceKey.mergeTool) private var mergeTool = MergeToolChoice.fileMerge
    @AppStorage(PreferenceKey.showAuthor) private var showAuthor = true
    @AppStorage(PreferenceKey.showAvatars) private var showAvatars = true
    @State private var pullRebase: String?

    var body: some View {
        Form {
            LabeledContent("Switch repositories with:") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        ForEach(RepositorySwitcher.allCases) { mode in
                            SwitcherThumbnail(mode: mode, isSelected: switcher == mode) {
                                if mode.isAvailable { switcher = mode }
                            }
                        }
                    }
                    Caption(switcher.summary)
                }
            }
            .padding(.bottom, 14)

            LabeledContent("Fetch:") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Toggle("Fetch automatically", isOn: $fetchAutomatically)
                            .toggleStyle(.checkbox)
                        Picker("Interval", selection: $fetchInterval) {
                            ForEach(FetchInterval.allCases) { interval in
                                Text(interval.title).tag(interval)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!fetchAutomatically)
                    }
                    Caption("Fetch only updates remote branches. It never changes your files. On battery Kaern waits at least 15 minutes and pauses in Low Power Mode.")
                }
            }

            LabeledContent("Pull:") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Pull", selection: $pull) {
                        ForEach(PullPreference.allCases) { preference in
                            Text(preference == .gitConfig ? "\(preference.title) (\(gitConfigPullTitle))" : preference.title)
                                .tag(preference)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if pull == .gitConfig {
                        Caption(pullRebase.map { "From pull.rebase = \($0) in ~/.gitconfig" } ?? "pull.rebase isn't set, so Kaern merges.")
                    }
                }
            }

            LabeledContent("When switching branches:") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("When switching branches", selection: $branchSwitch) {
                        ForEach(BranchSwitchPreference.allCases) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Caption("With uncommitted changes, asks to stash them or bring them along.")
                }
            }

            LabeledContent("Default branch name:") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Default branch name", text: $defaultBranch)
                        .labelsHidden()
                        .frame(width: 200)
                    Caption("For new repositories (init.defaultBranch).")
                }
            }
            .padding(.bottom, 14)

            Picker("Open files in:", selection: $editor) {
                ForEach(EditorChoice.allCases.filter(\.isInstalled)) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .fixedSize()

            Picker("Merge tool:", selection: $mergeTool) {
                ForEach(MergeToolChoice.allCases) { tool in
                    Text(tool.title).tag(tool)
                }
            }
            .fixedSize()
            .padding(.bottom, 14)

            LabeledContent("History:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Show Author column", isOn: $showAuthor)
                        .toggleStyle(.checkbox)
                    Toggle("Show GitHub avatars", isOn: $showAvatars)
                        .toggleStyle(.checkbox)
                        .onChange(of: showAvatars) { AvatarStore.shared.settingChanged() }
                    Caption("For repositories on GitHub, Kaern asks GitHub which accounts made the latest commits, with your token from Accounts if you added one. Only the repository's name is sent.")
                }
            }
        }
        .formStyle(.columns)
        .frame(width: 620)
        .padding(.vertical, 8)
        .task {
            pullRebase = await Self.globalConfig("pull.rebase")
        }
    }

    private var gitConfigPullTitle: String {
        switch pullRebase {
        case "true", "merges", "interactive": String(localized: "Rebase")
        case "false", nil: String(localized: "Merge")
        default: pullRebase ?? ""
        }
    }

    static func globalConfig(_ key: String) async -> String? {
        let runner = AppModel.shared.makeRunner()
        guard let output = try? await runner.run(["config", "--global", "--get", key], in: nil, acceptedStatus: [0, 1]),
              output.status == 0 else { return nil }
        let value = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private struct Caption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 380, alignment: .leading)
    }
}

/// A tiny drawing of each repository-switching layout.
private struct SwitcherThumbnail: View {
    let mode: RepositorySwitcher
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                preview
                    .frame(width: 70, height: 46)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2.5 : 1)
                    )
                Text(mode.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            }
            .opacity(mode.isAvailable ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!mode.isAvailable)
        .help(mode.isAvailable ? mode.summary : String(localized: "Coming in a later build"))
    }

    @ViewBuilder
    private var preview: some View {
        let accent = Color.accentColor
        let line = Color.secondary.opacity(0.25)
        switch mode {
        case .toolbar:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Capsule().fill(accent).frame(width: 16, height: 5)
                    Capsule().fill(line).frame(width: 22, height: 5)
                }
                layoutLines(line: line, sidebar: 12)
            }
            .padding(6)
        case .tabs:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2) {
                    Rectangle().fill(line).frame(height: 5)
                    Rectangle().fill(accent).frame(width: 18, height: 5)
                    Rectangle().fill(line).frame(height: 5)
                }
                layoutLines(line: line, sidebar: 12)
            }
            .padding(6)
        case .iconRail:
            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1.5).fill(accent).frame(width: 6, height: 6)
                    RoundedRectangle(cornerRadius: 1.5).fill(line).frame(width: 6, height: 6)
                    RoundedRectangle(cornerRadius: 1.5).fill(line).frame(width: 6, height: 6)
                }
                layoutLines(line: line, sidebar: 10)
            }
            .padding(6)
        case .namedList:
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(accent).frame(width: 14, height: 4)
                    Capsule().fill(line).frame(width: 14, height: 4)
                    Capsule().fill(line).frame(width: 14, height: 4)
                }
                layoutLines(line: line, sidebar: 8)
            }
            .padding(6)
        }
    }

    private func layoutLines(line: Color, sidebar: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(0 ..< 3, id: \.self) { _ in Capsule().fill(line).frame(width: sidebar, height: 3) }
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(0 ..< 4, id: \.self) { _ in Capsule().fill(line).frame(height: 3) }
            }
        }
    }
}

// MARK: - Accounts

/// GitHub and GitLab accounts, for pull requests and for cloning. Tokens stay with git's
/// credential helper (the Keychain); this list only remembers who and where.
struct AccountsSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var selection: String?
    @State private var isAdding = false
    @State private var signingOut: HostingAccount?

    private var accounts: [HostingAccount] {
        _ = appModel.accountsVersion
        return appModel.accounts
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    List(selection: $selection) {
                        ForEach(accounts) { account in
                            HStack(spacing: 8) {
                                Image(systemName: "person.crop.circle")
                                    .font(.system(size: 18))
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(account.login).fontWeight(.semibold)
                                    Text(account.host).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                            .tag(account.id)
                        }
                    }
                    .listStyle(.bordered)
                    .frame(width: 180, height: 170)
                    .overlay {
                        if accounts.isEmpty {
                            Text("No accounts").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 0) {
                        Button { isAdding = true } label: { Image(systemName: "plus").frame(width: 16) }
                            .help("Add an account")
                        Button { signingOut = accounts.first { $0.id == selection } } label: { Image(systemName: "minus").frame(width: 16) }
                            .disabled(selection == nil)
                            .help("Sign out of the selected account")
                    }
                    .controlSize(.small)
                }

                if let account = accounts.first(where: { $0.id == selection }) {
                    AccountDetail(account: account) { signingOut = account }
                        .id(account.id)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Add a GitHub or GitLab account to see pull requests and their checks.")
                        Caption("Signing in uses a token you create on the website. Git keeps it in your Keychain, so fetch and push in Terminal use it too.")
                        Button("Add Account…") { isAdding = true }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)

            Divider()
            Text("Kaern never sees your password: you make a token on the website and it stays in the Keychain with git's credential helper.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: 620)
        .onAppear { if selection == nil { selection = accounts.first?.id } }
        .sheet(isPresented: $isAdding) {
            AddAccountSheet { account in selection = account.id }
        }
        .confirmationDialog(
            signingOut.map { String(localized: "Sign out of \($0.login) on \($0.hostName)?") } ?? "",
            isPresented: Binding(get: { signingOut != nil }, set: { if !$0 { signingOut = nil } }),
            presenting: signingOut
        ) { account in
            Button("Sign Out", role: .destructive) {
                Task {
                    await appModel.signOut(account)
                    selection = appModel.accounts.first?.id
                }
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { account in
            Text("The token is removed from the Keychain. git asks for it again the next time it talks to \(account.host) over HTTPS.")
        }
    }
}

private struct AccountDetail: View {
    @Environment(AppModel.self) private var appModel
    @State var account: HostingAccount
    let onSignOut: () -> Void

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text("Account:").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text(account.login).fontWeight(.semibold)
            }
            GridRow {
                Text("Server:").foregroundStyle(.secondary)
                Text(account.host)
            }
            GridRow {
                Text("Signed in:").foregroundStyle(.secondary)
                Text("with a token · in the Keychain")
                    .fixedSize(horizontal: false, vertical: true)
            }
            GridRow {
                Text("Clone with:").foregroundStyle(.secondary)
                Picker("Clone with", selection: $account.clonesWithSSH) {
                    Text("HTTPS").tag(false)
                    Text("SSH").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                Text("Commit as:").foregroundStyle(.secondary)
                Picker("Commit as", selection: $account.commitEmail) {
                    Text("My Global Identity").tag(String?.none)
                    if let noreply = account.noreplyEmail {
                        Text("\(account.name ?? account.login) (noreply)").tag(String?.some(noreply))
                    }
                    if let email = account.publicEmail, email != account.noreplyEmail {
                        Text("\(account.name ?? account.login) <\(email)>").tag(String?.some(email))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("The email Kaern sets in repositories you clone from \(account.host)")
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Button("Sign Out…", action: onSignOut)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: account) { _, account in appModel.updateAccount(account) }
    }
}

/// + in Settings › Accounts: a token for GitHub, GitLab or GitHub Enterprise.
private struct AddAccountSheet: View {
    let onAdd: (HostingAccount) -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var service = Service.github
    @State private var host = ""
    @State private var token = ""
    @State private var error: String?
    @State private var isSigningIn = false

    enum Service: String, CaseIterable, Identifiable {
        case github
        case gitlab
        case enterprise

        var id: String { rawValue }
        var title: String {
            switch self {
            case .github: "GitHub"
            case .gitlab: "GitLab"
            case .enterprise: String(localized: "GitHub Enterprise")
            }
        }
    }

    private var resolvedHost: String {
        switch service {
        case .github: "github.com"
        case .gitlab: "gitlab.com"
        case .enterprise: host.trimmingCharacters(in: .whitespaces).lowercased()
        }
    }

    var body: some View {
        FormSheet(title: String(localized: "Add Account")) {
            GridRow {
                FormLabel("Service:")
                Picker("Service", selection: $service) {
                    ForEach(Service.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if service == .enterprise {
                GridRow {
                    FormLabel("Server:")
                    TextField("Server", text: $host, prompt: Text("github.company.com"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 280)
                }
            }
            GridRow {
                FormLabel("Token:")
                SecureField("Token", text: $token, prompt: Text(service == .gitlab ? "glpat-…" : "ghp_… or github_pat_…"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 280)
                    .onSubmit(signIn)
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                VStack(alignment: .leading, spacing: 6) {
                    if let error {
                        FormNote(text: error, isError: true)
                    } else {
                        FormNote(text: String(localized: "Make a token with the repo scope (read_api and read_repository on GitLab), then paste it here."))
                    }
                    Button("Create a Token on \(service == .gitlab ? "GitLab" : "GitHub")…") {
                        let page = RemoteURL("https://\(resolvedHost)/x/y.git")?.tokenPage
                        if let page { NSWorkspace.shared.open(page) }
                    }
                    .buttonStyle(.link)
                    .disabled(resolvedHost.isEmpty)
                }
            }
        } buttons: {
            if isSigningIn { ProgressView().controlSize(.small) }
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Sign In", action: signIn)
                .keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || resolvedHost.isEmpty || isSigningIn)
        }
    }

    private func signIn() {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !resolvedHost.isEmpty, !isSigningIn else { return }
        isSigningIn = true
        error = nil
        Task {
            do {
                let account = try await appModel.addAccount(kind: service == .gitlab ? .gitlab : .github, host: resolvedHost, token: token)
                onAdd(account)
                dismiss()
            } catch let failure as HostingError where failure.isUnauthorized {
                error = String(localized: "\(resolvedHost) didn't accept that token.")
            } catch {
                self.error = error.localizedDescription
            }
            isSigningIn = false
        }
    }
}

// MARK: - Advanced

/// What rarely changes and applies to every repository. Per-repository options live in
/// Repository Settings (⌥⌘,).
struct AdvancedSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage(PreferenceKey.gitPath) private var gitPath = GitRunner.defaultExecutableURL.path(percentEncoded: false)
    @AppStorage(PreferenceKey.historyPageSize) private var pageSize = 5000
    @AppStorage(PreferenceKey.useSSHAgent) private var useSSHAgent = true
    @AppStorage(PreferenceKey.watchFileChanges) private var watchFileChanges = true
    @State private var version: String?
    @State private var didReset = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                LabeledContent("Git:") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(version.map { "\(gitPath) — \($0)" } ?? String(localized: "\(gitPath) — not found"))
                                .foregroundStyle(version == nil ? Color(Palette.deleted) : Color.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose…", action: chooseGit)
                                .controlSize(.small)
                        }
                        Caption("Kaern runs this git, so your config, hooks, credential helpers and LFS all apply.")
                    }
                }
                .task(id: gitPath) {
                    version = await GitRunner.availableVersion(at: URL(filePath: gitPath))
                }

                LabeledContent("SSH:") {
                    Toggle("Use the SSH agent (ssh-agent, 1Password)", isOn: $useSSHAgent)
                        .toggleStyle(.checkbox)
                }

                LabeledContent("File changes:") {
                    Toggle("Refresh as soon as files change on disk", isOn: $watchFileChanges)
                        .toggleStyle(.checkbox)
                }

                Picker("Large repositories:", selection: $pageSize) {
                    Text("Load History in Pages of 1,000").tag(1000)
                    Text("Load History in Pages of 5,000").tag(5000)
                    Text("Load History in Pages of 10,000").tag(10000)
                }
                .fixedSize()

                LabeledContent("Command log:") {
                    VStack(alignment: .leading, spacing: 4) {
                        Button("Show Command Log…") { appModel.showCommandLog() }
                            .controlSize(.small)
                        Caption("Every git command Kaern ran, with its output — for bug reports.")
                    }
                }

                LabeledContent("Warnings:") {
                    HStack(spacing: 8) {
                        Button("Reset “Don’t Ask Again” Choices") {
                            Preferences.resetDontAskAgainChoices()
                            didReset = true
                        }
                        .controlSize(.small)
                        if didReset {
                            Text("Kaern asks again.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.columns)
            .padding(.vertical, 8)

            Divider()
            Text("These apply to every repository. Options for one repository are in Repository Settings (⌥⌘,).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: 620)
    }

    private func chooseGit() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(filePath: "/usr/bin")
        if panel.runModal() == .OK, let url = panel.url {
            gitPath = url.path(percentEncoded: false)
        }
    }
}

/// Window › Command Log: every git command Kaern ran, newest first, with its exit status.
struct CommandLogView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage(PreferenceKey.recordCommandLog) private var recordLog = true

    var body: some View {
        VStack(spacing: 0) {
            CommandLogList(records: appModel.commandLog)
            Divider()
            HStack {
                Toggle("Record git commands", isOn: $recordLog)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Copy All") {
                    let text = appModel.commandLog.map { "[\($0.status)] git \($0.arguments.joined(separator: " "))  (\($0.directory))" }
                        .joined(separator: "\n")
                    Pasteboard.copy(text)
                }
                .disabled(appModel.commandLog.isEmpty)
                Button("Clear") { appModel.clearCommandLog() }
                    .disabled(appModel.commandLog.isEmpty)
            }
            .controlSize(.small)
            .padding(10)
        }
        .frame(minWidth: 520, minHeight: 300)
    }
}

private struct CommandLogList: View {
    let records: [GitCommandRecord]

    var body: some View {
        List(records.reversed()) { record in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: record.status == 0 ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(record.status == 0 ? Color(Palette.added) : Color(Palette.deleted))
                VStack(alignment: .leading, spacing: 1) {
                    Text("git " + record.arguments.joined(separator: " "))
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text("\(URL(filePath: record.directory).lastPathComponent) · \(record.duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))) · \(record.date.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if records.isEmpty {
                Text("No commands yet").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
