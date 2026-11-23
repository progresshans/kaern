import Foundation
import Testing
@testable import KaernKit

@Suite("GitHub pull requests", .hangGuard)
struct GitHubTests {
    static let json = """
    [{
      "number": 15, "title": "fix: keep shortfall markers after recovery", "body": "Recovery cleared…",
      "user": {"login": "sungho-lee"}, "draft": false, "state": "open",
      "created_at": "2026-09-29T06:00:00Z", "updated_at": "2026-09-29T08:20:00Z",
      "html_url": "https://github.com/progresshans/powerlens/pull/15",
      "requested_reviewers": [{"login": "progresshans"}],
      "head": {"ref": "fix/shortfall-markers", "sha": "abc", "repo": {"full_name": "sungho-lee/powerlens"}},
      "base": {"ref": "develop", "sha": "def", "repo": {"full_name": "progresshans/powerlens"}}
    }]
    """

    @Test func decodesPullRequestsAndSuggestsABranch() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pulls = try decoder.decode([PullRequest].self, from: Data(Self.json.utf8))
        let pull = try #require(pulls.first)
        #expect(pull.number == 15)
        #expect(pull.isFromFork)
        #expect(!pull.isDraft)
        #expect(pull.suggestedLocalBranch == "pr/15-shortfall-markers")
        #expect(pull.requestedReviewers?.map(\.login) == ["progresshans"])
    }

    @Test func summarizesChecksAndReviews() {
        func run(_ status: String, _ conclusion: String?) -> CheckRun {
            CheckRun(id: Int.random(in: 0 ... 1_000_000), name: "x", status: status, conclusion: conclusion)
        }
        let checks = ChecksSummary([run("completed", "success"), run("completed", "failure"), run("in_progress", nil), run("completed", "skipped")])
        #expect(checks.total == 3)
        #expect(checks.passed == 1)
        #expect(checks.failed == 1)
        #expect(checks.pending == 1)

        let alice = PullRequest.User(login: "alice"), bob = PullRequest.User(login: "bob")
        let reviews = [
            PullRequestReview(user: alice, state: "CHANGES_REQUESTED", submittedAt: Date(timeIntervalSince1970: 1)),
            PullRequestReview(user: alice, state: "APPROVED", submittedAt: Date(timeIntervalSince1970: 2)),
            PullRequestReview(user: bob, state: "COMMENTED", submittedAt: Date(timeIntervalSince1970: 3)),
        ]
        #expect(ReviewSummary(reviews: reviews, requested: [], you: "han") == .approved)
        #expect(ReviewSummary(reviews: reviews, requested: ["HAN"], you: "han") == .yourReviewRequested)
        #expect(ReviewSummary(reviews: [], requested: ["bob"], you: "han") == .reviewRequested)
        #expect(ReviewSummary(reviews: [], requested: [], you: nil) == .noReviews)
    }

    @Test func fetchesAPullRequestHeadWithoutAddingARemote() async throws {
        let upstream = try await TestRepositories.make()
        defer { TestRepositories.remove(upstream) }
        try upstream.write("a\n", to: "a.txt")
        try await upstream.commitAll("first")
        try upstream.write("b\n", to: "b.txt")
        let head = try await upstream.commitAll("the pull request")
        // GitHub keeps every pull request's head at refs/pull/<n>/head.
        try await upstream.git(["update-ref", "refs/pull/15/head", head])
        try await upstream.git(["reset", "-q", "--hard", "HEAD~1"])

        let clone = try await TestRepositories.make()
        defer { TestRepositories.remove(clone) }
        try await clone.addRemote("origin", url: upstream.root.path(percentEncoded: false))
        try await clone.fetchPullRequest(15, from: "origin", into: "pr/15-test")
        #expect(await clone.resolve("refs/heads/pr/15-test") == head)
        #expect(await clone.remoteInfos().map(\.name) == ["origin"])
    }
}
