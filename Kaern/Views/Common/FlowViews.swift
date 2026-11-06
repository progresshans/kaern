import AppKit
import KaernKit
import SwiftUI

/// `.pbtn`: the accent button (Stage 3 Lines, Publish, Merge into Current Branch).
struct PrimaryButton: View {
    let title: String
    var height: CGFloat = 24
    var fontSize: CGFloat = 11.5
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(KFont.weighted(fontSize, 0.35))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(K.accent)
                        .shadow(color: K.shadowCtl, radius: 0.75, y: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .fixedSize()
    }
}

// MARK: - Toast

/// `.toast`: what just happened, with Undo when ⌘Z can take it back. Dark in light mode and
/// light in dark mode, 18 pt above the status bar.
struct ToastView: View {
    let repository: RepositoryModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let toast = repository.toast {
            let dark = scheme == .dark
            HStack(spacing: 8) {
                Text(toast.message)
                    .lineLimit(1)
                if toast.canUndo, repository.canUndo {
                    Button { repository.undo() } label: {
                        Text("Undo")
                            .font(.system(size: 12.5, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(dark ? Color.black.opacity(0.08) : Color.white.opacity(0.18)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(dark ? Color(nsColor: K.hex(0x1d1d1f)) : .white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(dark ? Color(.sRGB, red: 236 / 255, green: 236 / 255, blue: 240 / 255, opacity: 0.95)
                               : Color(.sRGB, red: 30 / 255, green: 30 / 255, blue: 32 / 255, opacity: 0.92))
                    .shadow(color: .black.opacity(0.25), radius: 15, y: 10)
            )
            .fixedSize()
            .id(toast.id)
            .transition(.opacity.combined(with: .offset(y: 8)))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

// MARK: - Alerts drawn in the window

/// The app icon the alerts show.
private struct AlertIcon: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .interpolation(.high)
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)
    }
}

/// `.ab`: an alert button. The default one is filled; a destructive one has red text and needs
/// a click (Return goes to the safe default).
private struct AlertButton: View {
    enum Role { case normal, preferred, destructive }
    let title: String
    var role: Role = .normal
    var stretches = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: role == .normal ? .medium : .semibold))
                .foregroundStyle(role == .preferred ? Color.white : role == .destructive ? K.err : K.label)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(maxWidth: stretches ? .infinity : nil)
                .frame(height: 26)
                .background {
                    if role == .preferred {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(K.accent)
                            .shadow(color: K.shadowCtl, radius: 0.75, y: 0.5)
                    } else {
                        Color.clear.controlSurface(radius: 7)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: !stretches, vertical: false)
    }
}

/// The shade behind an alert (`.shshade`); clicks don't reach the window under it.
struct AlertShade: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Color.black.opacity(scheme == .dark ? 0.3 : 0.1)
            .contentShape(Rectangle())
            .onTapGesture {}
            .accessibilityHidden(true)
    }
}

/// `.alert`: a question with the safe button as the default (Return) — Reset Hard, Delete on
/// origin, Force Push.
struct ConfirmationCard: View {
    let confirmation: Confirmation
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AlertIcon()
            Text(confirmation.title)
                .font(.system(size: 13, weight: .bold))
                .lineSpacing(2)
                .multilineTextAlignment(.center)
                .padding(.top, 14)
            Text(confirmation.message)
                .font(.system(size: 11.5))
                .lineSpacing(2.5)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            if !confirmation.lost.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(confirmation.lost) { commit in
                        HStack(spacing: 8) {
                            Text(commit.shortID)
                                .font(.system(size: 11.5, design: .monospaced))
                                .strikethrough()
                                .foregroundStyle(K.del)
                            Text(commit.subject)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(height: 18)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(K.field)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5)))
                .padding(.top, 10)
            }
            VStack(spacing: 7) {
                AlertButton(title: "Cancel", role: .preferred, action: dismiss)
                    .keyboardShortcut(.defaultAction)
                AlertButton(title: confirmation.confirmTitle, role: .destructive) {
                    dismiss()
                    confirmation.confirm()
                }
            }
            .padding(.top, 16)
            // Escape cancels too.
            Button("", action: dismiss).keyboardShortcut(.cancelAction).hidden().frame(width: 0, height: 0)
            if let note = confirmation.note {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(K.label3)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
            }
        }
        .foregroundStyle(K.label)
        .padding(EdgeInsets(top: 20, leading: 16, bottom: 14, trailing: 16))
        .frame(width: 300)
        .modifier(AlertSurface())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// `--pop` with the alert's deep shadow and hairline.
private struct AlertSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(K.pop)
                .shadow(color: .black.opacity(0.28), radius: 32, y: 24)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5))
        )
    }
}

