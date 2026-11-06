import Foundation

// MARK: - Models

/// A pull request as the list shows it.
public struct PullRequest: Sendable, Hashable, Identifiable, Decodable {
    public struct Branch: Sendable, Hashable, Decodable {
        public struct Repository: Sendable, Hashable, Decodable {
            public var fullName: String
            enum CodingKeys: String, CodingKey { case fullName = "full_name" }
        }

        public var ref: String
        public var sha: String
        /// `nil` when the fork was deleted.
        public var repo: Repository?
    }

    public struct User: Sendable, Hashable, Decodable {
        public var login: String
        public var avatarURL: URL?

        public init(login: String, avatarURL: URL? = nil) {
            self.login = login
            self.avatarURL = avatarURL
        }

        enum CodingKeys: String, CodingKey {
            case login
            case avatarURL = "avatar_url"
        }
    }

    public var number: Int
    public var title: String
    public var body: String?
    public var user: User
    public var head: Branch
    public var base: Branch
    public var draft: Bool?
    public var state: String
    public var createdAt: Date
    public var updatedAt: Date
    public var htmlURL: URL
    public var requestedReviewers: [User]?

    public var id: Int { number }
    public var isDraft: Bool { draft ?? false }

    /// The changes come from another repository (a fork).
    public var isFromFork: Bool { head.repo?.fullName != base.repo?.fullName }

    enum CodingKeys: String, CodingKey {
        case number, title, body, user, head, base, draft, state
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case htmlURL = "html_url"
        case requestedReviewers = "requested_reviewers"
    }

    /// "pr/15-shortfall-markers" for a fork, the branch's own name otherwise.
    public var suggestedLocalBranch: String {
        guard isFromFork else { return head.ref }
        let last = head.ref.split(separator: "/").last.map(String.init) ?? head.ref
        return "pr/\(number)-\(last)"
    }
}

/// What only the single-pull-request endpoint returns.
public struct PullRequestSize: Sendable, Hashable, Decodable {
    public var commits: Int
    public var additions: Int
    public var deletions: Int
    public var changedFiles: Int

    enum CodingKeys: String, CodingKey {
        case commits, additions, deletions
        case changedFiles = "changed_files"
    }
}

public struct CheckRun: Sendable, Hashable, Identifiable, Decodable {
    public var id: Int
    public var name: String
    /// queued, in_progress, completed
    public var status: String
    /// success, failure, neutral, cancelled, skipped, timed_out, action_required
    public var conclusion: String?
    public var startedAt: Date?
    public var completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }

    public init(id: Int, name: String, status: String, conclusion: String?, startedAt: Date? = nil, completedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public enum Outcome: Sendable, Hashable {
        case passed
        case failed
        case pending
        case skipped
    }

    public var outcome: Outcome {
        guard status == "completed" else { return .pending }
        switch conclusion {
        case "success": return .passed
        case "neutral", "skipped", "cancelled": return .skipped
        default: return .failed
        }
    }

    public var duration: TimeInterval? {
        guard let startedAt, let completedAt else { return nil }
        return completedAt.timeIntervalSince(startedAt)
    }
}

public struct PullRequestReview: Sendable, Hashable, Decodable {
    public var user: PullRequest.User?
    /// APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED, PENDING
    public var state: String
    public var submittedAt: Date?

    enum CodingKeys: String, CodingKey {
        case user, state
        case submittedAt = "submitted_at"
    }

    public init(user: PullRequest.User?, state: String, submittedAt: Date?) {
        self.user = user
        self.state = state
        self.submittedAt = submittedAt
    }
}

/// "4 of 4", "2 of 4" (some still running), "1 failing".
public struct ChecksSummary: Sendable, Hashable {
    public var total: Int
    public var passed: Int
    public var failed: Int
    public var pending: Int

    public init(_ runs: [CheckRun]) {
        let counted = runs.filter { $0.outcome != .skipped }
        total = counted.count
        passed = counted.count { $0.outcome == .passed }
        failed = counted.count { $0.outcome == .failed }
        pending = counted.count { $0.outcome == .pending }
    }
}

/// The review state the list shows, most important first.
public enum ReviewSummary: Sendable, Hashable {
    case yourReviewRequested
    case changesRequested
    case approved
    case reviewRequested
    case noReviews

    /// Each reviewer's latest decision counts; a request for your review comes first.
    public init(reviews: [PullRequestReview], requested: [String], you: String?) {
        if let you, requested.contains(where: { $0.caseInsensitiveCompare(you) == .orderedSame }) {
            self = .yourReviewRequested
            return
        }
        var latest: [String: String] = [:]
        for review in reviews.sorted(by: { ($0.submittedAt ?? .distantPast) < ($1.submittedAt ?? .distantPast) }) {
            guard let login = review.user?.login, ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].contains(review.state) else { continue }
            latest[login] = review.state
        }
        if latest.values.contains("CHANGES_REQUESTED") {
            self = .changesRequested
        } else if latest.values.contains("APPROVED") {
            self = .approved
        } else if !requested.isEmpty {
            self = .reviewRequested
        } else {
            self = .noReviews
        }
    }
}

/// The signed-in user.
public struct HostingUser: Sendable, Hashable, Decodable {
    public var login: String
    public var name: String?
    public var id: Int?
    public var email: String?

