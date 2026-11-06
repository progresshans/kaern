import Foundation

// MARK: - Discard, with a copy kept first

/// What Discard threw away: a stash entry with the changes (made before anything changed) and
/// the patches ⌘Z applies to put them back.
public struct DiscardRecord: Sendable, Hashable {
    /// The stash entry Kaern made first, `nil` when git made none.
    public var stash: String?
    /// HEAD → index of the discarded files (empty when the staged part was kept).
    public var staged: Data
    /// Index → working tree of the discarded tracked files.
    public var unstaged: Data
    /// Untracked files that were deleted (their contents are in the stash's third parent).
    public var untracked: [String]
    public var paths: [String]
    /// Only the unstaged part was discarded ("Discard Unstaged Changes").
    public var keptStaged: Bool
}

extension GitRepository {
    /// Throws away the changes of `paths` after keeping a copy in the stash list (`message`).
    ///
    /// - Parameters:
    ///   - untracked: The paths among `paths` git doesn't track; they're deleted.
    ///   - keepingStaged: Only the unstaged changes go; what's staged stays.
    public func discard(paths: [String], untracked: [String], keepingStaged: Bool, message: String) async throws -> DiscardRecord {
        let untrackedSet = Set(untracked)
        let tracked = paths.filter { !untrackedSet.contains($0) }
        let staged = keepingStaged || tracked.isEmpty ? Data() : try await patch(paths: tracked, staged: true)
        let unstaged = tracked.isEmpty ? Data() : try await patch(paths: tracked, staged: false)
        let stash = try await snapshotStash(paths: paths, message: message, includeUntracked: !untracked.isEmpty)
        if !tracked.isEmpty {
            if keepingStaged {
                try await discardUnstaged(tracked)
            } else {
                try await discardAll(tracked)
            }
        }
        for path in untracked {
            try FileManager.default.removeItem(at: root.appending(path: path))
        }
        return DiscardRecord(stash: stash, staged: staged, unstaged: unstaged, untracked: untracked, paths: paths,
                             keptStaged: keepingStaged)
    }

    /// Puts discarded changes back and drops the stash entry Discard made.
    public func restore(_ record: DiscardRecord) async throws {
        let existing = record.untracked.filter {
            FileManager.default.fileExists(atPath: root.appending(path: $0).path(percentEncoded: false))
        }
        guard existing.isEmpty else {
            throw GitError(arguments: ["restore"], status: -1,
                           message: "\(existing[0]) exists again, so Kaern can't put the discarded copy back.")
        }
        if !record.staged.isEmpty {
            try await apply(patchData: record.staged, index: true)
        }
        if !record.unstaged.isEmpty {
            try await apply(patchData: record.unstaged)
        }
        if !record.untracked.isEmpty, let stash = record.stash {
            try await git(["restore", "--source=\(stash)^3", "--worktree", "--"] + record.untracked.map { ":(literal)" + $0 })
        }
        if let object = record.stash, let entry = await stash(withObject: object) {
            try await dropStash(entry)
        }
    }

    /// Discard again after ⌘Z (the same paths, as they are now).
    public func discardAgain(_ record: DiscardRecord, message: String) async throws -> DiscardRecord {
        try await discard(paths: record.paths, untracked: record.untracked, keepingStaged: record.keptStaged, message: message)
    }

    /// Keeps a copy of the changes of one file in the stash list, then throws away picked lines
    /// of its unstaged diff. Returns the stash and the patch that puts the lines back.
    public func discardLines(_ selection: [Int: Set<Int>], of diff: FileDiff, message: String) async throws -> (stash: String?, patch: String)? {
        guard diff.supportsPartialPatches, !diff.stagesWholeFile, diff.patch(picking: selection, reverse: true) != nil else { return nil }
        let stash = try await snapshotStash(paths: [diff.path], message: message, includeUntracked: false)
        guard let patch = try await discard(lines: selection, of: diff) else { return nil }
        return (stash, patch)
    }

    /// Drops the stash entry with commit `object` if it's still in the list.
    public func dropStash(object: String) async throws {
        if let entry = await stash(withObject: object) {
            try await dropStash(entry)
        }
    }
}

// MARK: - .gitignore

/// A line added to the repository's `.gitignore`, with what the file held before (for ⌘Z).
public struct IgnoreEdit: Sendable, Hashable {
    public var pattern: String
    /// The file's contents before, `nil` when there was no `.gitignore`.
    public var previous: Data?
}

/// The patterns the Ignore menu offers for one path.
public struct IgnorePatterns: Sendable, Hashable {
    /// Only this file (`/notes.txt`, `docs/draft.md`).
    public var file: String
    /// Every file with its extension (`*.yml`), `nil` without one.
    public var fileExtension: String?
    /// Its folder (`.github/workflows/`), `nil` for a file at the top.
    public var folder: String?

    public init(path: String) {
        let name = (path as NSString).lastPathComponent
        let directory = (path as NSString).deletingLastPathComponent
        let escapedPath = IgnorePatterns.escape(path)
        // A pattern with a slash in it is relative to the .gitignore; a bare name matches at any depth.
        file = directory.isEmpty ? "/" + escapedPath : escapedPath
        let ext = (name as NSString).pathExtension
        fileExtension = ext.isEmpty || name.hasPrefix(".") && !name.dropFirst().contains(".") ? nil : "*." + IgnorePatterns.escape(ext)
        if directory.isEmpty {
            folder = nil
        } else {
            let escaped = IgnorePatterns.escape(directory) + "/"
            folder = directory.contains("/") ? escaped : "/" + escaped
        }
    }

    /// Backslash-escapes what gitignore treats as a pattern (`*`, `?`, `[`, `\`), a leading `#`
    /// or `!`, and trailing spaces.
    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if "*?[\\".contains(character) { result.append("\\") }
            result.append(character)
        }
        if result.hasPrefix("#") || result.hasPrefix("!") { result = "\\" + result }
        if result.hasSuffix(" ") { result = String(result.dropLast()) + "\\ " }
        return result
    }
}

extension GitRepository {
    private var gitignoreURL: URL { root.appending(path: ".gitignore") }

    /// Adds `pattern` as a line at the end of the top-level `.gitignore` (made when missing).
    public func addIgnorePattern(_ pattern: String) throws -> IgnoreEdit {
        let previous = FileManager.default.contents(atPath: gitignoreURL.path(percentEncoded: false))
        var data = previous ?? Data()
        if let last = data.last, last != 0x0A { data.append(0x0A) }
        data.append(contentsOf: Array((pattern + "\n").utf8))
        try data.write(to: gitignoreURL, options: .atomic)
        return IgnoreEdit(pattern: pattern, previous: previous)
    }

    /// Puts `.gitignore` back the way it was before `edit`.
    public func restoreIgnoreFile(_ edit: IgnoreEdit) throws {
        if let previous = edit.previous {
            try previous.write(to: gitignoreURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: gitignoreURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: gitignoreURL)
        }
    }
}
