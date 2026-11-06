import AppKit
import KaernKit
import SwiftUI

/// Settings › General › Icon Rail (52pt of initials with a change dot) or Named List (180pt of
/// names and current branches, which folds into the rail with ‹). One window holds several
/// repositories and a click switches between them.
struct RepositoryRail: View {
    let paths: [String]
    let current: String
    let isNamed: Bool
    let onSelect: (URL) -> Void
    let onAdd: (URL) -> Void
    let onRemove: (String) -> Void
    let onToggleNamed: () -> Void

    @Environment(AppModel.self) private var appModel
    @State private var summaries: [String: RepositorySummary] = [:]
    @State private var isChoosing = false

    var body: some View {
        VStack(spacing: 0) {
            if isNamed {
                HStack {
                    Text("Repositories")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onToggleNamed) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Show initials only")
                    .accessibilityLabel("Show Initials Only")
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            }
            ScrollView {
                VStack(spacing: isNamed ? 2 : 8) {
                    ForEach(paths, id: \.self) { path in
                        RailItem(path: path, summary: summaries[path], isCurrent: path == current, isNamed: isNamed)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(URL(filePath: path, directoryHint: .isDirectory)) }
                            .contextMenu {
                                Button("Open in New Window") { AppModel.shared.openInNewWindow(URL(filePath: path, directoryHint: .isDirectory)) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
                                Divider()
                                Button("Remove from List") { onRemove(path) }
                                    .disabled(path == current)
                            }
                    }
                }
                .padding(.vertical, isNamed ? 2 : 10)
                .padding(.horizontal, isNamed ? 6 : 0)
            }
            Spacer(minLength: 0)
            HStack {
                Button {
                    isChoosing = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.bordered)
                .help("Open another repository here")
                .accessibilityLabel("Add Repository")
                .popover(isPresented: $isChoosing, arrowEdge: .trailing) {
                    RepositoryPopover(currentURL: URL(filePath: current, directoryHint: .isDirectory)) { url, inNewWindow in
                        isChoosing = false
                        if inNewWindow { AppModel.shared.openInNewWindow(url) } else { onAdd(url) }
                    }
                }
                if isNamed { Spacer() }
            }
            .padding(.horizontal, isNamed ? 10 : 0)
            .padding(.bottom, 10)
        }
        .frame(width: isNamed ? 180 : 52)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
        .task(id: paths) { await loadSummaries() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await loadSummaries() }
        }
        .task {
            // Changes made in Terminal or another window show up within half a minute.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await loadSummaries()
            }
        }
    }

    private func loadSummaries() async {
        let runner = appModel.makeRunner()
        await withTaskGroup(of: (String, WorkingTreeStatus?).self) { group in
            for path in paths {
                group.addTask {
                    let url = URL(filePath: path, directoryHint: .isDirectory)
                    guard let repository = try? await GitRepository.open(url, runner: runner) else { return (path, nil) }
                    return (path, try? await repository.status())
                }
            }
            for await (path, status) in group {
                if let status { summaries[path] = RepositorySummary(status: status) }
            }
        }
    }
}

private struct RailItem: View {
    let path: String
    let summary: RepositorySummary?
    let isCurrent: Bool
    let isNamed: Bool

    private var name: String { URL(filePath: path).lastPathComponent }

