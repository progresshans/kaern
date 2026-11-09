import Foundation
import KaernKit

/// A working copy with thousands of changes (ScreenBigRepo › 변경 파일 1만 개). The panel lists folders
/// with how many files each holds instead of every file, and suggests ignoring a folder of new files
/// that holds most of them. Worked out once per status, not in the view.
struct BigChanges: Equatable {
    /// From this many changed files the panel lists folders.
    static let threshold = 1_000

    struct Folder: Identifiable, Equatable {
        /// "charts/vendor/": the top folder, joined with the folders below it while each holds only one.
        let path: String
        /// Its files, by path.
        let entries: [StatusEntry]
        let stagedCount: Int
        let unstagedCount: Int
        var id: String { path }
    }

    let total: Int
    /// Files with changes in the index, and in the work tree (a partly staged file is in both).
    let stagedCount: Int
    let unstagedCount: Int
    /// Files at the top of the repository.
    let rootEntries: [StatusEntry]
    /// Biggest first.
    let folders: [Folder]
    let suggestion: IgnoreSuggestion?

    init(_ entries: [StatusEntry]) {
        total = entries.count
        stagedCount = entries.count(where: \.hasStagedChanges)
        unstagedCount = entries.count(where: \.hasUnstagedChanges)
        var byTop: [String: [StatusEntry]] = [:]
        var root: [StatusEntry] = []
        for entry in entries {
            if let slash = entry.path.firstIndex(of: "/") {
                byTop[String(entry.path[...slash]), default: []].append(entry)
            } else {
                root.append(entry)
            }
        }
        rootEntries = root.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        folders = byTop.map { top, members in
            let sorted = members.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            return Folder(path: Self.compactPath(top, members: sorted), entries: sorted,
                          stagedCount: sorted.count(where: \.hasStagedChanges), unstagedCount: sorted.count(where: \.hasUnstagedChanges))
        }
        .sorted { $0.entries.count != $1.entries.count ? $0.entries.count > $1.entries.count : $0.path < $1.path }
        suggestion = IgnoreSuggestion.find(in: entries)
    }

    /// "charts/" whose files all sit in "charts/vendor/" (and no deeper single folder) is shown as
    /// "charts/vendor/", like a file tree that folds single-child folders.
    static func compactPath(_ top: String, members: [StatusEntry]) -> String {
        var folder = top
        while true {
            var next: String?
            for entry in members {
                let rest = entry.path.dropFirst(folder.count)
                guard let slash = rest.firstIndex(of: "/") else { return folder }   // a file right in `folder`
                let child = folder + rest[...slash]
                if next == nil { next = child } else if next != child { return folder }
            }
            guard let next else { return folder }
            folder = next
        }
    }
}

/// "11,920 of them are in charts/vendor/. They look generated. Ignore the folder?"
struct IgnoreSuggestion: Equatable {
    /// "charts/vendor/"
    let folder: String
    let count: Int

    /// Folder names projects generate (build output, dependencies, caches).
    static let generatedNames: Set<String> = [
        "node_modules", "vendor", "dist", "build", "out", "target", "coverage", "tmp", ".cache", ".build", ".swiftpm",
        "DerivedData", "Pods", "Carthage", ".gradle", ".next", ".nuxt", ".svelte-kit", ".astro", "__pycache__",
        ".venv", "venv", ".pytest_cache", ".mypy_cache", ".terraform",
    ]

