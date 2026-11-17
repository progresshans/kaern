import AppKit
import KaernKit

/// Clone, Create New Repository and Publish to GitHub (ScreenWelcome's Clone sheet, ScreenInit).
extension AppModel {
    // MARK: Sheets

    /// File › Clone Repository… (⇧⌘C).
    func showClone(in window: WindowModel, url: String = "") {
        if case .clone = window.sheet { return }
        guard canShowSheet(in: window) else { return }
        window.sheet = .clone(CloneModel(url: url))
    }

    /// A sheet that's working (a clone under way) stays: another one would take its place, and
    /// the work would close that one when it finishes.
    private func canShowSheet(in window: WindowModel) -> Bool {
        guard window.sheet?.isBusy == true else { return true }
        NSSound.beep()
        return false
    }

    /// Closes `model`'s sheet, if that's still the one the window shows.
    private func closeSheet(of model: AnyObject, in window: WindowModel) {
        if window.sheet?.id == ObjectIdentifier(model) { window.sheet = nil }
    }

    /// File › Create New Repository… (⌥⌘N), or Create Repository Here… for `folder`.
    func showCreate(in window: WindowModel, folder: URL? = nil) {
        guard canShowSheet(in: window) else { return }
        let model = CreateModel(existingFolder: folder)
        window.sheet = .create(model)
        Task {
            if let runner = await waitForGit() {
                let branch = await GitRepository.defaultBranchName(runner: runner)
                if model.branch == "main" { model.branch = branch }
            }
            if let folder {
                let survey = await Task.detached { FolderSurvey.survey(folder) }.value
                model.survey = survey
                model.ignore = survey.template
            }
        }
    }

    func showPublish(_ repository: RepositoryModel, in window: WindowModel) {
        guard canShowSheet(in: window) else { return }
        window.sheet = .publish(PublishModel(repositoryPath: repository.path, name: repository.name))
    }

    /// Closes the window's sheet; one that's working is stopped first.
    func closeSheet(in window: WindowModel) {
        switch window.sheet {
        case .clone(let model) where model.isCloning && model.task != nil:
            // The first Cancel stops the clone; the sheet stays to try again.
            model.task?.cancel()
        case .create(let model) where model.isRunning:
            return
        case .publish(let model) where model.isRunning:
            return
        default:
            window.sheet = nil
        }
    }

    /// The runner, as soon as git has been found. That takes a moment after launch (seconds when
    /// the developer tools are cold) and always ends with one; `nil` only when the waiting task
    /// was cancelled.
    func waitForGit() async -> GitRunner? {
        while runner == nil {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
        }
        return runner
    }

    // MARK: Clone

