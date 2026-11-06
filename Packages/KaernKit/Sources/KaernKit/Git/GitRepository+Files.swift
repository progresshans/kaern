import Foundation

// MARK: - Files in the repository

extension GitRepository {
    /// Every tracked path (`git ls-files -z`), for the quick switcher.
    public func trackedFiles() async -> [String] {
        guard let output = try? await git(["ls-files", "-z", "--cached"]) else { return [] }
        return Records.splitNUL(output.stdout)
    }

    /// When the last commit in HEAD's history that touched `path` was made ("last changed
    /// Sep 26" in the quick switcher). `nil` when no commit did.
    public func lastChangeDate(of path: String) async -> Date? {
        guard let output = try? await git(["log", "-1", "--format=%ct", "HEAD", "--", ":(literal)" + path]),
              let seconds = TimeInterval(output.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

// MARK: - Ignored paths

extension GitRepository {
    /// The working-tree paths among `paths` (absolute) that `.gitignore` doesn't exclude. A build
    /// writing thousands of files into an ignored folder then causes no refresh at all.
    public func notIgnored(_ paths: [String]) async -> [String] {
        let rootPath = root.path(percentEncoded: false).trimmingSuffix("/") + "/"
        let relative = paths.compactMap { path -> String? in
            guard path.hasPrefix(rootPath) else { return nil }
            let inside = String(path.dropFirst(rootPath.count))
            return inside.isEmpty ? nil : inside
        }
        guard !relative.isEmpty else { return [] }
        let input = Data(relative.joined(separator: "\0").appending("\0").utf8)
        // Exit status 1: none of them is ignored.
        guard let output = try? await git(["check-ignore", "-z", "--stdin"], input: input, accepted: [0, 1]) else { return relative }
        let ignored = Set(Records.splitNUL(output.stdout))
        return relative.filter { !ignored.contains($0) }
    }
}

// MARK: - File contents

extension GitRepository {
    /// A file's lines: on disk when `revision` is `nil`, from the index for `":"`, otherwise as
    /// of that commit. For showing the unchanged lines between hunks.
    public func fileLines(_ path: String, at revision: String?) async -> [String]? {
        let data: Data?
        if let revision {
            let spec = revision == ":" ? ":" + path : "\(revision):\(path)"
            data = try? await git(["show", spec]).stdout
        } else {
            data = FileManager.default.contents(atPath: root.appending(path: path).path(percentEncoded: false))
        }
        guard let data, !data.prefix(8000).contains(0) else { return nil }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
