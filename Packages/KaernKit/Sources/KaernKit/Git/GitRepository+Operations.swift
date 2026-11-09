import Foundation

// MARK: - Merge, rebase, cherry-pick, revert

extension GitRepository {
    public enum FastForward: Sendable, Hashable {
        /// Fast-forward when possible, otherwise make a merge commit.
        case allowed
        /// Always make a merge commit (`--no-ff`).
        case never
        /// Only fast-forward (`--ff-only`).
        case only
    }

    /// The operation in progress, read from the files git keeps in the git directory (no process).
    public func operationState() -> OperationState? {
        let fileManager = FileManager.default
        func path(_ name: String) -> String { gitDirectory.appending(path: name).path(percentEncoded: false) }
        func exists(_ name: String) -> Bool { fileManager.fileExists(atPath: path(name)) }
        func read(_ name: String) -> String? {
            fileManager.contents(atPath: path(name)).map { String(decoding: $0, as: UTF8.self) }
        }
        func firstLine(_ name: String) -> String? {
            guard let text = read(name) else { return nil }
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces)
            return line?.isEmpty == false ? line : nil
        }
        func branch(fromHeadName name: String?) -> String? {
            guard let name, name.hasPrefix("refs/heads/") else { return nil }
            return String(name.dropFirst("refs/heads/".count))
        }

