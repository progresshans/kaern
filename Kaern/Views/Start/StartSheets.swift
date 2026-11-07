import AppKit
import KaernKit
import SwiftUI

/// The window's own sheet (Clone, Create New Repository, Publish to GitHub): over a shade, hung
/// from the top of the content like the boards' `.insheet`.
struct WindowSheetHost: View {
    let window: WindowModel
    let topInset: CGFloat
    @Environment(AppModel.self) private var app

    var body: some View {
        if let sheet = window.sheet {
            ZStack(alignment: .top) {
                AlertShade()
                Group {
                    switch sheet {
                    case .clone(let model): CloneSheet(model: model, window: window)
                    case .create(let model): CreateSheet(model: model, window: window)
                    case .publish(let model): PublishSheet(model: model, window: window)
                    }
                }
                .id(sheet.id)
                .padding(.top, topInset)
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Parts

/// `.insheet`: square top corners, 14 pt bottom ones, the pop color.
private struct AttachedCard<Content: View>: View {
    var width: CGFloat = 560
    var fill: Color = K.pop
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .foregroundStyle(K.label)
            .padding(EdgeInsets(top: 20, leading: 22, bottom: 16, trailing: 22))
            .frame(width: width, alignment: .leading)
            .background(
                UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous)
                    .fill(fill)
                    .shadow(color: .black.opacity(0.28), radius: 25, y: 18)
                    .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous)
                        .strokeBorder(K.sepStrong, lineWidth: 0.5))
            )
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
    }
}

/// `.inl`: a right-aligned label in the 110 pt column.
private struct FormLabel: View {
    let text: String
    var color: Color = K.label

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(color)
            .frame(width: 110, alignment: .trailing)
            .padding(.top, 5)
    }
}

/// `.innote`: 11.5 pt under a control, red when it's an error.
private struct FormNote: View {
    let text: String
    var isError = false

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(isError ? K.err : K.label2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// `.ghost.lg` / `.primary2`: the sheet's 28 pt buttons.
struct SheetActionButton: View {
    let title: String
    var primary = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(primary ? Color.white : K.label)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background {
                    if primary {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(K.accent)
                            .shadow(color: K.shadowCtl, radius: 0.75, y: 0.5)
                    } else {
                        Color.clear.controlSurface(radius: 7)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : (primary ? 0.45 : 0.5))
        .fixedSize()
    }
}

/// `.insel`: a pop-up drawn like the board's select — a fixed width, the control fill, the value on
/// the left and ⌃⌄ on the right.
struct PopupField<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var width: CGFloat = 200
    let label: String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { value, title in
                Toggle(title, isOn: Binding(get: { selection == value }, set: { _ in selection = value }))
            }
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.0 == selection }?.1 ?? "")
                    .font(.system(size: 12.5))
                    .foregroundStyle(K.label)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Icon(Icons.upDown, size: 9, height: 12).foregroundStyle(K.label2)
            }
            .padding(.horizontal, 8)
            .frame(width: width, height: 26)
            .controlSurface(radius: 6)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel(label)
    }
}

/// `.inpath`: a folder in the monospaced face, cut in the middle.
private struct PathText: View {
    let path: String

    var body: some View {
        Text(path)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(K.label)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
    }
}

/// The account a sheet uses: initials in a circle, "login · host".
private struct AccountLine: View {
    let account: HostingAccount

    var body: some View {
        HStack(spacing: 7) {
            Text(account.initials)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(AvatarPalette.color(for: account.login)))
            Text("\(account.login) · \(account.host)")
                .font(.system(size: 12.5))
        }
    }
}

/// `.prog`: what git is doing, the bar and the counts.
private struct CloneProgressBox: View {
    let progress: GitProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text((progress?.phase ?? "Connecting") + "…").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if let percent = progress?.percent {
                    Text("\(percent)%").font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                }
            }
            ProgressBar(fraction: progress?.percent.map { Double($0) / 100 })
            if let detail = progress?.detail {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(K.label2).monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(K.hover))
        .padding(.top, 14)
    }
}

