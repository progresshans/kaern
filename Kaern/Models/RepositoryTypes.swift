import KaernKit
import SwiftUI

enum HistorySelection: Hashable {
    case workingCopy
    case commit(String)
}

/// The file whose diff fills the center of the window.
enum FileSelection: Hashable {
    case working(String)
    case commit(commitID: String, path: String)
}

/// A long-running git operation. Only one runs at a time per window.
enum Activity: Equatable {
    case fetching
    case pulling
    case pushing
    case committing
    case stashing
    case switching(String)
    case working(String)

    var title: String {
        switch self {
        case .fetching: String(localized: "Fetching…")
        case .pulling: String(localized: "Pulling…")
        case .pushing: String(localized: "Pushing…")
        case .committing: String(localized: "Committing…")
        case .stashing: String(localized: "Stashing…")
        case .switching(let branch): String(localized: "Switching to \(branch)…")
        case .working(let title): title
        }
    }
}

struct AlertItem: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

enum RepositorySheet: Identifiable {
    case newBranch(startPoint: String?, label: String)
    case stash
    case switchWithChanges(Ref)
    case pullThenPush
    case renameBranch(Ref)
    case newTag(commitID: String, label: String)
    /// Pick the branch to merge into, or rebase the current branch onto.
    case chooseBranch(BranchChoice)
    /// Sign In with Browser…: a token for a host that rejected the saved credentials.
    case signIn(RemoteProblem)
    /// Show Log: what git printed.
    case log(title: String, text: String)
    /// Create Branch from Stash…
    case branchFromStash(Stash)
    /// Repository › Repository Settings… (⌥⌘,)
    case repositorySettings
    /// Interactively Rebase from Here… / Branch › Interactive Rebase…
    case interactiveRebase(onto: String, label: String)
    /// Branch › New Worktree…
    case newWorktree
    /// Add Key… under an SSH signature git couldn't verify.
    case addSigningKey(commitID: String, signer: String)

    var id: String {
        switch self {
        case .newBranch(let startPoint, _): "newBranch-\(startPoint ?? "HEAD")"
        case .stash: "stash"
        case .switchWithChanges(let ref): "switch-\(ref.id)"
        case .pullThenPush: "pullThenPush"
        case .renameBranch(let ref): "rename-\(ref.id)"
        case .newTag(let commitID, _): "newTag-\(commitID)"
        case .chooseBranch(let choice): "choose-\(choice)"
        case .signIn(let problem): "signIn-\(problem.id)"
        case .log(let title, _): "log-\(title)"
        case .branchFromStash(let stash): "branchFromStash-\(stash.id)"
        case .repositorySettings: "repositorySettings"
        case .interactiveRebase(let onto, _): "interactiveRebase-\(onto)"
        case .newWorktree: "newWorktree"
        case .addSigningKey(let commitID, _): "addSigningKey-\(commitID)"
        }
    }
}

enum BranchChoice: Hashable {
    case merge
    case rebase
}

/// Actions that ask first. Local changes don't — they're undone with ⌘Z instead — so this is
/// for what can't be taken back (remote changes) or a hard reset. The confirm button is never
/// the default button.
enum Confirmation: Identifiable {
    case forcePush(branch: String)
    case abortOperation(OperationState.Kind)
    case deleteRemoteBranch(Ref)
    /// `git branch -d` would refuse: the branch has commits that aren't merged anywhere.
    case forceDeleteBranch(Ref)
    case resetHard(Commit, leaving: Int)
    /// Use SSH Instead…: change the remote's URL to its SSH address.
    case useSSH(remote: String, url: String, retry: RemoteAction)

    var id: String {
        switch self {
        case .forcePush(let branch): "forcePush-\(branch)"
        case .abortOperation(let kind): "abort-\(kind.rawValue)"
        case .deleteRemoteBranch(let ref): "deleteRemote-\(ref.id)"
        case .forceDeleteBranch(let ref): "forceDelete-\(ref.id)"
        case .resetHard(let commit, _): "resetHard-\(commit.id)"
        case .useSSH(let remote, let url, _): "useSSH-\(remote)-\(url)"
        }
    }
}

/// Staged and unstaged changes of one working-copy file.
struct WorkingDiff: Equatable {
    var entry: StatusEntry
    var staged: FileDiff?
    var unstaged: FileDiff?
    /// Loaded with Ignore Whitespace: the hunks don't match the file exactly, so they can't be
    /// staged or discarded one at a time.
    var ignoresWhitespace = false
}

enum DiffContent: Equatable {
    case working(WorkingDiff)
    case commit(Commit, FileChange, FileDiff)
}

/// Everything one repository window shows. Owned by the window; git work runs off the main actor
/// inside KaernKit and results are applied here.
