import AppKit
import KaernKit
import SwiftUI

// MARK: - Signature (ScreenMarks › 서명)

/// `.sgb`: who signed the selected commit and whether git trusts the key, folding open to the key,
/// signer and what git says; Trust This Key… or Show Raw Signature when it isn't verified.
/// "Not signed" with a hollow square for unsigned commits.
struct SignatureCard: View {
    @Bindable var repository: RepositoryModel
    let signed: SelectedSignature
    let committer: Signature?

    var body: some View {
        if let signature = signed.signature {
            let mark = SignatureMark(signature.status)
            let open = repository.signatureCardOpen
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { repository.signatureCardOpen.toggle() }
                } label: {
                    HStack(spacing: 9) {
                        Icon(mark.icon, size: 14).foregroundStyle(mark.color)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title(mark)).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(K.label)
                            Text("\(signature.format) · \(who(signature))").font(.system(size: 11.5)).foregroundStyle(K.label2)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Icon(Icons.chevronDown, size: 10)
                            .foregroundStyle(K.label2)
                            .rotationEffect(.degrees(open ? 0 : -90))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(open ? "expanded" : "collapsed")
                if open {
                    VStack(alignment: .leading, spacing: 5) {
                        row("Key", signature.key.isEmpty ? "\(signature.format) key" : "\(signature.format) key \(signature.key)")
                        row("Signer", who(signature))
                        row("Status", status(signature))
                    }
                    .padding(EdgeInsets(top: 0, leading: 33, bottom: mark == .verified ? 10 : 4, trailing: 10))
                    if mark != .verified {
                        GhostButton(title: mark == .unverified ? "Trust This Key…" : "Show Raw Signature") {
                            if mark == .unverified {
                                repository.from("Signature") { repository.askTrustSignatureKey() }
                            } else {
                                repository.showRawSignature()
                            }
                        }
                        .padding(EdgeInsets(top: 4, leading: 33, bottom: 10, trailing: 10))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(background(mark)))
            .padding(.top, 12)
        } else {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(K.label3, lineWidth: 1.5).frame(width: 10, height: 10)
                Text("Not signed")
            }
            .font(.system(size: 12))
            .foregroundStyle(K.label2)
            .padding(.top, 12)
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key).foregroundStyle(K.label2).frame(width: 46, alignment: .leading)
            Text(value).foregroundStyle(K.label).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5))
        .lineSpacing(1.5)
    }

    private func title(_ mark: SignatureMark) -> String {
        switch mark {
        case .verified: "Verified signature"
        case .unverified: "Signed, but not verified"
        case .bad: "Bad signature"
        }
    }

    /// The signer git names (an SSH principal, a GPG user id), else who committed it.
    private func who(_ signature: CommitSignature) -> String {
        signature.signer.isEmpty ? (committer?.name ?? "Unknown signer") : signature.signer
    }

    private func status(_ signature: CommitSignature) -> String {
        switch signature.status {
        case .verified:
            signature.format == "SSH" ? "Matches an entry in \(signed.allowedSigners ?? "your allowed signers")" : "Trusted in your GPG keychain"
        case .unverified:
            "This key isn’t in your keychain or allowed signers yet"
        case .missingKey:
            "The key isn’t on this Mac, so git can’t check the signature"
        case .expired:
            "The signature or its key has expired"
        case .revoked:
            "The key was revoked"
        case .bad:
            "The signature doesn’t match this commit. It may have been changed after signing."
        }
    }

    private func background(_ mark: SignatureMark) -> Color {
        switch mark {
        case .verified: K.okBg
        case .unverified: K.modBg
        case .bad: K.delBg
        }
    }
}

// MARK: - Worktree (ScreenMarks › 워크트리)

/// The right panel for another working tree picked in the sidebar: its folder, branch, HEAD, what
/// it shares, why its branch can't be checked out here, its uncommitted files, then Open in New
/// Tab · Show in Finder · Remove….
struct WorktreePanel: View {
    let repository: RepositoryModel
    let worktree: Worktree

