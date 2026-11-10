import AppKit
import Foundation
import KaernKit

// MARK: - The stash view

extension RepositoryModel {
    /// Opens a stash in the center (its files' diffs) with its details on the right.
    func openStash(_ id: String) {
        review = nil
        clearPicks()
        screen = .stash(id)
    }

    /// The stash entry the stash view shows (it may have moved in the list).
    var shownStash: Stash? {
        guard case .stash(let id) = screen else { return nil }
        return stashes.first { $0.id == id }
    }

    func loadStashDetails(_ id: String) {
        stashTask?.cancel()
        if stashDetails?.stash.id != id { stashDetails = nil }
        guard let repository, let stash = stashes.first(where: { $0.id == id }) else { return }
        stashTask = Task {
            let details = try? await GitCommandTrigger.$current.withValue(.background("Stash view")) {
                try await repository.stashDetails(stash)
            }
            guard !Task.isCancelled, let details else { return }
            stashDetails = details
        }
    }

    /// After a refresh that read the repository as Kaern left it (not one an action ended in the
    /// middle of): the stash view follows its stash (or shows that it's gone), and the conflict
    /// editor follows the conflicts.
    func screenStateChanged() {
        if case .stash(let id) = screen {
            if let stash = stashes.first(where: { $0.id == id }) {
                if stashDetails?.stash.id != id || stashDetails?.stash.index != stash.index || stashDetails?.stash.message != stash.message {
                    loadStashDetails(id)
                }
            } else if activity == nil, let first = stashes.first, stashDetails?.stash.id == id {
                // Dropped or popped: the next stash shows, like the board's list. Not while an
                // action runs: a rename takes its stash out of the list and puts it back, and a
                // pop closes the view itself. The refresh after the action looks again.
                screen = .stash(first.id)
            }
        }
        conflictsChanged()
    }

    /// The stash's files as Review files.
    var stashReviewFiles: [ReviewFile]? {
        guard let details = stashDetails, case .stash(let id) = screen, details.stash.id == id else { return nil }
        return details.files.map { diff in
            let letter = diff.isNewFile ? "A" : diff.isDeletedFile ? "D" : diff.oldPath != nil ? "R" : "M"
            let stat = diff.lineStat
            var file = ReviewFile(path: diff.path, letter: letter, additions: stat.additions ?? 0, deletions: stat.deletions ?? 0)
            file.hunks = diff.hunks.map { ReviewHunk(id: "t\($0.id)", hunk: $0, stage: .committed, path: diff.path) }
            if diff.isBinary { file.note = "Binary file" } else if diff.hunks.isEmpty { file.note = "No line changes (mode or type only)" }
            return file
        }
    }

    // MARK: Stash actions

    /// Create Branch from Stash…: a new branch where the stash was made, with the stash applied
    /// and dropped (`git stash branch`).
    func askBranchFromStash(_ stash: Stash) {
        let suggestion = Self.stashTitle(stash).lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "/" || $0 == "_" || $0 == "." }
        showBranchSheet(BranchSheetRequest(kind: .fromStash(stash), name: String(suggestion.prefix(40))))
    }

    func createBranch(_ name: String, from stash: Stash) {
        guard let shown = headPosition else { return }
        let label = "Create Branch \(name) from \(stash.reference)"
        perform(.creatingBranch(name), trigger: label) { [weak self] repository in
            // HEAD as git has it now, not as the status showed it (see `headNow`).
            let now = await Self.headNow(in: repository)
            let previous = now.map { HeadPosition(branch: $0.branch, id: $0.id) } ?? shown
            try await repository.createBranch(name, from: stash)
            guard let self, let tip = await repository.resolve("HEAD") else { return }
            self.screen = nil
            self.record(.createdBranch(label: label, name: name, at: tip, upstream: nil, previous: previous),
                        toast: "Created \(name) where \(stash.reference) was made · its changes are applied and the stash is gone")
        }
    }

    /// Rename…: a new message for the stash; it keeps its place in the list. ⌘Z names it back.
    func renameStash(_ stash: Stash, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != Self.stashTitle(stash) else { return }
        let prefix = stash.message.firstIndex(of: ":").map { String(stash.message[...$0]) + " " } ?? ""
        let message = prefix + trimmed
        perform(.working("Renaming \(stash.reference)…"), trigger: "Rename \(stash.reference)") { [weak self] repository in
            try await repository.renameStash(stash, to: message)
            self?.record(.renamedStash(object: stash.id, from: stash.message, to: message),
                         toast: "Renamed \(stash.reference) to “\(trimmed)”")
        }
    }

    func copyStashName(_ stash: Stash) {
        copy(stash.reference, toast: "Copied \(stash.reference)")
    }
}