    public init(login: String, name: String? = nil, id: Int? = nil, email: String? = nil) {
        self.login = login
        self.name = name
        self.id = id
        self.email = email
    }

    /// `12345+login@users.noreply.github.com`: commits that keep your address private.
    public var noreplyEmail: String? {
        id.map { "\($0)+\(login)@users.noreply.github.com" }
    }
}

/// The part of GitHub's commit object that says which accounts made it.
struct CommitAuthors: Decodable {
    struct Person: Decodable { var email: String? }
    struct GitCommit: Decodable {
        var author: Person?
        var committer: Person?
    }
    struct Account: Decodable {
        var avatarURL: URL?
        enum CodingKeys: String, CodingKey { case avatarURL = "avatar_url" }
    }

    var commit: GitCommit
    /// `null` when the email isn't tied to a GitHub account.
    var author: Account?
    var committer: Account?

    var avatars: [String: URL] {
        var result: [String: URL] = [:]
        if let email = commit.author?.email?.lowercased(), let url = author?.avatarURL { result[email] = url }
        if let email = commit.committer?.email?.lowercased(), let url = committer?.avatarURL, result[email] == nil { result[email] = url }
        return result
    }
}

// MARK: - Client

/// GitHub's error body: `{"message": "Bad credentials"}`.
private struct APIMessage: Decodable {
    var message: String?
}

public struct HostingError: Error, LocalizedError, Sendable {
    public var status: Int
    public var message: String

    public var errorDescription: String? { message }
    public var isUnauthorized: Bool { status == 401 }
}

/// The GitHub REST API with a personal access token. The token comes from git's credential
/// helper (the Keychain) and is never stored by Kaern itself.
public struct GitHubClient: Sendable {
    public var baseURL: URL
    public var token: String

    /// `https://api.github.com`, or `https://<host>/api/v3` for GitHub Enterprise.
    public static func apiURL(for host: String) -> URL {
        host.lowercased() == "github.com"
            ? URL(string: "https://api.github.com")!
            : URL(string: "https://\(host)/api/v3")!
    }

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        // Without a token: public repositories only, 60 requests an hour.
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Kaern", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            let message = (try? JSONDecoder().decode(APIMessage.self, from: data))?.message
            throw HostingError(status: status, message: message ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
        return try Self.decoder.decode(T.self, from: data)
    }

    public func user() async throws -> HostingUser {
        try await get("user", as: HostingUser.self)
    }

    public func pullRequests(_ repository: String, state: String) async throws -> [PullRequest] {
        try await get("repos/\(repository)/pulls", query: [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "direction", value: "desc"),
            URLQueryItem(name: "per_page", value: "50"),
        ], as: [PullRequest].self)
    }

    public func size(of number: Int, in repository: String) async throws -> PullRequestSize {
        try await get("repos/\(repository)/pulls/\(number)", as: PullRequestSize.self)
    }

    public func checkRuns(for sha: String, in repository: String) async throws -> [CheckRun] {
        struct Response: Decodable {
            var checkRuns: [CheckRun]
            enum CodingKeys: String, CodingKey { case checkRuns = "check_runs" }
        }
        return try await get("repos/\(repository)/commits/\(sha)/check-runs",
                             query: [URLQueryItem(name: "per_page", value: "100")], as: Response.self).checkRuns
    }

    public func reviews(of number: Int, in repository: String) async throws -> [PullRequestReview] {
        try await get("repos/\(repository)/pulls/\(number)/reviews", query: [URLQueryItem(name: "per_page", value: "100")],
                      as: [PullRequestReview].self)
    }

    /// Who made the latest commits of `repository`: each commit email GitHub ties to an
    /// account, with that account's avatar. One request covers the last `count` commits.
    public func commitAvatars(_ repository: String, count: Int = 100) async throws -> [String: URL] {
        let commits = try await get("repos/\(repository)/commits", query: [URLQueryItem(name: "per_page", value: "\(count)")],
                                    as: [CommitAuthors].self)
        var avatars: [String: URL] = [:]
        for commit in commits {
            avatars.merge(commit.avatars) { first, _ in first }
        }
        return avatars
    }

    /// The avatars of one commit's author and committer, by email.
    public func commitAvatars(_ repository: String, sha: String) async throws -> [String: URL] {
        try await get("repos/\(repository)/commits/\(sha)", as: CommitAuthors.self).avatars
    }

    /// How many pull requests are open or closed (`state:open` / `state:closed`).
    public func count(_ repository: String, state: String) async throws -> Int {
        struct Response: Decodable {
            var totalCount: Int
            enum CodingKeys: String, CodingKey { case totalCount = "total_count" }
        }
        return try await get("search/issues", query: [
            URLQueryItem(name: "q", value: "repo:\(repository) type:pr state:\(state)"),
            URLQueryItem(name: "per_page", value: "1"),
        ], as: Response.self).totalCount
    }
}

// MARK: - Checking out

extension GitRepository {
    /// Fetches a pull request's head (`refs/pull/<n>/head`, which works for forks too, without
    /// adding a remote) into `branch`.
    public func fetchPullRequest(_ number: Int, from remote: String, into branch: String) async throws {
        try await git(["fetch", remote, "+refs/pull/\(number)/head:refs/heads/\(branch)"])
    }
}
