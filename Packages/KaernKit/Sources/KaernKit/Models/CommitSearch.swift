import Foundation

/// What the toolbar search (⌘F) looks at. `.all` needs no token; the others show as a token in
/// the field and can be typed as a prefix ("author:minji").
public enum CommitSearchScope: String, CaseIterable, Sendable, Identifiable {
    case all
    case message
    case author
    case path
    case sha

    public var id: String { rawValue }

    /// Prefixes that pick the scope when typed at the start of the search text.
    var prefixes: [String] {
        switch self {
        case .all: []
        case .message: ["message:", "msg:"]
        case .author: ["author:"]
        case .path: ["path:", "file:"]
        case .sha: ["sha:", "commit:"]
        }
    }

    /// "author:minji" → (.author, "minji"). `nil` when the text doesn't start with a prefix.
    public static func parsePrefix(_ text: String) -> (scope: CommitSearchScope, query: String)? {
        let lowercased = text.lowercased()
        for scope in allCases {
            for prefix in scope.prefixes where lowercased.hasPrefix(prefix) {
                return (scope, String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// Whether a loaded commit matches by what the history already shows (subject, author,
    /// SHA). Paths and full messages need git, which the background search asks.
    public func matchesLoaded(_ commit: Commit, query: String) -> Bool {
        switch self {
        case .all:
            return commit.subject.localizedCaseInsensitiveContains(query)
                || commit.author.name.localizedCaseInsensitiveContains(query)
                || commit.author.email.localizedCaseInsensitiveContains(query)
                || Self.matchesSHA(commit.id, query: query)
        case .message:
            return commit.subject.localizedCaseInsensitiveContains(query)
        case .author:
            return commit.author.name.localizedCaseInsensitiveContains(query)
                || commit.author.email.localizedCaseInsensitiveContains(query)
        case .path:
            return false
        case .sha:
            return Self.matchesSHA(commit.id, query: query)
        }
    }

    /// A SHA prefix of at least four hex digits.
    static func matchesSHA(_ id: String, query: String) -> Bool {
        let query = query.lowercased()
        return query.count >= 4 && query.allSatisfy(\.isHexDigit) && id.hasPrefix(query)
    }
}

/// The result of searching the whole history in the background.
public struct HistorySearchResult: Sendable, Equatable {
    /// Matching commits, newest first.
    public var matches: [String]
    /// Commits in the history (all branches, remote branches and tags).
    public var total: Int

    public init(matches: [String], total: Int) {
        self.matches = matches
        self.total = total
    }
}
