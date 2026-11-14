import AppKit
import KaernKit
import SwiftUI

/// The center for a stash (ScreenStash): its files' diffs one under another, Split by default,
/// like Review.
struct StashView: View {
    @Bindable var repository: RepositoryModel
    @AppStorage(DiffPreferences.layoutKey, store: .kaern) private var layout = DiffLayout.split
    @AppStorage(SettingsKey.diffWords, store: .kaern) private var words = true
    @State private var limits: [String: Int] = [:]

    var body: some View {
        VStack(spacing: 0) {
            if let stash = repository.shownStash {
                header(stash)
                if let files = repository.stashReviewFiles {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                                ForEach(files) { file in
                                    Section {
                                        let rows = DiffRowItem.rows(for: file, layout: layout, limit: limits[file.path] ?? 2_000, words: words)
                                        ForEach(rows) { item in
                                            DiffRowView(item: item, repository: repository) { limits[file.path] = Int.max }
                                        }
                                        K.sep.frame(height: 1)
                                    } header: {
                                        StashFileHeader(file: file, untracked: repository.stashDetails?.untrackedPaths.contains(file.path) == true)
                                            .id("stash:" + file.path)
                                    }
                                }
                            }
                            .padding(.bottom, 20)
                        }
                        .diffSideScrolling(resetKey: (repository.shownStash?.id ?? "") + "\(layout)")
                        .onReceive(NotificationCenter.default.publisher(for: .kaernScrollStashFile)) { note in
                            guard let path = note.object as? String else { return }
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("stash:" + path, anchor: .top) }
                        }
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                emptyState
            }
        }
        .background(K.content)
        .diffSettings()
    }

    private func header(_ stash: Stash) -> some View {
        HStack(spacing: 8) {
            Button { repository.screen = nil } label: {
                HStack(spacing: 3) {
                    Icon(Icons.arrowLeft, size: 12)
                    Text("Graph").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(K.accentText)
                .padding(.leading, 5)
                .padding(.trailing, 10)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(AccentPlateStyle())
            .keyboardShortcut(.cancelAction)
            HStack(spacing: 7) {
                Icon(Icons.stash(1.3), size: 14).foregroundStyle(K.label2)
                Text(stash.reference).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(K.label2)
                Text(RepositoryModel.stashTitle(stash)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .layoutPriority(-1)
            Spacer(minLength: 0)
            Text("\(repository.stashDetails?.author.name ?? "") · \(stashedWhen(stash))")
                .font(.system(size: 12))
                .foregroundStyle(K.label2)
                .lineLimit(1)
            SegmentedChoice(options: [(DiffLayout.split, "Split"), (.unified, "Unified")], selection: $layout, label: "Diff layout")
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: 44)
        .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
    }

    private func stashedWhen(_ stash: Stash) -> String {
        (RepositoryModel.isKaernCopy(stash) ? "saved " : "stashed ") + Formatters.authoredAt(stash.date)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Icon(Icons.stash(1.3), size: 28).foregroundStyle(K.label3)
            Text("No stashes").font(.system(size: 14, weight: .semibold))
            Text("Stash Changes (⌥⌘S) puts your uncommitted changes aside; they show up here.")
                .font(.system(size: 12))
                .foregroundStyle(K.label2)
            GhostButton(title: "Back to the Graph") { repository.screen = nil }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Notification.Name {
    /// The stash panel asks the stash view to scroll to a file (object: its path).
    static let kaernScrollStashFile = Notification.Name("KaernScrollStashFile")
}

/// `.sfh`: a file's header in the stash view, with "untracked when stashed".
private struct StashFileHeader: View {
    let file: ReviewFile
    let untracked: Bool

    var body: some View {
        HStack(spacing: 8) {
            StatusTile(letter: file.letter)
            FilePathText(path: file.path, nameWeight: .semibold, size: 13)
            if untracked {
                Text("untracked when stashed")
                    .font(.system(size: 11))
                    .foregroundStyle(K.label2)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(K.chip2))
                    .fixedSize()
            }
            Spacer(minLength: 0)
            LineCounts(additions: file.additions, deletions: file.deletions)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(height: 36)
        .background(K.inspector)
        .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
    }
}

/// The right panel for a stash: what it is, where it was made, its files, Apply · Pop · ⋯.
struct StashPanel: View {
    @Bindable var repository: RepositoryModel

    var body: some View {
        VStack(spacing: 0) {
            if let stash = repository.shownStash {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(RepositoryModel.stashTitle(stash))
                            .font(.system(size: 14, weight: .semibold))
                            .textSelection(.enabled)
                        if let details = repository.stashDetails, details.stash.id == stash.id {
                            detailsBody(stash, details)
                        } else {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80)
                        }
                    }
                    .padding(EdgeInsets(top: 14, leading: 14, bottom: 10, trailing: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                actions(stash)
            } else {
                Text("Nothing selected")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(K.label2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(K.inspector)
        .overlay(alignment: .leading) { K.sep.frame(width: 1) }
    }

    @ViewBuilder
    private func detailsBody(_ stash: Stash, _ details: StashDetails) -> some View {
        let auto = RepositoryModel.isKaernCopy(stash)
        HStack(spacing: 9) {
            Text(auto ? "K" : details.author.initials)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(auto ? K.accent : AvatarPalette.color(for: details.author.email.isEmpty ? details.author.name : details.author.email)))
            VStack(alignment: .leading, spacing: 1) {
                Text(details.author.name).font(.system(size: 13, weight: .semibold))
                Text((auto ? "saved " : "stashed ") + Formatters.authoredAt(stash.date)).font(.system(size: 11.5)).foregroundStyle(K.label2)
            }
        }
        .padding(.top, 12)
        Text(description(stash, details))
            .font(.system(size: 13))
            .foregroundStyle(K.label2)
            .lineSpacing(2)
            .padding(.top, 10)
            .fixedSize(horizontal: false, vertical: true)
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Stash").foregroundStyle(K.label2)
                HStack(spacing: 6) {
                    Text(stash.reference).font(KFont.hash)
                    Button { repository.copyStashName(stash) } label: {
                        Icon(Icons.copy, size: 12).foregroundStyle(K.label2).frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(HoverPlateStyle(radius: 5))
                    .help("Copy the stash name")
                }
            }
            GridRow {
                Text("Based on").foregroundStyle(K.label2)
                Button {
                    if repository.commit(details.baseID) != nil {
                        repository.screen = nil
                        repository.selection = .commit(details.baseID)
                        repository.scrollRequest = ScrollRequest(id: details.baseID)
                    }
                } label: {
                    Text(details.baseID.prefix(7)).font(KFont.hash).foregroundStyle(K.accentText)
                }
                .buttonStyle(.plain)
                .help("Show \(details.baseID.prefix(7)) in the graph")
            }
            if let branch = details.branch {
                GridRow {
                    Text("On").foregroundStyle(K.label2)
                    Text(branch)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(K.accentText)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(K.accentSoft))
                }
            }
        }
        .font(.system(size: 12.5))
        .padding(.top, 14)
        let files = repository.stashReviewFiles ?? []
        HStack(spacing: 6) {
            Text(Formatters.count(files.count, "file changed", "files changed"))
            LineCounts(additions: files.reduce(0) { $0 + $1.additions }, deletions: files.reduce(0) { $0 + $1.deletions })
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(K.label2)
        .padding(.top, 16)
        .padding(.bottom, 4)
        ForEach(files) { file in
            StashFileRow(file: file) {
                NotificationCenter.default.post(name: .kaernScrollStashFile, object: file.path)
            }
        }
    }

    private func description(_ stash: Stash, _ details: StashDetails) -> String {
        if RepositoryModel.isKaernCopy(stash) {
            return "Kaern kept this copy before throwing changes away, so they can come back."
        }
        let from = details.branch.map { "Stashed from \($0)" } ?? "Stashed from a detached HEAD"
        return from + (details.includesUntracked ? ", including untracked files." : ".")
    }

    private func actions(_ stash: Stash) -> some View {
        let idle = repository.activity == nil && repository.stashConflict == nil
        return PanelActions {
            PrimaryButton(title: "Apply", height: 24) { repository.from("Stash view") { repository.applyStash(stash, pop: false) } }
                .disabled(!idle)
            GhostButton(title: "Pop") { repository.from("Stash view") { repository.applyStash(stash, pop: true) } }
                .disabled(!idle)
            Spacer(minLength: 0)
            Menu {
                Button("Create Branch from Stash…") { repository.askBranchFromStash(stash) }
                Button("Rename…") { repository.sheet = .renameStash(stash) }
                Button("Copy Stash Name") { repository.copyStashName(stash) }
                Divider()
                Button("Drop Stash", role: .destructive) { repository.from("Stash view") { repository.dropStash(stash) } }
            } label: {
                Text("⋯")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(K.label)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .controlSurface(radius: 7)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!idle)
            .accessibilityLabel("More stash actions")
        }
    }
}

/// A file row in the stash panel; clicking it scrolls the center to that file.
private struct StashFileRow: View {
    let file: ReviewFile
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                StatusTile(letter: file.letter)
                FilePathText(path: file.path)
                    .frame(maxWidth: .infinity, alignment: .leading)
                LineCounts(additions: file.additions, deletions: file.deletions)
            }
            .padding(.horizontal, 6)
            .frame(height: KMetric.fileRow)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? K.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(file.path)
    }
}
