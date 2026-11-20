import CryptoKit
import Foundation
import Testing
@testable import KaernKit

@Suite("Clone and create")
struct CloneAndCreateTests {
    static let runner = RepositoryTests.runner

    static func scratchFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "kaern-p5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func readsGitsProgressLines() throws {
        let receiving = try #require(GitProgress.parse("Receiving objects:  62% (1284/2071), 18.40 MiB | 3.20 MiB/s"))
        #expect(receiving.phase == "Receiving objects")
        #expect(receiving.percent == 62)
        #expect(receiving.done == 1284 && receiving.total == 2071)
        #expect(receiving.transferred == "18.40 MiB")
        #expect(receiving.speed == "3.20 MiB/s")
        #expect(receiving.detail == "1,284 of 2,071 objects · 19.3 MB · 3.4 MB/s")
        let fraction = try #require(receiving.overallFraction)
        #expect(fraction > 0.5 && fraction < 0.6)

        let remote = try #require(GitProgress.parse("remote: Compressing objects: 100% (9/9), done."))
        #expect(remote.phase == "Compressing objects" && remote.percent == 100 && remote.isFinished)
        let counting = try #require(GitProgress.parse("remote: Enumerating objects: 2071, done."))
        #expect(counting.done == 2071 && counting.percent == nil)
        let deltas = try #require(GitProgress.parse("Resolving deltas: 100% (40/40), done."))
        #expect(deltas.detail == "40 of 40 deltas")
        #expect(GitProgress.parse("Cloning into 'kaern'...") == nil)
        #expect(GitProgress.parse("warning: You appear to have cloned an empty repository.") == nil)
    }

    @Test func namesTheCloneFolderAfterTheURL() {
        #expect(GitRepository.folderName(forClone: "https://github.com/progresshans/kaern.git") == "kaern")
        #expect(GitRepository.folderName(forClone: "git@github.com:progresshans/kaern.git") == "kaern")
        #expect(GitRepository.folderName(forClone: "/Users/me/Developer/powerlens/") == "powerlens")
        #expect(GitRepository.folderName(forClone: "file:///tmp/samples/x.git") == "x")
        #expect(GitRepository.folderName(forClone: "  ") == nil)
    }

    @Test func aPlainFolderIsNotARepository() async throws {
        let folder = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect(throws: NotARepositoryError.self) {
            _ = try await GitRepository.open(folder, runner: Self.runner)
        }
        #expect(await GitRepository.isInsideWorkTree(folder, runner: Self.runner) == false)
    }

    @Test func surveysAFolderBeforeItBecomesARepository() throws {
        let folder = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = #"{"name":"travel-blog","dependencies":{"astro":"^5.0.0"},"devDependencies":{"typescript":"^5"}}"#
        try Data(package.utf8).write(to: folder.appending(path: "package.json"))
        try FileManager.default.createDirectory(at: folder.appending(path: "src/pages"), withIntermediateDirectories: true)
        try Data("---\n---\n<h1>Hi</h1>\n".utf8).write(to: folder.appending(path: "src/pages/index.astro"))
        try Data([0, 1, 2]).write(to: folder.appending(path: ".DS_Store"))
        for index in 0 ..< 7 {
            let module = folder.appending(path: "node_modules/pkg\(index)")
            try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: module.appending(path: "index.js"))
            try Data("{}".utf8).write(to: module.appending(path: "package.json"))
        }
        let survey = FolderSurvey.survey(folder)
        #expect(survey.kind == "Astro site")
        #expect(survey.marker == "package.json")
        #expect(survey.template == .node)
        #expect(survey.files == 2)
        #expect(survey.generated == [FolderSurvey.GeneratedFolder(name: "node_modules/", files: 14)])
        #expect(IgnoreTemplate.node.contents?.contains("node_modules/") == true)
        #expect(IgnoreTemplate.node.contents?.contains(".DS_Store") == true)
        #expect(IgnoreTemplate.none.contents == nil)

        let swift = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: swift) }
        try Data("// swift-tools-version: 6.0\n".utf8).write(to: swift.appending(path: "Package.swift"))
        #expect(FolderSurvey.survey(swift).template == .swift)
        #expect(FolderSurvey.survey(swift).kind == "Swift package")
    }

    @Test func createsANewRepositoryWithItsFirstCommit() async throws {
        let parent = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appending(path: "travel-blog")
        let steps = StepLog()
        let (repository, written) = try await GitRepository.create(
            at: folder, defaultBranch: "trunk",
            files: [(".gitignore", Data(IgnoreTemplate.macOS.contents!.utf8)), ("README.md", Data("# travel-blog\n".utf8))],
            commitMessage: "Initial commit", runner: Self.runner, onStep: { steps.append($0) })
        #expect(written == [".gitignore", "README.md"])
        #expect(steps.all == [.initialize, .writeFiles([".gitignore", "README.md"]), .commit])
        #expect(try await repository.headSubject() == "Initial commit")
        let status = try await repository.status()
        #expect(status.branch == "trunk")
        #expect(status.isClean)
        #expect(try await repository.git(["ls-files"]).text.split(separator: "\n") == [".gitignore", "README.md"])
    }

    @Test func addsGitToAFolderWithoutTouchingItsFiles() async throws {
        let folder = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("# Mine\n".utf8).write(to: folder.appending(path: "README.md"))
        try Data("print(1)\n".utf8).write(to: folder.appending(path: "main.py"))
        let (repository, written) = try await GitRepository.create(
            at: folder, defaultBranch: "main",
            files: [("README.md", Data("# Generated\n".utf8)), (".gitignore", Data(IgnoreTemplate.python.contents!.utf8))],
            commitMessage: nil, runner: Self.runner)
        #expect(written == [".gitignore"])
        #expect(repository.read("README.md") == "# Mine\n")
        // No first commit: everything waits, unstaged.
        let status = try await repository.status()
        #expect(status.headID == nil)
        #expect(Set(status.entries.map(\.path)) == [".gitignore", "README.md", "main.py"])
    }

    @Test func clonesALocalRepositoryWithProgress() async throws {
        let source = try await TestRepositories.make()
        defer { TestRepositories.remove(source) }
        for index in 0 ..< 30 {
            try source.write(String(repeating: "line \(index)\n", count: 200), to: "file\(index).txt")
            try await source.commitAll("commit \(index)")
        }
        let parent = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appending(path: "copy")
        let lines = ProgressLog()
        // file:// goes through the pack protocol, so git reports its progress like a network clone.
        let clone = try await GitRepository.clone("file://" + source.root.path(percentEncoded: false), into: destination,
                                                  runner: Self.runner, onProgress: { lines.append($0) })
        #expect(try await clone.headSubject() == "commit 29")
        #expect(lines.all.contains { $0.phase == "Receiving objects" && $0.percent == 100 })

        // A destination with files in it is refused before git runs.
        await #expect(throws: GitError.self) {
            _ = try await GitRepository.clone(source.root.path(percentEncoded: false), into: destination, runner: Self.runner)
        }
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "file0.txt").path(percentEncoded: false)))

        // A clone that fails leaves no folder behind.
        let failed = parent.appending(path: "nothing")
        await #expect(throws: GitError.self) {
            _ = try await GitRepository.clone(parent.appending(path: "no-such-repo").path(percentEncoded: false), into: failed,
                                              runner: Self.runner)
        }
        #expect(!FileManager.default.fileExists(atPath: failed.path(percentEncoded: false)))
    }

    @Test func aTaskHearsTheProgressOfItsFetch() async throws {
        let upstream = try await TestRepositories.make()
        defer { TestRepositories.remove(upstream) }
        try upstream.write("start\n", to: "a.txt")
        try await upstream.commitAll("start")
        let clone = try await TestRepositories.make()
        defer { TestRepositories.remove(clone) }
        try await clone.addRemote("origin", url: "file://" + upstream.root.path(percentEncoded: false))
        for index in 0 ..< 40 {
            try upstream.write(String(repeating: "more \(index)\n", count: 300), to: "f\(index).txt")
            try await upstream.commitAll("more \(index)")
        }
        let heard = ProgressLog()
        try await GitProgressReporter.$current.withValue({ heard.append($0) }) {
            try await clone.fetch()
        }
        // Receiving (or unpacking, for a small fetch) reaches 100%.
        #expect(heard.all.contains { ($0.phase == "Receiving objects" || $0.phase == "Unpacking objects") && $0.percent == 100 })
        #expect(heard.all.compactMap(\.overallFraction).max() ?? 0 > 0.5)
    }

    @Test func readsTheDefaultBranchSetting() async throws {
        #expect(await GitRepository.defaultBranchName(runner: Self.runner) == "main")
        let config = FileManager.default.temporaryDirectory.appending(path: "kaern-p5-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: config) }
        try Data("[init]\n\tdefaultBranch = develop\n".utf8).write(to: config)
        let runner = GitRunner(extraEnvironment: ["GIT_CONFIG_GLOBAL": config.path(percentEncoded: false), "GIT_CONFIG_NOSYSTEM": "1"])
        #expect(await GitRepository.defaultBranchName(runner: runner) == "develop")
    }
}

