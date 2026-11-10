import Foundation
import KaernKit

/// The center screens besides the graph and Review.
enum CenterScreen: Equatable {
    /// A stash's changes (its object id), with its details on the right.
    case stash(String)
    /// The conflict editor, with Resolve Conflicts on the right.
    case conflicts
    /// File History or Blame of one file (`RepositoryModel.explore`).
    case explore
}

/// The conflict editor's state: which files stopped, the one shown, and the blocks picked so far.
struct ConflictSession: Equatable {
    /// Files that were conflicted when the editor opened; resolved ones stay listed with ✓.
    var files: [String]
    var path: String?
    /// The file as it was read (markers included).
    var original: ConflictDocument?
    /// The side picked for each block (by index), not written to the file yet.
    var choices: [Int: ConflictDocument.Resolution] = [:]
    /// Editing the result directly: its text.
    var editingText: String?
    /// The message for the commit the operation makes next.
    var message = ""
    var messageEdited = false
    /// The commit being replayed, picked or reverted: its subject.
    var incomingSubject: String?

    /// The result with the picked blocks applied (open blocks keep their markers).
    var result: ConflictDocument? {
        guard let original else { return nil }
        var resolutions: [Int: [String]] = [:]
        for (index, choice) in choices where index < original.blocks.count {
            let block = original.blocks[index]
            switch choice {
            case .ours: resolutions[index] = block.ours
            case .theirs: resolutions[index] = block.theirs
            case .both: resolutions[index] = block.ours + block.theirs
            }
        }
        return original.applying(resolutions)
    }

    var openBlocks: Int {
        guard let original else { return 0 }
        return (0..<original.conflictCount).count { choices[$0] == nil }
    }
}

/// Where an action that stopped on conflicts began (for ⌘Z once it's finished).
struct OperationStart: Equatable {
    var label: String
    var branch: String?
    var head: String
    /// Uncommitted changes Kaern put in the stash list first.
    var kept: String?
}

/// The green bar after an operation finished.
struct OperationFinish: Equatable {
    let id = UUID()
    var title: String
    var detail: String
}

/// Who "ours" and "theirs" are, in the words the editor uses.
struct ConflictSideNames {
    /// A long branch name cut in the middle for buttons ("feature/re…matic-alpha").
    static func buttonName(_ name: String, limit: Int = 20) -> String {
        guard name.count > limit else { return name }
        let head = (limit - 1) / 2, tail = limit - 1 - head
        return String(name.prefix(head)) + "…" + String(name.suffix(tail))
    }

    /// "develop · 55b2d9a"
    var oursTitle: String
    /// "the branch you are rebasing onto"
    var oursNote: String
    /// What "Use …" calls it ("develop").
    var oursShort: String
    var theirsTitle: String
    var theirsNote: String
    var theirsShort: String
}

extension RepositoryModel {
    /// A merge, rebase, cherry-pick or revert waits, or a stash stopped on conflicts.
    var isMidOperation: Bool { operation != nil || stashConflict != nil }

    /// Conflicted files right now.
    var conflictedPaths: [String] { status.entries.filter(\.isConflicted).map(\.path) }

    /// Files the operation staged without conflicts ("Merged automatically").
    var mergedAutomatically: [StatusEntry] {
        let conflicted = Set(conflictSession?.files ?? []).union(conflictedPaths)
        return status.entries.filter { $0.hasStagedChanges && !$0.isConflicted && !conflicted.contains($0.path) }
    }

    // MARK: Opening the editor

    /// Opens the conflict editor on `path` (or the first file still in conflict).
    func openConflicts(path: String? = nil) {
        let current = conflictedPaths
        var files = conflictSession?.files ?? []
        for file in current where !files.contains(file) { files.append(file) }
        if files.isEmpty { files = current }
        guard !files.isEmpty else { return }
        var session = conflictSession ?? ConflictSession(files: files)
        session.files = files
        if !session.messageEdited { session.message = operation?.message ?? "" }
        conflictSession = session
        review = nil
        clearPicks()
        screen = .conflicts
        showConflict(path ?? current.first ?? files[0])
        loadIncomingSubject()
    }

    /// Shows one conflicted file (reads it from disk).
    func showConflict(_ path: String) {
        guard var session = conflictSession else { return }
        session.path = path
        session.choices = [:]
        session.editingText = nil
        session.original = repository?.conflictDocument(path)
        conflictSession = session
    }

