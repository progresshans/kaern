import Foundation

// MARK: - Searching the whole history

extension GitRepository {
    /// Every commit in the history (all branches, remote branches, tags and HEAD, or what
    /// `history` keeps) that matches the search, beyond the pages the history has loaded.
    /// Messages are searched in full (subject and body), paths by any part of the path,
    /// case-insensitively.
    public func searchHistory(_ query: String, scope: CommitSearchScope, includeHEAD: Bool,
                              history: HistoryScope = .all(hidden: [])) async throws -> HistorySearchResult {
        let query = query.trimmingCharacters(in: .whitespaces)
        let revisions = Self.revisionArguments(for: history, head: includeHEAD ? headState() : .leftOut)
        async let total = historyCount(revisions)
        guard !query.isEmpty else { return HistorySearchResult(matches: [], total: try await total) }

        var found: [String] = []
        switch scope {
        case .all:
            // Message or author or SHA: git ANDs different kinds of limits, so ask separately.
            async let message = logIDs(revisions, ["-i", "-F", "--grep=\(query)"])
            async let author = logIDs(revisions, ["-i", "-F", "--author=\(query)"])
            async let sha = shaMatches(revisions, query: query)
            found = merge(try await message, try await author, try await sha)
        case .message:
            found = try await logIDs(revisions, ["-i", "-F", "--grep=\(query)"])
        case .author:
            found = try await logIDs(revisions, ["-i", "-F", "--author=\(query)"])
        case .path:
            // Files and folders whose path contains the text, anywhere in the tree.
            let pattern = Self.globEscaped(query)
            found = try await logIDs(revisions, [], paths: [":(icase,glob)**/*\(pattern)*", ":(icase,glob)**/*\(pattern)*/**"])
        case .sha:
            found = try await shaMatches(revisions, query: query)
        }
        return HistorySearchResult(matches: found, total: try await total)
    }

    private func historyCount(_ revisions: [String]) async throws -> Int {
        let output = try await git(["rev-list", "--count"] + revisions + ["--"])
        return Int(output.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func logIDs(_ revisions: [String], _ limits: [String], paths: [String] = []) async throws -> [String] {
        let output = try await git(["log", "--date-order", "--format=%H"] + limits + revisions + ["--"] + paths)
        return output.text.split(separator: "\n").map(String.init)
    }

    private func shaMatches(_ revisions: [String], query: String) async throws -> [String] {
        let prefix = query.lowercased()
        guard prefix.count >= 4, prefix.allSatisfy(\.isHexDigit) else { return [] }
        let output = try await git(["rev-list", "--date-order"] + revisions + ["--"])
        return output.text.split(separator: "\n").lazy.filter { $0.hasPrefix(prefix) }.map(String.init)
    }

    /// Several newest-first lists as one, without duplicates, keeping the first list's order
    /// and appending the others' extras (the history's date order decides display anyway).
    private func merge(_ lists: [String]...) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for list in lists {
            for id in list where seen.insert(id).inserted {
                result.append(id)
            }
        }
        return result
    }

    /// Escapes glob characters so a search for "a*b" looks for those characters literally.
    static func globEscaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if "*?[]\\".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