/// `.alert.wide`: a hook stopped the commit. Its output, with clickable `file:line` locations,
/// then Close, Commit Without Hooks and Try Again (the default).
struct HookFailureCard: View {
    let repository: RepositoryModel
    let failure: HookFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AlertIcon()
            Text("\(failure.hook) failed — nothing was committed")
                .font(.system(size: 13, weight: .bold))
                .padding(.top, 14)
            Text(message)
                .font(.system(size: 11.5))
                .lineSpacing(2.5)
                .padding(.top, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let command = failure.command {
                        Text("$ " + command)
                            .foregroundStyle(K.label2)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 4)
                    }
                    ForEach(failure.lines) { line in
                        HookOutputRow(line: line) {
                            if let path = line.path { repository.open(path: path, line: line.line) }
                        }
                    }
                    Text(failure.summary)
                        .foregroundStyle(K.label2)
                        .padding(EdgeInsets(top: 6, leading: 6, bottom: 0, trailing: 6))
                }
                .font(.system(size: 11, design: .monospaced))
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 200)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(K.field)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5)))
            .padding(.top, 12)
            HStack(spacing: 7) {
                AlertButton(title: "Close", stretches: false) { repository.hookFailure = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                AlertButton(title: "Commit Without Hooks", stretches: false) {
                    repository.hookFailure = nil
                    repository.commit(runHooks: false)
                }
                AlertButton(title: "Try Again", role: .preferred, stretches: false) {
                    repository.hookFailure = nil
                    repository.commit()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)
        }
        .foregroundStyle(K.label)
        .padding(EdgeInsets(top: 18, leading: 18, bottom: 14, trailing: 18))
        .frame(width: 620)
        .modifier(AlertSurface())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var message: String {
        let found = failure.errors > 0
            ? " found \(Formatters.count(failure.errors, "error", "errors")) in the staged files"
            : " stopped the commit"
        return "The \(failure.hook) hook" + found + ". Fix them and try again, or commit without running hooks."
    }
}

/// `.ol`: one output line; a `path:line` location opens the file there.
private struct HookOutputRow: View {
    let line: HookOutputLine
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let path = line.path, let number = line.line {
                    Text("\((path as NSString).lastPathComponent):\(number)")
                        .underline()
                        .foregroundStyle(K.accentText)
                        .fixedSize()
                    if let kind = line.kind {
                        Text(kind)
                            .fontWeight(.bold)
                            .foregroundStyle(kind == "error" ? K.err : kind == "warning" ? K.mod : K.label2)
                            .fixedSize()
                    }
                    Text(line.message)
                        .foregroundStyle(K.label2)
                } else {
                    Text(line.text).foregroundStyle(K.label)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering && line.path != nil ? K.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(line.path == nil)
        .onHover { hovering = $0 }
        .help(line.path.map { "Open \($0) at line \(line.line ?? 1)" } ?? "")
    }
}

// MARK: - Pre-commit HUD

/// `.hookhud`: the hook that's running, how long it has run, and Stop.
struct HookHUD: View {
    let repository: RepositoryModel
    let run: HookRun

    var body: some View {
        HStack(spacing: 9) {
            Spinner(size: 14)
            Text("\(Text(run.hook).fontWeight(.bold)) · \(run.command)")
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 360, alignment: .leading)
            TimelineView(.periodic(from: run.started, by: 0.1)) { context in
                Text(String(format: "%.1fs", max(0, context.date.timeIntervalSince(run.started))))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(K.label2)
                    .monospacedDigit()
            }
            GhostButton(title: "Stop") { repository.stopCommit() }
        }
        .font(.system(size: 12))
        .foregroundStyle(K.label)
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 10))
        .popSurface(radius: 10)
        .fixedSize()
    }
}

/// `.spin`: an accent arc turning on a soft ring.
struct Spinner: View {
    var size: CGFloat = 14
    var lineWidth: CGFloat = 2
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(K.accentSoft, lineWidth: lineWidth)
            Circle().trim(from: 0, to: 0.25)
                .stroke(K.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
        }
        .frame(width: size - lineWidth, height: size - lineWidth)
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { turning = true }
        }
    }
}

// MARK: - Publish

/// The publish popover (`.pubpop`): where to push a branch that isn't on any remote yet.
struct PublishPopover: View {
    let repository: RepositoryModel
    @State var draft: PublishDraft
    @State private var nameIsValid = true
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Publish “\(draft.branch)”")
                .font(.system(size: 13.5, weight: .bold))
            Text("This branch isn’t on any remote yet. Push it once and Kaern keeps pushing and pulling it there.")
                .font(.system(size: 12))
                .lineSpacing(3)
                .foregroundStyle(K.label2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, -4)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
                GridRow {
                    Text("Remote").foregroundStyle(K.label2).gridColumnAlignment(.trailing)
                    Picker("Remote", selection: $draft.remote) {
                        ForEach(repository.remotes.map(\.name), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                }
                GridRow {
                    Text("As").foregroundStyle(K.label2)
                    TextField("Branch name", text: $draft.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($nameFocused)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(K.field)
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(nameFocused ? K.accent : K.sepStrong, lineWidth: nameFocused ? 1 : 0.5)))
                        .onSubmit(publish)
                }
            }
            .font(.system(size: 12.5))
            Toggle(isOn: $draft.track) {
                Text("Track it — Pull and Push use \(draft.remote)/\(trimmedName) from now on")
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            Text(note)
                .font(.system(size: 11.5))
                .foregroundStyle(nameIsValid ? K.label2 : K.err)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { repository.publishDraft = nil }
                    .keyboardShortcut(.cancelAction)
                Button(draft.track ? "Publish" : "Push Once", action: publish)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!nameIsValid || trimmedName.isEmpty)
            }
            .controlSize(.regular)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
        .frame(width: 360)
        .task(id: draft.name) {
            let name = trimmedName
            guard !name.isEmpty else { nameIsValid = false; return }
            nameIsValid = await repository.isValidBranchName(name)
        }
        .onAppear { nameFocused = true }
    }

    private var trimmedName: String { draft.name.trimmingCharacters(in: .whitespaces) }

    private var note: String {
        guard nameIsValid else { return "Branch names can’t have spaces, “..” or a trailing /." }
        return "Creates \(draft.remote)/\(trimmedName)" + (repository.remoteURL?.hostName == "GitHub" ? " · a pull request can start from it" : "")
    }

    private func publish() {
        guard nameIsValid, !trimmedName.isEmpty else { return }
        var final = draft
        final.name = trimmedName
        repository.publish(final)
    }
}