        if exists("rebase-merge") {
            return OperationState(
                kind: .rebase,
                branch: branch(fromHeadName: firstLine("rebase-merge/head-name")),
                onto: firstLine("rebase-merge/onto"),
                incoming: firstLine("REBASE_HEAD") ?? firstLine("rebase-merge/stopped-sha"),
                step: firstLine("rebase-merge/msgnum").flatMap(Int.init),
                total: firstLine("rebase-merge/end").flatMap(Int.init),
                message: OperationState.cleanMessage(read("rebase-merge/message") ?? read("MERGE_MSG") ?? "")
            )
        }
        // `rebase-apply` is also used by `git am`, which Kaern doesn't drive.
        if exists("rebase-apply"), !exists("rebase-apply/applying") {
            return OperationState(
                kind: .rebase,
                branch: branch(fromHeadName: firstLine("rebase-apply/head-name")),
                onto: firstLine("rebase-apply/onto"),
                incoming: firstLine("REBASE_HEAD") ?? firstLine("rebase-apply/original-commit"),
                step: firstLine("rebase-apply/next").flatMap(Int.init),
                total: firstLine("rebase-apply/last").flatMap(Int.init),
                message: OperationState.cleanMessage(read("rebase-apply/final-commit") ?? ""),
                isApplyBackend: true
            )
        }
        if let head = firstLine("MERGE_HEAD") {
            let message = read("MERGE_MSG") ?? ""
            return OperationState(
                kind: .merge,
                incoming: head,
                incomingName: OperationState.mergeSource(fromMessage: message),
                message: OperationState.cleanMessage(message)
            )
        }
        if let pick = firstLine("CHERRY_PICK_HEAD") {
            return OperationState(kind: .cherryPick, incoming: pick,
                                  message: OperationState.cleanMessage(read("MERGE_MSG") ?? ""))
        }
        if let revert = firstLine("REVERT_HEAD") {
            return OperationState(kind: .revert, incoming: revert,
                                  message: OperationState.cleanMessage(read("MERGE_MSG") ?? ""))
        }
        return nil
    }

    /// `git merge --no-edit --autostash <revision>`. Conflicts stop the merge instead of throwing.
    public func merge(_ revision: String, fastForward: FastForward = .allowed) async throws -> OperationOutcome {
        var arguments = ["merge", "--no-edit", "--autostash"]
        switch fastForward {
        case .allowed: break
        case .never: arguments.append("--no-ff")
        case .only: arguments.append("--ff-only")
        }
        arguments.append(revision)
        return try await runStoppable(arguments)
    }

    /// `git rebase --autostash <upstream>`: replays the current branch on top of `upstream`.
    public func rebase(onto upstream: String) async throws -> OperationOutcome {
        try await runStoppable(["rebase", "--autostash", upstream])
    }

    /// `git cherry-pick <commit>`.
    public func cherryPick(_ commit: String) async throws -> OperationOutcome {
        try await runStoppable(["cherry-pick", commit])
    }

    /// Continues after the conflicts are resolved. `message` replaces the prepared commit message.
    public func continueOperation(_ state: OperationState, message: String? = nil) async throws -> OperationOutcome {
        if let message, state.canEditMessage {
            let file = state.kind == .rebase ? "rebase-merge/message" : "MERGE_MSG"
            try Data((message + "\n").utf8).write(to: gitDirectory.appending(path: file))
        }
        return try await runStoppable([state.kind.command, "--continue"])
    }

    /// Skips the commit being replayed (rebase, cherry-pick, revert).
    public func skipOperationStep(_ kind: OperationState.Kind) async throws -> OperationOutcome {
        guard kind.canSkip else {
            throw GitError(arguments: [kind.command, "--skip"], status: -1, message: "A merge can't skip a commit.")
        }
        return try await runStoppable([kind.command, "--skip"])
    }

    /// Returns the repository to where it was before the operation started.
    public func abortOperation(_ kind: OperationState.Kind) async throws {
        try await git([kind.command, "--abort"])
    }

    /// Runs a command that may stop for conflicts. Exit status 1 counts as "stopped" when it left
    /// an operation waiting (a new one, or the same one at a different commit); otherwise it's an error.
    func runStoppable(_ arguments: [String], onProgress: (@Sendable (String) -> Void)? = nil) async throws -> OperationOutcome {
        let before = operationState()
        let output = try await git(arguments, accepted: [0, 1], onProgress: onProgress)
        let after = operationState()
        if output.status == 0 {
            return after == nil ? .finished : .stopped
        }
        if let after, before == nil || before?.incoming != after.incoming || before?.step != after.step {
            return .stopped
        }
        let message = output.errorText.isEmpty ? output.text : output.errorText
        throw GitError(arguments: arguments, status: output.status, message: message)
    }

    // MARK: - Resolving conflicts

    /// Stages present for a conflicted path: 1 = common ancestor, 2 = ours, 3 = theirs.
    public func conflictStages(_ path: String) async throws -> Set<Int> {
        let output = try await git(["ls-files", "--unmerged", "-z", "--", path])
        var stages = Set<Int>()
        for record in Records.splitNUL(output.stdout) {
            // <mode> SP <object> SP <stage> TAB <path>
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let fields = record[..<tab].split(separator: " ")
            if fields.count == 3, let stage = Int(fields[2]) {
                stages.insert(stage)
            }
        }
        return stages
    }

    /// Takes one side of a conflicted file whole. When that side deleted the file, it's removed.
    public func resolveConflict(_ path: String, taking side: ConflictSide) async throws {
        let stages = try await conflictStages(path)
        if !stages.contains(side == .ours ? 2 : 3) {
            try await git(["rm", "-q", "--ignore-unmatch", "--", path])
            return
        }
        try await git(["checkout", side == .ours ? "--ours" : "--theirs", "--", path])
        try await git(["add", "--", path])
    }

    /// Writes the resolved contents of a conflicted file and stages it.
    public func writeResolution(_ text: String, to path: String) async throws {
        try Data(text.utf8).write(to: root.appending(path: path))
        try await git(["add", "--", path])
    }

    /// The working-tree text of a conflicted file with its markers, `nil` when it's gone or binary.
    public func conflictDocument(_ path: String) -> ConflictDocument? {
        let url = root.appending(path: path)
        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)),
              !data.prefix(8000).contains(0),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return ConflictDocument(text: text)
    }

    /// Opens FileMerge on a conflicted file and waits until it's closed.
    public func openMergeTool(_ path: String) async throws {
        try await git(["-c", "mergetool.keepBackup=false", "mergetool", "--tool=opendiff", "--no-prompt", "--", path])
    }
}
