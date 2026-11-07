import AppKit
import KaernKit
import SwiftUI

/// Kaern › Settings… (⌘,): General, Accounts, Git, Diff and Advanced as toolbar tabs, like
/// every Mac app's settings. The window title follows the pane.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    enum Pane: String, CaseIterable {
        case general = "General", accounts = "Accounts", git = "Git", diff = "Diff", advanced = "Advanced"

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .accounts: "person.crop.circle"
            case .git: "arrow.triangle.branch"
            case .diff: "rectangle.split.2x1"
            case .advanced: "slider.horizontal.3"
            }
        }
    }

    private let tabs = NSTabViewController()

    private init() {
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        for pane in Pane.allCases {
            let host = NSHostingController(rootView: SettingsPaneView(pane: pane).environment(AppModel.shared))
            host.sizingOptions = [.preferredContentSize]
            host.title = pane.rawValue
            let item = NSTabViewItem(viewController: host)
            item.label = pane.rawValue
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.rawValue)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.toolbarStyle = .preference
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ pane: Pane? = nil) {
        if let pane, let index = Pane.allCases.firstIndex(of: pane) {
            tabs.selectedTabViewItemIndex = index
        }
        window?.makeKeyAndOrderFront(nil)
    }

    var currentPane: Pane { Pane.allCases[max(0, tabs.selectedTabViewItemIndex)] }
}

// MARK: - Layout

/// One pane: its rows on the content color, then the note that these are app-wide settings.
private struct SettingsPaneView: View {
    let pane: SettingsWindowController.Pane

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch pane {
                case .general: GeneralPane()
                case .accounts: AccountsPane()
                case .git: GitPane()
                case .diff: DiffPane()
                case .advanced: AdvancedPane()
                }
            }
            .padding(EdgeInsets(top: 24, leading: 40, bottom: 18, trailing: 40))
            .frame(maxWidth: .infinity, minHeight: 430, alignment: .topLeading)
            K.sep.frame(height: 1)
            Text("These apply to every repository. Options for one repository are in Repository Settings (⌥⌘,).")
                .font(.system(size: 11.5))
                .foregroundStyle(K.label2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 12, leading: 40, bottom: 14, trailing: 40))
        }
        .frame(width: 780)
        .fixedSize(horizontal: false, vertical: true)
        .background(K.content)
        .foregroundStyle(K.label)
    }
}

/// `.grid2`: right-aligned labels in a 170 pt column, controls on the right.
private struct SettingsGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 16) {
            content
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        GridRow {
            Text(label)
                .font(.system(size: 13))
                .frame(width: 170, alignment: .trailing)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 7) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// `.chk`: a checkbox row, 26 pt tall so its text lines up with the row's label.
private struct Checkbox: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.checkbox)
            .font(.system(size: 13))
            .frame(minHeight: 26)
    }
}

/// `.hint`: gray help text under a control.
private struct Hint: View {
    let text: String
    var strong = false