    private func loadIncomingSubject() {
        guard let repository, let id = stashConflict == nil ? operation?.incoming : nil else { return }
        if let commit = commit(id) {
            conflictSession?.incomingSubject = commit.subject
            return
        }
        Task {
            let subject = try? await GitCommandTrigger.$current.withValue(.background("Conflict editor")) {
                try await repository.commit(id).subject
            }
            conflictSession?.incomingSubject = subject
        }
    }

    var conflictSides: ConflictSideNames {
        let head = status.headID.map(short) ?? "HEAD"
        let branch = status.branch ?? operation?.branch
        if let conflict = stashConflict {
            return ConflictSideNames(
                oursTitle: "\(branch ?? "HEAD") · \(head)", oursNote: "what’s committed now", oursShort: ConflictSideNames.buttonName(branch ?? head),
                theirsTitle: "\(conflict.stash.reference) · \(Self.stashTitle(conflict.stash))", theirsNote: "the stash being applied",
                theirsShort: conflict.stash.reference)
        }
        guard let operation else {
            return ConflictSideNames(oursTitle: "Ours", oursNote: "", oursShort: "Ours", theirsTitle: "Theirs", theirsNote: "", theirsShort: "Theirs")
        }
        let incoming = operation.incoming.map(short) ?? "?"
        let subject = conflictSession?.incomingSubject.map { " · " + $0 } ?? ""
        switch operation.kind {
        case .rebase:
            let onto = operation.onto.map { ontoName($0) } ?? "the base"
            let ontoShort = operation.onto.map(short) ?? ""
            return ConflictSideNames(
                oursTitle: onto == ontoShort ? onto : "\(onto) · \(ontoShort)", oursNote: "the branch you are rebasing onto", oursShort: ConflictSideNames.buttonName(onto),
                theirsTitle: incoming + subject, theirsNote: "the commit being replayed", theirsShort: incoming)
        case .merge:
            let name = operation.incomingName ?? incoming
            return ConflictSideNames(
                oursTitle: "\(branch ?? "HEAD") · \(head)", oursNote: "your branch", oursShort: ConflictSideNames.buttonName(branch ?? head),
                theirsTitle: name == incoming ? name : "\(name) · \(incoming)", theirsNote: "the branch you are merging",
                theirsShort: ConflictSideNames.buttonName(name))
        case .cherryPick:
            return ConflictSideNames(
                oursTitle: "\(branch ?? "HEAD") · \(head)", oursNote: "your branch", oursShort: ConflictSideNames.buttonName(branch ?? head),
                theirsTitle: incoming + subject, theirsNote: "the commit being cherry-picked", theirsShort: incoming)
        case .revert:
            return ConflictSideNames(
                oursTitle: "\(branch ?? "HEAD") · \(head)", oursNote: "your branch", oursShort: ConflictSideNames.buttonName(branch ?? head),
                theirsTitle: incoming + subject, theirsNote: "the commit being reverted", theirsShort: incoming)
        }
    }

    /// The branch at `id` ("develop"), or its short hash.
    private func ontoName(_ id: String) -> String {
        if let local = refs.localBranches.first(where: { $0.target == id }) { return local.name }
        if let remote = refs.remoteBranches.first(where: { $0.target == id }) { return remote.name }
        return short(id)
    }

    // MARK: Picking sides

    func pickConflict(_ index: Int, _ resolution: ConflictDocument.Resolution) {
        conflictSession?.choices[index] = resolution
    }

    func unpickConflict(_ index: Int) {
        conflictSession?.choices[index] = nil
    }

    /// Keep develop / Keep 7b1e04d / Keep Both: every block of the file.
    func keepAll(_ resolution: ConflictDocument.Resolution) {
        guard let count = conflictSession?.original?.conflictCount else { return }
        for index in 0..<count { conflictSession?.choices[index] = resolution }
    }

    /// Switches the result to a text editor, or reads the edited text back.
    func toggleDirectEdit() {
        guard var session = conflictSession else { return }
        if let text = session.editingText {
            session.original = ConflictDocument(text: text)
            session.choices = [:]
            session.editingText = nil
        } else {
            session.editingText = session.result?.text ?? ""
        }
        conflictSession = session
    }

