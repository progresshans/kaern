import AppKit
import KaernKit

/// How a commit's signature reads in the Commit column and the panel (ScreenMarks › 서명): a green
/// shield with a check, an orange one with a question mark, a red one with a cross.
enum SignatureMark: Equatable {
    /// git checked the signature against a key it trusts.
    case verified
    /// Signed, but by a key git can't vouch for (not in allowed signers or the keychain, can't be
    /// checked, expired).
    case unverified
    /// The signature doesn't match the commit, or the key was revoked.
    case bad

    /// `%G?`: `nil` for unsigned commits (N).
    init?(code: Character) {
        switch code {
        case "G": self = .verified
        case "B", "R": self = .bad
        case "N": return nil
        default: self = .unverified   // U, E, X, Y
        }
    }

    init(_ status: CommitSignature.Status) {
        switch status {
        case .verified: self = .verified
        case .bad, .revoked: self = .bad
        case .unverified, .expired, .missingKey: self = .unverified
        }
    }

    var icon: SVGIcon {
        switch self {
        case .verified: Icons.shieldVerified
        case .unverified: Icons.shieldUnknown
        case .bad: Icons.shieldBad
        }
    }
}

/// The selected commit's signature, once read (`nil`: unsigned).
struct SelectedSignature: Equatable {
    let id: String
    let signature: CommitSignature?
    /// Where git looks up SSH keys ("~/.config/git/allowed_signers"), when set.
    var allowedSigners: String?
}

extension RepositoryModel {
    /// Reads `%G?` for history rows that came on screen. Checking runs gpg or ssh-keygen once per
    /// signed commit, so only for rows that have been seen.
    func loadSignatures(for ids: [String], again: Bool = false) {
        let missing = ids.filter { (again || signatureCodes[$0] == nil) && !signaturesInFlight.contains($0) }
        guard !missing.isEmpty else { return }
        signaturesInFlight.formUnion(missing)
        signaturesWanted.formUnion(missing)
        readWantedSignatures()
    }

    /// One read at a time: scrolling fast would otherwise start one per frame, each running gpg
    /// or ssh-keygen once per signed commit. Rows that come on screen meanwhile go in the next one.
    private func readWantedSignatures() {
        guard signatureReadTask == nil, !signaturesWanted.isEmpty, let repository else { return }
        let batch = Array(signaturesWanted)
        signaturesWanted = []
        signatureReadTask = Task {
            let codes = await GitCommandTrigger.$current.withValue(.background("Checking signatures")) {
                await repository.signatureCodes(of: batch)
            }
            signaturesInFlight.subtract(batch)
            var updated = signatureCodes
            for id in batch { updated[id] = codes[id] ?? "N" }
            signatureCodes = updated
            signatureReadTask = nil
            readWantedSignatures()
        }
    }

    /// The shield for a history row, once its signature was read.
    func signatureMark(of id: String) -> SignatureMark? {
        signatureCodes[id].flatMap(SignatureMark.init(code:))
    }

