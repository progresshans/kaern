import KaernKit
import SwiftUI

/// Branch › New Worktree…: a branch checked out in a folder of its own, opened in a new window.
struct NewWorktreeSheet: View {
    let model: RepositoryModel

    @Environment(\.dismiss) private var dismiss
    /// `nil` makes a new branch; otherwise a local branch no working tree has checked out.
    @State private var existing: String?
    @State private var name = ""
    /// `nil` is HEAD.
    @State private var from: String?
    @State private var parent: URL?
    @State private var folderName = ""
    @State private var editedFolderName = false
    @State private var problem: String?
    @State private var isValid = false
    @State private var isCreating = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var branch: String { existing ?? trimmedName }
    private var trimmedFolder: String { folderName.trimmingCharacters(in: .whitespaces) }

    /// Branches git can check out in another folder: not the current one, not in another worktree.
    private var freeBranches: [Ref] {
        model.refs.localBranches.filter { !$0.isHead && model.worktree(using: $0.name) == nil }
    }

    private var sources: [(value: String?, title: String)] {
        [(nil, "\(model.headTitle) (HEAD)")] + model.refs.localBranches.filter { !$0.isHead }.map { ($0.name, $0.name) }
    }

    private var destination: URL? {
        guard let parent, !trimmedFolder.isEmpty else { return nil }
        return parent.appending(path: trimmedFolder, directoryHint: .isDirectory)
    }

