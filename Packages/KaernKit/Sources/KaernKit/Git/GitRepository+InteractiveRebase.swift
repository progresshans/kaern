import Foundation

/// One line of an interactive rebase.
public struct RebaseStep: Sendable, Hashable, Identifiable {
    public enum Action: String, CaseIterable, Sendable {
        case pick
        case reword
        case edit
        case squash
        case fixup
        case drop

        /// The key that picks the action in the list (P R E S F D).
        public var key: Character { rawValue.first! }

        /// Squash and fixup fold into the commit above.
        public var joinsPrevious: Bool { self == .squash || self == .fixup }
    }

    public var commit: Commit
    public var action: Action
    /// Reword: the new message.
    public var message: String?

    public var id: String { commit.id }

    public init(commit: Commit, action: Action = .pick, message: String? = nil) {
        self.commit = commit
        self.action = action
        self.message = message
    }
}

extension GitRepository {
    /// The commits a rebase onto `base` replays, oldest first (merges are flattened, as
    /// `git rebase -i` does).
    public func commitsToRebase(onto base: String) async throws -> [Commit] {
        let output = try await git(["log", "--reverse", "--no-merges", "-z", "--format=\(LogParser.format)", "\(base)..HEAD", "--"])
        return LogParser.parse(output.stdout)
    }

    /// Commits of HEAD that aren't on its upstream yet (`@{upstream}..HEAD`); `nil` without an upstream.
    public func unpushedCommits() async -> Set<String>? {
        guard let output = try? await git(["rev-list", "@{upstream}..HEAD"]) else { return nil }
        return Set(output.text.split(separator: "\n").map(String.init))
    }

    /// `git rebase -i` with Kaern's list instead of an editor. Reword's new messages are applied
    /// right after each pick. Stops like any rebase: on conflicts, and at `edit` lines.
    public func interactiveRebase(onto base: String, steps: [RebaseStep], autostash: Bool) async throws -> OperationOutcome {
        let folder = gitDirectory.appending(path: "kaern-rebase", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var lines: [String] = []
        for (index, step) in steps.enumerated() {
            if step.action == .reword, let message = step.message {
                lines.append("pick \(step.commit.id)")
                let file = folder.appending(path: "message-\(index)")
                try Data(message.utf8).write(to: file)
                lines.append("exec git commit --amend --allow-empty --no-verify --cleanup=whitespace -F \(Self.shellQuoted(file.path(percentEncoded: false)))")
            } else {
                lines.append("\(step.action.rawValue) \(step.commit.id)")
            }
        }
        let todo = folder.appending(path: "todo")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: todo)
        // git runs the sequence editor with the todo file's path; copying ours over it is the edit.
        var arguments = ["-c", "sequence.editor=cp \(Self.shellQuoted(todo.path(percentEncoded: false)))", "rebase", "-i"]
        if autostash { arguments.append("--autostash") }
        arguments.append(base)
        return try await runStoppable(arguments)
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
