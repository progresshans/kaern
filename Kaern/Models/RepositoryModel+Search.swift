import Foundation
import KaernKit

// MARK: - Search (⌘F)

extension RepositoryModel {
    var trimmedSearchText: String { searchText.trimmingCharacters(in: .whitespaces) }

    var isSearching: Bool { !trimmedSearchText.isEmpty }

    /// Matching commits don't filter the history: the others are dimmed, so the graph keeps its
    /// shape. The loaded pages answer at once; git searches the rest of the history (full
    /// messages, paths) in the background and its matches are added when they arrive.
    func updateSearch(rerunHistorySearch: Bool = false) {
        let query = trimmedSearchText
        guard !query.isEmpty else {
            historySearchTask?.cancel()
            historySearchTask = nil
            historySearchKey = nil
            historySearch = nil
            isSearchingHistory = false
            if searchMatches != nil {
                searchMatches = nil
                searchVersion += 1
            }
            return
        }
        var matches = Set<String>()
        for commit in commits where searchScope.matchesLoaded(commit, query: query) {
            matches.insert(commit.id)
        }
        if searchScope == .all {
            // A branch or tag name finds the commit it points at.
            for ref in refs.refs where ref.name.localizedCaseInsensitiveContains(query) {
                matches.insert(ref.target)
            }
        }
        let key = "\(searchScope.rawValue):\(query)"
        if key != historySearchKey {
            historySearch = nil
            startHistorySearch(query: query, key: key)
        } else if rerunHistorySearch {
            startHistorySearch(query: query, key: key)
        }
        if let historySearch {
            matches.formUnion(historySearch.matches)
        }
        searchMatches = matches
        searchVersion += 1
    }

    private func startHistorySearch(query: String, key: String) {
        historySearchTask?.cancel()
        historySearchKey = key
        guard let repository else { return }
        let scope = searchScope
        let includeHEAD = hasHead
        isSearchingHistory = true
        historySearchTask = Task { [weak self] in
            // Wait for typing to pause.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let result = try? await repository.searchHistory(query, scope: scope, includeHEAD: includeHEAD)
            guard let self, !Task.isCancelled, self.historySearchKey == key else { return }
            self.isSearchingHistory = false
            self.historySearch = result
            self.updateSearch()
        }
    }

    /// Every match, loaded or not, when git has answered; the loaded ones until then.
    var searchMatchCount: Int {
        guard let searchMatches else { return 0 }
        guard let historySearch else { return searchMatches.count }
        // Branch-name matches the history search doesn't know about still count.
        return Set(historySearch.matches).union(searchMatches).count
    }

    /// "4 of 31 commits match “release” · ⌘G next" (the status bar while searching).
    var searchSummary: String? {
        guard isSearching else { return nil }
        let query = trimmedSearchText
        let count = searchMatchCount
        if count == 0 {
            return isSearchingHistory
                ? String(localized: "Searching all history for “\(query)”…")
                : String(localized: "No commits match “\(query)”")
        }
        let total = historySearch?.total ?? commits.count
        var text = String(localized: "\(count) of \(total) commits match “\(query)”")
        if isSearchingHistory { text += " …" }
        return text + " · " + String(localized: "⌘G next")
    }

    /// Return / ⌘G: the next match after the selection (⇧: the previous one). A match past the
    /// loaded pages loads them until it's there.
    func selectNextSearchMatch(backwards: Bool = false) {
        guard let searchMatches, !searchMatches.isEmpty else { return }
        let start: Int
        if case .commit(let id) = selection, let index = commitIndex[id] {
            start = index
        } else {
            start = backwards ? commits.count : -1
        }
        if backwards {
            let candidates = Array(stride(from: start - 1, through: 0, by: -1))
            if let previous = candidates.first(where: { searchMatches.contains(commits[$0].id) }) {
                select(commits[previous])
            } else if let last = commits.indices.last(where: { searchMatches.contains(commits[$0].id) }) {
                select(commits[last])   // wrap around to the last loaded match
            }
            return
        }
        if let next = commits.indices.first(where: { $0 > start && searchMatches.contains(commits[$0].id) }) {
            select(commits[next])
            return
        }
        // Past the loaded pages: load until the next match shows up, or wrap to the first one.
        let unloaded = (historySearch?.matches ?? []).filter { commitIndex[$0] == nil }
        if let target = unloaded.first, hasMoreHistory {
            Task { await loadHistory(until: target) }
        } else if let first = commits.indices.first(where: { searchMatches.contains(commits[$0].id) }) {
            select(commits[first])
        }
    }

    private func select(_ commit: Commit) {
        selectedFile = nil
        selection = .commit(commit.id)
    }

    /// Loads pages until `id` is in the history (at most 50 pages), then selects it.
    func loadHistory(until id: String) async {
        var pages = 0
        while commitIndex[id] == nil, hasMoreHistory, pages < 50 {
            await loadMoreHistory()
            pages += 1
        }
        if let commit = commit(withID: id) {
            select(commit)
        }
    }
}
