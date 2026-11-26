import AppKit
import KaernKit
import Quartz

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

/// A submodule as the sidebar lists it (ScreenMarks › Submodules).
struct SubmoduleItem: Equatable, Identifiable {
    var path: String
    var state: Submodule.State
    /// "2.6.4 → 2.7.0 · 3 new commits", "0.54.6 · up to date", "Not initialized".
    var detail: String

    var id: String { path }
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
            showInQuickLook(URL(filePath: self.path, directoryHint: .isDirectory).appending(path: path))
            return
        }
        Task {
            guard let contents = await fileContents(path, at: version) else { return }
            guard let data = contents.data else {
                showToast(contents.isMissingLFSContent ? "\(file.name) isn’t downloaded · Download it first" : "\(file.name) is too big for Quick Look")
                return
            }
            do {
                showInQuickLook(try QuickLookCopies.make(data, name: (path as NSString).lastPathComponent))
            } catch {
                showToast("Couldn’t open Quick Look: \(error.localizedDescription)")
            }
        }
    }

    /// Shows `url` in Quick Look: now, or once the panel has finished a close that's still underway.
    func showInQuickLook(_ url: URL) {
        QuickLookPanel.open(for: self) { [weak self] in self?.quickLookURL = url }
    }

    /// Closes Quick Look (Space again), or drops the file that waits to be shown.
    func closeQuickLook() {
        QuickLookPanel.close(for: self)
        quickLookURL = nil
    }

    /// Quick Look is open, or its file waits for the last close to finish.
    var showsQuickLook: Bool { quickLookURL != nil || QuickLookPanel.isWaiting(for: self) }

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

    // MARK: Shallow clones

    /// Fetch 100 More, or with `nil` Fetch Full History, at the end of a shallow clone's history.
    func fetchMoreHistory(_ count: Int?) {
        let remote = defaultRemote ?? "origin"
        let title = count.map { "Fetching \($0) more commits…" } ?? "Fetching the full history…"
        perform(.network(title), trigger: count.map { "Fetch \($0) More" } ?? "Fetch Full History") { repository in
            try await repository.deepen(by: count, remote: remote)
        } onSuccess: { [weak self] in
            guard let self else { return }
            self.isShallow = self.repository?.isShallow ?? false
            self.showToast(count.map { _ in "Fetched older commits" } ?? "Fetched the full history")
        }
    }

    // MARK: Submodules

    func refreshSubmodules() async {
        guard let repository else { return }
        var items: [SubmoduleItem] = []
        for submodule in await repository.submodules() {
            let detail: String
            switch submodule.state {
            case .notInitialized:
                detail = "Not initialized"
            case .conflicted:
                detail = "Conflicted"
            case .upToDate:
                let change = await repository.submoduleChange(submodule.path, from: submodule.commit, to: submodule.commit, limit: 0)
                detail = "\(change.newTag ?? String(submodule.commit.prefix(7))) · up to date"
            case .moved:
                // Porcelain can omit a submodule (including when submodule.<name>.ignore is all).
                // Read its stage-zero gitlink from the same repository that reported the move.
                guard let recorded = await repository.resolve(":0:\(submodule.path)") else { continue }
                let change = await repository.submoduleChange(submodule.path, from: recorded, to: submodule.commit, limit: 0)
                let from = change.oldTag ?? String(recorded.prefix(7))
                let to = change.newTag ?? String(submodule.commit.prefix(7))
                let movement = change.isFastForward
                    ? Formatters.count(change.addedCount, "new commit", "new commits")
                    : Self.submoduleNote(CommitDistance(ahead: change.addedCount, behind: change.removedCount))
                detail = "\(from) → \(to) · \(movement)"
            }
            items.append(SubmoduleItem(path: submodule.path, state: submodule.state, detail: detail))
        }
        if items != submoduleItems { submoduleItems = items }
    }

    /// Initialize: clones the submodule at the commit this repository records.
    func initializeSubmodule(_ submodulePath: String) {
        perform(.network("Cloning \(submodulePath)…"), trigger: "Initialize \(submodulePath)") { repository in
            try await repository.updateSubmodule(submodulePath)
        } onSuccess: { [weak self] in
            self?.showToast("Initialized \(submodulePath)")
        }
    }

    /// Update to Recorded: checks out, inside the submodule, the commit this repository records.
    /// When no branch in the submodule holds what's checked out there, those commits would be
    /// left behind, so it asks first. ⌘Z checks out what the submodule had before.
    func updateSubmoduleToRecorded(_ submodulePath: String, label: String) {
        guard let repository, activity == nil else { return }
        Task { [weak self] in
            let behind = await repository.submoduleCommitsOnNoBranch(submodulePath)
            guard let self else { return }
            guard !behind.isEmpty else {
                updateSubmoduleNow(submodulePath, label: label)
                return
            }
            let them = behind.count == 1 ? "it" : "them"
            confirmation = Confirmation(
                title: "Leave \(Formatters.count(behind.count, "commit", "commits")) in \(submodulePath) on no branch?",
                message: "No branch or tag in \(submodulePath) has \(behind.count == 1 ? "this commit" : "these commits"). Checking out "
                    + "\(label) leaves \(them) where only Git’s reflog finds \(them); ⌘Z checks \(them) out again.",
                lost: behind,
                note: "Return cancels. To keep \(them) under a name, open the submodule and make a branch first.",
                confirmTitle: "Update to \(label)",
                confirm: { [weak self] in self?.updateSubmoduleNow(submodulePath, label: label) }
            )
        }
    }

    private func updateSubmoduleNow(_ submodulePath: String, label: String) {
        let action = "Update \(submodulePath) to \(label)"
        perform(.working("Checking out \(label) in \(submodulePath)…"), trigger: "Update \(submodulePath) to Recorded") { [weak self] repository in
            let before = await repository.submodulePosition(submodulePath)
            try await repository.checkOutRecordedSubmodule(submodulePath)
            guard let self else { return }
            var step: ReversibleStep?
            if let before, let after = await repository.submoduleHead(submodulePath), before.commit != after || before.branch != nil {
                step = .submoduleCheckout(label: action, path: submodulePath,
                                          from: before.branch.map { .branch($0) } ?? .detached(before.commit), to: after)
            }
            self.record(step, toast: "\(submodulePath) is at \(label) again")
        }
    }

    /// Open Submodule: the submodule as its own tab.
    func openSubmodule(_ submodulePath: String) {
        let url = URL(filePath: path, directoryHint: .isDirectory).appending(path: submodulePath, directoryHint: .isDirectory)
        guard let window = AppModel.shared.activeWindow?.model else { return }
        AppModel.shared.open([url], in: window)
    }
}

