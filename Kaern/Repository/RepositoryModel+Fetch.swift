import Foundation
import KaernKit

/// A fetch that failed, for the status bar (ScreenStatusBar's 로그인 필요 · 연결 실패).
struct FetchProblem: Equatable {
    var failure: GitFailure?
    var remote: String
    var message: String
    var date: Date
}

extension RepositoryModel {
    /// Auto-fetch and Fetch All: a quiet fetch (no toast, no alert); a failure goes to the status
    /// bar and Activity. A turned-down sign-in pauses auto-fetch here until you fetch or sign in.
    func fetchInBackground(trigger: String, auto: Bool) async {
        if auto, autoFetchPaused || isMidOperation { return }
        guard repository != nil, !remotes.isEmpty, activity == nil else { return }
        let remote = remotes.count == 1 ? remotes.first?.name : nil
        let task = perform(.fetching(remote: remote), trigger: trigger, background: auto) { try await $0.fetch() } onSuccess: { [weak self] in
            self?.fetchProblem = nil
            self?.autoFetchPaused = false
        } onFailure: { [weak self] error in
            self?.noteFetchFailure(error, auto: auto)
            return true
        }
        await task?.value
    }

    /// Remembers why a fetch failed (the status bar's blocked state).
    func noteFetchFailure(_ error: any Error, auto: Bool) {
        guard !(error is CancellationError) else { return }
        let gitError = error as? GitError
        let failure = gitError.flatMap { GitFailure.explain(arguments: $0.arguments, errorOutput: $0.message, status: $0.status) }
        fetchProblem = FetchProblem(failure: failure, remote: defaultRemote ?? "origin", message: error.localizedDescription, date: .now)
        if case .signIn = failure { autoFetchPaused = true }
        if case .sshKey = failure { autoFetchPaused = true }
    }

    /// The host of the default remote ("github.com"), for Sign In.
    var remoteHost: String? { remoteURL?.host }
}