/// A thin bar: filled to `fraction`, or a sliding piece when there's no number yet.
struct ProgressBar: View {
    let fraction: Double?
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(K.chip2)
                if let fraction {
                    Capsule().fill(K.accent).frame(width: max(6, geometry.size.width * min(1, max(0, fraction))))
                } else {
                    Capsule().fill(K.accent).frame(width: geometry.size.width * 0.3)
                        .offset(x: (geometry.size.width * 0.7) * phase)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = 1 }
                        }
                }
            }
        }
        .frame(height: 5)
        .clipShape(Capsule())
        .animation(.easeOut(duration: 0.2), value: fraction)
    }
}

// MARK: - Clone

/// ScreenWelcome's Clone sheet: URL / GitHub / GitLab, Clone into, the account, the progress.
struct CloneSheet: View {
    @Bindable var model: CloneModel
    let window: WindowModel
    @Environment(AppModel.self) private var app
    @FocusState private var urlFocused: Bool
    @FocusState private var folderFocused: Bool
    @FocusState private var filterFocused: Bool

    var body: some View {
        AttachedCard(width: 520, fill: K.inspector) {
            Text("Clone a Repository").font(.system(size: 14, weight: .bold)).padding(.bottom, 12)
            SegmentedChoice(options: [(CloneModel.Source.url, "URL"), (.github, "GitHub"), (.gitlab, "GitLab")],
                            selection: $model.source, label: "Source")
                .disabled(model.isCloning)
                .padding(.bottom, 14)
            if model.source != .url { hostedList.padding(.bottom, 12) }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    FormLabel(text: "Repository URL", color: K.label2).padding(.top, -5)
                    SheetField(placeholder: "https://github.com/owner/name.git", text: $model.url, focus: $urlFocused, onSubmit: start)
                }
                HStack(spacing: 10) {
                    FormLabel(text: "Clone into", color: K.label2).padding(.top, -5)
                    SheetField(placeholder: "~/Developer/name", text: Binding(get: { model.destination }, set: {
                        model.destination = $0
                        model.destinationEdited = true
                    }), isBad: model.problem.map { !$0.isEmpty } ?? false, focus: $folderFocused, onSubmit: start)
                    SheetActionButton(title: "Choose…") { choose() }
                }
                HStack(spacing: 10) {
                    FormLabel(text: "Account", color: K.label2).padding(.top, -5)
                    accountRow
                }
                HStack(spacing: 10) {
                    Color.clear.frame(width: 110, height: 1)
                    Toggle("Open it in a new tab when the clone finishes", isOn: $model.opensTab)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5))
                }
            }
            .disabled(model.isCloning)
            if model.isCloning {
                CloneProgressBox(progress: model.progress)
            }
            if let problem = model.problem, !problem.isEmpty, !model.isCloning {
                FormNote(text: problem, isError: true).padding(.top, 10).padding(.leading, 120)
            }
            if let error = model.error {
                HStack(alignment: .top, spacing: 8) {
                    Icon(Icons.error, size: 13).foregroundStyle(K.err).padding(.top, 1)
                    Text(error).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if case .signIn(let host) = model.failure {
                        SheetActionButton(title: "Sign In…") {
                            SettingsWindowController.shared.showSignIn(host: host ?? model.host ?? "github.com")
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(K.cbBg))
                .padding(.top, 12)
            }
            HStack(spacing: 8) {
                Spacer()
                SheetActionButton(title: "Cancel") { app.closeSheet(in: window) }
                    .keyboardShortcut(.cancelAction)
                SheetActionButton(title: model.isCloning ? "Cloning…" : "Clone", primary: true, action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isCloning || model.problem != nil)
            }
            .padding(.top, 18)
        }
        .onAppear {
            DispatchQueue.main.async { urlFocused = model.source == .url }
        }
    }

    private func start() {
        app.startClone(model, in: window)
    }

    @ViewBuilder
    private var accountRow: some View {
        if let account = model.account {
            AccountLine(account: account)
        } else if model.host == nil {
            Text(model.url.isEmpty ? "—" : "None needed for a folder on this Mac")
                .font(.system(size: 12.5)).foregroundStyle(K.label2)
        } else {
            HStack(spacing: 8) {
                Text("Not signed in — public repositories only").font(.system(size: 12.5)).foregroundStyle(K.label2)
                Button("Sign In…") { SettingsWindowController.shared.showSignIn(host: model.host ?? "github.com") }
                    .buttonStyle(.link)
                    .font(.system(size: 12.5))
            }
        }
    }

    /// GitHub or GitLab: the account's repositories, newest first.
    @ViewBuilder
    private var hostedList: some View {
        let service = model.source == .github ? "GitHub" : "GitLab"
        switch model.listState {
        case .needsAccount:
            HStack(spacing: 10) {
                Text("Sign in to \(service) to pick from your repositories, or paste a URL below.")
                    .font(.system(size: 12.5)).foregroundStyle(K.label2)
                Spacer()
                SheetActionButton(title: "Sign In to \(service)…") {
                    SettingsWindowController.shared.showSignIn(host: model.source == .github ? "github.com" : "gitlab.com")
                }
            }
        case .loading, .idle:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading your \(service) repositories…").font(.system(size: 12.5)).foregroundStyle(K.label2)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        case .failed(let message):
            FormNote(text: message, isError: true)
        case .loaded:
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Icon(Icons.search(1.4), size: 12).foregroundStyle(K.label2)
                    TextField("Filter \(model.hosted.count) repositories", text: $model.filter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused($filterFocused)
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(K.field)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5)))
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(model.filteredHosted) { item in
                            HostedRow(item: item, isPicked: model.url == item.httpsURL || model.url == item.sshURL) { model.pick(item) }
                        }
                        if model.filteredHosted.isEmpty {
                            Text("No repository matches “\(model.filter)”.").font(.system(size: 12)).foregroundStyle(K.label2).padding(12)
                        }
                    }
                }
                .frame(height: 176)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(K.field))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5))
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Clone Here"
        panel.message = "Choose the folder the clone goes into. Kaern makes a folder named after the repository in it."
        panel.directoryURL = model.destinationURL?.deletingLastPathComponent() ?? ProjectsFolder.current
        let host = AppModel.shared.windows.first { $0.model === window }?.window
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let folder = panel.url else { return }
            let name = GitRepository.folderName(forClone: model.url) ?? model.destinationURL?.lastPathComponent ?? "repository"
            model.destination = Formatters.abbreviatedPath(folder.appending(path: name).path(percentEncoded: false))
            model.destinationEdited = true
        }
        if let host { panel.beginSheetModal(for: host, completionHandler: handler) } else { handler(panel.runModal()) }
    }
}

