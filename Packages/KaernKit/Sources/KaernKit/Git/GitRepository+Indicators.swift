import Foundation

/// A submodule from `git submodule status`.
public struct Submodule: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        case upToDate
        /// Not cloned: its files are missing (`-`).
        case notInitialized
        /// Checked out at another commit than the one this repository records (`+`).
        case moved
        /// Merge conflict on the submodule (`U`).
        case conflicted
    }

    public var path: String
    /// The commit checked out inside (or recorded, when not initialized).
    public var commit: String
    public var state: State

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    /// Parses one `git submodule status` line: `<flag><sha> <path>[ (<describe>)]`.
    static func parse(_ line: Substring) -> Submodule? {
        guard let flag = line.first else { return nil }
        let rest = line.dropFirst()
        let parts = rest.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        var path = String(parts[1])
        if let paren = path.range(of: " (", options: .backwards) { path = String(path[..<paren.lowerBound]) }
        let state: State = switch flag {
        case "-": .notInitialized
        case "+": .moved
        case "U": .conflicted
        default: .upToDate
        }
        return Submodule(path: path, commit: String(parts[0]), state: state)
    }
}

/// A working tree from `git worktree list --porcelain`.
public struct Worktree: Sendable, Hashable, Identifiable {
    public var path: String
    public var head: String?
    /// Short branch name; `nil` when detached.
    public var branch: String?
    public var isBare = false
    public var isLocked = false

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

/// Who signed a commit and whether git trusts the key (`%G?`, `%GS`, `%GK`).
public struct CommitSignature: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        case verified
        /// Good signature from a key git can't vouch for (not in allowed signers, unknown trust).
        case unverified
        case bad
        case expired
        case revoked
        /// Signed, but the key isn't available to check.
        case missingKey
    }

    public var status: Status
    public var signer: String
    public var key: String
    /// "SSH", "GPG" or "X.509".
    public var format: String

    /// `nil` for unsigned commits.
    static func parse(_ text: String) -> CommitSignature? {
        let fields = Records.fields(text.trimmingCharacters(in: .newlines), maxSplits: 3)
        guard let code = fields.first?.first, code != "N" else { return nil }
        let status: Status = switch code {
        case "G": .verified
        case "U": .unverified
        case "B": .bad
        case "X", "Y": .expired
        case "R": .revoked
        default: .missingKey
        }
        let key = fields.count > 2 ? fields[2] : ""
        let raw = fields.count > 3 ? fields[3] : ""
        let format = raw.contains("SSH") || key.hasPrefix("SHA256:") ? "SSH" : (raw.contains("x509") || raw.contains("X.509") ? "X.509" : "GPG")
        return CommitSignature(status: status, signer: fields.count > 1 ? fields[1] : "", key: key, format: format)
    }
}

/// A Git LFS pointer file (`version https://git-lfs.github.com/spec/v1`, `oid`, `size`).
public struct LFSPointer: Sendable, Hashable {
    public var oid: String
    public var size: Int

    public static func parse(_ lines: [String]) -> LFSPointer? {
        guard lines.contains(where: { $0.hasPrefix("version https://git-lfs.github.com/spec/") }) else { return nil }
        let oid = lines.first { $0.hasPrefix("oid ") }.map { String($0.dropFirst(4)) } ?? ""
        let size = lines.first { $0.hasPrefix("size ") }.flatMap { Int($0.dropFirst(5)) } ?? 0
        return LFSPointer(oid: oid, size: size)
    }
}

extension FileDiff {
    /// The old and new pointers when the diff is of a file stored in Git LFS.
    public var lfsChange: (old: LFSPointer?, new: LFSPointer?)? {
        let lines = hunks.flatMap(\.lines)
        let old = LFSPointer.parse(lines.filter { $0.kind != .addition }.map(\.text))
        let new = LFSPointer.parse(lines.filter { $0.kind != .deletion }.map(\.text))
        guard old != nil || new != nil else { return nil }
        return (isNewFile ? nil : old, isDeletedFile ? nil : new)
    }
}

// MARK: - Reading

extension GitRepository {
    public func submodules() async -> [Submodule] {
        guard FileManager.default.fileExists(atPath: root.appending(path: ".gitmodules").path(percentEncoded: false)),
              let output = try? await git(["submodule", "status"]) else { return [] }
        return output.text.split(separator: "\n").compactMap(Submodule.parse)
    }

    /// Clone Submodule / Check Out <recorded>: `git submodule update --init -- <path>`.
    public func updateSubmodule(_ path: String) async throws {
        try await git(["submodule", "update", "--init", "--", path])
    }

    public func worktrees() async -> [Worktree] {
        guard let output = try? await git(["worktree", "list", "--porcelain"]) else { return [] }
        var result: [Worktree] = []
        var current: Worktree?
        for line in output.text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                if let current { result.append(current) }
                current = Worktree(path: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst(5))
            } else if line.hasPrefix("branch ") {
                current?.branch = String(line.dropFirst("branch ".count)).replacingOccurrences(of: "refs/heads/", with: "")
            } else if line == "bare" {
                current?.isBare = true
            } else if line.hasPrefix("locked") {
                current?.isLocked = true
            }
        }
        if let current { result.append(current) }
        return result
    }

    /// The signature of one commit (checking it runs gpg or ssh-keygen, so only on demand).
    public func signature(of id: String) async -> CommitSignature? {
        guard let output = try? await git(["log", "-1", "--format=%G?%x1f%GS%x1f%GK%x1f%GG", id, "--"]) else { return nil }
        return CommitSignature.parse(output.text)
    }

    /// Whether the repository stores files in Git LFS (`filter=lfs` in `.gitattributes`).
    public var usesLFS: Bool {
        guard let data = FileManager.default.contents(atPath: root.appending(path: ".gitattributes").path(percentEncoded: false)) else { return false }
        return String(decoding: data, as: UTF8.self).contains("filter=lfs")
    }

    /// `%G?` for each commit (G good, U untrusted, B bad, X/Y expired, R revoked, E can't check,
    /// N unsigned). For the rows on screen: checking runs gpg or ssh-keygen per signed commit.
    public func signatureCodes(of ids: [String]) async -> [String: Character] {
        guard !ids.isEmpty,
              let output = try? await git(["log", "--no-walk=unsorted", "--format=%H%x1f%G?"] + ids + ["--"]) else { return [:] }
        var codes: [String: Character] = [:]
        for line in output.text.split(separator: "\n") {
            let fields = Records.fields(line)
            if fields.count == 2, let code = fields[1].first { codes[fields[0]] = code }
        }
        return codes
    }
}

