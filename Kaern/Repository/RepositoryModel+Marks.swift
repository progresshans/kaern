import AppKit
import KaernKit

/// Git LFS and submodule facts about the working copy's files (ScreenMarks): which are in LFS
/// and their sizes, which are still pointers, and how far each moved submodule is from the
/// commit recorded for it.
struct WorkingMarks: Equatable {
    var lfsSizes: [String: LFSSizes] = [:]
    /// Every tracked LFS file that's still a pointer on disk (the status bar counts them).
    var lfsPointers: Set<String> = []
    /// "3 commits" for submodules checked out away from the commit recorded for them.
    var submoduleNotes: [String: String] = [:]

    static let empty = WorkingMarks()
}

/// The same for one commit's files.
struct CommitMarks: Equatable {
    let id: String
    var lfsSizes: [String: LFSSizes] = [:]
    /// LFS files whose content in this commit isn't on this Mac.
    var lfsMissing: Set<String> = []
}

extension RepositoryModel {
    func refreshWorkingMarks() async {
        guard let repository else { return }
        var marks = WorkingMarks()
        if repository.usesLFS {
            let paths = status.entries.map(\.path)
            marks.lfsSizes = await repository.lfsSizes(of: paths, from: status.headID == nil ? nil : "HEAD", to: nil)
            // Pointers whose content isn't in .git/lfs/objects either: really not downloaded.
            for path in await repository.lfsPointerFiles() {
                let pointer = await repository.lfsPointer(of: path, at: .workTree)
                if pointer.map({ repository.lfsObjectURL($0.oid) == nil }) ?? true { marks.lfsPointers.insert(path) }
            }
        }
        for entry in status.entries {
            guard let submodule = entry.submodule, submodule.commitChanged, let recorded = submodule.indexCommit,
                  let head = await repository.submoduleHead(entry.path),
                  let distance = await repository.submoduleDistance(entry.path, recorded: recorded, checkedOut: head) else { continue }
            marks.submoduleNotes[entry.path] = Self.submoduleNote(distance)
        }
        if marks != workingMarks { workingMarks = marks }
    }

    /// "3 commits", "2 back", "3 new · 2 back".
    static func submoduleNote(_ distance: CommitDistance) -> String {
        switch (distance.ahead, distance.behind) {
        case (0, 0): "moved"
        case (let ahead, 0): Formatters.count(ahead, "commit", "commits")
        case (0, let behind): "\(behind) back"
        case (let ahead, let behind): "\(ahead) new · \(behind) back"
        }
    }

    func loadCommitMarks(_ commit: Commit, files: [FileChange]) async {
        guard let repository else { return }
        var marks = CommitMarks(id: commit.id)
        if repository.usesLFS {
            let oldPaths = Dictionary(files.compactMap { file in file.oldPath.map { (file.path, $0) } }, uniquingKeysWith: { first, _ in first })
            marks.lfsSizes = await repository.lfsSizes(of: files.map(\.path), oldPaths: oldPaths, from: commit.parents.first, to: commit.id)
            for path in marks.lfsSizes.keys {
                if let pointer = await repository.lfsPointer(of: path, at: .revision(commit.id)),
                   repository.lfsObjectURL(pointer.oid) == nil {
                    marks.lfsMissing.insert(path)
                }
            }
        }
        guard case .commit(let id) = selection, id == commit.id else { return }
        commitMarks = marks
    }

    // MARK: Reading versions

    func fileContents(_ path: String, at version: FileVersion?, limit: Int = 64 << 20) async -> FileContents? {
        guard let version, let repository else { return nil }
        return await repository.contents(of: path, at: version, limit: limit)
    }

    func submoduleHead(_ submodulePath: String) async -> String? {
        await repository?.submoduleHead(submodulePath)
    }

    func submoduleChange(_ submodulePath: String, from old: String?, to new: String?) async -> SubmoduleChange {
        await repository?.submoduleChange(submodulePath, from: old, to: new)
            ?? SubmoduleChange(path: submodulePath, old: old, new: new, isInitialized: false)
    }

    /// Whether `.gitattributes` keeps files in Git LFS (Repository › Fetch LFS Files).
    var usesLFS: Bool { repository?.usesLFS ?? false }

    // MARK: Quick Look