/// One repository in Clone's GitHub / GitLab list.
private struct HostedRow: View {
    let item: HostedRepository
    let isPicked: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.fullName).font(.system(size: 12.5, weight: .semibold))
                    if let summary = item.summary, !summary.isEmpty {
                        Text(summary).font(.system(size: 11)).foregroundStyle(isPicked ? .white.opacity(0.8) : K.label2)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                if item.isPrivate {
                    Text("private").font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(isPicked ? .white : K.label2)
                        .padding(.horizontal, 6).frame(height: 16)
                        .background(Capsule().fill(isPicked ? Color.white.opacity(0.22) : K.chip2))
                }
                if let updated = item.updated {
                    Text(Formatters.historyDate(updated)).font(.system(size: 11)).foregroundStyle(isPicked ? .white.opacity(0.8) : K.label2)
                }
            }
            .foregroundStyle(isPicked ? .white : K.label)
            .padding(.horizontal, 10)
            .frame(height: item.summary?.isEmpty == false ? 38 : 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isPicked ? K.sel : (hovering ? K.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 3)
        .onHover { hovering = $0 }
    }
}

// MARK: - Create

/// ScreenInit's Create sheet: name, location, default branch, .gitignore, license, README, the
/// first commit and publishing; while it works, the steps it takes.
struct CreateSheet: View {
    @Bindable var model: CreateModel
    let window: WindowModel
    @Environment(AppModel.self) private var app
    @FocusState private var nameFocused: Bool
    @FocusState private var branchFocused: Bool

