import Foundation

/// How a file changed. The letter is what Kaern shows next to the path (always with a color).
public enum ChangeKind: String, Sendable, Hashable, CaseIterable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case typeChanged
    case untracked
    case conflicted

    public var letter: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .untracked: "U"
        case .conflicted: "!"
        }
    }

    public var label: String {
        switch self {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typeChanged: "Type Changed"
        case .untracked: "Untracked"
        case .conflicted: "Conflicted"
        }
    }

    /// Maps a porcelain/name-status letter.
    public init?(statusLetter: Character) {
        switch statusLetter {
        case "M": self = .modified
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        case "U": self = .conflicted
        case "?": self = .untracked
        default: return nil
        }
    }
}

public enum StageState: Sendable, Hashable {
    case unstaged
    case partial
    case staged
}

/// One changed path in the working tree, from `git status --porcelain=v2`.
public struct StatusEntry: Sendable, Hashable, Identifiable {
    public var path: String
    /// Source path of a staged rename or copy.
    public var originalPath: String?
    /// Index status (X): `.` when unchanged.
    public var indexStatus: Character
    /// Work tree status (Y): `.` when unchanged.
    public var worktreeStatus: Character
    public var isUntracked: Bool
    public var isConflicted: Bool
    /// Set when the path is a submodule.
    public var submodule: SubmoduleStatus?

    public init(
        path: String,
        originalPath: String? = nil,
        indexStatus: Character,
        worktreeStatus: Character,
        isUntracked: Bool = false,
        isConflicted: Bool = false
    ) {
        self.path = path
        self.originalPath = originalPath
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
        self.isUntracked = isUntracked
        self.isConflicted = isConflicted
    }

    public var id: String { path }

    public var hasStagedChanges: Bool {
        !isUntracked && !isConflicted && indexStatus != "."
    }

    public var hasUnstagedChanges: Bool {
        isUntracked || isConflicted || worktreeStatus != "."
    }

    public var stageState: StageState {
        switch (hasStagedChanges, hasUnstagedChanges) {
        case (true, false): .staged
        case (true, true): .partial
        default: .unstaged
        }
    }

    /// The kind shown in the file list: the staged change wins, otherwise the work tree change.
    public var kind: ChangeKind {
        if isConflicted { return .conflicted }
        if isUntracked { return .untracked }
        if indexStatus != ".", let kind = ChangeKind(statusLetter: indexStatus) { return kind }
        return ChangeKind(statusLetter: worktreeStatus) ?? .modified
    }
}

/// A submodule's line in `git status`: the commits HEAD and the index record for it, and what
/// changed in its own working tree.
public struct SubmoduleStatus: Sendable, Hashable {
    /// `nil` when HEAD doesn't have the submodule yet.
    public var headCommit: String?
    /// `nil` when the submodule was removed from the index.
    public var indexCommit: String?
    /// Another commit is checked out inside than the one the index records.
    public var commitChanged: Bool
    /// Uncommitted changes to its tracked files.
    public var hasModifiedContent: Bool
    /// Untracked files inside.
    public var hasUntrackedContent: Bool

    public init(headCommit: String?, indexCommit: String?, commitChanged: Bool, hasModifiedContent: Bool, hasUntrackedContent: Bool) {
        self.headCommit = headCommit
        self.indexCommit = indexCommit
        self.commitChanged = commitChanged
        self.hasModifiedContent = hasModifiedContent
        self.hasUntrackedContent = hasUntrackedContent
    }
}

/// The commits a submodule moved between (`nil` on the side where it didn't exist).
public struct SubmoduleMove: Sendable, Hashable {
    public var old: String?
    public var new: String?

    public init(old: String?, new: String?) {
        self.old = old
        self.new = new
    }
}

/// `git status` for the whole repository.
public struct WorkingTreeStatus: Sendable, Hashable {
    /// `nil` in a repository without commits.
    public var headID: String?
    /// `nil` when HEAD is detached.
    public var branch: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var stashCount: Int
    public var entries: [StatusEntry]

    public init(
        headID: String? = nil,
        branch: String? = nil,
        upstream: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        stashCount: Int = 0,
        entries: [StatusEntry] = []
    ) {
        self.headID = headID
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.stashCount = stashCount
        self.entries = entries
    }

    public static let empty = WorkingTreeStatus()

    public var isClean: Bool { entries.isEmpty }
    public var stagedCount: Int { entries.count { $0.hasStagedChanges } }
    public var conflictCount: Int { entries.count { $0.isConflicted } }

    public var head: HeadState {
        if let branch {
            return headID == nil ? .unborn(branch) : .branch(branch)
        }
        return .detached(headID ?? "")
    }
}

/// Added/removed line counts for one file. `nil` counts mean the file is binary.
public struct LineStat: Sendable, Hashable {
    public var additions: Int?
    public var deletions: Int?

    public init(additions: Int?, deletions: Int?) {
        self.additions = additions
        self.deletions = deletions
    }

    public var isBinary: Bool { additions == nil || deletions == nil }

    public static func + (lhs: LineStat, rhs: LineStat) -> LineStat {
        guard let la = lhs.additions, let ld = lhs.deletions, let ra = rhs.additions, let rd = rhs.deletions else {
            return LineStat(additions: nil, deletions: nil)
        }
        return LineStat(additions: la + ra, deletions: ld + rd)
    }
}

/// A file touched by a commit.
public struct FileChange: Sendable, Hashable, Identifiable {
    public var path: String
    public var oldPath: String?
    public var kind: ChangeKind
    public var stat: LineStat?
    /// Set when the path is a submodule (git records a commit for it, mode 160000).
    public var submodule: SubmoduleMove?

    public init(path: String, oldPath: String? = nil, kind: ChangeKind, stat: LineStat? = nil, submodule: SubmoduleMove? = nil) {
        self.path = path
        self.oldPath = oldPath
        self.kind = kind
        self.stat = stat
        self.submodule = submodule
    }

    public var id: String { path }
}
