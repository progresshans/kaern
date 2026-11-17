import AppKit
import KaernKit
import Observation

/// A sheet over the whole window rather than one repository: Clone a Repository, Create a New
/// Repository, Publish to GitHub. It works with no tab open (the welcome view) too.
enum WindowSheet: Identifiable {
    case clone(CloneModel)
    case create(CreateModel)
    case publish(PublishModel)

    var id: ObjectIdentifier {
        switch self {
        case .clone(let model): ObjectIdentifier(model)
        case .create(let model): ObjectIdentifier(model)
        case .publish(let model): ObjectIdentifier(model)
        }
    }

    /// Esc and Cancel don't close it while it works (Cancel stops the work first).
    var isBusy: Bool {
        switch self {
        case .clone(let model): model.isCloning
        case .create(let model): model.isRunning
        case .publish(let model): model.isRunning
        }
    }
}

/// Where new clones and repositories go: the last folder used, else ~/Developer when there is
/// one, else the home folder.
@MainActor
enum ProjectsFolder {
    static var current: URL {
        if let saved = UserDefaults.kaern.string(forKey: SettingsKey.projectsFolder), !saved.isEmpty {
            var isDirectory: ObjCBool = false
            let path = (saved as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(filePath: path, directoryHint: .isDirectory)
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let developer = home.appending(path: "Developer", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: developer.path(percentEncoded: false)) ? developer : home
    }

    static func remember(_ folder: URL) {
        UserDefaults.kaern.set(folder.path(percentEncoded: false), forKey: SettingsKey.projectsFolder)
    }

    /// "~/Developer/kaern" typed or shown in a field, as a file URL.
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let path = (trimmed as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
    }
}

// MARK: - Clone

/// Clone a Repository (⇧⌘C): a URL (or a repository from a signed-in GitHub or GitLab account),
/// the folder it goes into, and the clone's progress.
@MainActor @Observable
final class CloneModel {
    enum Source: String, CaseIterable { case url, github, gitlab }

    enum ListState: Equatable {
        case idle
        case loading
        case loaded
        /// No account for that service.
        case needsAccount
        case failed(String)
    }

    var source: Source = .url {
        didSet { if source != oldValue { loadListIfNeeded() } }
    }
    var url = "" {
        didSet {
            guard url != oldValue, !destinationEdited, let name = GitRepository.folderName(forClone: url) else { return }
            destination = Formatters.abbreviatedPath(ProjectsFolder.current.appending(path: name).path(percentEncoded: false))
        }
    }
    var destination = ""
    /// The user typed a folder or chose one: a new URL doesn't replace it anymore.
    var destinationEdited = false
    var opensTab = true
    var filter = ""
    var hosted: [HostedRepository] = []
    var listState: ListState = .idle
    var progress: GitProgress?
    var isCloning = false
    var error: String?
    var failure: GitFailure?
    @ObservationIgnored var task: Task<Void, Never>?

    init(url: String = "") {
        destination = Formatters.abbreviatedPath(ProjectsFolder.current.path(percentEncoded: false)) + "/"
        self.url = url
    }

    /// The host the URL points at ("github.com"), `nil` for a folder on this Mac.
    var host: String? {
        let text = url.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text.hasPrefix("/") || text.hasPrefix("~") || text.hasPrefix("file:") { return nil }
        return RemoteURL(text)?.host.lowercased()
    }

    var account: HostingAccount? {
        switch source {
        case .github: HostingAccount.all.first { $0.kind == .github }
        case .gitlab: HostingAccount.all.first { $0.kind == .gitlab }
        case .url: host.flatMap { HostingAccount.account(forHost: $0) }
        }
    }

    var destinationURL: URL? { ProjectsFolder.url(from: destination) }

    /// Why Clone is off, if it is.
    var problem: String? {
        if url.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        guard let destination = destinationURL, destination.lastPathComponent != "" else { return "Choose the folder to clone into." }
        let path = destination.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { return "\(Formatters.abbreviatedPath(path)) is a file." }
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: path), !contents.isEmpty {
                return "\(Formatters.abbreviatedPath(path)) already exists and has files in it."
            }
        }
        return nil
    }

