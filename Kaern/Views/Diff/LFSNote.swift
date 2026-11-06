import KaernKit
import QuickLook
import SwiftUI

/// A file stored in Git LFS: its size change instead of the pointer text, and both versions in
/// Quick Look when git-lfs has downloaded them.
struct LFSNote: View {
    let path: String
    let change: (old: LFSPointer?, new: LFSPointer?)
    let content: DiffContent
    let model: RepositoryModel
    @State private var showsPointer = false
    @State private var versions: [Version] = []
    @State private var previewItems: [URL] = []
    @State private var previewURL: URL?

    /// One side of the change that's on disk, and the name Quick Look shows for it.
    private struct Version {
        var title: String
        var url: URL
        /// The file in the working tree itself, shown without a copy.
        var isWorkingFile: Bool
    }

    private var name: String { (path as NSString).lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(name) is stored in Git LFS", systemImage: "doc.plaintext")
                    .font(.system(size: 13, weight: .semibold))
                Text(sizeText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack {
                    Button(showsPointer ? "Hide Pointer" : "Show Pointer") { showsPointer.toggle() }
                    Button(versions.count > 1 ? "Quick Look Both" : "Quick Look", action: quickLook)
                        .disabled(versions.isEmpty)
                        .help(versions.isEmpty ? "git-lfs hasn't downloaded these versions (git lfs pull)" : "Opens the versions in Quick Look; the arrows go from one to the other")
                }
                .controlSize(.small)
                if showsPointer {
                    Text(pointerText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(Palette.diffGutter)))
                }
            }
            .padding(14)
            .frame(maxWidth: 560, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))

            // The bar under the toolbar says it too, unless it was closed.
            if model.repository?.runner.isLFSInstalled == false, !model.notices.contains(where: { $0.id == "lfs" }) {
                NoticeRow(
                    text: String(localized: "git-lfs isn't installed — files in Git LFS stay pointers until it is.")
                ) {
                    Button("Copy Install Command") { Pasteboard.copy(RepositoryModel.lfsInstallCommand) }
                }
                .frame(maxWidth: 560)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .quickLookPreview($previewURL, in: previewItems)
        .task(id: path) { versions = findVersions() }
    }

    private var sizeText: String {
        switch (change.old, change.new) {
        case (let old?, let new?):
            return String(localized: "\(Formatters.fileSize(old.size)) → \(Formatters.fileSize(new.size)). The diff shows the size change instead of the pointer text.")
        case (nil, let new?): return String(localized: "New file, \(Formatters.fileSize(new.size)).")
        case (let old?, nil): return String(localized: "Deleted (was \(Formatters.fileSize(old.size))).")
        case (nil, nil): return ""
        }
    }

    private var pointerText: String {
        [change.old.map { "- oid \($0.oid)\n- size \($0.size)" }, change.new.map { "+ oid \($0.oid)\n+ size \($0.size)" }]
            .compactMap { $0 }.joined(separator: "\n")
    }

    /// "HEAD" and the file on disk for a working change; the parent and the commit otherwise.
    private var sideLabels: (old: String, new: String?) {
        switch content {
        case .working: ("HEAD", nil)
        case .commit(let commit, _, _): ((model.comparisonBase ?? commit.parents.first).map { String($0.prefix(7)) } ?? "before", commit.shortID)
        }
    }

    private func findVersions() -> [Version] {
        guard let repository = model.repository else { return [] }
        let base = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        func titled(_ label: String) -> String {
            pathExtension.isEmpty ? "\(base) (\(label))" : "\(base) (\(label)).\(pathExtension)"
        }
        var result: [Version] = []
        if let old = change.old, let url = repository.lfsObjectURL(old.oid) {
            result.append(Version(title: titled(sideLabels.old), url: url, isWorkingFile: false))
        }
        if let new = change.new {
            let file = repository.root.appending(path: path)
            if case .working = content, Self.isContent(file) {
                result.append(Version(title: name, url: file, isWorkingFile: true))
            } else if let url = repository.lfsObjectURL(new.oid) {
                result.append(Version(title: sideLabels.new.map(titled) ?? name, url: url, isWorkingFile: false))
            }
        }
        return result
    }

    /// The file on disk is the real content, not a pointer git-lfs hasn't replaced yet.
    private static func isContent(_ url: URL) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: url.path(percentEncoded: false)) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64)) ?? Data()
        return !head.starts(with: Data("version https://git-lfs.github.com/spec/".utf8))
    }

    /// Git LFS keeps objects under their hash: copies named like the file let Quick Look pick a
    /// viewer (APFS clones them, so even big videos take no time or space).
    private func quickLook() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Kaern Quick Look", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        var items: [URL] = []
        for (index, version) in versions.enumerated() {
            if version.isWorkingFile {
                items.append(version.url)
                continue
            }
            let side = folder.appending(path: "\(index)", directoryHint: .isDirectory)
            let copy = side.appending(path: version.title)
            do {
                try FileManager.default.createDirectory(at: side, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: version.url, to: copy)
                items.append(copy)
            } catch {
                model.showError(error, title: String(localized: "Couldn't Show \(version.title)"))
            }
        }
        previewItems = items
        previewURL = items.first
    }
}

/// A warning with a button: "git-lfs isn't installed — … [Copy Install Command]".
struct NoticeRow<Buttons: View>: View {
    let text: String
    @ViewBuilder var buttons: Buttons

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            buttons
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
    }
}
