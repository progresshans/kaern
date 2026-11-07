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