    /// Mark Resolved: writes the result and stages the file. Then the next open file shows.
    func markResolved() {
        guard let session = conflictSession, let path = session.path else { return }
        let text: String
        if let editing = session.editingText {
            text = editing
        } else {
            guard let result = session.result, !result.hasConflicts else { return }
            text = result.text
        }
        if ConflictDocument(text: text).hasConflicts { return }
        perform(.working("Marking \((path as NSString).lastPathComponent) resolved…"), trigger: "Mark Resolved") { [weak self] repository in
            try await repository.writeResolution(text, to: path)
            guard let self else { return }
            let remaining = await repository.unmergedPaths()
            if let next = remaining.first {
                self.showConflict(next)
            } else {
                self.conflictSession?.path = path
                self.conflictSession?.original = ConflictDocument(text: text)
                self.conflictSession?.choices = [:]
                self.conflictSession?.editingText = nil
                self.allConflictsResolved()
            }
        }
    }

    /// Takes one side of the whole file as it is in git (for deleted or binary files too).
    func resolveWholeFile(_ path: String, side: ConflictSide) {
        perform(.working("Resolving \((path as NSString).lastPathComponent)…"), trigger: "Resolve \(path)") { [weak self] repository in
            try await repository.resolveConflict(path, taking: side)
            guard let self else { return }
            if let next = await repository.unmergedPaths().first { self.showConflict(next) } else { self.allConflictsResolved() }
        }
    }

    private func allConflictsResolved() {
        if let conflict = stashConflict {
            stashConflict = nil
            screen = nil
            showToast("Resolved the conflicts from \(conflict.stash.reference) · it stays in Stashes until you drop it")
        } else if let operation {
            showToast("All conflicts resolved · Continue the \(operation.kind.title.lowercased()) in the bar above")
        }
    }

    func openInFileMerge(_ path: String) {
        guard let repository else { return }
        Task {
            try? await GitCommandTrigger.$current.withValue(GitCommandTrigger(triggerName("Open in FileMerge"))) {
                try await repository.openMergeTool(path)
            }
            showConflict(path)
        }
    }

    // MARK: The operation

    /// A stop on conflicts: the conflict editor opens (and the operation bar shows what's going on).
    /// `start`: where the action began, so finishing it can be undone and an abort brings the
    /// put-aside changes back.
    func stoppedOnConflicts(_ what: String, start: OperationStart? = nil) {
        conflictSession = nil
        operationStart = start
        Task {
            // The status that lists the conflicts comes first.
            await refreshStatusNow()
            openConflicts()
        }
        if start?.kept != nil {
            showToast("\(what) stopped on conflicts · your uncommitted changes wait in Stashes until it’s done")
        }
    }

    func abortOperation() {
        guard let operation else { return }
        let name = operation.kind.title
        let start = operationStart
        perform(.working("Aborting the \(name.lowercased())…"), trigger: "Abort \(name)") { [weak self] repository in
            try await repository.abortOperation(operation.kind)
            guard let self else { return }
            self.operationStart = nil
            self.closeConflicts()
            if let kept = start?.kept {
                // The uncommitted changes put aside before it started come back as they were.
                do {
                    try await repository.popStash(object: kept)
                } catch {
                    self.showToast("Aborted the \(name.lowercased()) · your changes are still in Stashes")
                    return
                }
            }
            self.showToast("Aborted the \(name.lowercased()) · everything is as it was before")
        }
    }

    func skipOperationCommit() {
        guard let operation, operation.kind.canSkip else { return }
        let name = operation.kind.title
        let skipped = operation.incoming.map(short) ?? "the commit"
        perform(.working("Skipping \(skipped)…"), trigger: "Skip Commit") { [weak self] repository in
            let outcome = try await repository.skipOperationStep(operation.kind)
            guard let self else { return }
            self.conflictSession = nil
            if outcome == .stopped, !(await repository.unmergedPaths()).isEmpty {
                self.reopenConflictsAfterRefresh()
                self.showToast("Skipped \(skipped) · the next commit has conflicts too")
            } else if outcome == .stopped {
                self.closeConflicts()
                self.showToast("Skipped \(skipped)")
            } else {
                self.finished(operation, name: name)
            }
        }
    }

    func continueOperation() {
        guard let operation else { return }
        let name = operation.kind.title
        let message = conflictSession?.messageEdited == true ? conflictSession?.message : nil
        perform(.working("Continuing the \(name.lowercased())…"), trigger: "Continue \(name)") { [weak self] repository in
            let outcome = try await repository.continueOperation(operation, message: message)
            guard let self else { return }
            self.conflictSession = nil
            if outcome == .stopped {
                if !(await repository.unmergedPaths()).isEmpty {
                    self.reopenConflictsAfterRefresh()
                } else {
                    self.closeConflicts()
                    self.showToast("The \(name.lowercased()) stopped at the next step")
                }
            } else {
                self.finished(operation, name: name)
            }
        }
    }

