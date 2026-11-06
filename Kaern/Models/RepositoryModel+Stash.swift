import AppKit
import Foundation
import KaernKit

/// A stash picked in the sidebar.
struct StashViewState: Equatable {
    var stash: Stash
    /// `nil` while loading.
    var details: StashDetails?
    var error: String?
    /// A file picked in the inspector, for the center to scroll to.
    var scrollTarget: String?
    var scrollRequest = 0
}

extension RepositoryModel {
    func showStash(_ stash: Stash) {
        guard stashView?.stash.id != stash.id else { return }
        fileHistory = nil
        selectedFile = nil
        stashView = StashViewState(stash: stash)
        Task { await loadStashDetails() }
    }

    func closeStash() {
        guard stashView != nil else { return }
        stashView = nil
        historyFocusRequest += 1
    }

    func loadStashDetails() async {
        guard let repository, let stash = stashView?.stash else { return }
        do {
            let details = try await repository.stashDetails(stash)
            guard stashView?.stash.id == stash.id else { return }
            stashView?.details = details
            stashView?.error = nil
        } catch {
            guard stashView?.stash.id == stash.id else { return }
            stashView?.error = error.localizedDescription
        }
    }

    func scrollStash(to path: String) {
        stashView?.scrollTarget = path
        stashView?.scrollRequest += 1
    }

    /// Based on: the commit the stash was made on, in the history.
    func showStashBase(_ id: String) {
        stashView = nil
        if commitIndex[id] != nil {
            selection = .commit(id)
        } else {
            Task { await loadHistory(until: id) }
        }
    }

    /// Apply puts the stash's changes into the working tree; Pop also takes it off the list
    /// (git keeps it when applying conflicts). Both are undone with ⌘Z: back to how the
    /// working tree was, and a popped stash returns to the list.
    func apply(_ stash: Stash, pop: Bool) async {
        guard let repository else { return }
        let name = pop ? String(localized: "Pop Stash") : String(localized: "Apply Stash")
        let title = pop ? String(localized: "Couldn't Pop Stash") : String(localized: "Couldn't Apply Stash")
        // What the working tree looked like, to put it back.
        let before = await repository.stashCreate()
        let untrackedBefore = Set(await repository.untrackedFiles())
        let applied = await perform(.working(String(localized: "Applying stash…")), failureTitle: title) { repository in
            try await repository.applyStash(stash, pop: pop)
        }
        guard applied else { return }
        let after = await repository.stashCreate()
        let afterTree: String? = if let after { await repository.treeID(of: after) } else { nil }
        let added = Set(await repository.untrackedFiles()).subtracting(untrackedBefore).sorted()
        let root = repository.root
        let hint = pop ? String(localized: "Popped “\(stash.message)”") : String(localized: "Applied “\(stash.message)”")
        registerUndo(name, hint: hint) { model in
            await model.undoStep(name) { repository in
                // Edits made since the apply go to the stash list first, so nothing is lost.
                if let now = await repository.stashCreate(), await repository.treeID(of: now) != afterTree {
                    try await repository.storeStash(now, message: "Before undoing \(name.lowercased()) of “\(stash.message)”")
                }
                try await repository.reset(to: "HEAD", mode: .hard)
                if let before {
                    try await repository.applyStash(object: before)
                }
                // Files the stash brought back as untracked go to the Trash.
                for path in added {
                    let url = root.appending(path: path)
                    if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    }
                }
                if pop {
                    try await repository.storeStash(stash.id, message: stash.message)
                }
            }
        }
    }

    /// Create Branch from Stash: a branch at the commit the stash was made on, with the stash's
    /// changes in the working tree (the stash leaves the list).
    func createBranch(_ name: String, from stash: Stash) async {
        let created = await perform(.working(String(localized: "Creating “\(name)”…")),
                                    failureTitle: String(localized: "Couldn't Create Branch from Stash")) { repository in
            try await repository.createBranch(name, from: stash)
        }
        if created {
            stashView = nil
            didRenameBranch(from: name, to: name)
        }
    }
}