    func startClone(_ model: CloneModel, in window: WindowModel) {
        guard !model.isCloning, model.problem == nil, let destination = model.destinationURL else { return }
        let remote = model.url.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only a path that starts with ~ is expanded (NSString would also fold the slashes of file:///).
        let source = remote.hasPrefix("~") ? (remote as NSString).expandingTildeInPath : remote
        model.isCloning = true
        model.error = nil
        model.failure = nil
        model.progress = nil
        let name = destination.lastPathComponent
        let center = ActivityCenter.shared
        let taskID = center.begin(repositoryPath: destination.path(percentEncoded: false), repositoryName: name,
                                  title: "Cloning \(name)", cancel: { [weak model] in model?.task?.cancel() })
        model.task = Task {
            guard let runner = await waitForGit() else {
                // Cancel before git was found.
                center.finish(taskID, result: "Stopped")
                model.isCloning = false
                model.task = nil
                return
            }
            do {
                let repository = try await GitCommandTrigger.$current.withValue(GitCommandTrigger("Clone Repository")) {
                    try await GitRepository.clone(source, into: destination, runner: runner) { progress in
                        Task { @MainActor in
                            model.progress = progress
                            center.update(taskID, progress: progress)
                        }
                    }
                }
                ProjectsFolder.remember(destination.deletingLastPathComponent())
                let path = repository.root.path(percentEncoded: false).trimmingTrailingSlash
                let from = model.host ?? Formatters.abbreviatedPath(source.hasPrefix("file://") ? String(source.dropFirst(7)) : source)
                center.finish(taskID, result: "Cloned \(name) from \(from)")
                model.isCloning = false
                model.task = nil
                closeSheet(of: model, in: window)
                if model.opensTab {
                    await openNow([URL(filePath: path, directoryHint: .isDirectory)], in: window)
                    self.repository(for: path).showToast("Cloned \(name) from \(from)")
                } else {
                    noteRecent(path: path, name: name)
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
                }
            } catch is CancellationError {
                center.finish(taskID, result: "Stopped")
                model.isCloning = false
                model.progress = nil
                model.task = nil
            } catch {
                let gitError = error as? GitError
                let failure = gitError.flatMap { GitFailure.explain(arguments: $0.arguments, errorOutput: $0.message, status: $0.status) }
                center.finish(taskID, result: error.localizedDescription, failure: failure, failed: true)
                model.isCloning = false
                model.task = nil
                model.progress = nil
                model.failure = failure
                model.error = FailureHelp.sentence(for: failure) ?? error.localizedDescription
            }
        }
    }

    // MARK: Create

    func startCreate(_ model: CreateModel, in window: WindowModel) {
        guard model.canCreate else { return }
        let folder = model.folder
        let name = model.existingFolder?.lastPathComponent ?? model.cleanName
        let branch = model.branch.trimmingCharacters(in: .whitespaces)
        model.isRunning = true
        model.error = nil
        var steps: [(String, String)] = [("init", "git init --initial-branch=\(branch)"
            + (model.existingFolder == nil ? " \(Formatters.abbreviatedPath(folder.path(percentEncoded: false)))" : ""))]
        var files: [(path: String, contents: Data)] = []
        if let ignore = model.ignore.contents { files.append((".gitignore", Data(ignore.utf8))) }
        if model.readme { files.append(("README.md", Data("# \(name)\n".utf8))) }
        let holder = HostingAccount.all.first?.name ?? NSFullUserName()
        if let license = model.license.text(holder: holder, year: Calendar.current.component(.year, from: .now)) {
            files.append(("LICENSE", Data(license.utf8)))
        }
        let writable = files.filter { !FileManager.default.fileExists(atPath: folder.appending(path: $0.path).path(percentEncoded: false)) }
        if !writable.isEmpty { steps.append(("write", "Write " + writable.map(\.path).joined(separator: ", "))) }
        if model.firstCommit { steps.append(("commit", "git add -A && git commit -m \"Initial commit\"")) }
        // GitHub's own name for it (a space or 한글 in the folder's name is a dash there).
        let githubName = GitHubClient.repositoryName(for: name)
        if model.publish { steps.append(("publish", "Create \(githubName) on GitHub (\(model.isPrivate ? "private" : "public")) and push \(branch)")) }
        model.setSteps(steps)
        let center = ActivityCenter.shared
        let taskID = center.begin(repositoryPath: folder.path(percentEncoded: false), repositoryName: name, title: "Creating \(name)")
        model.task = Task {
            guard let runner = await waitForGit() else {
                center.finish(taskID, result: "Stopped")
                model.isRunning = false
                return
            }
            model.advance(to: "init")
            do {
                let (repository, _) = try await GitCommandTrigger.$current.withValue(GitCommandTrigger("Create Repository")) {
                    try await GitRepository.create(at: folder, defaultBranch: branch, files: files,
                                                   commitMessage: model.firstCommit ? "Initial commit" : nil, runner: runner) { step in
                        let key = switch step {
                        case .initialize: "init"
                        case .writeFiles: "write"
                        case .commit: "commit"
                        }
                        Task { @MainActor in model.advance(to: key) }
                    }
                }
                if model.existingFolder == nil { ProjectsFolder.remember(folder.deletingLastPathComponent()) }
                let path = repository.root.path(percentEncoded: false).trimmingTrailingSlash
                let fileCount = await repository.trackedFiles().count
                let note = model.firstCommit ? "Created \(name) · 1 commit · \(Formatters.count(fileCount, "file", "files"))" : "Created \(name)"
                // The repository is there from here on. When only publishing fails it still opens,
                // and Publish to GitHub comes up with what went wrong: its sheet can try again
                // (under another name too), where Create would fail at a commit with nothing new.
                var publishError: Error?
                if model.publish, let account = model.githubAccount {
                    model.advance(to: "publish")
                    do {
                        try await publish(repository, name: githubName, isPrivate: model.isPrivate, account: account, runner: runner)
                    } catch {
                        publishError = error
                    }
                }
                if let publishError {
                    model.failCurrentStep()
                    center.finish(taskID, result: "\(note) · Publishing failed: \(publishError.localizedDescription)", failed: true)
                } else {
                    model.advance(to: nil)
                    center.finish(taskID, result: note)
                    // A moment to see every step ticked off.
                    try? await Task.sleep(for: .milliseconds(350))
                }
                model.isRunning = false
                closeSheet(of: model, in: window)
                await openNow([URL(filePath: path, directoryHint: .isDirectory)], in: window, restart: true)
                let opened = self.repository(for: path)
                opened.createdNote = note
                opened.showsPublishBanner = !model.publish || publishError != nil
                if let publishError, window.sheet == nil {
                    let retry = PublishModel(repositoryPath: path, name: name)
                    retry.isPrivate = model.isPrivate
                    retry.error = publishError.localizedDescription
                    window.sheet = .publish(retry)
                }
            } catch {
                model.failCurrentStep()
                center.finish(taskID, result: error.localizedDescription, failed: true)
                model.isRunning = false
                model.error = error.localizedDescription
            }
        }
    }

    // MARK: Publish

    /// Makes the GitHub repository, adds it as origin and pushes HEAD with its upstream.
    func publish(_ repository: GitRepository, name: String, isPrivate: Bool, account: HostingAccount, runner: GitRunner) async throws {
        guard let token = await runner.credential(host: account.host, username: account.login) else {
            throw HostingError(status: 401, message: "Kaern couldn’t read the token for \(account.login). Sign in again in Settings › Accounts.")
        }
        let client = GitHubClient(baseURL: GitHubClient.apiURL(for: account.host), token: token)
        let created = try await client.createRepository(name: name, isPrivate: isPrivate)
        try await GitCommandTrigger.$current.withValue(GitCommandTrigger("Publish to GitHub")) {
            try await repository.addRemote("origin", url: account.clonesWithSSH ? created.sshURL : created.httpsURL)
            try await repository.push(setUpstreamOn: "origin")
        }
    }

    func startPublish(_ model: PublishModel, in window: WindowModel) {
        guard model.nameIsValid, !model.isRunning, let account = model.account else { return }
        let target = repository(for: model.repositoryPath)
        guard let git = target.repository else { return }
        model.isRunning = true
        model.error = nil
        let name = model.githubName
        model.progress = "Creating \(name) on GitHub…"
        Task {
            guard let runner = await waitForGit() else {
                model.isRunning = false
                model.progress = nil
                return
            }
            do {
                try await publish(git, name: name, isPrivate: model.isPrivate, account: account, runner: runner)
                model.isRunning = false
                closeSheet(of: model, in: window)
                target.showsPublishBanner = false
                target.createdNote = nil
                await target.refreshRemotes()
                target.showToast("Published \(target.name) to github.com/\(account.login)/\(name)")
            } catch {
                model.isRunning = false
                model.progress = nil
                model.error = error.localizedDescription
            }
        }
    }

    // MARK: Opening folders

    /// Opens folders as tabs and waits until they're in the strip. A folder that isn't in a
    /// repository becomes a tab too: it shows what's in it and offers Create Repository Here.
    /// `restart`: the folder's model reopens (it just became a repository).
    @discardableResult
    func openNow(_ urls: [URL], in window: WindowModel, restart: Bool = false) async -> [String] {
        guard let runner = await waitForGit() else { return [] }
        var paths: [String] = []
        var failures: [String] = []
        for url in urls {
            do {
                let repository = try await GitRepository.open(url, runner: runner)
                paths.append(repository.root.path(percentEncoded: false).trimmingTrailingSlash)
            } catch let error as NotARepositoryError {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory), isDirectory.boolValue {
                    paths.append(canonicalPath(url.path(percentEncoded: false)).trimmingTrailingSlash)
                } else {
                    failures.append(error.localizedDescription)
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !paths.isEmpty {
            for path in paths {
                let model = repository(for: path)
                if restart { retry(model) }
            }
            window.open(paths: paths)
            for path in paths.reversed() { noteRecent(path: path, in: window) }
            releaseUnusedRepositoriesNow()
            updateVisibility()
        }
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = failures.count == 1 ? "Couldn't open the folder" : "Couldn't open \(failures.count) folders"
            alert.informativeText = failures.joined(separator: "\n")
            if let host = hostWindow(for: window) {
                alert.beginSheetModal(for: host) { _ in }
            } else {
                alert.runModal()
            }
        }
        return paths
    }
}

extension AppModel {
    /// Locate…: a repository's folder moved to `url`. Every tab showing the old folder points at
    /// the new one. Returns the new folder, or `nil` when `url` isn't a repository's own folder:
    /// a folder inside another repository (a parent folder that is one, a monorepo) would point
    /// the tab at that repository instead.
    func relocate(_ oldPath: String, to url: URL) async -> String? {
        guard let runner = await waitForGit(),
              let repository = try? await GitRepository.open(url, runner: runner) else { return nil }
        let newPath = repository.root.path(percentEncoded: false).trimmingTrailingSlash
        guard newPath == canonicalPath(url.path(percentEncoded: false)).trimmingTrailingSlash else { return nil }
        guard newPath != oldPath else { retry(self.repository(for: oldPath)); return newPath }
        _ = self.repository(for: newPath)
        for controller in windows {
            controller.model.replacePath(oldPath, with: newPath)
        }
        forgetRecent(oldPath)
        releaseUnusedRepositoriesNow()
        updateVisibility()
        scheduleSave()
        return newPath
    }
}

extension ActivityCenter {
    /// A progress line from git (Receiving objects: 62%…) for a running task.
    func update(_ id: UUID, progress: GitProgress) {
        let fraction = progress.overallFraction
        let detail = [progress.percent.map { "\(progress.phase) \($0)%" } ?? progress.phase, progress.detail].compactMap { $0 }
            .joined(separator: " · ")
        update(id, detail: detail, fraction: fraction)
    }
}
