import AppKit
import Foundation
import KaernKit

/// One row of Pull Requests, with what loads after the list.
struct PullRequestItem: Identifiable, Equatable {
    var pull: PullRequest
    /// `nil` until loaded.
    var checks: [CheckRun]?
    var review: ReviewSummary?
    var size: PullRequestSize?

    var id: Int { pull.number }
}

/// Sidebar › Pull Requests (shown when the remote's host has an account in Settings › Accounts).
struct PullRequestsState: Equatable {
    var repositoryPath: String
    var account: HostingAccount
    /// The remote `refs/pull/<n>/head` is fetched from.
    var remote: String
    var showsClosed = false
    /// `nil` while loading.
    var items: [PullRequestItem]?
    var error: String?
    var updatedAt: Date?
    var openCount: Int?
    var closedCount: Int?
    var selected: Int?

    var selectedItem: PullRequestItem? {
        items?.first { $0.id == selected }
    }
}

extension RepositoryModel {
    /// Where pull requests come from: the primary remote on GitHub, with a signed-in account.
    var pullRequestSource: (account: HostingAccount, path: String, remote: String)? {
        guard let url = primaryRemote, let account = AppModel.shared.account(forHost: url.host), account.kind == .github,
              let remote = upstreamRemote ?? (remotes.contains("origin") ? "origin" : remotes.first) else { return nil }
        return (account, url.repositoryPath, remote)
    }

    func showPullRequests() {
        guard let source = pullRequestSource else { return }
        fileHistory = nil
        stashView = nil
        selectedFile = nil
        if pullRequests?.repositoryPath != source.path {
            pullRequests = PullRequestsState(repositoryPath: source.path, account: source.account, remote: source.remote)
        }
        Task { await loadPullRequests() }
    }

    func closePullRequests() {
        guard pullRequests != nil else { return }
        pullRequests = nil
        historyFocusRequest += 1
    }

    func setPullRequestsShowClosed(_ closed: Bool) {
        guard pullRequests?.showsClosed != closed else { return }
        pullRequests?.showsClosed = closed
        pullRequests?.items = nil
        pullRequests?.selected = nil
        Task { await loadPullRequests() }
    }

    func loadPullRequests() async {
        guard let state = pullRequests else { return }
        guard let token = await AppModel.shared.token(for: state.account) else {
            pullRequests?.items = []
            pullRequests?.error = String(localized: "There's no token for \(state.account.login) in the Keychain anymore. Sign in again in Settings › Accounts.")
            return
        }
        let client = GitHubClient(baseURL: state.account.apiURL, token: token)
        let path = state.repositoryPath
        let showsClosed = state.showsClosed
        do {
            async let list = client.pullRequests(path, state: showsClosed ? "closed" : "open")
            async let open = try? client.count(path, state: "open")
            async let closed = try? client.count(path, state: "closed")
            let pulls = try await list
            guard pullRequests?.repositoryPath == path, pullRequests?.showsClosed == showsClosed else { return }
            let previous = Dictionary((pullRequests?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            pullRequests?.items = pulls.map { pull in
                var item = PullRequestItem(pull: pull)
                if let old = previous[pull.number], old.pull.head.sha == pull.head.sha {
                    item.checks = old.checks
                    item.size = old.size
                }
                item.review = previous[pull.number]?.review
                return item
            }
            pullRequests?.error = nil
            pullRequests?.updatedAt = .now
            pullRequests?.openCount = await open
            pullRequests?.closedCount = await closed
            if pullRequests?.selected == nil || !pulls.contains(where: { $0.number == pullRequests?.selected }) {
                pullRequests?.selected = pulls.first?.number
            }
            if let selected = pullRequests?.selected { selectPullRequest(selected) }
            await loadStatuses(of: pulls, client: client, you: state.account.login)
        } catch {
            guard pullRequests?.repositoryPath == path else { return }
            pullRequests?.items = pullRequests?.items ?? []
            pullRequests?.error = (error as? HostingError)?.isUnauthorized == true
                ? String(localized: "GitHub didn't accept the token for \(state.account.login). Sign in again in Settings › Accounts.")
                : error.localizedDescription
        }
    }

    /// Checks and reviews for every row, a few at a time.
    private func loadStatuses(of pulls: [PullRequest], client: GitHubClient, you: String) async {
        let path = pullRequests?.repositoryPath ?? ""
        await withTaskGroup(of: (Int, [CheckRun]?, ReviewSummary?).self) { group in
            var pending = pulls.makeIterator()
            func next() -> Bool {
                guard let pull = pending.next() else { return false }
                group.addTask {
                    async let checks = try? client.checkRuns(for: pull.head.sha, in: path)
                    async let reviews = try? client.reviews(of: pull.number, in: path)
                    let requested = (pull.requestedReviewers ?? []).map(\.login)
                    let summary = await reviews.map { ReviewSummary(reviews: $0, requested: requested, you: you) }
                        ?? ReviewSummary(reviews: [], requested: requested, you: you)
                    return (pull.number, await checks, summary)
                }
                return true
            }
            for _ in 0 ..< 6 { _ = next() }
            for await (number, checks, review) in group {
                if let index = pullRequests?.items?.firstIndex(where: { $0.id == number }) {
                    pullRequests?.items?[index].checks = checks ?? []
                    pullRequests?.items?[index].review = review
                }
                _ = next()
            }
        }
    }

    func selectPullRequest(_ number: Int?) {
        pullRequests?.selected = number
        guard let number, let state = pullRequests, let item = state.items?.first(where: { $0.id == number }), item.size == nil else { return }
        Task {
            guard let token = await AppModel.shared.token(for: state.account) else { return }
            let client = GitHubClient(baseURL: state.account.apiURL, token: token)
            guard let size = try? await client.size(of: number, in: state.repositoryPath),
                  let index = pullRequests?.items?.firstIndex(where: { $0.id == number }) else { return }
            pullRequests?.items?[index].size = size
        }
    }

    /// The pull request is what's checked out now.
    func isCurrentBranch(_ pull: PullRequest) -> Bool {
        guard let branch = status.branch else { return false }
        return branch == pull.suggestedLocalBranch || (!pull.isFromFork && branch == pull.head.ref)
    }

    /// Check Out: fetches `refs/pull/<n>/head` from the remote into a local branch (forks need no
    /// new remote), tracks the real branch when it's in this repository, and switches to it —
    /// stashing the changes first when asked. ⌘Z switches back.
    func checkOutPullRequest(_ pull: PullRequest, as name: String, stashing: Bool) async {
        guard let remote = pullRequests?.remote else { return }
        let fetched = await perform(.working(String(localized: "Fetching #\(pull.number)…")),
                                    failureTitle: String(localized: "Couldn't Fetch Pull Request #\(pull.number)"), remote: .fetch) { repository in
            try await repository.fetchPullRequest(pull.number, from: remote, into: name)
            let upstream = "\(remote)/\(pull.head.ref)"
            if !pull.isFromFork, await repository.resolve("refs/remotes/\(upstream)") != nil {
                try? await repository.setUpstream(of: name, to: upstream)
            }
        }
        guard fetched, let ref = refs.localBranch(named: name) else { return }
        await switchBranch(to: ref, stashingChanges: stashing && !status.isClean)
    }

    func openOnHost(_ pull: PullRequest) {
        NSWorkspace.shared.open(pull.htmlURL)
    }
}
