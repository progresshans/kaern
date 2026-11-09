import Foundation

/// A Git LFS file's size before and after a change (`nil` on the side where it doesn't exist).
public struct LFSSizes: Sendable, Hashable {
    public var old: Int?
    public var new: Int?

    public init(old: Int?, new: Int?) {
        self.old = old
        self.new = new
    }
}

// MARK: - Git LFS

extension GitRepository {
    /// The paths among `paths` that `.gitattributes` keeps in Git LFS (`filter=lfs`).
    public func lfsPaths(_ paths: [String]) async -> [String] {
        guard !paths.isEmpty, usesLFS else { return [] }
        let input = Data(paths.joined(separator: "\0").appending("\0").utf8)
        guard let output = try? await git(["check-attr", "-z", "--stdin", "filter"], input: input) else { return [] }
        // <path> NUL filter NUL <value> NUL
        let records = Records.splitNUL(output.stdout)
        var result: [String] = []
        var index = 0
        while index + 2 < records.count {
            if records[index + 2] == "lfs" { result.append(records[index]) }
            index += 3
        }
        return result
    }

    /// Sizes of the Git LFS files among `paths` between two revisions (commits, or "HEAD"). A
    /// `nil` `new` means the files on disk. `oldPaths` maps renamed files to their old path.
    public func lfsSizes(of paths: [String], oldPaths: [String: String] = [:], from old: String?, to new: String?) async -> [String: LFSSizes] {
        let lfs = await lfsPaths(paths)
        guard !lfs.isEmpty else { return [:] }
        var specs: [String] = []
        if let old { specs += lfs.map { "\(old):\(oldPaths[$0] ?? $0)" } }
        if let new { specs += lfs.map { "\(new):\($0)" } }
        let sizes = await lfsBlobSizes(specs)
        var result: [String: LFSSizes] = [:]
        for path in lfs {
            let oldSize = old.flatMap { sizes["\($0):\(oldPaths[path] ?? path)"] }
            let newSize: Int?
            if let new {
                newSize = sizes["\(new):\(path)"]
            } else {
                newSize = workingTreeLFSSize(path)
            }
            if oldSize != nil || newSize != nil {
                result[path] = LFSSizes(old: oldSize, new: newSize)
            }
        }
        return result
    }

    /// Tracked files in Git LFS paths that are still pointers on disk: git-lfs never replaced
    /// them with their content.
    public func lfsPointerFiles() async -> [String] {
        guard usesLFS else { return [] }
        return await lfsPaths(await trackedFiles()).filter { path in
            guard let handle = FileHandle(forReadingAtPath: root.appending(path: path).path(percentEncoded: false)) else { return false }
            defer { try? handle.close() }
            let head = (try? handle.read(upToCount: 64)) ?? Data()
            return head.starts(with: Data(Self.lfsPointerPrefix.utf8))
        }
    }

    /// Where Git LFS keeps the content of `oid` ("sha256:…"), when it has been downloaded.
    public func lfsObjectURL(_ oid: String) -> URL? {
        let hex = oid.hasPrefix("sha256:") ? String(oid.dropFirst("sha256:".count)) : oid
        // A SHA-256 in hex and nothing else: a pointer from a commit must not name a path
        // ("sha256:../../…") outside .git/lfs/objects.
        guard hex.utf8.count == 64, hex.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }) else { return nil }
        let url = commonGitDirectory
            .appending(path: "lfs/objects")
            .appending(path: String(hex.prefix(2)))
            .appending(path: String(hex.dropFirst(2).prefix(2)))
            .appending(path: hex)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// The git directory shared by all working trees (a linked worktree's own one points to it).
    var commonGitDirectory: URL {
        let file = gitDirectory.appending(path: "commondir").path(percentEncoded: false)
        guard let data = FileManager.default.contents(atPath: file) else { return gitDirectory }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/")
            ? URL(filePath: path, directoryHint: .isDirectory)
            : gitDirectory.appending(path: path, directoryHint: .isDirectory).standardizedFileURL
    }

    static let lfsPointerPrefix = "version https://git-lfs.github.com/spec/"

    /// What each `<rev>:<path>` holds in Git LFS: the size its pointer gives, or the blob's own
    /// size when the file was committed without LFS. Missing ones are left out.
    private func lfsBlobSizes(_ specs: [String]) async -> [String: Int] {
        guard !specs.isEmpty else { return [:] }
        let input = Data(specs.joined(separator: "\n").appending("\n").utf8)
        guard let check = try? await git(["cat-file", "--batch-check=%(objectname) %(objectsize)"], input: input) else { return [:] }
        var objects: [String: (oid: String, size: Int)] = [:]
        for (spec, line) in zip(specs, check.text.split(separator: "\n", omittingEmptySubsequences: false)) {
            // "<spec> missing" when the revision doesn't have the file.
            let parts = line.split(separator: " ")
            guard parts.count == 2, let size = Int(parts[1]) else { continue }
            objects[spec] = (String(parts[0]), size)
        }
        // Pointers are about 130 bytes: read those, and keep the size of anything bigger.
        let small = Set(objects.values.filter { $0.size < 1024 }.map(\.oid))
        var pointerSizes: [String: Int] = [:]
        if !small.isEmpty {
            let input = Data(small.joined(separator: "\n").appending("\n").utf8)
            if let output = try? await git(["cat-file", "--batch"], input: input) {
                pointerSizes = Self.pointerSizes(inBatch: output.stdout)
            }
        }
        return objects.mapValues { pointerSizes[$0.oid] ?? $0.size }
    }

    /// `git cat-file --batch` output ("<oid> <type> <size>" LF <contents> LF, repeated): the
    /// size each pointer among them gives, by object name.
    static func pointerSizes(inBatch data: Data) -> [String: Int] {
        var result: [String: Int] = [:]
        var index = data.startIndex
        while index < data.endIndex {
            guard let newline = data[index...].firstIndex(of: 0x0A) else { break }
            let header = String(decoding: data[index ..< newline], as: UTF8.self).split(separator: " ")
            index = data.index(after: newline)
            guard header.count == 3, let size = Int(header[2]) else { continue }
            let end = data.index(index, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            let lines = String(decoding: data[index ..< end], as: UTF8.self).components(separatedBy: "\n")
            if let pointer = LFSPointer.parse(lines) {
                result[String(header[0])] = pointer.size
            }
            index = end < data.endIndex ? data.index(after: end) : end
        }
        return result
    }

    /// A file on disk in an LFS path: the size its pointer gives while it's a pointer, else its own.
    private func workingTreeLFSSize(_ path: String) -> Int? {
        let file = root.appending(path: path).path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file),
              let size = (attributes[.size] as? NSNumber)?.intValue else { return nil }
        if size < 1024, let data = FileManager.default.contents(atPath: file),
           let pointer = LFSPointer.parse(String(decoding: data, as: UTF8.self).components(separatedBy: "\n")) {
            return pointer.size
        }
        return size
    }
}