    var body: some View {
        let nameCheck = model.nameCheck
        AttachedCard {
            Text(model.existingFolder == nil ? "Create a New Repository" : "Create a Repository in “\(model.name)”")
                .font(.system(size: 15, weight: .bold))
            Text(model.existingFolder == nil ? "Kaern makes the folder, sets up Git and can make the first commit for you."
                 : "Kaern adds Git to the folder. Your files stay where they are.")
                .font(.system(size: 12))
                .foregroundStyle(K.label2)
                .padding(.top, 4)
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    FormLabel(text: "Name")
                    VStack(alignment: .leading, spacing: 4) {
                        SheetField(placeholder: "my-project", text: $model.name, isBad: nameCheck.isError && !model.name.isEmpty,
                                   focus: $nameFocused, onSubmit: create)
                            .disabled(model.existingFolder != nil)
                            .opacity(model.existingFolder != nil ? 0.6 : 1)
                        if let note = nameCheck.note, !(model.name.isEmpty && nameCheck.isError) {
                            FormNote(text: note, isError: nameCheck.isError)
                        }
                    }
                }
                GridRow {
                    FormLabel(text: "Location")
                    HStack(spacing: 8) {
                        PathText(path: Formatters.abbreviatedPath(model.folder.path(percentEncoded: false)).trimmingTrailingSlash
                                 + (model.existingFolder == nil && model.cleanName.isEmpty ? "/…" : ""))
                        if model.existingFolder == nil {
                            SheetActionButton(title: "Choose…") { choose() }
                        }
                    }
                    .frame(minHeight: 26)
                }
                GridRow {
                    FormLabel(text: "Default branch")
                    VStack(alignment: .leading, spacing: 4) {
                        SheetField(placeholder: "main", text: $model.branch, isBad: !model.branchIsValid, focus: $branchFocused, onSubmit: create)
                            .frame(width: 160)
                        FormNote(text: model.branchIsValid ? "From init.defaultBranch in your Git config" : "Not a valid branch name",
                                 isError: !model.branchIsValid)
                    }
                }
                GridRow {
                    FormLabel(text: ".gitignore")
                    VStack(alignment: .leading, spacing: 4) {
                        PopupField(options: IgnoreTemplate.allCases.map { ($0, $0.rawValue) }, selection: $model.ignore, label: ".gitignore")
                        FormNote(text: model.ignoreNote)
                    }
                }
                GridRow {
                    FormLabel(text: "License")
                    PopupField(options: LicenseChoice.allCases.map { ($0, $0.rawValue) }, selection: $model.license, label: "License")
                }
                GridRow {
                    Color.clear.frame(width: 110, height: 1)
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Add README.md", isOn: $model.readme).toggleStyle(.checkbox)
                        Toggle("Make the first commit", isOn: $model.firstCommit).toggleStyle(.checkbox)
                        FormNote(text: model.firstCommitNote)
                    }
                    .font(.system(size: 12.5))
                    .padding(.top, 2)
                }
            }
            .padding(.top, 16)
            .disabled(model.isRunning)
            publishSection
                .disabled(model.isRunning)
            if !model.steps.isEmpty { StepList(steps: model.steps) }
            if let error = model.error {
                FormNote(text: error, isError: true).padding(.top, 10)
            }
            HStack(spacing: 8) {
                Spacer()
                SheetActionButton(title: "Cancel") { app.closeSheet(in: window) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isRunning)
                SheetActionButton(title: model.isRunning ? "Creating…" : "Create Repository", primary: true, action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCreate)
            }
            .padding(.top, 16)
        }
        .onAppear {
            DispatchQueue.main.async { if model.existingFolder == nil { nameFocused = true } }
        }
    }

    @ViewBuilder
    private var publishSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let account = model.githubAccount {
                Toggle("Also publish to GitHub (\(account.name?.isEmpty == false ? account.name! : account.login))", isOn: $model.publish)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5))
                if model.publish {
                    HStack(spacing: 8) {
                        PathText(path: "Name on GitHub: \(model.existingFolder?.lastPathComponent ?? model.cleanName)")
                        Spacer()
                        SegmentedChoice(options: [(true, "Private"), (false, "Public")], selection: $model.isPrivate, label: "Visibility")
                    }
                    .padding(.leading, 22)
                }
            } else {
                Toggle("Also publish to GitHub", isOn: .constant(false))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5))
                    .disabled(true)
                FormNote(text: "Sign in to GitHub in Settings › Accounts to publish from here.")
                    .padding(.leading, 22)
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { K.sep.frame(height: 1) }
        .padding(.top, 14)
    }

    private func create() {
        app.startCreate(model, in: window)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where the new repository's folder goes."
        panel.directoryURL = model.location
        let host = AppModel.shared.windows.first { $0.model === window }?.window
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let folder = panel.url else { return }
            model.location = folder
        }
        if let host { panel.beginSheetModal(for: host, completionHandler: handler) } else { handler(panel.runModal()) }
    }
}