/// How many commits one side has that the other doesn't.
public struct CommitDistance: Sendable, Hashable {
    public var ahead: Int
    public var behind: Int

    public init(ahead: Int, behind: Int) {
        self.ahead = ahead
        self.behind = behind
    }
}

// MARK: - Submodules and worktrees

extension GitRepository {
    /// How far the commit checked out in the submodule at `path` is from `recorded`, the one
    /// this repository records. `nil` when the submodule doesn't have one of the commits.
    public func submoduleDistance(_ path: String, recorded: String, checkedOut: String) async -> CommitDistance? {
        let directory = root.appending(path: path, directoryHint: .isDirectory)
        guard let output = try? await runner.run(["rev-list", "--left-right", "--count", "\(recorded)...\(checkedOut)", "--"], in: directory) else { return nil }
        let counts = output.text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard counts.count == 2 else { return nil }
        return CommitDistance(ahead: counts[1], behind: counts[0])
    }

    /// `git worktree add`: a new folder with `branch` checked out. With `startPoint`, the branch
    /// is new and starts there (a remote branch as start point becomes its upstream).
    public func addWorktree(at folder: URL, branch: String, newBranchFrom startPoint: String?) async throws {
        let path = folder.path(percentEncoded: false)
        if let startPoint {
            try await git(["worktree", "add", "-b", branch, path, startPoint])
        } else {
            try await git(["worktree", "add", path, branch])
        }
    }

    /// `git worktree remove`: git refuses when the folder has changes that aren't committed.
    public func removeWorktree(_ path: String) async throws {
        try await git(["worktree", "remove", path])
    }
}

// MARK: - SSH signatures

extension GitRepository {
    /// The public key that made `commit`'s SSH signature ("ssh-ed25519 AAAA…"), read from the
    /// signature itself. `nil` for unsigned commits and GPG signatures.
    public func sshSigningKey(of commit: String) async -> String? {
        guard let output = try? await git(["cat-file", "commit", commit]) else { return nil }
        return SSHSignature.publicKey(inCommitObject: output.text)
    }

    /// The allowed signers file git checks SSH signatures against (`gpg.ssh.allowedSignersFile`),
    /// `nil` when none is set.
    public func allowedSignersFile() async -> URL? {
        guard let path = await config("gpg.ssh.allowedSignersFile") else { return nil }
        return URL(filePath: Self.expandingTilde(path), relativeTo: root)
    }

    /// Adds "<principal> <key>" to `file`, creating it (and its folder) when needed.
    public static func addAllowedSigner(principal: String, key: String, to file: URL) throws {
        let path = file.path(percentEncoded: false)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += "\(principal) \(key)\n"
        try Data(text.utf8).write(to: file, options: .atomic)
    }

    static func expandingTilde(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        return FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false).trimmingSuffix("/") + "/" + path.dropFirst(2)
    }
}

extension GitRunner {
    /// `git config --global <key> <value>`.
    public func setGlobalConfig(_ key: String, _ value: String) async throws {
        try await run(["config", "--global", key, value], in: nil)
    }
}

/// Reads the `SSHSIG` blob git stores in a commit's `gpgsig` header.
enum SSHSignature {
    static func publicKey(inCommitObject text: String) -> String? {
        var armored: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if armored.isEmpty {
                if line.hasPrefix("gpgsig ") || line.hasPrefix("gpgsig-sha256 ") {
                    armored.append(String(line.drop(while: { $0 != " " }).dropFirst()))
                } else if line.isEmpty {
                    return nil   // end of the headers
                }
            } else if line.hasPrefix(" ") {
                armored.append(String(line.dropFirst()))
            } else {
                break
            }
        }
        guard armored.first == "-----BEGIN SSH SIGNATURE-----" else { return nil }
        let body = armored.dropFirst().prefix { !$0.hasPrefix("-----END") }.joined()
        guard let data = Data(base64Encoded: body) else { return nil }
        return publicKey(inSignature: [UInt8](data))
    }

    /// "SSHSIG", a version, then the signer's public key as an SSH string.
    static func publicKey(inSignature bytes: [UInt8]) -> String? {
        guard bytes.count > 10, Array(bytes[0 ..< 6]) == Array("SSHSIG".utf8) else { return nil }
        var offset = 10
        guard let blob = readString(bytes, at: &offset) else { return nil }
        var inner = 0
        guard let type = readString(blob, at: &inner), let name = String(bytes: type, encoding: .utf8) else { return nil }
        return "\(name) \(Data(blob).base64EncodedString())"
    }

    private static func readString(_ bytes: [UInt8], at offset: inout Int) -> [UInt8]? {
        guard offset + 4 <= bytes.count else { return nil }
        let length = bytes[offset ..< offset + 4].reduce(0) { $0 << 8 | Int($1) }
        offset += 4
        guard offset + length <= bytes.count else { return nil }
        defer { offset += length }
        return Array(bytes[offset ..< offset + length])
    }
}