    var body: some View {
        Group {
            if isNamed {
                HStack(spacing: 8) {
                    badge(size: 22, font: 9)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(summary?.branch ?? " ")
                            .font(.system(size: 11))
                            .foregroundStyle(isCurrent ? Color.white.opacity(0.85) : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 2)
                    if let summary, summary.changes > 0 {
                        Text("\(summary.changes)")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(isCurrent ? Color.white.opacity(0.85) : Color.secondary)
                    }
                }
                .foregroundStyle(isCurrent ? Color.white : Color.primary)
                .padding(.horizontal, 6)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 6).fill(isCurrent ? Color.accentColor : .clear))
            } else {
                badge(size: 30, font: 11)
                    .frame(width: 52)
                    .overlay(alignment: .leading) {
                        if isCurrent {
                            Capsule().fill(Color.accentColor).frame(width: 3, height: 22)
                        }
                    }
            }
        }
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(tooltip)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    /// Colored initials with an orange dot when there are uncommitted changes.
    private func badge(size: CGFloat, font: CGFloat) -> some View {
        Text(Self.initials(name))
            .font(.system(size: font, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27).fill(Self.color(for: name)))
            .overlay(alignment: .topTrailing) {
                if let summary, summary.changes > 0 {
                    Circle()
                        .fill(Color.orange)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                        .offset(x: 3, y: -3)
                }
            }
    }

    /// "godj — main · 11 changes · ↑5"
    private var tooltip: String {
        guard let summary else { return name }
        let detail = summary.detail
        return detail.isEmpty ? "\(name) — \(summary.branch)" : "\(name) — \(summary.branch) · \(detail)"
    }

    /// "godj-web" → "GW", "powerlens" → "PL"? — the first letters of the words, else the
    /// first two letters.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { "-_ .".contains($0) })
        if words.count >= 2 {
            return String(words.prefix(2).compactMap(\.first)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    static func color(for name: String) -> Color {
        let palette: [Color] = [.green, .purple, .orange, .blue, .gray, .pink, .teal, .indigo, .brown, .red]
        let hash = name.unicodeScalars.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }
}

/// Settings › General › Tabs: a tab for each repository this window has open, under the bar,
/// with + at the end for the repository list. ⌃Tab and ⇧⌘] / ⇧⌘[ move between tabs.
struct RepositoryTabStrip: View {
    let paths: [String]
    let current: String
    let onSelect: (URL) -> Void
    let onClose: (String) -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(paths, id: \.self) { path in
                RepositoryTab(path: path, isCurrent: path == current, canClose: paths.count > 1,
                              onSelect: { onSelect(URL(filePath: path, directoryHint: .isDirectory)) },
                              onClose: { onClose(path) })
                if path != paths.last { Divider().frame(height: 14) }
            }
            Divider().frame(height: 14)
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open a repository in a new tab (⌘T)")
            .accessibilityLabel("New Tab")
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(Color(Palette.titleBar))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1) }
        .background {
            // ⌃Tab / ⌃⇧Tab and ⇧⌘] / ⇧⌘[ like window tabs.
            Group {
                Button("") { step(1) }.keyboardShortcut(.tab, modifiers: .control)
                Button("") { step(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
                Button("") { step(1) }.keyboardShortcut("]", modifiers: [.shift, .command])
                Button("") { step(-1) }.keyboardShortcut("[", modifiers: [.shift, .command])
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    private func step(_ offset: Int) {
        guard let index = paths.firstIndex(of: current), paths.count > 1 else { return }
        let next = (index + offset + paths.count) % paths.count
        onSelect(URL(filePath: paths[next], directoryHint: .isDirectory))
    }
}

private struct RepositoryTab: View {
    let path: String
    let isCurrent: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Text(URL(filePath: path).lastPathComponent)
                .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 24)
            HStack {
                if canClose && (isHovered || isCurrent) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Color.primary.opacity(isHovered ? 0.08 : 0)))
                    }
                    .buttonStyle(.plain)
                    .help("Close Tab")
                    .accessibilityLabel("Close Tab")
                }
                Spacer()
            }
            .padding(.leading, 6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(isCurrent ? Color(Palette.titleBarControl) : (isHovered ? Color.primary.opacity(0.04) : .clear)))
        .shadow(color: .black.opacity(isCurrent ? 0.06 : 0), radius: 1, y: 0.5)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .help(Formatters.abbreviatedPath(URL(filePath: path)))
        .contextMenu {
            Button("Open in New Window") { AppModel.shared.openInNewWindow(URL(filePath: path, directoryHint: .isDirectory)) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
            Divider()
            Button("Close Tab", action: onClose).disabled(!canClose)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}