    var filteredHosted: [HostedRepository] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return hosted }
        return hosted.filter { $0.fullName.localizedCaseInsensitiveContains(query) || ($0.summary ?? "").localizedCaseInsensitiveContains(query) }
    }

    func pick(_ repository: HostedRepository) {
        let ssh = account?.clonesWithSSH ?? false
        url = ssh ? repository.sshURL : repository.httpsURL
    }

    /// The GitHub or GitLab list, once per source.
    func loadListIfNeeded() {
        guard source != .url, listState != .loading else { return }
        guard let account else {
            listState = .needsAccount
            hosted = []
            return
        }
        listState = .loading
        hosted = []
        let kind = source
        Task {
            guard let runner = AppModel.shared.runner,
                  let token = await runner.credential(host: account.host, username: account.login) else {
                listState = .failed("Kaern couldn’t read the token for \(account.login) from the Keychain. Sign in again in Settings › Accounts.")
                return
            }
            do {
                let list: [HostedRepository]
                if kind == .github {
                    list = try await GitHubClient(baseURL: GitHubClient.apiURL(for: account.host), token: token).repositories()
                } else {
                    list = try await GitLabClient.projects(host: account.host, token: token)
                }
                guard source == kind else { return }
                hosted = list
                listState = .loaded
            } catch {
                guard source == kind else { return }
                listState = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Create

/// The license a new repository starts with.
enum LicenseChoice: String, CaseIterable, Identifiable {
    case none = "None", mit = "MIT", apache = "Apache 2.0", gpl = "GPL-3.0"

    var id: String { rawValue }

    /// The LICENSE text (`nil` for None). MIT gets the year and the holder; the others are the
    /// license texts as published.
    func text(holder: String, year: Int) -> String? {
        switch self {
        case .none:
            return nil
        case .mit:
            return """
            MIT License

            Copyright (c) \(year) \(holder)

            Permission is hereby granted, free of charge, to any person obtaining a copy
            of this software and associated documentation files (the "Software"), to deal
            in the Software without restriction, including without limitation the rights
            to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
            copies of the Software, and to permit persons to whom the Software is
            furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all
            copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
            FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
            AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
            LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
            OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
            SOFTWARE.

            """
        case .apache, .gpl:
            let name = self == .apache ? "Apache-2.0" : "GPL-3.0"
            guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

/// Create a New Repository (⌥⌘N), or Create Repository Here… on a folder that isn't one yet.
@MainActor @Observable
final class CreateModel {
    struct Step: Identifiable, Equatable {
        enum State { case waiting, running, done, failed }
        let id: Int
        var text: String
        var state: State
    }

    /// Adding Git to a folder that's there already (its name and place are fixed).
    let existingFolder: URL?
    var name: String
    var location: URL
    var branch = "main"
    var ignore: IgnoreTemplate = .macOS
    var license: LicenseChoice = .none
    var readme = true
    var firstCommit = true
    var publish = false
    var isPrivate = true
    var survey: FolderSurvey?
    var steps: [Step] = []
    var isRunning = false
    var error: String?
    @ObservationIgnored var task: Task<Void, Never>?

    init(existingFolder: URL? = nil) {
        self.existingFolder = existingFolder
        if let existingFolder {
            name = existingFolder.lastPathComponent
            location = existingFolder.deletingLastPathComponent()
            readme = !FileManager.default.fileExists(atPath: existingFolder.appending(path: "README.md").path(percentEncoded: false))
        } else {
            name = ""
            location = ProjectsFolder.current
        }
    }

    /// "travel blog" → "travel-blog".
    var cleanName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    var folder: URL { existingFolder ?? location.appending(path: cleanName, directoryHint: .isDirectory) }

    var githubAccount: HostingAccount? { HostingAccount.all.first { $0.kind == .github && $0.host == "github.com" } }

    /// The line under Name, and whether it's an error.
    var nameCheck: (note: String?, isError: Bool) {
        guard existingFolder == nil else { return (nil, false) }
        let raw = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return ("Give the repository a name", true) }
        if raw.contains(where: { "/\\:*?\"<>|".contains($0) }) { return ("Names can’t contain / \\ : * ? \" < > |", true) }
        if raw.hasPrefix(".") { return ("Names can’t start with a dot", true) }
        let path = folder.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue { return ("\(Formatters.abbreviatedPath(path)) is a file", true) }
            if FileManager.default.fileExists(atPath: folder.appending(path: ".git").path(percentEncoded: false)) {
                return ("\(Formatters.abbreviatedPath(path)) is already a repository", true)
            }
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: path), !contents.isEmpty {
                return ("\(Formatters.abbreviatedPath(path)) already has files in it — open it and use Create Repository Here", true)
            }
        }
        if raw.contains(where: \.isWhitespace) { return ("Spaces become dashes: \(cleanName)", false) }
        return (nil, false)
    }

    var branchIsValid: Bool {
        let value = branch.trimmingCharacters(in: .whitespaces)
        return !value.isEmpty && RepositoryModel.isWellFormedRefName(value)
    }

    var ignoreNote: String {
        if existingFolder != nil, let survey, let marker = survey.marker, survey.template == ignore, ignore != .macOS {
            var note = "Found \(marker), so \(ignore.rawValue) is picked."
            if let biggest = survey.generated.first {
                note += " \(biggest.name) (\(Formatters.count(biggest.files, "file", "files"))) stays out."
            }
            return note
        }
        return ignore.note
    }

    /// "“Initial commit” with 7 files".
    var firstCommitNote: String {
        guard firstCommit else { return "Leaves everything unstaged" }
        var count = (existingFolder != nil ? survey?.files ?? 0 : 0)
        if ignore != .none, !exists(".gitignore") { count += 1 }
        if readme, !exists("README.md") { count += 1 }
        if license != .none, !exists("LICENSE") { count += 1 }
        return "“Initial commit” with \(Formatters.count(count, "file", "files"))"
    }

    private func exists(_ file: String) -> Bool {
        guard let existingFolder else { return false }
        return FileManager.default.fileExists(atPath: existingFolder.appending(path: file).path(percentEncoded: false))
    }

    var canCreate: Bool { !nameCheck.isError && branchIsValid && !isRunning && (!publish || githubAccount != nil) }

    /// The steps Create will take, by key ("init", "write", "commit", "publish").
    @ObservationIgnored private var stepKeys: [String] = []

    func setSteps(_ list: [(key: String, text: String)]) {
        stepKeys = list.map(\.key)
        steps = list.enumerated().map { Step(id: $0.offset, text: $0.element.text, state: .waiting) }
    }

    /// The step `key` starts: the ones before it are done (`nil`: all of them are).
    func advance(to key: String?) {
        let index = key.flatMap { stepKeys.firstIndex(of: $0) } ?? steps.count
        for position in steps.indices {
            if position < index { steps[position].state = .done } else if position == index { steps[position].state = .running }
        }
    }

    func failCurrentStep() {
        if let index = steps.firstIndex(where: { $0.state == .running }) { steps[index].state = .failed }
    }
}

// MARK: - Publish

/// Publish to GitHub…: makes a repository on GitHub for one that's only on this Mac, adds it as
/// origin and pushes the current branch.
@MainActor @Observable
final class PublishModel {
    let repositoryPath: String
    var name: String
    var isPrivate = true
    var isRunning = false
    var error: String?
    var progress: String?

    init(repositoryPath: String, name: String) {
        self.repositoryPath = repositoryPath
        self.name = name
    }

    var account: HostingAccount? { HostingAccount.all.first { $0.kind == .github && $0.host == "github.com" } }

    /// What GitHub will call it: a space or a letter GitHub doesn't take becomes a dash there, so
    /// the sheet shows that name and Publish asks for it.
    var githubName: String { GitHubClient.repositoryName(for: name) }

    /// Something of the name is left on GitHub (a letter or a digit), within its 100 characters.
    var nameIsValid: Bool {
        let value = githubName
        return value.count <= 100 && value.contains { $0.isLetter || $0.isNumber }
    }
}