    var body: some View {
        let details = repository.worktreeDetails?.path == worktree.path ? repository.worktreeDetails : nil
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Worktree")
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.3)
                        .foregroundStyle(K.label2)
                    Text(worktree.name).font(.system(size: 16, weight: .bold)).padding(.top, 6)
                        .lineLimit(1).truncationMode(.middle)
                    Text(Formatters.abbreviatedPath(worktree.path)).font(.system(size: 11.5)).foregroundStyle(K.label2)
                        .lineLimit(1).truncationMode(.middle).padding(.top, 2)
                    fact("Branch") {
                        if let branch = worktree.branch {
                            Text(branch)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(K.accentText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 7)
                                .frame(height: 20)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(K.lt1))
                        } else {
                            Text("None (HEAD is detached)").foregroundStyle(K.label2)
                        }
                    }
                    if let head = worktree.head {
                        fact("HEAD") {
                            Text(head.prefix(7)).font(KFont.hash)
                            if let subject = details?.headSubject {
                                Text(subject).lineLimit(1).truncationMode(.tail)
                            }
                        }
                    }
                    fact("Shares") {
                        Text("commits, branches and tags with \(repository.name)").lineLimit(1).truncationMode(.tail)
                    }
                    if let branch = worktree.branch {
                        Text("\(branch) is checked out in this worktree, so Git won’t check it out in \(repository.name) too. Open the worktree to work on it.")
                            .font(.system(size: 12))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(K.accentSoft))
                            .padding(.top, 14)
                    }
                    if let details {
                        Text(details.entries.isEmpty ? "No uncommitted changes" : Formatters.count(details.entries.count, "uncommitted change", "uncommitted changes"))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(K.label2)
                            .padding(.top, 16)
                            .padding(.bottom, 6)
                        ForEach(details.entries.prefix(200)) { entry in
                            WorktreeFileRow(entry: entry, stat: entry.hasUnstagedChanges ? details.lineStats.unstaged[entry.path] : details.lineStats.staged[entry.path])
                        }
                    } else {
                        ProgressView().controlSize(.small).padding(.top, 16)
                    }
                }
                .padding(EdgeInsets(top: 14, leading: 14, bottom: 10, trailing: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contextClip()
            HStack(spacing: 6) {
                PrimaryButton(title: "Open in New Tab") { repository.openWorktree(worktree.path) }
                GhostButton(title: "Show in Finder") { repository.revealWorktree(worktree.path) }
                Spacer(minLength: 0)
                GhostButton(title: "Remove…", tint: K.err) {
                    repository.from("Worktree") { repository.askRemoveWorktree(worktree) }
                }
                .disabled(repository.activity != nil || worktree.isLocked)
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
            .overlay(alignment: .top) { K.sep.frame(height: 1) }
        }
    }

    /// `.wtk`: "Branch  [hotfix/0.9.3.1]".
    private func fact<Content: View>(_ key: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(key).foregroundStyle(K.label2).frame(width: 52, alignment: .leading)
            content()
        }
        .font(.system(size: 12))
        .foregroundStyle(K.label)
        .padding(.top, 10)
    }
}

/// A file of the other worktree (status tile, path, line counts); not clickable, it's not this tab's.
private struct WorktreeFileRow: View {
    let entry: StatusEntry
    let stat: LineStat?

    var body: some View {
        HStack(spacing: 7) {
            StatusTile(letter: letter)
            FilePathText(path: entry.path)
                .frame(maxWidth: .infinity, alignment: .leading)
            LineCounts(additions: stat?.additions, deletions: stat?.deletions)
        }
        .padding(.horizontal, 6)
        .frame(height: KMetric.fileRow)
        .help(entry.path)
    }

    private var letter: String {
        if entry.isConflicted { return "!" }
        if entry.isUntracked { return "A" }
        let status = entry.hasStagedChanges ? entry.indexStatus : entry.worktreeStatus
        return ChangeKind(statusLetter: status)?.letter ?? entry.kind.letter
    }
}