    /// Opens the editor again once the status shows the next commit's conflicts.
    private func reopenConflictsAfterRefresh() {
        Task {
            // Reads the operation too.
            await refreshStatusNow()
            openConflicts()
        }
    }

    private func finished(_ operation: OperationState, name: String) {
        closeConflicts()
        let wasPull = operationStart?.label == "Pull"
        if let start = operationStart {
            operationStart = nil
            Task { await recordFinishedOperation(start) }
        }
        var detail = ""
        switch operation.kind {
        case .rebase where wasPull:
            // Pull (rebase): your commits now sit on what was pulled; a plain push sends them.
            let branch = operation.branch ?? status.branch ?? "The branch"
            detail = "\(branch) has what \(status.upstream ?? "its upstream") had, with your commits on top."
        case .rebase:
            let branch = operation.branch ?? status.branch ?? "The branch"
            let onto = operation.onto.map { ontoName($0) } ?? "its base"
            detail = "\(branch) now sits on top of \(onto)"
            if status.upstream != nil { detail += " — push with lease to update \(defaultRemote ?? "origin")." } else { detail += "." }
        case .merge:
            detail = "\(operation.incomingName ?? operation.incoming.map(short) ?? "The branch") is merged into \(status.branch ?? "HEAD")."
        case .cherryPick:
            detail = "\(operation.incoming.map(short) ?? "The commit") is on \(status.branch ?? "HEAD")."
        case .revert:
            detail = "\(operation.incoming.map(short) ?? "The commit") is reverted on \(status.branch ?? "HEAD")."
        }
        let finish = OperationFinish(title: "\(name) finished.", detail: detail)
        operationFinish = finish
        Task {
            try? await Task.sleep(for: .seconds(10))
            if operationFinish?.id == finish.id { operationFinish = nil }
        }
    }

    /// ⌘Z for an operation that stopped on the way: back to where it started. Changes that were
    /// put aside come back now that it's done.
    private func recordFinishedOperation(_ start: OperationStart) async {
        guard let repository, let after = await repository.resolve("HEAD"), after != start.head else { return }
        var kept = start.kept
        if let object = kept {
            if (try? await repository.popStash(object: object)) != nil { kept = nil }
            noteOwnChange()
        }
        if let kept {
            record(.moveBranchKeepingStash(label: start.label, branch: start.branch, from: start.head, to: after, stash: kept), toast: nil)
            showToast("Your uncommitted changes touch the same files, so they’re still in Stashes")
        } else {
            record(.moveBranch(label: start.label, branch: start.branch, from: start.head, to: after), toast: nil)
        }
        await refreshStatusNow()
    }

    func closeConflicts() {
        conflictSession = nil
        if screen == .conflicts { screen = nil }
    }

    /// Undo Pop (or Apply) after a stash stopped on conflicts.
    func takeBackStashConflict() {
        guard let conflict = stashConflict else { return }
        perform(.working("Undoing the \(conflict.wasPop ? "pop" : "apply")…"), trigger: "Undo \(conflict.wasPop ? "Pop" : "Apply")") { [weak self] repository in
            try await repository.takeBack(conflict)
            self?.stashConflict = nil
            self?.closeConflicts()
            self?.showToast("Undid the partial \(conflict.wasPop ? "pop" : "apply") · your working copy is as it was")
        }
    }

    /// After a refresh: the editor keeps up with conflicts resolved elsewhere (Terminal, an editor).
    func conflictsChanged() {
        // Only a status read after everything Kaern did itself says what's resolved. One from
        // before a stash pop stopped on its conflict lists no conflicted file either.
        guard statusIsCurrent else { return }
        if let conflict = stashConflict, conflictedPaths.isEmpty, activity == nil {
            // Resolved outside Kaern (or by Mark Resolved).
            stashConflict = nil
            if screen == .conflicts { screen = nil }
            showToast("Resolved the conflicts from \(conflict.stash.reference) · it stays in Stashes until you drop it")
        }
        if screen == .conflicts, operation == nil, stashConflict == nil, activity == nil {
            closeConflicts()
        }
        guard screen == .conflicts, var session = conflictSession else { return }
        var changed = false
        for path in conflictedPaths where !session.files.contains(path) {
            session.files.append(path)
            changed = true
        }
        if changed { conflictSession = session }
    }
}