    init(_ text: String, strong: Bool = false) {
        self.text = text
        self.strong = strong
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .lineSpacing(2)
            .foregroundStyle(strong ? K.label : K.label2)
            .frame(maxWidth: 440, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @AppStorage(SettingsKey.onLaunch, store: .kaern) private var onLaunch = LaunchBehavior.reopen
    @AppStorage(SettingsKey.groupFolders, store: .kaern) private var groupFolders = true
    @AppStorage(SettingsKey.tabCharacters, store: .kaern) private var tabCharacters = 12
    @AppStorage(SettingsKey.autoFetch, store: .kaern) private var autoFetch = true
    @AppStorage(SettingsKey.autoFetchMinutes, store: .kaern) private var autoFetchMinutes = 5
    @AppStorage("KaernPullStrategy", store: .kaern) private var pull = PullChoice.fastForwardIfPossible
    @AppStorage(SettingsKey.theme, store: .kaern) private var theme = AppTheme.system

    var body: some View {
        SettingsGrid {
            SettingsRow(label: "On launch:") {
                Picker("On launch", selection: $onLaunch) {
                    Text("Reopen the tabs from last time").tag(LaunchBehavior.reopen)
                    Text("Show the welcome window").tag(LaunchBehavior.welcome)
                    Text("Open nothing").tag(LaunchBehavior.nothing)
                }
                .labelsHidden()
                .fixedSize()
                Hint(onLaunch == .reopen
                     ? "Kaern saves your tabs and groups itself, so they come back even when macOS doesn’t restore windows."
                     : "Last time’s tabs wait behind the Reopen button of the welcome window.")
            }
            SettingsRow(label: "Switch repositories:") {
                HStack(spacing: 10) {
                    SwitchingModeButton(mode: .tabs, isOn: true)
                    SwitchingModeButton(mode: .sidebar, isOn: false).disabled(true)
                    SwitchingModeButton(mode: .toolbar, isOn: false).disabled(true)
                }
                .padding(.top, -2)
                Hint("Every open repository is a tab at the top of the window, grouped by folder. Best when you move between a handful of repositories all day.", strong: true)
                Hint("The Sidebar and Toolbar layouts come in a later version.")
            }
            SettingsRow(label: "Tabs:") {
                Checkbox("Group repositories from the same folder", isOn: $groupFolders)
                HStack(spacing: 7) {
                    Text("Shrink a tab until it shows")
                    Picker("Characters kept", selection: $tabCharacters) {
                        ForEach([8, 12, 16], id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text("characters, then scroll")
                }
                .font(.system(size: 13))
            }
            SettingsRow(label: "Fetch:") {
                HStack(spacing: 7) {
                    Checkbox("Fetch in the background every", isOn: $autoFetch)
                    Picker("Fetch interval", selection: $autoFetchMinutes) {
                        Text("1 minute").tag(1)
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!autoFetch)
                }
                .font(.system(size: 13))
            }
            SettingsRow(label: "Pull:") {
                Picker("Default pull", selection: $pull) {
                    Text("Fast-forward if possible").tag(PullChoice.fastForwardIfPossible)
                    Text("Fast-forward only").tag(PullChoice.fastForwardOnly)
                    Text("Rebase").tag(PullChoice.rebase)
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(label: "Appearance:") {
                SegmentedChoice(options: [(AppTheme.system, "System"), (.light, "Light"), (.dark, "Dark")], selection: $theme, label: "Appearance")
                    .padding(.top, 1)
            }
        }
        .onChange(of: theme) { AppSettings.applyTheme() }
        .onChange(of: autoFetch) { NotificationCenter.default.post(name: .kaernSettingsChanged, object: SettingsKey.autoFetch) }
        .onChange(of: autoFetchMinutes) { NotificationCenter.default.post(name: .kaernSettingsChanged, object: SettingsKey.autoFetch) }
    }
}

/// `.mode`: a thumbnail of the layout and its name.
private struct SwitchingModeButton: View {
    let mode: RepositorySwitching
    let isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            SwitchingThumbnail(mode: mode)
                .frame(width: 74, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isOn ? K.accent : K.sepStrong, lineWidth: 1))
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isOn ? K.accentSoft : .clear).padding(-3))
            Text(title)
                .font(KFont.weighted(11.5, isOn ? 0.4 : 0.23))
                .foregroundStyle(isOn ? K.accentText : K.label)
            if mode == .tabs {
                Text("DEFAULT")
                    .font(KFont.weighted(9.5, 0.4))
                    .tracking(0.3)
                    .foregroundStyle(K.label3)
                    .padding(.top, -3)
            }
        }
        .frame(width: 86)
        .padding(EdgeInsets(top: 6, leading: 4, bottom: 5, trailing: 4))
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering && isEnabled && !isOn ? K.hover : .clear))
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private var title: String {
        switch mode {
        case .tabs: "Tabs"
        case .sidebar: "Sidebar"
        case .toolbar: "Toolbar"
        }
    }
}

/// `.th-tabs` / `.th-sidebar` / `.th-toolbar`, drawn in the board's sizes (74 × 50).
private struct SwitchingThumbnail: View {
    let mode: RepositorySwitching