    var body: some View {
        FormSheet(title: String(localized: "New Worktree")) {
            GridRow {
                FormLabel("Branch:")
                Picker("Branch", selection: $existing) {
                    Text("New Branch").tag(String?.none)
                    if !freeBranches.isEmpty {
                        Divider()
                        ForEach(freeBranches) { ref in
                            Text(ref.name).tag(Optional(ref.name))
                        }
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if existing == nil {
                GridRow {
                    FormLabel("Name:")
                    TextField("Name", text: $name, prompt: Text("hotfix/0.9.4"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: FormMetrics.fieldWidth)
                        .accessibilityLabel("Branch name")
                        .onSubmit(create)
                }
                GridRow {
                    FormLabel("From:")
                    Picker("From", selection: $from) {
                        ForEach(sources, id: \.title) { source in
                            Text(source.title).tag(source.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            GridRow {
                FormLabel("Folder:")
                HStack(spacing: 6) {
                    TextField("Folder", text: $folderName)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Folder name")
                        .onChange(of: folderName) { _, value in
                            if value != defaultFolderName { editedFolderName = true }
                        }
                    Button("Choose…", action: chooseParent)
                }
                .frame(width: FormMetrics.fieldWidth)
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                FormNote(text: problem ?? note, isError: problem != nil)
                    .frame(width: FormMetrics.fieldWidth, alignment: .leading)
            }
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create Worktree", action: create)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isCreating)
        }
        .onAppear {
            parent = model.repository?.root.deletingLastPathComponent()
            folderName = defaultFolderName
        }
        .onChange(of: branch) {
            if !editedFolderName { folderName = defaultFolderName }
        }
        .task(id: "\(branch)|\(trimmedFolder)|\(parent?.path() ?? "")") { await validate() }
    }

    /// "powerlens-hotfix-0.9.4": the repository's folder name and the branch.
    private var defaultFolderName: String {
        let repository = model.repository?.root.lastPathComponent ?? model.displayName
        guard !branch.isEmpty else { return "" }
        return repository + "-" + branch.replacingOccurrences(of: "/", with: "-")
    }

    private var note: String {
        let folder = parent.map { ($0.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath } ?? ""
        return String(localized: "In \(folder). The folder gets its own checkout of the branch and shares this repository's history; it opens in a new window.")
    }

    private func validate() async {
        guard let repository = model.repository else { return }
        problem = nil
        isValid = false
        if existing == nil {
            guard !trimmedName.isEmpty else { return }
            if model.refs.localBranch(named: trimmedName) != nil {
                problem = String(localized: "A branch named “\(trimmedName)” already exists. Pick it under Branch instead.")
                return
            }
            let valid = await repository.isValidBranchName(trimmedName)
            // Typing on cancels this check; the next one decides.
            guard !Task.isCancelled else { return }
            guard valid else {
                problem = String(localized: "“\(trimmedName)” isn't a valid branch name.")
                return
            }
        }
        guard let destination, !trimmedFolder.contains("/") else {
            if trimmedFolder.contains("/") { problem = String(localized: "The folder name can't contain “/”.") }
            return
        }
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            problem = String(localized: "“\(trimmedFolder)” already exists there.")
            return
        }
        isValid = true
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose where to create the worktree's folder.")
        panel.directoryURL = parent
        if panel.runModal() == .OK, let url = panel.url { parent = url }
    }

    private func create() {
        guard isValid, !isCreating, let destination else { return }
        isCreating = true
        let startPoint = existing == nil ? (from ?? "HEAD") : nil
        let branch = branch
        Task {
            if await model.addWorktree(branch: branch, newBranchFrom: startPoint, at: destination) {
                dismiss()
            }
            isCreating = false
        }
    }
}

/// Add Key…: trusts the SSH key that signed a commit, by adding it to the allowed signers file.
struct AddSigningKeySheet: View {
    let model: RepositoryModel
    let commitID: String
    @State var signer: String

    @Environment(\.dismiss) private var dismiss
    @State private var key: String?
    @State private var file: URL?
    /// No `gpg.ssh.allowedSignersFile` yet: Kaern sets one in ~/.gitconfig.
    @State private var setsConfig = false
    @State private var didLoad = false

    init(model: RepositoryModel, commitID: String, signer: String) {
        self.model = model
        self.commitID = commitID
        _signer = State(initialValue: signer)
    }

    private var fingerprint: String? {
        guard let signature = model.detailSignature, model.selection == .commit(commitID), !signature.key.isEmpty else { return nil }
        return signature.key
    }

    private var trimmedSigner: String { signer.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        SheetScaffold(
            systemImage: "lock.shield",
            title: "Add Key to Allowed Signers",
            message: "Git checks SSH signatures against this list. Commits signed with this key then show as Verified for the signer below."
        ) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    FormLabel("Signer:")
                    TextField("Signer", text: $signer, prompt: Text("name@example.com"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .accessibilityLabel("Signer")
                }
                GridRow {
                    FormLabel("Key:")
                    VStack(alignment: .leading, spacing: 2) {
                        if let key {
                            Text(fingerprint ?? String(key.prefix(48)) + "…")
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(key.split(separator: " ").first.map(String.init) ?? "")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else if didLoad {
                            FormNote(text: String(localized: "Couldn't read the key from the commit's signature."), isError: true)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                GridRow {
                    FormLabel("File:")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.map { ($0.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath } ?? "")
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if setsConfig {
                            FormNote(text: String(localized: "gpg.ssh.allowedSignersFile isn't set, so Kaern creates this file and sets it in ~/.gitconfig."))
                        }
                    }
                }
            }
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add Key") {
                guard let key, let file else { return }
                let signer = trimmedSigner
                let setsConfig = setsConfig
                Task {
                    await model.addAllowedSigner(principal: signer, key: key, to: file, setGlobalConfig: setsConfig)
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(key == nil || file == nil || trimmedSigner.isEmpty || trimmedSigner.contains(" "))
        }
        .frame(width: 460)
        .task {
            guard let repository = model.repository else { return }
            key = await repository.sshSigningKey(of: commitID)
            if let configured = await repository.allowedSignersFile() {
                file = configured
                setsConfig = false
            } else {
                file = RepositoryModel.defaultAllowedSignersFile
                setsConfig = true
            }
            didLoad = true
        }
    }
}
