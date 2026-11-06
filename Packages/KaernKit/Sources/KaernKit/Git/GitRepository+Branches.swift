import Foundation

// MARK: - Branches and tags

extension GitRepository {
    /// `git branch -m <old> <new>`. The upstream setting moves with the branch.
    public func renameBranch(_ name: String, to newName: String) async throws {
        try await git(["branch", "-m", name, newName])
    }

    /// Deletes a branch on the remote: `git push <remote> --delete <branch>`.
    public func deleteRemoteBranch(_ branch: String, on remote: String, onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        try await git(["push", "--progress", remote, "--delete", branch], onProgress: onProgress)
    }

    /// A lightweight tag, or an annotated one when there's a message (signing follows
    /// `tag.gpgSign`).
    public func createTag(_ name: String, at commit: String, message: String?) async throws {
        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await git(["tag", "-a", "--file=-", "--cleanup=whitespace", name, commit], input: Data(message.utf8))
        } else {
            try await git(["tag", name, commit])
        }
    }

    public func deleteTag(_ name: String) async throws {
        try await git(["tag", "-d", name])
    }

    /// `git push <remote> refs/tags/<name>`
    public func pushTag(_ name: String, to remote: String, onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        try await git(["push", "--progress", remote, "refs/tags/\(name)"], onProgress: onProgress)
    }

    /// Checks a new tag name with `git check-ref-format`.
    public func isValidTagName(_ name: String) async -> Bool {
        guard !name.isEmpty, let output = try? await git(["check-ref-format", "refs/tags/\(name)"], accepted: [0, 1, 128]) else {
            return false
        }
        return output.status == 0
    }
    /// Branch names from the HEAD reflog's "checkout: moving from A to B" entries, most recent
    /// first and without duplicates. Detached commits appear as object names; callers keep the
    /// names that are still local branches.
    public func recentlyCheckedOut(limit: Int = 300) async -> [String] {
        guard let output = try? await git(["reflog", "show", "--format=%gs", "-n", "\(limit)", "HEAD", "--"], accepted: [0, 128]),
              output.status == 0 else { return [] }
        var names: [String] = []
        var seen = Set<String>()
        for line in output.text.split(separator: "\n") {
            guard line.hasPrefix("checkout: moving from ") else { continue }
            let rest = line.dropFirst("checkout: moving from ".count)
            guard let range = rest.range(of: " to ", options: .backwards) else { continue }
            for name in [String(rest[range.upperBound...]), String(rest[..<range.lowerBound])] where seen.insert(name).inserted {
                names.append(name)
            }
        }
        return names
    }
}
