import Foundation

/// Where a version of a file comes from.
public enum FileVersion: Sendable, Hashable {
    /// `<revision>:<path>`: a commit, a stash, `HEAD`.
    case revision(String)
    /// The staged version (`:<path>`).
    case index
    /// The file on disk.
    case workTree
}

/// One version of a file: its bytes or, for a Git LFS file whose content isn't on this Mac,
/// just its pointer.
public struct FileContents: Sendable, Hashable {
    /// `nil` for an LFS file that isn't downloaded, or a file over the size limit.
    public var data: Data?
    /// Set when the version is a Git LFS pointer.
    public var pointer: LFSPointer?
    /// The file's real size (the LFS object's for LFS files).
    public var size: Int

    public init(data: Data?, pointer: LFSPointer? = nil, size: Int) {
        self.data = data
        self.pointer = pointer
        self.size = size
    }

    /// An LFS file whose content was never downloaded.
    public var isMissingLFSContent: Bool { pointer != nil && data == nil }
}

/// Downloading LFS files needs the git-lfs command.
public struct LFSNotInstalledError: LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? {
        "Git LFS isn't installed. Install it (brew install git-lfs, then git lfs install) and try again."
    }
}

extension GitRepository {
    /// A version of `path`. An LFS pointer comes back with the content from `.git/lfs/objects`
    /// when it's been downloaded. Files over `limit` bytes come back without their bytes.
    public func contents(of path: String, at version: FileVersion, limit: Int = 64 << 20) async -> FileContents? {
        guard let raw = await rawContents(of: path, at: version, limit: limit) else { return nil }
        guard let data = raw.data else { return FileContents(data: nil, size: raw.size) }
        guard let pointer = Self.lfsPointer(in: data) else { return FileContents(data: data, size: data.count) }
        guard pointer.size <= limit, let object = lfsObjectURL(pointer.oid),
              let content = FileManager.default.contents(atPath: object.path(percentEncoded: false)) else {
            return FileContents(data: nil, pointer: pointer, size: pointer.size)
        }
        return FileContents(data: content, pointer: pointer, size: pointer.size)
    }

    /// The Git LFS pointer a version of `path` is, reading nothing bigger than a pointer.
    public func lfsPointer(of path: String, at version: FileVersion) async -> LFSPointer? {
        guard let data = await rawContents(of: path, at: version, limit: 1023)?.data else { return nil }
        return Self.lfsPointer(in: data)
    }

    /// The bytes git stores (no filters: an LFS file is its pointer), or just the size when
    /// it's over `limit`.
    private func rawContents(of path: String, at version: FileVersion, limit: Int) async -> (data: Data?, size: Int)? {
        switch version {
        case .workTree:
            let file = root.appending(path: path).path(percentEncoded: false)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.intValue else { return nil }
            guard size <= limit else { return (nil, size) }
            return FileManager.default.contents(atPath: file).map { ($0, size) }
        case .index, .revision:
            let spec = if case .revision(let revision) = version { "\(revision):\(path)" } else { ":\(path)" }
            guard let sizeText = try? await git(["cat-file", "-s", spec]).text.trimmingCharacters(in: .whitespacesAndNewlines),
                  let size = Int(sizeText) else { return nil }
            guard size <= limit else { return (nil, size) }
            return (try? await git(["cat-file", "blob", spec]).stdout).map { ($0, size) }
        }
    }

    static func lfsPointer(in data: Data) -> LFSPointer? {
        guard data.count < 1024, data.starts(with: Data(lfsPointerPrefix.utf8)) else { return nil }
        return LFSPointer.parse(String(decoding: data, as: UTF8.self).components(separatedBy: "\n"))
    }

    /// Downloads LFS files: into the work tree (`git lfs pull`), or for `commit`, only their
    /// content (`git lfs fetch`), so a commit that isn't checked out can show them.
    public func downloadLFS(_ paths: [String], at commit: String? = nil, remote: String = "origin",
                            onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        guard runner.isLFSInstalled else { throw LFSNotInstalledError() }
        // `--include` takes a comma-separated list; a comma in a name is escaped.
        let include = paths.map { $0.replacingOccurrences(of: ",", with: "\\,") }.joined(separator: ",")
        if let commit {
            try await git(["lfs", "fetch", "--include=\(include)", "--exclude=", remote, commit], onProgress: onProgress)
        } else {
            try await git(["lfs", "pull", "--include=\(include)", "--exclude="], onProgress: onProgress)
        }
    }
}

extension GitRepository {
    /// Repository › Fetch LFS Files: every LFS file of the checked-out commit (`git lfs pull`).
    public func downloadAllLFS(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        guard runner.isLFSInstalled else { throw LFSNotInstalledError() }
        try await git(["lfs", "pull"], onProgress: onProgress)
    }
}