    /// Quick Look (Space, ⌘Y): the file on disk, or a copy of the version Review shows.
    func quickLook(_ file: ReviewFile) {
        let deleted = file.sides.new == nil
        let path = deleted ? (file.sides.oldPath ?? file.path) : file.path
        guard let version = deleted ? file.sides.old : file.sides.new else { return }
        // An LFS file on disk may still be its pointer: show the content Kaern has instead.
        if case .workTree = version, !file.isLFS {
            quickLookURL = URL(filePath: self.path, directoryHint: .isDirectory).appending(path: path)
            return
        }
        Task {
            guard let contents = await fileContents(path, at: version) else { return }
            guard let data = contents.data else {
                showToast(contents.isMissingLFSContent ? "\(file.name) isn’t downloaded · Download it first" : "\(file.name) is too big for Quick Look")
                return
            }
            let folder = FileManager.default.temporaryDirectory
                .appending(path: "Kaern Quick Look", directoryHint: .isDirectory)
                .appending(path: String(UUID().uuidString.prefix(8)), directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appending(path: (path as NSString).lastPathComponent)
                try data.write(to: url)
                quickLookURL = url
            } catch {
                showToast("Couldn’t open Quick Look: \(error.localizedDescription)")
            }
        }
    }

    /// The file Review shows on its own (one file, or the Focus drawer's), for Quick Look.
    var quickLookFile: ReviewFile? {
        guard let files = reviewFiles else { return nil }
        if let review, !review.showsAllFiles {
            return files.first { $0.path == review.path } ?? files.first
        }
        if let drawerPath { return files.first { $0.path == drawerPath } }
        return nil
    }

    // MARK: Git LFS

    /// Settings: this repository downloads LFS files when one is opened.
    var alwaysDownloadsLFS: Bool {
        get { (UserDefaults.kaern.stringArray(forKey: SettingsKey.lfsAlwaysDownload) ?? []).contains(path) }
        set {
            var paths = UserDefaults.kaern.stringArray(forKey: SettingsKey.lfsAlwaysDownload) ?? []
            paths.removeAll { $0 == path }
            if newValue { paths.append(path) }
            UserDefaults.kaern.set(paths, forKey: SettingsKey.lfsAlwaysDownload)
        }
    }

    /// Downloads LFS files: into the work tree, or for `commit` just their content (the commit
    /// isn't checked out).
    func downloadLFS(_ paths: [String], at commit: String? = nil) {
        let what = paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) LFS files"
        let remote = defaultRemote ?? "origin"
        perform(.network("Downloading \(what)…"), trigger: "Download \(what)") { repository in
            try await repository.downloadLFS(paths, at: commit, remote: remote)
        } onSuccess: { [weak self] in
            guard let self else { return }
            self.showToast("Downloaded \(what)")
            self.reloadDiffs()
            if let commit, case .commit(let id) = self.selection, id == commit, let selected = self.commit(id) {
                Task { await self.loadCommitMarks(selected, files: self.selectedFiles) }
            }
        }
    }

    /// Repository › Fetch LFS Files: every LFS file of the checked-out commit.
    func fetchAllLFS() {
        perform(.network("Downloading LFS files…"), trigger: "Fetch LFS Files") { repository in
            try await repository.downloadAllLFS()
        } onSuccess: { [weak self] in
            self?.showToast("Downloaded the LFS files")
            self?.reloadDiffs()
        }
    }

    // MARK: Submodules

    /// Update to Recorded: checks out, inside the submodule, the commit this repository records.
    func updateSubmoduleToRecorded(_ submodulePath: String, label: String) {
        perform(.working("Checking out \(label) in \(submodulePath)…"), trigger: "Update \(submodulePath) to Recorded") { repository in
            try await repository.updateSubmodule(submodulePath)
        } onSuccess: { [weak self] in
            self?.showToast("\(submodulePath) is at \(label) again")
        }
    }

    /// Open Submodule: the submodule as its own tab.
    func openSubmodule(_ submodulePath: String) {
        let url = URL(filePath: path, directoryHint: .isDirectory).appending(path: submodulePath, directoryHint: .isDirectory)
        guard let window = AppModel.shared.activeWindow?.model else { return }
        AppModel.shared.open([url], in: window)
    }
}
