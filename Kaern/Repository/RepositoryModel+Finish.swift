import Foundation
import KaernKit

/// How Finish Feature goes about it. Kept per repository: the next Finish starts with them.
nonisolated struct FinishOptions: Equatable, Sendable {
    /// A merge commit even when the target could fast-forward (`--no-ff`): the feature's commits
    /// stay together in the graph, under one commit that says what they were.
    var mergeCommit = true
    var deleteBranch = true
    /// Replays the feature on the target before it's merged.
    var rebaseFirst = false

    init(mergeCommit: Bool = true, deleteBranch: Bool = true, rebaseFirst: Bool = false) {
        self.mergeCommit = mergeCommit
        self.deleteBranch = deleteBranch
        self.rebaseFirst = rebaseFirst
    }

    /// From what the settings keep: "merge,delete,rebase", each there when it's on.
    init(stored: String) {
        let parts = Set(stored.split(separator: ",").map(String.init))
        self.init(mergeCommit: parts.contains("merge"), deleteBranch: parts.contains("delete"), rebaseFirst: parts.contains("rebase"))
    }

    var stored: String {
        [mergeCommit ? "merge" : nil, deleteBranch ? "delete" : nil, rebaseFirst ? "rebase" : nil].compactMap { $0 }.joined(separator: ",")
    }
}

/// Finish Feature…: `branch` goes into `target`.
struct FinishSheetRequest: Equatable {
    var branch: String
    var target: String
}

/// Finish Feature (Gitflow's, as GitKraken has it): a feature branch goes into develop in one
/// step, with a merge commit that says what it was, and leaves or stays as the repository last chose.
extension RepositoryModel {
    /// Gitflow's prefix for a feature branch.
    nonisolated static let featurePrefix = "feature/"

    /// Where a finished feature goes: develop, in a repository that has one.
    var finishTarget: String? { refs.localBranch(named: "develop") != nil ? "develop" : nil }

    /// A local feature/… branch, in a repository with a develop branch.
    func canFinish(_ name: String) -> Bool {
        name.hasPrefix(Self.featurePrefix) && name.count > Self.featurePrefix.count
            && finishTarget != nil && refs.localBranch(named: name) != nil
    }

    var finishOptions: FinishOptions {
        get {
            let kept = (UserDefaults.kaern.dictionary(forKey: SettingsKey.finishOptions) as? [String: String])?[path]
            return kept.map(FinishOptions.init(stored:)) ?? FinishOptions()
        }
        set {
            var kept = UserDefaults.kaern.dictionary(forKey: SettingsKey.finishOptions) as? [String: String] ?? [:]
            kept[path] = newValue.stored
            UserDefaults.kaern.set(kept, forKey: SettingsKey.finishOptions)
        }
    }

    func askFinish(branch name: String) {
        guard canFinish(name), let target = finishTarget else { return }
        sheet = .finish(FinishSheetRequest(branch: name, target: target))
    }

    /// What the sheet's message starts as: "Merge feature/zoom: ", to go on with what the feature was.
    nonisolated static func finishMessageStart(for branch: String) -> String { "Merge \(branch): " }

    /// The merge commit's message from what was typed: left as it started, it's "Merge feature/zoom".
    nonisolated static func finishMessage(_ typed: String, for branch: String) -> String {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = finishMessageStart(for: branch).trimmingCharacters(in: .whitespaces)
        return text.isEmpty || text == start ? "Merge \(branch)" : text
    }

    /// The sheet's Finish: the choices are kept for this repository, then the branch is finished.
    func confirmFinish(_ request: FinishSheetRequest, message: String, options: FinishOptions) {
        finishOptions = options
        finish(branch: request.branch, into: request.target, message: message, options: options)
    }

    /// Goes to `target` and merges `name` into it, after replaying `name` on `target` when asked,
    /// then deletes `name` when asked. Each step is one ⌘Z can take back, last one first. A rebase
    /// or a merge that stops on conflicts ends it there: the rest is Kaern's usual way from then on.
    func finish(branch name: String, into target: String, message: String, options: FinishOptions) {
        guard let shown = headPosition, let ref = refs.localBranch(named: name), name != target else { return }
        let label = "Finish \(name)"
        let text = Self.finishMessage(message, for: name)
        perform(.working("Finishing \(name)…"), trigger: label) { [weak self] repository in
            // HEAD as git has it now, not as the status showed it (see `headNow`).
            let now = await Self.headNow(in: repository)
            var position = now.map { HeadPosition(branch: $0.branch, id: $0.id) } ?? shown
            @MainActor func switchTo(_ branch: String) async throws {
                guard position != .branch(branch) else { return }
                try await repository.switchBranch(branch)
                self?.record(.checkout(label: "Checkout \(branch)", from: position, to: .branch(branch)), toast: nil)
                position = .branch(branch)
            }
            if options.rebaseFirst {
                try await switchTo(name)
                guard let before = await repository.resolve("HEAD") else { return }
                let rebase = "Rebase onto \(target)"
                let result = try await repository.withChangesStashed(message: "Before \(rebase)") {
                    try await repository.rebase(onto: target)
                }
                guard result.outcome == .finished, let after = await repository.resolve("HEAD") else {
                    self?.stoppedOnConflicts("Rebase", start: OperationStart(label: rebase, branch: name, head: before, kept: result.kept))
                    return
                }
                if after != before {
                    self?.recordMove(label: rebase, branch: name, from: before, to: after, kept: result.kept, toast: nil)
                }
            }
            try await switchTo(target)
            guard let before = await repository.resolve("HEAD") else { return }
            let result = try await repository.withChangesStashed(message: "Before \(label)") {
                try await repository.merge(name, fastForward: options.mergeCommit ? .never : .allowed, message: text)
            }
            guard let self else { return }
            guard result.outcome == .finished, let after = await repository.resolve("HEAD") else {
                self.stoppedOnConflicts("Merge", start: OperationStart(label: label, branch: target, head: before, kept: result.kept))
                return
            }
            guard after != before else {
                self.showToast("\(name) is already part of \(target)")
                return
            }
            let tip = await repository.resolve("refs/heads/\(name)") ?? ref.target
            let merged = tip == after ? "Fast-forwarded \(target) to \(name)" : "Merged \(name) into \(target) with \(self.short(after))"
            guard options.deleteBranch else {
                self.recordMove(label: label, branch: target, from: before, to: after, kept: result.kept, toast: merged)
                return
            }
            self.recordMove(label: label, branch: target, from: before, to: after, kept: result.kept, toast: nil)
            try await repository.deleteBranch(name, force: true)
            self.record(.deletedBranch(name: name, tip: tip, upstream: ref.upstream), toast: merged + " · deleted \(name)")
        }
    }
}