    /// The panel's card for the selected commit: who signed it, the key, what git says.
    func loadSelectedSignature(_ id: String) {
        guard let repository, selectedSignature?.id != id else { return }
        signatureTask?.cancel()
        signatureTask = Task {
            let signature = await GitCommandTrigger.$current.withValue(.background("Commit signature")) {
                await repository.signature(of: id)
            }
            let file = signature?.format == "SSH" ? await repository.allowedSignersFile() : nil
            guard !Task.isCancelled, selection == .commit(id) else { return }
            selectedSignature = SelectedSignature(id: id, signature: signature,
                                                  allowedSigners: file.map { ($0.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath })
            // The row's shield agrees with the card.
            if let signature { signatureCodes[id] = signature.code } else { signatureCodes[id] = "N" }
        }
    }

    /// After the allowed signers changed: the shields seen so far and the card are read again
    /// (the old shields stay until the new ones are in).
    func recheckSignatures() {
        // Everything is read again, after any read that's running (reads go one at a time, so
        // the new answers land last).
        signaturesInFlight = []
        signaturesWanted = []
        loadSignatures(for: Array(signatureCodes.keys), again: true)
        let selected = selectedSignature?.id
        selectedSignature = nil
        if let selected { loadSelectedSignature(selected) }
    }

    // MARK: Trust This Key…

    /// The allowed signers file Trust This Key… writes to when git has none set: in a test
    /// instance next to its session file, never the real ~/.config/git.
    static var defaultAllowedSignersFile: URL {
        #if DEBUG
        if let stem = TestSession.stem { return URL(filePath: stem + ".allowed_signers") }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/git/allowed_signers")
    }

    /// Trust This Key…: an SSH key goes into the allowed signers file once you've compared its
    /// fingerprint (the confirmation shows it); ⌘Z takes it out again. GPG keys are trusted in
    /// GPG, so for those it says how.
    func askTrustSignatureKey() {
        guard case .commit(let id) = selection, let signed = selectedSignature, signed.id == id,
              let signature = signed.signature, let repository else { return }
        let committer = selectedDetails?.committer
        let who = signature.signer.isEmpty ? (committer?.name ?? "the signer") : signature.signer
        guard signature.format == "SSH" else {
            let key = signature.key.isEmpty ? "<key id>" : signature.key
            confirmation = Confirmation(
                title: "Trust \(who)’s GPG key in GPG",
                message: "Git checks GPG signatures with the keys in your GPG keychain. Import the key and sign it locally, then Kaern shows the commit as verified:\n\ngpg --recv-keys \(key)\ngpg --quick-lsign-key \(key)",
                confirmTitle: "Copy Commands",
                confirm: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("gpg --recv-keys \(key)\ngpg --quick-lsign-key \(key)", forType: .string)
                }
            )
            return
        }
        Task { [weak self] in
            guard let self else { return }
            guard let key = await repository.sshSigningKey(of: id) else {
                showToast("Couldn’t read the key from \(short(id))’s signature")
                return
            }
            let configured = await repository.allowedSignersFile()
            let file = configured ?? Self.defaultAllowedSignersFile
            let principal = committer?.email ?? who
            let place = (file.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
            confirmation = Confirmation(
                title: "Trust \(who)’s SSH key?",
                message: "Compare this fingerprint with the one \(who) gave you:\n\(signature.key)\n\nKaern adds the key for \(principal) to \(place), and git shows the commits it signed as verified.",
                note: configured == nil ? "Git has no allowed signers file yet: Kaern makes this one and sets gpg.ssh.allowedSignersFile in your Git settings." : nil,
                confirmTitle: "Trust Key",
                confirm: { [weak self] in self?.trustSigningKey(key, principal: principal, file: file, setsConfig: configured == nil) }
            )
        }
    }

    private func trustSigningKey(_ key: String, principal: String, file: URL, setsConfig: Bool) {
        perform(.working("Trusting the key…"), trigger: "Trust Key") { [weak self] repository in
            // A file kept in a dotfiles folder is often a link: the key goes into what it points
            // at, and the link stays a link.
            let target = file.resolvingSymlinksInPath()
            let previous = FileManager.default.contents(atPath: target.path(percentEncoded: false))
            try GitRepository.addAllowedSigner(principal: principal, key: key, to: target)
            let configPath = file.path(percentEncoded: false)
            if setsConfig {
                try await repository.runner.setGlobalConfig("gpg.ssh.allowedSignersFile", configPath)
            }
            guard let self else { return }
            self.recheckSignatures()
            self.record(.trustedKey(file: target, previous: previous, configPath: setsConfig ? configPath : nil, model: self),
                        toast: "Trusted the key of \(principal) · commits it signed show as verified")
        }
    }

    /// Show Raw Signature (a bad one): the commit object as git stores it, signature included, in
    /// Quick Look (`git cat-file commit`).
    func showRawSignature() {
        guard case .commit(let id) = selection, let repository else { return }
        Task {
            guard let raw = try? await repository.commitObject(id) else { return }
            do {
                quickLookURL = try QuickLookCopies.make(raw, name: "\(short(id)) signed commit.txt")
            } catch {
                showToast("Couldn’t open Quick Look: \(error.localizedDescription)")
            }
        }
    }
}

extension CommitSignature {
    /// `%G?` again, for the row's shield.
    var code: Character {
        switch status {
        case .verified: "G"
        case .unverified: "U"
        case .bad: "B"
        case .expired: "X"
        case .revoked: "R"
        case .missingKey: "E"
        }
    }
}

nonisolated extension ReversibleStep {
    /// Trust This Key… wrote to the allowed signers file `file` (a link's target, never the link)
    /// and, with `configPath`, set it as `gpg.ssh.allowedSignersFile` in the global config. Undo
    /// puts the file back and unsets the setting, each only while it's as Trust Key left it;
    /// redo writes them again only while they're as undo left them.
    static func trustedKey(file: URL, previous: Data?, configPath: String?, model: RepositoryModel) -> ReversibleStep {
        let path = file.path(percentEncoded: false)
        let after = FileManager.default.contents(atPath: path)
        let name = (path as NSString).lastPathComponent
        @Sendable func setting(_ repository: GitRepository) async -> String? {
            guard let output = try? await repository.runner.run(["config", "--global", "--get", "gpg.ssh.allowedSignersFile"], in: nil,
                                                                acceptedStatus: [0, 1]), output.status == 0 else { return nil }
            return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ReversibleStep(label: "Trust Key") { repository in
            guard FileManager.default.contents(atPath: path) == after else {
                throw UndoRefusal(message: "\(name) changed since “Trust Key”, so Kaern can’t take it back.")
            }
            if let configPath, await setting(repository) != configPath {
                throw UndoRefusal(message: "gpg.ssh.allowedSignersFile changed since “Trust Key”, so Kaern can’t take it back.")
            }
            if let previous { try previous.write(to: file, options: .atomic) } else { try FileManager.default.removeItem(at: file) }
            if configPath != nil { try await repository.runner.run(["config", "--global", "--unset", "gpg.ssh.allowedSignersFile"], in: nil) }
            await MainActor.run { model.recheckSignatures() }
            return ReversibleStep(label: "Trust Key") { repository in
                guard FileManager.default.contents(atPath: path) == previous else {
                    throw UndoRefusal(message: "\(name) changed since, so Kaern can’t do “Trust Key” again.")
                }
                if configPath != nil, await setting(repository) != nil {
                    throw UndoRefusal(message: "gpg.ssh.allowedSignersFile is set again, so Kaern can’t do “Trust Key” again.")
                }
                if let after { try after.write(to: file, options: .atomic) }
                if let configPath { try await repository.runner.setGlobalConfig("gpg.ssh.allowedSignersFile", configPath) }
                await MainActor.run { model.recheckSignatures() }
                return trustedKey(file: file, previous: previous, configPath: configPath, model: model)
            }
        }
    }
}