    var body: some View {
        Canvas { context, size in
            func fill(_ rect: CGRect, _ color: Color, radius: CGFloat = 2) {
                context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(color))
            }
            func lines(left: CGFloat, top: CGFloat, count: Int) {
                for index in 0..<count {
                    fill(CGRect(x: left, y: top + CGFloat(index) * 8, width: size.width - left - 6, height: 4), K.chip2)
                }
            }
            fill(CGRect(origin: .zero, size: size), K.content, radius: 0)
            switch mode {
            case .tabs:
                fill(CGRect(x: 0, y: 0, width: size.width, height: 9), K.band, radius: 0)
                fill(CGRect(x: 6, y: 2, width: 16, height: 7), K.accent)
                fill(CGRect(x: 24, y: 2, width: 16, height: 7), K.label3)
                lines(left: 6, top: 15, count: 4)
            case .sidebar:
                fill(CGRect(x: 0, y: 0, width: size.width, height: 7), K.chip2, radius: 0)
                fill(CGRect(x: 0, y: 0, width: 22, height: size.height), K.band, radius: 0)
                fill(CGRect(x: 4, y: 6, width: 14, height: 4), K.accent)
                for index in 1...3 { fill(CGRect(x: 4, y: 6 + CGFloat(index) * 8, width: 14, height: 4), K.label3) }
                lines(left: 28, top: 14, count: 3)
            case .toolbar:
                fill(CGRect(x: 0, y: 0, width: size.width, height: 11), K.chip2, radius: 0)
                fill(CGRect(x: 6, y: 3, width: 30, height: 5), K.accent, radius: 3)
                fill(CGRect(x: 38, y: 3, width: 18, height: 5), K.label3, radius: 3)
                lines(left: 6, top: 17, count: 4)
            }
        }
    }
}

// MARK: - Accounts

/// A GitHub or GitLab account Kaern signed in to. The token lives in the Keychain (git's
/// credential helper); Kaern keeps only who it is.
struct HostingAccount: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case github, gitlab }

    var kind: Kind
    var host: String
    var login: String
    var name: String?
    var userID: Int?
    var email: String?
    /// Clone with HTTPS or SSH.
    var clonesWithSSH = false

    var id: String { "\(host)/\(login)" }

    var initials: String {
        let source = (name?.isEmpty == false ? name! : login)
        let words = source.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." })
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.joined().isEmpty ? "?" : letters.joined()
    }

    var noreplyEmail: String? {
        guard kind == .github, let userID else { return nil }
        return "\(userID)+\(login)@users.noreply.\(host)"
    }

    @MainActor static var all: [HostingAccount] {
        get {
            guard let data = UserDefaults.kaern.data(forKey: SettingsKey.accounts),
                  let list = try? JSONDecoder().decode([HostingAccount].self, from: data) else { return [] }
            return list
        }
        set {
            UserDefaults.kaern.set(try? JSONEncoder().encode(newValue), forKey: SettingsKey.accounts)
            NotificationCenter.default.post(name: .kaernSettingsChanged, object: SettingsKey.accounts)
        }
    }

    /// The account for a remote's host, if one is signed in.
    @MainActor static func account(forHost host: String) -> HostingAccount? {
        all.first { $0.host.caseInsensitiveCompare(host) == .orderedSame }
    }
}

