import KaernKit
import SwiftUI

/// The right panel, phase 1: what's selected in the history. The working copy lists its
/// unstaged and staged files; a commit shows its details and files. Staging, the composer
/// and Review come in phase 2.
struct DetailsPanel: View {
    let repository: RepositoryModel

    var body: some View {
        VStack(spacing: 0) {
            switch repository.selection {
            case .workingCopy:
                WorkingCopyPanel(repository: repository)
            case .commit:
                CommitPanel(repository: repository)
            }
        }
        .frame(width: KMetric.panelWidth)
        .frame(maxHeight: .infinity)
        .background(K.inspector)
        .overlay(alignment: .leading) { K.sep.frame(width: 1) }
    }
}

private struct WorkingCopyPanel: View {
    let repository: RepositoryModel

    var body: some View {
        let entries = repository.status.entries
        let unstaged = entries.filter(\.hasUnstagedChanges)
        let staged = entries.filter(\.hasStagedChanges)
        VStack(alignment: .leading, spacing: 0) {
            let branch = repository.currentBranch ?? (repository.operation?.kind == .rebase ? repository.operation?.branch : nil)
            FlowLayout(spacing: 5) {
                Text((entries.isEmpty ? "No changes" : Formatters.count(entries.count, "file change", "file changes")) + (branch == nil ? "" : " on"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(height: 20)
                if let branch {
                    Text(branch)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(K.accentText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(K.lt1))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 8, trailing: 14))
            if entries.isEmpty {
                VStack(spacing: 6) {
                    Text("Working tree clean").font(.system(size: 13, weight: .semibold)).foregroundStyle(K.label2)
                    Text("Changes you make in this folder show up here.")
                        .font(.system(size: 12)).foregroundStyle(K.label2).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader("Unstaged Files (\(unstaged.count))")
                        ForEach(unstaged) { entry in
                            FileRow(path: entry.path, letter: entry.isUntracked ? "A" : entry.kind.letter,
                                    stat: repository.lineStats[entry.path], partial: entry.stageState == .partial)
                        }
                        sectionHeader("Staged Files (\(staged.count))")
                        ForEach(staged) { entry in
                            FileRow(path: entry.path, letter: entry.kind.letter, stat: nil, partial: entry.stageState == .partial)
                        }
                    }
                    .padding(EdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8))
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(K.label2)
            .padding(.horizontal, 6)
            .frame(height: 28, alignment: .leading)
            .padding(.top, 4)
    }
}

private struct CommitPanel: View {
    let repository: RepositoryModel

    var body: some View {
        if let details = repository.selectedDetails {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text("commit").foregroundStyle(K.label2)
                        Text(details.commit.shortID).font(KFont.hash).foregroundStyle(K.label)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(details.commit.id, forType: .string)
                        } label: {
                            Icon(Icons.copy, size: 12).foregroundStyle(K.label2).frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .help("Copy the full commit hash")
                        if let parent = details.commit.parents.first {
                            Text("parent").foregroundStyle(K.label2)
                            Text(parent.prefix(7)).font(KFont.hash).foregroundStyle(K.accentText)
                        }
                    }
                    .font(.system(size: 11.5))
                    HStack(spacing: 9) {
                        Text(details.commit.author.initials)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(AvatarPalette.color(for: details.commit.author.email)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(details.commit.author.name).font(.system(size: 13, weight: .semibold))
                            Text("authored \(Formatters.historyDate(details.commit.author.date))")
                                .font(.system(size: 11.5)).foregroundStyle(K.label2)
                        }
                    }
                    .padding(.top, 12)
                    Text(details.commit.subject)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.top, 12)
                        .textSelection(.enabled)
                    if !details.body.isEmpty {
                        Text(details.body)
                            .font(.system(size: 13))
                            .foregroundStyle(K.label2)
                            .lineSpacing(2)
                            .padding(.top, 5)
                            .textSelection(.enabled)
                    }
                    Text(Formatters.count(repository.selectedFiles.count, "file", "files"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(K.label2)
                        .padding(.top, 16)
                        .padding(.bottom, 4)
                    ForEach(repository.selectedFiles) { file in
                        FileRow(path: file.path, letter: file.kind.letter, stat: file.stat, partial: false)
                    }
                }
                .padding(EdgeInsets(top: 14, leading: 14, bottom: 10, trailing: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A file row (`.file`): status letter tile, folder in secondary text, name, line counts.
struct FileRow: View {
    let path: String
    let letter: String
    let stat: LineStat?
    let partial: Bool

    @State private var hovering = false

    var body: some View {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        HStack(spacing: 7) {
            Text(letter)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(letterColor)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(letterFill))
            HStack(spacing: 0) {
                if !directory.isEmpty {
                    Text(directory + "/").foregroundStyle(K.label2).truncationMode(.head)
                }
                Text(name).layoutPriority(1)
            }
            .font(.system(size: 12.5))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if partial {
                Text("partial").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(K.accentText)
            }
            if let stat, let additions = stat.additions, let deletions = stat.deletions {
                HStack(spacing: 5) {
                    if additions > 0 { Text("+\(additions)").foregroundStyle(K.add) }
                    if deletions > 0 { Text("−\(deletions)").foregroundStyle(K.del) }
                }
                .font(.system(size: 11, design: .monospaced))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: KMetric.fileRow)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? K.hover : .clear))
        .onHover { hovering = $0 }
        .help(path)
    }

    private var letterColor: Color {
        switch letter {
        case "A", "U": K.add
        case "D": K.del
        default: K.mod
        }
    }

    private var letterFill: Color {
        switch letter {
        case "A", "U": K.addBg
        case "D": K.delBg
        default: K.modBg
        }
    }
}