// MARK: - Shallow clones

extension GitRepository {
    /// A shallow clone (`git clone --depth`): history stops before the first commit.
    public var isShallow: Bool {
        let file = commonGitDirectory.appending(path: "shallow").path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file) else { return false }
        return ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0
    }

    /// Fetch 100 More (`git fetch --deepen=<count>`) or, with `nil`, Fetch Full History
    /// (`git fetch --unshallow`) from `remote`.
    public func deepen(by count: Int?, remote: String, onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        let depth = count.map { "--deepen=\($0)" } ?? "--unshallow"
        try await git(["fetch", "--progress", depth, remote], onProgress: onProgress)
    }
}

// MARK: - Submodule moves

/// What a submodule's move from one commit to another brings, as the submodule's own clone
/// tells it (ScreenMarks: Recorded → Checked out now, and the commits in between).
public struct SubmoduleChange: Sendable, Hashable {
    public var path: String
    public var old: String?
    public var new: String?
    /// The tag on each side's commit, when there is one ("2.6.4").
    public var oldTag: String?
    public var newTag: String?
    /// The submodule is cloned here, so its commits can be read.
    public var isInitialized: Bool
    /// Commits `new` has that `old` doesn't, newest first (at most the limit asked for).
    public var added: [Commit]
    public var addedCount: Int
    /// Commits `old` has that `new` doesn't: going back, or two lines that went apart.
    public var removed: [Commit]
    public var removedCount: Int

    public init(path: String, old: String?, new: String?, oldTag: String? = nil, newTag: String? = nil, isInitialized: Bool,
                added: [Commit] = [], addedCount: Int = 0, removed: [Commit] = [], removedCount: Int = 0) {
        self.path = path
        self.old = old
        self.new = new
        self.oldTag = oldTag
        self.newTag = newTag
        self.isInitialized = isInitialized
        self.added = added
        self.addedCount = addedCount
        self.removed = removed
        self.removedCount = removedCount
    }

    /// Only new commits on top: moving there is a fast-forward.
    public var isFastForward: Bool { addedCount > 0 && removedCount == 0 }
}

extension GitRepository {
    /// The folder of the submodule at `path`, when it's cloned.
    func submoduleFolder(_ path: String) -> URL? {
        let folder = root.appending(path: path, directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: folder.appending(path: ".git").path(percentEncoded: false)) ? folder : nil
    }

    /// The commit checked out inside the submodule at `path` (`nil` when it isn't cloned).
    public func submoduleHead(_ path: String) async -> String? {
        guard let folder = submoduleFolder(path),
              let output = try? await runner.run(["rev-parse", "--verify", "HEAD"], in: folder) else { return nil }
        let id = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// What moving the submodule at `path` from `old` to `new` brings: the tags on both, and
    /// the commits in between (up to `limit` each way).
    public func submoduleChange(_ path: String, from old: String?, to new: String?, limit: Int = 50) async -> SubmoduleChange {
        guard let folder = submoduleFolder(path) else {
            return SubmoduleChange(path: path, old: old, new: new, isInitialized: false)
        }
        func run(_ arguments: [String]) async -> GitOutput? {
            try? await runner.run(arguments, in: folder, acceptedStatus: [0])
        }
        func tag(_ commit: String?) async -> String? {
            // The newest version among the tags on it (`tag --points-at` lists none without failing).
            guard let commit, let output = await run(["tag", "--points-at", commit, "--sort=-version:refname"]) else { return nil }
            return output.text.split(separator: "\n").first.map(String.init)
        }
        func commits(_ range: String) async -> [Commit] {
            guard let output = await run(["log", "-z", "--format=\(LogParser.format)", "--max-count=\(limit)", range, "--"]) else { return [] }
            return LogParser.parse(output.stdout)
        }
        var change = SubmoduleChange(path: path, old: old, new: new, isInitialized: true)
        change.oldTag = await tag(old)
        change.newTag = await tag(new)
        switch (old, new) {
        case let (old?, new?):
            if let counts = await run(["rev-list", "--left-right", "--count", "\(old)...\(new)", "--"]) {
                let numbers = counts.text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
                if numbers.count == 2 {
                    change.removedCount = numbers[0]
                    change.addedCount = numbers[1]
                }
            }
            if change.addedCount > 0 { change.added = await commits("\(old)..\(new)") }
            if change.removedCount > 0 { change.removed = await commits("\(new)..\(old)") }
        case (nil, let new?):
            change.added = await commits(new)
            let count = await run(["rev-list", "--count", new, "--"])?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            change.addedCount = count.flatMap(Int.init) ?? change.added.count
        default:
            break
        }
        return change
    }
}