    /// A folder whose changes are all new files and hold at least half of all the changes (and a
    /// thousand or more). A folder with a generated name wins (the outermost one); otherwise the
    /// deepest folder that still holds that many.
    static func find(in entries: [StatusEntry]) -> IgnoreSuggestion? {
        guard entries.count >= BigChanges.threshold else { return nil }
        var untracked: [String: Int] = [:]
        var tracked = Set<String>()
        for entry in entries {
            var rest = Substring(entry.path)
            var folder = ""
            while let slash = rest.firstIndex(of: "/") {
                folder += rest[...slash]
                if entry.isUntracked { untracked[folder, default: 0] += 1 } else { tracked.insert(folder) }
                rest = rest[rest.index(after: slash)...]
            }
        }
        let needed = max(BigChanges.threshold, (entries.count + 1) / 2)
        let candidates = untracked.filter { $0.value >= needed && !tracked.contains($0.key) }
        func depth(_ folder: String) -> Int { folder.count(where: { $0 == "/" }) }
        func isGenerated(_ folder: String) -> Bool { generatedNames.contains(String(folder.dropLast().split(separator: "/").last ?? "")) }
        let pick = candidates.filter { isGenerated($0.key) }.min { depth($0.key) < depth($1.key) }
            ?? candidates.max { depth($0.key) != depth($1.key) ? depth($0.key) < depth($1.key) : $0.key > $1.key }
        return pick.map { IgnoreSuggestion(folder: $0.key, count: $0.value) }
    }
}

extension RepositoryModel {
    /// The suggestion the panel shows: not put away with Not Now for this folder.
    var ignoreSuggestion: IgnoreSuggestion? {
        guard let suggestion = bigChanges?.suggestion, !dismissedIgnoreSuggestions.contains(suggestion.folder) else { return nil }
        return suggestion
    }

    /// Add to .gitignore: the folder's pattern at the end of the top-level `.gitignore`; ⌘Z puts
    /// the file back.
    func ignoreSuggestedFolder() {
        guard let suggestion = ignoreSuggestion else { return }
        let pattern = IgnorePatterns.folderPattern(suggestion.folder)
        let folder = suggestion.folder
        let before = status.entries.count { $0.path.hasPrefix(folder) }
        perform(.working("Updating .gitignore…"), trigger: "Ignore \(folder)") { [weak self] repository in
            let edit = try repository.addIgnorePattern(pattern)
            let after = (try await repository.status()).entries.count { $0.path.hasPrefix(folder) }
            self?.record(.ignored(edit: edit),
                         toast: "Ignored \(folder) · \(Formatters.count(max(0, before - after), "file", "files")) left the list")
        }
    }

    /// Not Now: the card doesn't come back for this folder of this repository.
    func dismissIgnoreSuggestion() {
        guard let folder = bigChanges?.suggestion?.folder else { return }
        dismissedIgnoreSuggestions.insert(folder)
        var kept = UserDefaults.kaern.stringArray(forKey: SettingsKey.ignoreSuggestionsDismissed) ?? []
        let key = path + "\t" + folder
        if !kept.contains(key) { kept.append(key) }
        UserDefaults.kaern.set(kept, forKey: SettingsKey.ignoreSuggestionsDismissed)
    }

    /// Folders put away with Not Now, from the settings.
    static func dismissedIgnoreSuggestions(for path: String) -> Set<String> {
        let kept = UserDefaults.kaern.stringArray(forKey: SettingsKey.ignoreSuggestionsDismissed) ?? []
        return Set(kept.compactMap { key in
            let parts = key.split(separator: "\t", maxSplits: 1)
            return parts.count == 2 && parts[0] == path ? String(parts[1]) : nil
        })
    }

    /// The folder row's checkbox: stages (or unstages) every file in it with one git command.
    /// ⌘Z restores the index under the whole folder: the command can touch more than the listed
    /// files (a nested repository it stages, a rename it splits).
    func stageFolder(_ folder: BigChanges.Folder, staged: Bool) {
        let paths = [folder.path.hasSuffix("/") ? folder.path : folder.path + "/"]
        let label = (staged ? "Unstage " : "Stage ") + folder.path
        if staged {
            let hasHead = status.headID != nil
            changeIndex(label: label, paths: paths) { try await $0.unstage([folder.path], hasHead: hasHead) }
        } else {
            changeIndex(label: label, paths: paths) { try await $0.stage([folder.path]) }
        }
    }
}