/// Copies of file versions for Quick Look, which needs a file (an older version, an LFS file's
/// content). Each new copy removes the one before it, quitting removes the last, and copies an
/// earlier run left behind go at launch.
@MainActor
enum QuickLookCopies {
    static let folder = FileManager.default.temporaryDirectory.appending(path: "Kaern Quick Look", directoryHint: .isDirectory)
    private static var last: URL?

    static func make(_ data: Data, name: String) throws -> URL {
        removeLast()
        let place = folder.appending(path: String(UUID().uuidString.prefix(8)), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let url = place.appending(path: name)
        try data.write(to: url)
        last = place
        return url
    }

    static func removeLast() {
        if let last { try? FileManager.default.removeItem(at: last) }
        last = nil
    }

    /// Copies more than a day old (another Kaern that's open may be showing a newer one).
    static func removeOld() {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }
        let dayAgo = Date.now.addingTimeInterval(-86_400)
        for item in items {
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < dayAgo { try? fileManager.removeItem(at: item) }
        }
    }
}

/// Quick Look's panel, which every window shares, fades out when it closes, and SwiftUI's quickLookPreview clears
/// its binding when that fade ends, also when a new file was put in it meanwhile: Quick Look opened again right
/// after a close (Space twice) closed at once. So a file opened while a close is underway waits for it to finish.
@MainActor
enum QuickLookPanel {
    private static var closing: (observer: any NSObjectProtocol, number: Int)?
    private static var closes = 0
    /// The file to show once the close has finished: the last one asked for.
    private static var waiting: (owner: ObjectIdentifier, open: () -> Void)?

    /// Runs `open` now, or once the close underway has finished.
    static func open(for owner: AnyObject, _ open: @escaping () -> Void) {
        guard closing != nil else { return open() }
        waiting = (ObjectIdentifier(owner), open)
    }

    static func isWaiting(for owner: AnyObject) -> Bool { waiting?.owner == ObjectIdentifier(owner) }

    /// Kaern closes Quick Look; a file opened from now on waits until the panel's willClose. SwiftUI clears its
    /// binding in that notification too, so the file goes in after it. A close that never reports one (the panel
    /// wasn't up yet) holds a file for 2 seconds at most.
    static func close(for owner: AnyObject) {
        if isWaiting(for: owner) { waiting = nil }
        guard closing == nil else { return }
        closes += 1
        let number = closes
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard note.object is QLPreviewPanel else { return }
            Task { @MainActor in closed(number) }
        }
        closing = (observer, number)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            closed(number)
        }
    }

    private static func closed(_ number: Int) {
        guard let current = closing, current.number == number else { return }
        NotificationCenter.default.removeObserver(current.observer)
        closing = nil
        let open = waiting?.open
        waiting = nil
        open?()
    }
}
