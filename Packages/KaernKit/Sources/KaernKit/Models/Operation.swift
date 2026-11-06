import Foundation

/// A merge, rebase, cherry-pick or revert that stopped — usually on conflicts — and waits for the
/// user to resolve, continue, skip or abort. Read from the files git keeps in the git directory.
public struct OperationState: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case merge
        case rebase
        case cherryPick
        case revert

        /// The git subcommand (`git <command> --continue`).
        public var command: String {
            switch self {
            case .merge: "merge"
            case .rebase: "rebase"
            case .cherryPick: "cherry-pick"
            case .revert: "revert"
            }
        }

        /// Merges have no "skip": there's only one commit to make.
        public var canSkip: Bool { self != .merge }
    }

    public var kind: Kind
    /// Rebase: the branch being rebased (`feature/x`); `nil` when rebasing a detached HEAD.
    public var branch: String?
    /// Rebase: the commit the branch is being replayed onto.
    public var onto: String?
    /// The commit being merged (merge), replayed (rebase), picked (cherry-pick) or reverted.
    public var incoming: String?
    /// Merge: what git says is being merged, from the prepared message (`develop`, `origin/main`).
    public var incomingName: String?
    /// Rebase progress: commit `step` of `total`, 1-based.
    public var step: Int?
    public var total: Int?
    /// The message git prepared for the commit it makes next, without comment lines.
    public var message: String
    /// The older `rebase-apply` backend, where Kaern can't change the message.
    public var isApplyBackend: Bool

    public init(
        kind: Kind,
        branch: String? = nil,
        onto: String? = nil,
        incoming: String? = nil,
        incomingName: String? = nil,
        step: Int? = nil,
        total: Int? = nil,
        message: String = "",
        isApplyBackend: Bool = false
    ) {
        self.kind = kind
        self.branch = branch
        self.onto = onto
        self.incoming = incoming
        self.incomingName = incomingName
        self.step = step
        self.total = total
        self.message = message
        self.isApplyBackend = isApplyBackend
    }

    public var canEditMessage: Bool { !isApplyBackend }

    /// Removes comment lines ("# Conflicts: …") and surrounding blank lines, like `--cleanup=strip`.
    static func cleanMessage(_ raw: String, commentCharacter: Character = "#") -> String {
        var lines: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first == commentCharacter { continue }
            var text = String(line)
            while let last = text.last, last == " " || last == "\t" || last == "\r" {
                text.removeLast()
            }
            // No leading blank lines and no runs of blank lines.
            if text.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(text)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// "Merge branch 'develop' into main" → "develop"; also remote-tracking branches, tags and commits.
    static func mergeSource(fromMessage message: String) -> String? {
        guard let first = message.split(separator: "\n").first,
              let open = first.firstIndex(of: "'") else { return nil }
        let rest = first[first.index(after: open)...]
        guard let close = rest.firstIndex(of: "'") else { return nil }
        let name = rest[..<close]
        return name.isEmpty ? nil : String(name)
    }
}

/// How a command that can stop for conflicts ended.
public enum OperationOutcome: Sendable, Hashable {
    /// The merge, rebase, pick or revert is complete.
    case finished
    /// It stopped and waits in ``GitRepository/operationState()`` (conflicts or an edit step).
    case stopped
}

/// The two sides of a conflict. During a rebase "ours" is the branch being rebased onto and
/// "theirs" the commit being replayed — the UI names them instead of using these words.
public enum ConflictSide: Sendable, Hashable {
    case ours
    case theirs
}
