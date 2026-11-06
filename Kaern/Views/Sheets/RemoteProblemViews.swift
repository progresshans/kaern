import AppKit
import KaernKit
import SwiftUI

/// Title and message of the remote problem alerts: what failed, and that nothing changed.
enum RemoteProblemText {
    static func title(_ problem: RemoteProblem) -> String {
        switch problem.kind {
        case .authentication: String(localized: "Sign in to \(problem.host)")
        case .sshAuthentication: String(localized: "\(problem.host) didn't accept your SSH key")
        case .unknownHostKey: String(localized: "\(problem.host) isn't a known host yet")
        case .unreachable: String(localized: "Couldn't reach \(problem.remote)")
        }
    }

    static func message(_ problem: RemoteProblem) -> String {
        switch problem.kind {
        case .authentication:
            if let username = problem.username {
                return String(localized: "\(problem.remote) rejected the saved credentials for \(username). Sign in again to keep pulling and pushing.")
            }
            return String(localized: "\(problem.remote) didn't accept the saved credentials. Sign in again to keep pulling and pushing.")
        case .sshAuthentication:
            return String(localized: "Check that your key is loaded (ssh-add -l) and added to your account on \(problem.host). Nothing in this repository was changed.")
        case .unknownHostKey:
            return String(localized: "SSH hasn't connected to this server before. Run ssh -T git@\(problem.host) in Terminal once to check and trust its key, then try again.")
        case .unreachable:
            return String(localized: "\(problem.host) didn't answer. Check your network or VPN. Nothing in this repository was changed.")
        }
    }
}

/// The buttons of a remote problem alert; the first one is the default (Return).
struct RemoteProblemButtons: View {
    let problem: RemoteProblem
    let model: RepositoryModel

    var body: some View {
        switch problem.kind {
        case .authentication:
            Button("Sign In with Browser…") { model.sheet = .signIn(problem) }
                .keyboardShortcut(.defaultAction)
            if let url = problem.url, !url.isSSH {
                Button("Use SSH Instead…") {
                    model.confirmation = .useSSH(remote: problem.remote, url: url.sshEquivalent, retry: problem.retry)
                }
            }
            Button("Cancel", role: .cancel) {}
        case .sshAuthentication:
            Button("Try Again") { Task { await model.retry(problem.retry) } }
                .keyboardShortcut(.defaultAction)
            Button("Show Log") { model.sheet = .log(title: RemoteProblemText.title(problem), text: problem.log) }
            Button("Cancel", role: .cancel) {}
        case .unknownHostKey:
            Button("Try Again") { Task { await model.retry(problem.retry) } }
                .keyboardShortcut(.defaultAction)
            Button("Open Terminal") { model.openInTerminal() }
            Button("Cancel", role: .cancel) {}
        case .unreachable:
            Button("Try Again") { Task { await model.retry(problem.retry) } }
                .keyboardShortcut(.defaultAction)
            Button("Show Log") { model.sheet = .log(title: RemoteProblemText.title(problem), text: problem.log) }
            Button("Work Offline", role: .cancel) { model.workOffline() }
        }
    }
}

/// Sign In with Browser…: Kaern never asks for a password. You create a token on the host's
/// site, paste it here, and it goes to git's credential helper (the Keychain), so Terminal's git
/// uses the same one.
struct SignInSheet: View {
    let model: RepositoryModel
    let problem: RemoteProblem

    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var token = ""
    @State private var keep = true
    @State private var isSigningIn = false

    private var canSignIn: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !token.trimmingCharacters(in: .whitespaces).isEmpty && !isSigningIn
    }

    var body: some View {
        FormSheet(title: String(localized: "Sign in to \(problem.host)")) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                VStack(alignment: .leading, spacing: 8) {
                    FormNote(text: String(localized: "Kaern doesn't take passwords. Create a token on \(problem.host) in your browser, then paste it below. It's kept in the Keychain through git, so Terminal uses it too."))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Create a Token…") {
                        if let page = problem.url?.tokenPage {
                            NSWorkspace.shared.open(page)
                        }
                    }
                    .fixedSize()
                    .help("Opens \(problem.host) in your browser")
                }
            }
            GridRow {
                FormLabel("Username:")
                TextField("Username", text: $username, prompt: Text("Your \(problem.host) username"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Username")
            }
            GridRow {
                FormLabel("Token:")
                SecureField("Token", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Token")
                    .onSubmit(signIn)
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Toggle("Save in Keychain", isOn: $keep)
                    .toggleStyle(.checkbox)
            }
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Sign In", action: signIn)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSignIn)
        }
        .onAppear { username = problem.username ?? "" }
    }

    private func signIn() {
        guard canSignIn else { return }
        isSigningIn = true
        let user = username.trimmingCharacters(in: .whitespaces)
        let secret = token.trimmingCharacters(in: .whitespaces)
        dismiss()
        Task {
            _ = await model.signIn(to: problem, username: user, token: secret, keep: keep)
        }
    }
}

/// Show Log: git's own words, selectable and copyable.
struct LogSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 180)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            HStack {
                Text("More in Settings › Advanced › Command Log.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { Pasteboard.copy(text) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
