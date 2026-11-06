import AppKit
import KaernKit
import SwiftUI
import UniformTypeIdentifiers

/// Lets menus ask the Welcome window to show Clone or Create.
@Observable
final class WelcomeActions {
    static let shared = WelcomeActions()

    enum Action {
        case clone
        case create
    }

    var pending: Action?

    func request(_ action: Action) {
        pending = action
    }
}

/// Shown when no repository is open (like Xcode's welcome window). Return opens the selected
/// recent repository, ⌘Return opens it in a new window, and folders can be dropped on the list.
struct WelcomeView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var selection: RecentRepository.ID?
    @State private var isCloning = false
    @State private var isDropTargeted = false
    @State private var actions = WelcomeActions.shared

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: 400)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor).ignoresSafeArea())
            Divider()
                .ignoresSafeArea()
            recentPane
                .frame(width: 400)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        }
        .frame(height: 440)
        .onAppear {
            appModel.register(openWindow: openWindow, dismissWindow: dismissWindow)
            selection = appModel.recents.first?.id
        }
        .task {
            // At launch, a repository window that's restored (or opened from the Finder) takes
            // over. A Welcome window asked for later, for Clone or New Repository, stays.
            guard appModel.isLaunchWelcome else { return }
            try? await Task.sleep(for: .milliseconds(600))
            stepAsideForRepositoryWindow()
        }
        .onChange(of: appModel.openWindows.isEmpty) { _, isEmpty in
            // The repository window can come up after the Welcome window, once git has answered.
            if !isEmpty, appModel.isLaunchWelcome { stepAsideForRepositoryWindow() }
        }
        .onDisappear { appModel.isLaunchWelcome = false }
        .alert("Kaern needs Git", isPresented: Binding(get: { appModel.showsGitAlert }, set: { _ in })) {
            Button("Install Developer Tools…") { appModel.installDeveloperTools() }
                .keyboardShortcut(.defaultAction)
            Button("Choose Git…") { appModel.chooseGit() }
            Button("Quit", role: .cancel) { NSApp.terminate(nil) }
        } message: {
            Text("Git isn't installed on this Mac. Apple's Command Line Developer Tools include it and install in a few minutes.")
        }
        .onChange(of: actions.pending, initial: true) { _, pending in
            guard let pending else { return }
            actions.pending = nil
            switch pending {
            case .clone: isCloning = true
            case .create: createRepository()
            }
        }
        .sheet(isPresented: $isCloning) {
            CloneSheet()
        }
    }

    private func stepAsideForRepositoryWindow() {
        if !appModel.openWindows.isEmpty && appModel.isGitAvailable != false {
            dismissWindow(id: SceneID.welcome)
        }
    }

    private var leftPane: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 30)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Kaern")
                .font(.system(size: 26, weight: .semibold))
                .padding(.top, 10)
            Text(version)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            VStack(spacing: 8) {
                WelcomeButton(title: "Open Repository…", systemImage: "folder", shortcut: "⌘O") {
                    for url in appModel.chooseRepositories() { appModel.open(url) }
                }
                WelcomeButton(title: "Clone Repository…", systemImage: "cloud", shortcut: nil) {
                    isCloning = true
                }
                WelcomeButton(title: "Create New Repository…", systemImage: "plus", shortcut: nil) {
                    createRepository()
                }
            }
            .frame(width: 250)
            .padding(.top, 34)
            Spacer()
        }
    }

    private var recentPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Repositories")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 6)

            if appModel.recents.isEmpty {
                Text("Repositories you open appear here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(appModel.recents) { recent in
                        RecentRow(recent: recent)
                            .tag(recent.id)
                            .contextMenu {
                                Button("Open") { appModel.open(recent.url) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([recent.url]) }
                                Divider()
                                Button("Remove from Recents") { appModel.removeRecent(recent) }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: RecentRepository.ID.self) { _ in
                } primaryAction: { ids in
                    if let id = ids.first, let recent = appModel.recents.first(where: { $0.id == id }) {
                        appModel.open(recent.url)
                    }
                }
                .onKeyPress(.return, phases: .down) { _ in
                    guard let selection, let recent = appModel.recents.first(where: { $0.id == selection }) else { return .ignored }
                    appModel.open(recent.url)
                    return .handled
                }
            }

            Text("Drop a folder here to open it")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor))
                )
                .padding(12)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            for url in folders { appModel.open(url) }
            return !folders.isEmpty
        } isTargeted: { isDropTargeted = $0 }
    }

    private func createRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Create")
        panel.message = String(localized: "Choose an empty folder for the new repository.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let repository = try await GitRepository.initialize(
                    at: url,
                    defaultBranch: Preferences.defaultBranch,
                    runner: appModel.makeRunner()
                )
                appModel.open(repository.root)
            } catch {
                appModel.presentError(error, title: String(localized: "Couldn't Create Repository"))
            }
        }
    }
}

