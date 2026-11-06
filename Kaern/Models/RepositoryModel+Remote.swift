import KaernKit
import SwiftUI

// MARK: - Remote operations

extension RepositoryModel {
    func fetch(userInitiated: Bool = true) async {
        guard let repository, activity == nil else { return }
        guard !remotes.isEmpty else {
            if userInitiated {
                alert = AlertItem(title: String(localized: "Nothing to Fetch"),
                                  message: String(localized: "This repository doesn't have a remote."))
            }
            return
        }
        setActivity(.fetching)
        var failure: (any Error)?
        do {
            try await repository.fetch()
            setFetchResult(date: repository.lastFetchDate ?? .now, error: nil)
            isWorkingOffline = false
        } catch {
            let message = error.localizedDescription
            setFetchResult(date: nil, error: Self.isNetworkFailure(message) ? message : nil)
            failure = error
        }
        setActivity(nil)
        await refreshEverything()
        // Background fetches only show up in the status bar; a fetch you asked for explains itself.
        if userInitiated, let failure, !(await handleRemoteFailure(failure, retry: .fetch)) {
            alert = AlertItem(title: String(localized: "Couldn't Fetch"), message: failure.localizedDescription)
        }
    }

    static func isNetworkFailure(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        if lowercased.contains("permission denied") || lowercased.contains("authentication") {
            return false
        }
        return ["could not resolve host", "unable to access", "timed out", "network is unreachable",
                "connection refused", "could not read from remote", "failed to connect"]
            .contains { lowercased.contains($0) }
    }

    /// Pull, with the strategy from Settings (or one picked from the Pull button's menu).
    func pull(using override: GitRepository.PullStrategy? = nil) async {
        let strategy: GitRepository.PullStrategy
        if let override {
            strategy = override
        } else {
            strategy = await resolvedPullStrategy()
        }
        let before = status.headID
        await perform(.pulling, failureTitle: String(localized: "Couldn't Pull"), remote: .pull) { repository in
            try await repository.pull(strategy: strategy)
        }
        registerHistoryUndo(String(localized: "Pull"), hint: String(localized: "Pulled into \(currentBranchTitle)"), before: before)
    }

    /// "merges", "rebases", "fast-forwards only": what a plain Pull does here (its tooltip).
    var pullDescription: String {
        switch Preferences.pull {
        case .merge: String(localized: "merges")
        case .rebase: String(localized: "rebases")
        case .fastForwardOnly: String(localized: "fast-forwards only")
        case .gitConfig: String(localized: "follows pull.rebase")
        }
    }

    /// "Use Git Configuration" with neither pull.rebase nor pull.ff set: merge, like Git always did.
    /// (Recent Git refuses to pull divergent branches until one of them is configured.)
    private func resolvedPullStrategy() async -> GitRepository.PullStrategy {
        let preference = Preferences.pull
        guard preference == .gitConfig, let repository else { return preference.strategy }
        async let rebase = repository.config("pull.rebase")
        async let fastForward = repository.config("pull.ff")
        let (rebaseValue, fastForwardValue) = await (rebase, fastForward)
        return rebaseValue == nil && fastForwardValue == nil ? .merge : .gitConfig
    }

    /// Push the current branch. Publishes it when there's no upstream; asks to pull first when behind.
    func push() async {
        guard status.branch != nil, hasHead else {
            alert = AlertItem(title: String(localized: "Can't Push"),
                              message: String(localized: "HEAD isn't on a branch. Create a branch first."))
            return
        }
        if status.upstream == nil {
            guard let remote = remotes.contains("origin") ? "origin" : remotes.first else {
                alert = AlertItem(title: String(localized: "Can't Push"),
                                  message: String(localized: "This repository doesn't have a remote."))
                return
            }
            await perform(.pushing, failureTitle: String(localized: "Couldn't Push"), remote: .push) { repository in
                try await repository.push(setUpstreamOn: remote)
            }
            return
        }
        if status.behind > 0 {
            sheet = .pullThenPush
            return
        }
        await perform(.pushing, failureTitle: String(localized: "Couldn't Push"), remote: .push) { repository in
            try await repository.push()
        }
    }

    func pullThenPush() async {
        let strategy = await resolvedPullStrategy()
        let pulled = await perform(.pulling, failureTitle: String(localized: "Couldn't Pull"), remote: .pullThenPush) { repository in
            try await repository.pull(strategy: strategy)
        }
        guard pulled, status.behind == 0, status.conflictCount == 0 else { return }
        await perform(.pushing, failureTitle: String(localized: "Couldn't Push"), remote: .push) { repository in
            try await repository.push()
        }
    }

    /// Repository › Force Push (with lease). The menu confirms first.
    func forcePush() async {
        await perform(.pushing, failureTitle: String(localized: "Couldn't Force Push"), remote: .forcePush) { repository in
            try await repository.push(forceWithLease: true)
        }
    }
}