/// Collects values a `@Sendable` callback hands over.
final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [GitRepository.CreationStep] = []
    func append(_ step: GitRepository.CreationStep) { lock.withLock { steps.append(step) } }
    var all: [GitRepository.CreationStep] { lock.withLock { steps } }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [GitProgress] = []
    func append(_ item: GitProgress) { lock.withLock { items.append(item) } }
    var all: [GitProgress] { lock.withLock { items } }
}

// MARK: - Hosting

/// Answers requests from canned responses, so API calls run without the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = data
        }
        var recorded = request
        recorded.httpBody = body
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let (status, text) = Self.lock.withLock {
            Self.requests.append(recorded)
            return Self.responses[key] ?? (404, #"{"message":"Not Found"}"#)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@Suite("Hosted repositories", .serialized)
struct HostedRepositoryTests {
    @Test func listsAndCreatesGitHubRepositories() async throws {
        StubProtocol.lock.withLock {
            StubProtocol.requests = []
            StubProtocol.responses = [
                "GET /user/repos": (200, """
                [{"id": 7, "name": "kaern", "full_name": "progresshans/kaern", "private": true, "description": "Git GUI",
                  "clone_url": "https://github.com/progresshans/kaern.git", "ssh_url": "git@github.com:progresshans/kaern.git",
                  "html_url": "https://github.com/progresshans/kaern", "pushed_at": "2026-11-06T10:00:00Z"}]
                """),
                "POST /user/repos": (201, """
                {"id": 8, "name": "travel-blog", "full_name": "progresshans/travel-blog", "private": false, "description": null,
                 "clone_url": "https://github.com/progresshans/travel-blog.git", "ssh_url": "git@github.com:progresshans/travel-blog.git",
                 "html_url": "https://github.com/progresshans/travel-blog", "pushed_at": null}
                """),
            ]
        }
        #expect(GitHubClient.repositoryName(for: "powerlens") == "powerlens")
        #expect(GitHubClient.repositoryName(for: "  my app v1.2_beta ") == "my-app-v1.2_beta")
        #expect(GitHubClient.repositoryName(for: "내 app!") == "--app-")
        #expect(GitHubClient.repositoryName(for: "") == "")
        // A typed host that can't be an address used to end the app (a force-unwrapped URL).
        #expect(GitHubClient.apiURL(for: "my host").path() == "/api/v3")
        #expect(GitHubClient.apiURL(for: "git.example.com").absoluteString == "https://git.example.com/api/v3")
        #expect(GitLabClient.apiURL(for: "").path() == "/api/v4")
        #expect(GitLabClient.apiURL(for: "gitlab.example.com").absoluteString == "https://gitlab.example.com/api/v4")
        var client = GitHubClient(baseURL: GitHubClient.apiURL(for: "github.com"), token: "ghp_test")
        client.session = StubProtocol.session()
        let list = try await client.repositories()
        #expect(list.map(\.fullName) == ["progresshans/kaern"])
        #expect(list.first?.isPrivate == true)
        #expect(list.first?.sshURL == "git@github.com:progresshans/kaern.git")

        let created = try await client.createRepository(name: "travel-blog", isPrivate: false)
        #expect(created.httpsURL == "https://github.com/progresshans/travel-blog.git")
        let post = try #require(StubProtocol.lock.withLock { StubProtocol.requests.last })
        #expect(post.httpMethod == "POST")
        #expect(post.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_test")
        let body = try #require(post.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["name"] as? String == "travel-blog")
        #expect(body["private"] as? Bool == false)

        // A name that's taken comes back as 422 with the reason.
        StubProtocol.lock.withLock {
            StubProtocol.responses["POST /user/repos"] = (422, #"{"message":"Repository creation failed.","errors":[{"message":"name already exists on this account"}]}"#)
        }
        do {
            _ = try await client.createRepository(name: "travel-blog", isPrivate: true)
            Issue.record("expected a failure")
        } catch let error as HostingError {
            #expect(error.status == 422)
            #expect(error.message.contains("name already exists"))
        }
    }

    @Test func listsGitLabProjects() async throws {
        StubProtocol.lock.withLock {
            StubProtocol.responses = [
                "GET /api/v4/projects": (200, """
                [{"id": 3, "name": "recipe-box", "path_with_namespace": "acme/recipe-box", "visibility": "private", "description": "",
                  "http_url_to_repo": "https://gitlab.com/acme/recipe-box.git", "ssh_url_to_repo": "git@gitlab.com:acme/recipe-box.git",
                  "web_url": "https://gitlab.com/acme/recipe-box", "last_activity_at": "2026-11-05T09:30:12.512Z"}]
                """),
            ]
        }
        let projects = try await GitLabClient.projects(host: "gitlab.com", token: "glpat", session: StubProtocol.session())
        #expect(projects.map(\.fullName) == ["acme/recipe-box"])
        #expect(projects.first?.isPrivate == true)
        #expect(projects.first?.updated != nil)
    }
}

@Suite("Big repositories")
struct BigRepositoryTests {
    static func repository(commits: Int) async throws -> GitRepository {
        let repository = try await TestRepositories.make()
        for index in 0 ..< commits {
            try repository.write("\(index)\n", to: "f.txt")
            try await repository.git(["add", "-A"])
            // Commit dates one minute apart, so date order is unambiguous.
            let date = "2026-01-01T00:\(String(format: "%02d", index / 60)):\(String(format: "%02d", index % 60))Z"
            try await repository.git(["commit", "-q", "-m", "commit \(index)"], environment: ["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date])
        }
        return repository
    }

    @Test func readsHistoryFromOneStreamAsItIsNeeded() async throws {
        let repository = try await Self.repository(commits: 50)
        defer { TestRepositories.remove(repository) }
        let all = try await repository.log(skip: 0, limit: 1000, includeHEAD: true)
        #expect(all.count == 50)

        let events = EventLog()
        let runner = GitRunner(executableURL: repository.runner.executableURL, extraEnvironment: [
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        ], onCommand: { events.append($0) })
        let watched = GitRepository(root: repository.root, gitDirectory: repository.gitDirectory, runner: runner)
        let stream = watched.historyStream()
        let first = try await stream.next(10)
        let second = try await stream.next(25)
        #expect(first.map(\.id) == Array(all.prefix(10)).map(\.id))
        #expect(second.map(\.id) == Array(all.dropFirst(10).prefix(25)).map(\.id))
        // Between pages git waits on the pipe: one command, still running.
        #expect(events.started == 1 && events.finished == 0)
        #expect(!stream.isFinished)
        let rest = try await stream.next(1000)
        #expect(rest.map(\.id) == Array(all.dropFirst(35)).map(\.id))
        #expect(stream.isFinished)
        #expect(try await stream.next(10).isEmpty)
        #expect(stream.count == 50)
        // No wait here: the record ends in the read that reaches the end of history.
        #expect(events.started == 1 && events.finished == 1)
        #expect(events.lastOutput == "50 commits read")

        // A stream picks up where another stopped.
        let resumed = repository.historyStream(skip: 40)
        #expect(try await resumed.next(5).map(\.id) == Array(all.dropFirst(40).prefix(5)).map(\.id))
        resumed.cancel()
        // Stopped isn't the end of history, and a stopped stream gives nothing more.
        #expect(!resumed.isFinished)
        await #expect(throws: CancellationError.self) { _ = try await resumed.next(5) }
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var startedCount = 0
    private var finishedCount = 0
    private var output = ""
    func append(_ event: GitCommandEvent) {
        lock.withLock {
            switch event {
            case .started: startedCount += 1
            case .finished(let record): finishedCount += 1; output = record.output
            case .progress: break
            }
        }
    }
    var started: Int { lock.withLock { startedCount } }
    var finished: Int { lock.withLock { finishedCount } }
    var lastOutput: String { lock.withLock { output } }
}

@Suite("Bot folding")
struct BotFoldingTests {
    static func commit(_ id: String, _ parents: [String], by author: String, _ subject: String, minutes: Int) -> Commit {
        Commit(id: id + String(repeating: "0", count: 40 - id.count), parents: parents.map { $0 + String(repeating: "0", count: 40 - $0.count) },
               author: Signature(name: author, email: author.hasSuffix("[bot]") ? "\(author)@users.noreply.github.com" : "x@kaern.invalid",
                                 date: Date(timeIntervalSince1970: 1_800_000_000 - Double(minutes) * 60)),
               subject: subject)
    }

    /// h1 ← b1 ← b2 ← b3 ← b4 ← h2 ← r1 ← r2 ← h3 (newest first; b = deployer bot, r = renovate)
    static var history: [Commit] {
        [
            commit("aa01", ["bb01"], by: "Han Hyeonjin", "feat: staging overlay", minutes: 1),
            commit("bb01", ["bb02"], by: "deployer[bot]", "build: automatic update of orders-api to 1.42.3", minutes: 2),
            commit("bb02", ["bb03"], by: "deployer[bot]", "build: automatic update of orders-web to 2.0.1", minutes: 3),
            commit("bb03", ["bb04"], by: "deployer[bot]", "build: automatic update of orders-api to 1.42.2", minutes: 4),
            commit("bb04", ["aa02"], by: "deployer[bot]", "build: automatic update of powerlens-feed to 0.9", minutes: 5),
            commit("aa02", ["cc01"], by: "Mina Park", "fix: gateway memory", minutes: 6),
            commit("cc01", ["cc02"], by: "renovate[bot]", "chore(deps): update dependency ingress-nginx to v4.9", minutes: 7),
            commit("cc02", ["aa03"], by: "renovate[bot]", "chore(deps): update helm release loki to v5", minutes: 8),
            commit("aa03", [], by: "Han Hyeonjin", "first", minutes: 9),
        ]
    }

    @Test func foldsARunOfOneBotIntoOneRow() throws {
        let folded = BotFolding.fold(Self.history, mode: .collapse, keep: [])
        #expect(folded.commits.map { String($0.id.prefix(4)) } == ["aa01", "bb01", "aa02", "cc01", "cc02", "aa03"])
        let run = try #require(folded.runs[Self.history[1].id])
        #expect(run.count == 4)
        #expect(run.title == "4 updates by deployer[bot]")
        #expect(run.detail == "orders-api · orders-web · powerlens-feed")
        // The row stands for the run: the oldest one's parent, so the lane runs on to aa02.
        #expect(folded.commits[1].parents == [Self.history[5].id])
        #expect(folded.insideRun[Self.history[3].id] == Self.history[1].id)
        #expect(folded.foldedCount == 4)
        // Two renovate commits are under the minimum of three.
        #expect(folded.runs.count == 1)
        #expect(BotRun(commits: Array(Self.history[6...7]), bot: "renovate[bot]").title == "2 dependency updates by renovate[bot]")
        #expect(BotRun(commits: Array(Self.history[6...7]), bot: "renovate[bot]").detail == "ingress-nginx · loki")
    }

    @Test func keepsRefsBranchPointsAndOpenRuns() {
        // A ref on bb03 ends the run before it: bb01 bb02 are only two.
        let withRef = BotFolding.fold(Self.history, mode: .collapse, keep: [Self.history[3].id])
        #expect(withRef.runs.isEmpty)
        // A branch that grew from bb03 splits the run there (its line needs bb03 to show):
        // bb01 bb02 and bb03 bb04, each under three.
        var branched = Self.history
        branched.insert(Self.commit("dd01", ["bb03"], by: "Mina Park", "feat: from the middle", minutes: 0), at: 0)
        #expect(BotFolding.fold(branched, mode: .collapse, keep: []).runs.isEmpty)
        let pairs = BotFolding.fold(branched, mode: .collapse, keep: [], minimumRun: 2)
        #expect(pairs.runs[Self.history[1].id]?.count == 2)
        #expect(pairs.runs[Self.history[3].id]?.count == 2)
        #expect(pairs.commits.contains { $0.id == Self.history[3].id })
        // An opened run shows every commit.
        let open = BotFolding.fold(Self.history, mode: .collapse, keep: [], expanded: [Self.history[1].id])
        #expect(open.commits.count == Self.history.count)
        #expect(BotFolding.fold(Self.history, mode: .show, keep: []).commits.count == Self.history.count)
    }

    @Test func hideLeavesBotsOutAndJoinsTheLines() {
        let hidden = BotFolding.fold(Self.history, mode: .hide, keep: [])
        #expect(hidden.commits.map { String($0.id.prefix(4)) } == ["aa01", "aa02", "aa03"])
        #expect(hidden.commits[0].parents == [Self.history[5].id])
        #expect(hidden.commits[1].parents == [Self.history[8].id])
        #expect(hidden.hiddenCount == 6)
        // The graph still has one lane from top to bottom.
        var builder = CommitGraphBuilder()
        builder.append(hidden.commits)
        #expect(builder.rows.map(\.lane) == [0, 0, 0])
    }

    @Test func recognizesBots() {
        func signature(_ name: String, _ email: String = "x@y") -> Signature { Signature(name: name, email: email, date: .now) }
        #expect(BotFolding.isBot(signature("dependabot[bot]")))
        #expect(BotFolding.isBot(signature("ci", "41898282+github-actions[bot]@users.noreply.github.com")))
        #expect(BotFolding.isBot(signature("renovate")))
        #expect(!BotFolding.isBot(signature("Robot Kim")))
    }
}

@Suite("Diff extras")
struct DiffExtrasTests {
    static let runner = RepositoryTests.runner

    @Test func readsAFileAtEachVersion() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        try repository.write("one\n", to: "a.txt")
        let first = try await repository.commitAll("One")
        try repository.write("two\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        try repository.write("three\n", to: "a.txt")
        func text(_ version: FileVersion) async -> String? {
            await repository.contents(of: "a.txt", at: version)?.data.map { String(decoding: $0, as: UTF8.self) }
        }
        #expect(await text(.revision(first)) == "one\n")
        #expect(await text(.index) == "two\n")
        #expect(await text(.workTree) == "three\n")
        #expect(await repository.contents(of: "missing.txt", at: .revision(first)) == nil)
        let tooBig = try #require(await repository.contents(of: "a.txt", at: .workTree, limit: 2))
        #expect(tooBig.data == nil && tooBig.size == 6 && !tooBig.isMissingLFSContent)
    }

    @Test func findsTheContentOfAnLFSFileOnceItIsDownloaded() async throws {
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        let content = Data("pretend these are the bytes of a PNG".utf8)
        let hex = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        try repository.write("*.png filter=lfs diff=lfs merge=lfs -text\n", to: ".gitattributes")
        try repository.write("version https://git-lfs.github.com/spec/v1\noid sha256:\(hex)\nsize \(content.count)\n", to: "art/logo.png")
        let commit = try await repository.commitAll("Add the logo")

        let missing = try #require(await repository.contents(of: "art/logo.png", at: .revision(commit)))
        #expect(missing.isMissingLFSContent)
        #expect(missing.size == content.count && missing.pointer?.oid == "sha256:\(hex)")

        // git-lfs keeps content in .git/lfs/objects/<2>/<2>/<oid>.
        let object = repository.root.appending(path: ".git/lfs/objects/\(hex.prefix(2))/\(hex.dropFirst(2).prefix(2))/\(hex)")
        try FileManager.default.createDirectory(at: object.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: object)
        let found = try #require(await repository.contents(of: "art/logo.png", at: .revision(commit)))
        #expect(found.data == content && found.pointer != nil && !found.isMissingLFSContent)
        // The work tree still holds the pointer, so it reads the same way.
        #expect(await repository.contents(of: "art/logo.png", at: .workTree)?.data == content)
    }

    @Test func downloadingLFSFilesNeedsGitLFS() async throws {
        guard !Self.runner.isLFSInstalled else { return }
        let repository = try await TestRepositories.make()
        defer { TestRepositories.remove(repository) }
        await #expect(throws: LFSNotInstalledError.self) {
            try await repository.downloadLFS(["art/logo.png"])
        }
    }

    @Test func deepensAShallowCloneAndFetchesTheRest() async throws {
        let origin = try await TestRepositories.make()
        defer { TestRepositories.remove(origin) }
        for number in 1...4 {
            try origin.write("\(number)\n", to: "n.txt")
            try await origin.commitAll("Commit \(number)")
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "kaern-shallow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try await Self.runner.run(["clone", "-q", "--depth", "2", "file://" + origin.root.path(percentEncoded: false), folder.path(percentEncoded: false)],
                                  in: nil)
        let clone = try await GitRepository.open(folder, runner: Self.runner)
        func count() async throws -> Int {
            Int(try await clone.git(["rev-list", "--count", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        }
        #expect(clone.isShallow)
        #expect(try await count() == 2)
        try await clone.deepen(by: 1, remote: "origin")
        #expect(try await count() == 3 && clone.isShallow)
        try await clone.deepen(by: nil, remote: "origin")
        #expect(try await count() == 4)
        #expect(!clone.isShallow)
        #expect(!origin.isShallow)
    }

    @Test func tellsWhatASubmoduleMoveBrings() async throws {
        // The submodule's own repository: three commits, with tags on the first and the last.
        let library = try await TestRepositories.make()
        defer { TestRepositories.remove(library) }
        try library.write("2.6.4\n", to: "VERSION")
        let oldest = try await library.commitAll("Release 2.6.4")
        try await library.git(["tag", "2.6.4"])
        try library.write("2.6.5-dev\n", to: "VERSION")
        try await library.commitAll("Fix appcast parsing for alpha channels")
        try library.write("2.7.0\n", to: "VERSION")
        let newest = try await library.commitAll("Bump version to 2.7.0")
        try await library.git(["tag", "2.7.0"])

        let app = try await TestRepositories.make()
        defer { TestRepositories.remove(app) }
        try app.write("app\n", to: "README.md")
        try await app.commitAll("Start")
        try await app.git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", library.root.path(percentEncoded: false), "Vendor/Sparkle"])
        let folder = app.root.appending(path: "Vendor/Sparkle")
        try await Self.runner.run(["checkout", "-q", oldest], in: folder)
        try await app.commitAll("Add Sparkle at 2.6.4")
        try await Self.runner.run(["checkout", "-q", newest], in: folder)

        #expect(await app.submoduleHead("Vendor/Sparkle") == newest)
        let forward = await app.submoduleChange("Vendor/Sparkle", from: oldest, to: newest)
        #expect(forward.isInitialized && forward.isFastForward)
        #expect(forward.oldTag == "2.6.4" && forward.newTag == "2.7.0")
        #expect(forward.addedCount == 2)
        #expect(forward.added.map(\.subject) == ["Bump version to 2.7.0", "Fix appcast parsing for alpha channels"])
        let back = await app.submoduleChange("Vendor/Sparkle", from: newest, to: oldest)
        #expect(back.removedCount == 2 && back.addedCount == 0 && !back.isFastForward)
        #expect(back.removed.first?.subject == "Bump version to 2.7.0")
        let added = await app.submoduleChange("Vendor/Sparkle", from: nil, to: newest)
        #expect(added.addedCount == 3)
        #expect(await app.submoduleChange("Vendor/Other", from: oldest, to: newest).isInitialized == false)
        #expect(await app.submoduleHead("Vendor/Other") == nil)
    }
}