private struct WelcomeButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                Text(title)
                    .fontWeight(.medium)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }
}

private struct RecentRow: View {
    let recent: RecentRepository
    @State private var branch: String?
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(prominence == .increased ? Color.white : Color.accentColor)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 1) {
                Text(recent.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(recent.displayPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let branch {
                Text(branch)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 3)
        .task(id: recent.path) {
            let url = recent.url
            let runner = AppModel.shared.makeRunner()
            if let repository = try? await GitRepository.open(url, runner: runner),
               let status = try? await repository.status() {
                branch = status.head.branchName ?? String(status.headID?.prefix(7) ?? "")
            }
        }
    }
}

/// Clone Repository…: remote URL and a destination folder, with git's progress below.
struct CloneSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var remote = ""
    @State private var parentFolder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Developer")
    @State private var name = ""
    @State private var progress = ""
    @State private var isCloning = false
    @State private var cloneTask: Task<Void, Never>?

    private var suggestedName: String {
        var last = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        while last.hasSuffix("/") { last.removeLast() }
        last = String(last.split(whereSeparator: { $0 == "/" || $0 == ":" }).last ?? "")
        if last.hasSuffix(".git") { last.removeLast(4) }
        return last
    }

    private var folderName: String { name.isEmpty ? suggestedName : name }
    private var destination: URL { parentFolder.appending(path: folderName, directoryHint: .isDirectory) }

    var body: some View {
        SheetScaffold(
            systemImage: "cloud",
            title: "Clone Repository",
            message: "Kaern uses your Git credentials (Keychain, ssh-agent and ~/.ssh/config)."
        ) {
            Form {
                TextField("URL", text: $remote, prompt: Text("https://github.com/owner/repository.git"))
                TextField("Name", text: $name, prompt: Text(suggestedName.isEmpty ? "repository" : suggestedName))
                LabeledContent("Location") {
                    HStack {
                        Text(Formatters.abbreviatedPath(parentFolder))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                            .controlSize(.small)
                    }
                }
            }
            .formStyle(.columns)
            .disabled(isCloning)

            if isCloning || !progress.isEmpty {
                HStack(spacing: 8) {
                    if isCloning { ProgressView().controlSize(.small) }
                    Text(progress.isEmpty ? String(localized: "Starting…") : progress)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } buttons: {
            Button("Cancel", role: .cancel) {
                cloneTask?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Clone", action: clone)
                .keyboardShortcut(.defaultAction)
                .disabled(remote.trimmingCharacters(in: .whitespaces).isEmpty || folderName.isEmpty || isCloning)
        }
        .frame(width: 480)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = parentFolder
        if panel.runModal() == .OK, let url = panel.url {
            parentFolder = url
        }
    }

    private func clone() {
        let target = destination
        if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            progress = String(localized: "“\(folderName)” already exists in that folder.")
            return
        }
        try? FileManager.default.createDirectory(at: parentFolder, withIntermediateDirectories: true)
        isCloning = true
        progress = ""
        var remoteURL = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        // Settings › Accounts › Clone with SSH, and Commit as.
        let account = RemoteURL(remoteURL).flatMap { appModel.account(forHost: $0.host) }
        if let account, account.clonesWithSSH, let parsed = RemoteURL(remoteURL), !parsed.isSSH {
            remoteURL = parsed.sshEquivalent
        }
        let runner = appModel.makeRunner()
        let (lines, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
        cloneTask = Task {
            let progressUpdates = Task {
                for await line in lines {
                    progress = line
                }
            }
            defer { progressUpdates.cancel() }
            do {
                let repository = try await GitRepository.clone(remoteURL, to: target, runner: runner) { line in
                    continuation.yield(line)
                }
                continuation.finish()
                if let email = account?.commitEmail {
                    try? await repository.setLocalConfig("user.email", email)
                    if let name = account?.name { try? await repository.setLocalConfig("user.name", name) }
                }
                isCloning = false
                dismiss()
                appModel.open(repository.root)
            } catch {
                continuation.finish()
                isCloning = false
                progress = error.localizedDescription
            }
        }
    }
}