/// `.insteps`: the steps Create takes, ticked off as they finish.
private struct StepList: View {
    let steps: [CreateModel.Step]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(steps) { step in
                HStack(spacing: 8) {
                    Group {
                        switch step.state {
                        case .running: Spinner(size: 11)
                        case .done: Icon(Icons.checkSmall, size: 11).foregroundStyle(K.ok)
                        case .failed: Icon(Icons.closeLarge, size: 10).foregroundStyle(K.err)
                        case .waiting: Color.clear
                        }
                    }
                    .frame(width: 12, height: 12)
                    Text(step.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(step.state == .running ? K.label : step.state == .done ? K.label2 : step.state == .failed ? K.err : K.label3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(K.field)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5)))
        .padding(.top, 14)
    }
}

// MARK: - Publish

/// Publish to GitHub… (the new repository's banner): the name and who sees it, then Kaern makes
/// the repository on GitHub, adds it as origin and pushes the branch.
struct PublishSheet: View {
    @Bindable var model: PublishModel
    let window: WindowModel
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool

    var body: some View {
        AttachedCard(width: 480) {
            Text("Publish to GitHub").font(.system(size: 15, weight: .bold))
            Text("Kaern makes the repository on GitHub, adds it as origin and pushes your branch.")
                .font(.system(size: 12)).foregroundStyle(K.label2).padding(.top, 4)
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    FormLabel(text: "Name")
                    VStack(alignment: .leading, spacing: 4) {
                        SheetField(placeholder: "name", text: $model.name, isBad: !model.nameIsValid, focus: $focused, onSubmit: publish)
                        if !model.nameIsValid {
                            FormNote(text: "Letters, numbers, - _ and . only", isError: true)
                        }
                    }
                }
                GridRow {
                    FormLabel(text: "Visibility")
                    SegmentedChoice(options: [(true, "Private"), (false, "Public")], selection: $model.isPrivate, label: "Visibility")
                        .padding(.top, 1)
                }
                GridRow {
                    FormLabel(text: "Account")
                    if let account = model.account {
                        AccountLine(account: account).padding(.top, 3)
                    } else {
                        HStack(spacing: 8) {
                            Text("Not signed in to GitHub").font(.system(size: 12.5)).foregroundStyle(K.label2)
                            Button("Sign In…") { SettingsWindowController.shared.showSignIn(host: "github.com") }
                                .buttonStyle(.link).font(.system(size: 12.5))
                        }
                        .padding(.top, 3)
                    }
                }
            }
            .padding(.top, 16)
            .disabled(model.isRunning)
            if let progress = model.progress {
                HStack(spacing: 8) {
                    Spinner(size: 11)
                    Text(progress).font(.system(size: 12))
                }
                .padding(.top, 12)
            }
            if let error = model.error {
                FormNote(text: error, isError: true).padding(.top, 10)
            }
            HStack(spacing: 8) {
                Spacer()
                SheetActionButton(title: "Cancel") { app.closeSheet(in: window) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isRunning)
                SheetActionButton(title: model.isRunning ? "Publishing…" : "Publish", primary: true, action: publish)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.nameIsValid || model.account == nil || model.isRunning)
            }
            .padding(.top, 16)
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func publish() {
        app.startPublish(model, in: window)
    }
}