private struct AccountsPane: View {
    @Environment(AppModel.self) private var app
    @State private var accounts = HostingAccount.all
    @State private var selection: String?
    @State private var signingIn = false
    @State private var identity: (name: String?, email: String?) = (nil, nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    accountList
                    HStack(spacing: 0) {
                        SmallSquareButton(title: "+", label: "Add account") { signingIn = true }
                        SmallSquareButton(title: "−", label: "Remove account") { removeSelected() }
                            .disabled(selected == nil)
                    }
                }
                if let account = selected {
                    details(account)
                } else {
                    Text(accounts.isEmpty
                         ? "Sign in to GitHub or GitLab so Kaern can fetch and push over HTTPS and show who made each commit."
                         : "Choose an account.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(K.label2)
                        .frame(maxWidth: 360, alignment: .leading)
                        .padding(.top, 8)
                }
            }
            Text("Kaern keeps each token in the Keychain through git’s credential helper — the same place Terminal’s git looks.")
                .font(.system(size: 11.5))
                .foregroundStyle(K.label2)
                .padding(.top, 52)
        }
        .sheet(isPresented: $signingIn) {
            SignInSheet { account in
                accounts.removeAll { $0.id == account.id }
                accounts.append(account)
                HostingAccount.all = accounts
                selection = account.id
            }
            .environment(app)
        }
        .onAppear {
            accounts = HostingAccount.all
            if selection == nil { selection = accounts.first?.id }
        }
        .task(id: selection) { await loadIdentity() }
    }

    private var selected: HostingAccount? { accounts.first { $0.id == selection } }

    private var accountList: some View {
        VStack(spacing: 2) {
            ForEach(accounts) { account in
                let isOn = account.id == selection
                Button { selection = account.id } label: {
                    HStack(spacing: 9) {
                        Text(account.initials)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(account.kind == .gitlab ? Color(nsColor: K.hex(0xc2410c)) : Color(nsColor: K.hex(0x2f62c8))))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.login).font(.system(size: 12.5, weight: .bold))
                            Text(account.host).font(.system(size: 11.5)).foregroundStyle(isOn ? .white.opacity(0.85) : K.label2)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(isOn ? .white : K.label)
                    .padding(.horizontal, 8)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isOn ? K.sel : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(width: 230, height: 250, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(K.field)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5)))
    }

    private func details(_ account: HostingAccount) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                label("Account:")
                Text(account.login).font(.system(size: 13)).padding(.top, 5)
            }
            GridRow {
                label("Server:")
                Text(account.host).font(.system(size: 13)).padding(.top, 5)
            }
            GridRow {
                label("Signed in:")
                Text("with a token · in the Keychain").font(.system(size: 13)).padding(.top, 5)
            }
            GridRow {
                label("Clone with:")
                SegmentedChoice(options: [(false, "HTTPS"), (true, "SSH")], selection: Binding(
                    get: { account.clonesWithSSH },
                    set: { value in update(account) { $0.clonesWithSSH = value } }
                ), label: "Clone protocol")
                .padding(.top, 1)
            }
            if !commitIdentities(account).isEmpty {
                GridRow {
                    label("Commit as:")
                    Picker("Commit identity", selection: Binding(
                        get: { identity.email ?? "" },
                        set: { email in setIdentity(account, email: email) }
                    )) {
                        if let email = identity.email, !commitIdentities(account).contains(where: { $0.email == email }) {
                            Text("\(identity.name ?? "") (\(email))").tag(email)
                        }
                        ForEach(commitIdentities(account), id: \.email) { option in
                            Text(option.title).tag(option.email)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            GridRow {
                Color.clear.frame(width: 100, height: 1)
                Button("Sign Out…") { removeSelected() }
                    .controlSize(.regular)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).frame(width: 100, alignment: .trailing).padding(.top, 5)
    }

    private struct Identity { var title: String; var email: String }

    private func commitIdentities(_ account: HostingAccount) -> [Identity] {
        let name = account.name?.isEmpty == false ? account.name! : account.login
        var options: [Identity] = []
        if let noreply = account.noreplyEmail { options.append(Identity(title: "\(name) (noreply)", email: noreply)) }
        if let email = account.email, !email.isEmpty { options.append(Identity(title: "\(name) (\(email))", email: email)) }
        return options
    }

    private func setIdentity(_ account: HostingAccount, email: String) {
        guard let runner = app.runner, !email.isEmpty else { return }
        let name = account.name?.isEmpty == false ? account.name! : account.login
        Task {
            try? await runner.setGlobalConfig("user.name", name)
            try? await runner.setGlobalConfig("user.email", email)
            await loadIdentity()
        }
    }

    private func loadIdentity() async {
        guard let runner = app.runner else { return }
        async let name = runner.globalConfig("user.name")
        async let email = runner.globalConfig("user.email")
        identity = (await name, await email)
    }

    private func update(_ account: HostingAccount, _ change: (inout HostingAccount) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        change(&accounts[index])
        HostingAccount.all = accounts
    }

    private func removeSelected() {
        guard let account = selected else { return }
        accounts.removeAll { $0.id == account.id }
        HostingAccount.all = accounts
        selection = accounts.first?.id
        if let runner = app.runner {
            Task { await runner.rejectCredential(host: account.host, username: account.login) }
        }
    }
}

/// `.apm button`: + and − under a list.
private struct SmallSquareButton: View {
    let title: String
    let label: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 24, height: 22)
                .controlSurface(radius: 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }
}

/// Add account: the server and a personal access token, checked with the server before it's
/// stored in the Keychain.
struct SignInSheet: View {
    var initialHost = "github.com"
    let completion: (HostingAccount) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var server = "github.com"
    @State private var otherHost = ""
    @State private var token = ""
    @State private var checking = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign In").font(.system(size: 13, weight: .bold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Server").foregroundStyle(K.label2).gridColumnAlignment(.trailing)
                    Picker("Server", selection: $server) {
                        Text("GitHub (github.com)").tag("github.com")
                        Text("GitLab (gitlab.com)").tag("gitlab.com")
                        Divider()
                        Text("GitHub Enterprise…").tag("enterprise")
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
                if server == "enterprise" {
                    GridRow {
                        Text("Host").foregroundStyle(K.label2)
                        TextField("github.example.com", text: $otherHost)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                GridRow {
                    Text("Token").foregroundStyle(K.label2)
                    SecureField("Personal access token", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(signIn)
                }
            }
            .font(.system(size: 12.5))
            Text(note)
                .font(.system(size: 11.5))
                .foregroundStyle(failure == nil ? K.label2 : K.err)
                .fixedSize(horizontal: false, vertical: true)
            if let page = tokenPage {
                Button(server == "gitlab.com" ? "Create a Token on GitLab…" : "Create a Token on GitHub…") { NSWorkspace.shared.open(page) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            HStack(spacing: 8) {
                if checking { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sign In", action: signIn)
                    .keyboardShortcut(.defaultAction)
                    .disabled(checking || token.trimmingCharacters(in: .whitespaces).isEmpty || host.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if initialHost == "github.com" || initialHost == "gitlab.com" {
                server = initialHost
            } else {
                server = "enterprise"
                otherHost = initialHost
            }
        }
    }

    private var host: String {
        server == "enterprise" ? otherHost.trimmingCharacters(in: .whitespaces).lowercased() : server
    }

    private var note: String {
        if let failure { return failure }
        return server == "gitlab.com"
            ? "Use a token with the read_api, read_repository and write_repository scopes."
            : "Use a token with the repo scope (classic) or Contents read and write (fine-grained)."
    }

    private var tokenPage: URL? {
        switch server {
        case "github.com": URL(string: "https://github.com/settings/tokens/new?scopes=repo,read:user,user:email&description=Kaern")
        case "gitlab.com": URL(string: "https://gitlab.com/-/user_settings/personal_access_tokens?name=Kaern&scopes=read_api,read_repository,write_repository")
        default: otherHost.isEmpty ? nil : URL(string: "https://\(host)/settings/tokens/new?scopes=repo,read:user,user:email&description=Kaern")
        }
    }

    private func signIn() {
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = host
        guard !secret.isEmpty, !host.isEmpty, !checking, let runner = app.runner else { return }
        checking = true
        failure = nil
        let isGitLab = server == "gitlab.com"
        Task {
            do {
                let user = isGitLab
                    ? try await GitLabClient.user(host: host, token: secret)
                    : try await GitHubClient(baseURL: GitHubClient.apiURL(for: host), token: secret).user()
                try await runner.approveCredential(host: host, username: user.login, secret: secret)
                completion(HostingAccount(kind: isGitLab ? .gitlab : .github, host: host, login: user.login, name: user.name,
                                          userID: user.id, email: user.email))
                checking = false
                dismiss()
            } catch let error as HostingError where error.isUnauthorized {
                failure = "\(host) didn’t accept this token. Check that you copied all of it and that it hasn’t expired."
                checking = false
            } catch {
                failure = "Couldn’t sign in: \(error.localizedDescription)"
                checking = false
            }
        }
    }
}

// MARK: - Git

private struct GitPane: View {
    @Environment(AppModel.self) private var app
    @State private var name = ""
    @State private var email = ""
    @State private var branch = ""
    @State private var signs = false
    @State private var signingKey: String?
    @State private var lineEndings = "keep"
    @State private var loaded = false
    @State private var failure: String?

    var body: some View {
        SettingsGrid {
            SettingsRow(label: "Name:") {
                field($name, label: "Name", key: "user.name")
            }
            SettingsRow(label: "Email:") {
                field($email, label: "Email", key: "user.email")
                Hint("Saved in your global Git config. Repository Settings (⌥⌘,) can override it per repository.")
            }
            SettingsRow(label: "New repositories:") {
                HStack(spacing: 7) {
                    Text("Default branch name").font(.system(size: 13))
                    field($branch, label: "Default branch name", key: "init.defaultBranch", width: 110)
                }
            }
            SettingsRow(label: "Signing:") {
                Checkbox("Sign commits with my SSH key", isOn: Binding(get: { signs }, set: { setSigning($0) }))
                    .disabled(!signs && signingKey == nil)
                if !signs && signingKey == nil {
                    Hint("No SSH key found in ~/.ssh. Create one with ssh-keygen, then turn this on.")
                } else if let signingKey {
                    Hint("Uses \(Formatters.abbreviatedPath(signingKey)).")
                }
            }
            SettingsRow(label: "Line endings:") {
                Picker("Line endings", selection: Binding(get: { lineEndings }, set: { setLineEndings($0) })) {
                    Text("Keep as they are").tag("keep")
                    Text("Convert to LF on commit").tag("input")
                }
                .labelsHidden()
                .fixedSize()
            }
            if let failure {
                SettingsRow(label: "") { Hint(failure) }
            }
        }
        .disabled(!loaded)
        .task { await load() }
    }

    private func field(_ text: Binding<String>, label: String, key: String, width: CGFloat = 320) -> some View {
        TextField(label, text: text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13))
            .frame(width: width)
            .labelsHidden()
            .onSubmit { save(key, text.wrappedValue) }
            .onChange(of: text.wrappedValue) { old, new in
                guard loaded else { return }
                // Saved a moment after typing stops, and on Return.
                pending[key] = new
                scheduleSave()
            }
    }

    @State private var pending: [String: String] = [:]
    @State private var saveTask: Task<Void, Never>?

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            for (key, value) in pending { save(key, value) }
            pending = [:]
        }
    }

    private func save(_ key: String, _ value: String) {
        guard let runner = app.runner else { return }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await runner.setGlobalConfig(key, trimmed.isEmpty ? nil : trimmed)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func load() async {
        guard let runner = app.runner else { return }
        async let name = runner.globalConfig("user.name")
        async let email = runner.globalConfig("user.email")
        async let branch = runner.globalConfig("init.defaultBranch")
        async let sign = runner.globalConfig("commit.gpgsign")
        async let signingFormat = runner.globalConfig("gpg.format")
        async let key = runner.globalConfig("user.signingkey")
        async let autocrlf = runner.globalConfig("core.autocrlf")
        self.name = await name ?? ""
        self.email = await email ?? ""
        self.branch = await branch ?? ""
        let format = await signingFormat
        self.signs = (await sign)?.lowercased() == "true" && format == "ssh"
        self.signingKey = await key ?? Self.defaultSSHKey()
        self.lineEndings = (await autocrlf) == "input" ? "input" : "keep"
        // Let the fields settle before typing counts as a change.
        try? await Task.sleep(for: .milliseconds(50))
        loaded = true
    }

    /// `~/.ssh/id_ed25519.pub` (or the RSA / ECDSA one) when there's one.
    private static func defaultSSHKey() -> String? {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
        for name in ["id_ed25519.pub", "id_ecdsa.pub", "id_rsa.pub"] {
            let path = folder.appending(path: name).path(percentEncoded: false)
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    private func setSigning(_ on: Bool) {
        guard let runner = app.runner else { return }
        signs = on
        let key = signingKey
        Task {
            do {
                if on {
                    try await runner.setGlobalConfig("gpg.format", "ssh")
                    if await runner.globalConfig("user.signingkey") == nil, let key { try await runner.setGlobalConfig("user.signingkey", key) }
                    try await runner.setGlobalConfig("commit.gpgsign", "true")
                } else {
                    try await runner.setGlobalConfig("commit.gpgsign", "false")
                }
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func setLineEndings(_ value: String) {
        lineEndings = value
        guard let runner = app.runner else { return }
        Task { try? await runner.setGlobalConfig("core.autocrlf", value == "input" ? "input" : nil) }
    }
}

// MARK: - Diff

private struct DiffPane: View {
    @AppStorage(DiffPreferences.layoutKey, store: .kaern) private var layout = DiffLayout.split
    @AppStorage(SettingsKey.diffContext, store: .kaern) private var context = 3
    @AppStorage(SettingsKey.diffWords, store: .kaern) private var words = true
    @AppStorage(SettingsKey.diffWrap, store: .kaern) private var wraps = true
    @AppStorage(DiffPreferences.ignoreWhitespaceKey, store: .kaern) private var ignoresWhitespace = false
    @AppStorage(SettingsKey.diffFontName, store: .kaern) private var fontName = ""
    @AppStorage(SettingsKey.diffFontSize, store: .kaern) private var fontSize = 12.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGrid {
                SettingsRow(label: "Default view:") {
                    SegmentedChoice(options: [(DiffLayout.split, "Split"), (.unified, "Unified")], selection: $layout, label: "Default diff view")
                        .padding(.top, 1)
                    Hint("Every diff opens this way. Switch one diff with the Split / Unified control or ⌥⌘D.")
                }
                SettingsRow(label: "Context:") {
                    HStack(spacing: 7) {
                        Text("Show")
                        Picker("Context lines", selection: $context) {
                            ForEach([3, 5, 10], id: \.self) { Text("\($0)").tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Text("unchanged lines around each change")
                    }
                    .font(.system(size: 13))
                }
                SettingsRow(label: "Display:") {
                    VStack(alignment: .leading, spacing: 0) {
                        Checkbox("Highlight the changed words in a line", isOn: $words)
                        Checkbox("Wrap long lines", isOn: $wraps)
                        Checkbox("Ignore whitespace-only changes", isOn: $ignoresWhitespace)
                    }
                }
                SettingsRow(label: "Font:") {
                    HStack(spacing: 10) {
                        Text(fontDescription).font(.system(size: 13))
                        Button("Choose…") { DiffFontPicker.shared.show() }
                    }
                }
            }
            DiffPreview(layout: layout, font: previewFont)
                .padding(.leading, 184)
                .padding(.top, 22)
        }
        .onChange(of: context) { reloadDiffs() }
        .onChange(of: ignoresWhitespace) { reloadDiffs() }
    }

    private var fontDescription: String {
        _ = fontName
        _ = fontSize
        return AppSettings.diffFontDescription
    }

    private var previewFont: Font {
        _ = fontName
        _ = fontSize
        return Font(AppSettings.diffFont)
    }

    private func reloadDiffs() {
        for controller in AppModel.shared.windows {
            guard let tab = controller.model.activeTab else { continue }
            AppModel.shared.repository(for: tab.path).reloadDiffs()
        }
    }
}

/// `.prev`: two lines of AlphaVersion.swift in the chosen layout and font.
private struct DiffPreview: View {
    let layout: DiffLayout
    let font: Font

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Preview")
                Spacer()
                Text(layout == .split ? "Split — before on the left, after on the right" : "Unified — one column")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(K.hunkText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(K.hunk)
            if layout == .split {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        line(13, "    let marketing: String", nil)
                        line(14, "    let build: Int", K.delBg)
                        line(15, "", nil)
                    }
                    K.sep.frame(width: 1)
                    VStack(spacing: 0) {
                        line(13, "    let marketing: String", nil)
                        line(14, "    let alpha: Int", K.addBg)
                        line(15, "", nil)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    line(13, "    let marketing: String", nil)
                    line(14, "  - let build: Int", K.delBg)
                    line(14, "  + let alpha: Int", K.addBg)
                }
            }
        }
        .font(font)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5))
    }

    private func line(_ number: Int, _ text: String, _ fill: Color?) -> some View {
        HStack(spacing: 0) {
            Text("\(number)")
                .foregroundStyle(K.label2)
                .frame(width: 34, alignment: .trailing)
                .padding(.trailing, 8)
            Text(text).foregroundStyle(K.code)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .frame(height: 20)
        .background(fill ?? .clear)
    }
}

/// Diff › Font › Choose…: the system font panel, saving what's picked.
@MainActor
final class DiffFontPicker: NSObject {
    static let shared = DiffFontPicker()

    func show() {
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(AppSettings.diffFont, isMultiple: false)
        manager.orderFrontFontPanel(self)
    }

    @objc func changeFont(_ sender: Any?) {
        let manager = NSFontManager.shared
        let font = manager.convert(AppSettings.diffFont)
        let isSystemMono = font.fontName.hasPrefix(".") || font.familyName == NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).familyName
        UserDefaults.kaern.set(isSystemMono ? "" : font.fontName, forKey: SettingsKey.diffFontName)
        UserDefaults.kaern.set(Double(font.pointSize), forKey: SettingsKey.diffFontSize)
    }
}

// MARK: - Advanced

private struct AdvancedPane: View {
    @Environment(AppModel.self) private var app
    @AppStorage(GitLocator.userPathKey, store: .kaern) private var gitPath = ""
    @AppStorage(SettingsKey.sshAgent, store: .kaern) private var sshAgent = true
    @AppStorage(SettingsKey.watchFiles, store: .kaern) private var watchFiles = true
    @AppStorage(SettingsKey.historyLoading, store: .kaern) private var historyLoading = HistoryLoading.pages
    @State private var chosen: (path: String, version: String?)?
    @State private var choiceError: String?

    var body: some View {
        SettingsGrid {
            SettingsRow(label: "Git:") {
                HStack(spacing: 10) {
                    Text(currentGit)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(app.git.map { "\($0.url.path(percentEncoded: false)) · \($0.version ?? "")" } ?? "")
                    Button("Choose…", action: choose)
                    if !gitPath.isEmpty {
                        Button("Use Default") { setGitPath("") }
                    }
                }
                Hint("Kaern runs this git, so your config, hooks, credential helpers and LFS all apply.")
                if let choiceError {
                    Hint(choiceError).foregroundStyle(K.err)
                }
                if needsRelaunch {
                    HStack(spacing: 8) {
                        Hint("Kaern switches to \(gitPath.isEmpty ? "the default git" : Formatters.abbreviatedPath(gitPath)) the next time it opens.")
                        Button("Relaunch Now") { Relauncher.relaunch() }
                            .controlSize(.small)
                    }
                }
            }
            SettingsRow(label: "SSH:") {
                Checkbox("Use the SSH agent (ssh-agent, 1Password)", isOn: $sshAgent)
                if sshAgent != launchSSHAgent {
                    Hint("Applies the next time Kaern opens.")
                }
            }
            SettingsRow(label: "File changes:") {
                Checkbox("Refresh as soon as files change on disk", isOn: $watchFiles)
                if !watchFiles {
                    Hint("Kaern refreshes when you come back to it and after its own actions.")
                }
            }
            SettingsRow(label: "Large repositories:") {
                Picker("History loading", selection: $historyLoading) {
                    Text("Load history as you scroll").tag(HistoryLoading.pages)
                    Text("Load all history").tag(HistoryLoading.all)
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(label: "Command log:") {
                Button("Show Command Log…") { CommandLogWindowController.shared.show(repository: nil) }
                Hint("Every git command Kaern ran, with its output — useful for bug reports.")
            }
        }
        .onChange(of: watchFiles) { NotificationCenter.default.post(name: .kaernSettingsChanged, object: SettingsKey.watchFiles) }
    }

    /// The SSH setting the running git was started with.
    private var launchSSHAgent: Bool { app.launchUsesSSHAgent }

    /// "/usr/bin/git — 2.50.1" (the version number without Apple's build).
    private var currentGit: String {
        guard let git = app.git else { return "Looking for git…" }
        let version = git.version?.split(separator: " ").first.map(String.init)
        return Formatters.abbreviatedPath(git.url.path(percentEncoded: false)) + (version.map { " — \($0)" } ?? "")
    }

    /// The chosen path differs from the git this launch runs.
    private var needsRelaunch: Bool {
        guard let git = app.git else { return false }
        if gitPath.isEmpty { return git.source == .userChoice }
        return git.url.path(percentEncoded: false) != gitPath
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.prompt = "Use This Git"
        panel.message = "Choose the git executable Kaern should run (for example /opt/homebrew/bin/git)."
        panel.directoryURL = URL(filePath: "/usr/local/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let path = url.resolvingSymlinksInPath().path(percentEncoded: false)
            guard FileManager.default.isExecutableFile(atPath: path),
                  let version = await GitRunner(executableURL: URL(filePath: path)).version() else {
                choiceError = "\(url.lastPathComponent) isn’t a git Kaern can run."
                return
            }
            choiceError = nil
            chosen = (path, version)
            setGitPath(url.path(percentEncoded: false))
        }
    }

    private func setGitPath(_ path: String) {
        gitPath = path
    }
}

/// Quits and opens Kaern again (a new git or SSH setting).
@MainActor
enum Relauncher {
    static func relaunch() {
        let path = Bundle.main.bundleURL.path(percentEncoded: false)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        // Waits for this process to end, then opens the app again.
        process.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
