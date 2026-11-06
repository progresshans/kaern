import AppKit
import KaernKit
import SwiftUI

/// Root of a repository window. The window's value is the repository URL, so SwiftUI restores
/// one window per repository on relaunch. With Settings › General › Tabs the windows are tabs
/// of one window; with Icon Rail or Named List a column on the left lists the repositories
/// this window switches between.
struct RepositoryWindowRoot: View {
    @Binding var url: URL?
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.appearsActive) private var appearsActive
    @AppStorage(PreferenceKey.repositorySwitcher) private var switcher = RepositorySwitcher.toolbar
    /// Icon Rail / Named List: this window's repositories, one path per line.
    @SceneStorage("railRepositories") private var railStorage = ""
    /// Named List folded into the rail with ‹.
    @SceneStorage("railFolded") private var railFolded = false
    @State private var isChoosingTab = false

    private var railPaths: [String] {
        railStorage.split(separator: "\n").map(String.init)
    }

    var body: some View {
        Group {
            if let url {
                HStack(spacing: 0) {
                    if switcher.usesRail {
                        RepositoryRail(
                            paths: railPaths.contains(url.plainPath) ? railPaths : railPaths + [url.plainPath],
                            current: url.plainPath,
                            isNamed: switcher == .namedList && !railFolded,
                            onSelect: { switchRail(to: $0) },
                            onAdd: { switchRail(to: $0) },
                            onRemove: { path in setRail(railPaths.filter { $0 != path }) },
                            onToggleNamed: { railFolded.toggle() }
                        )
                        Divider()
                    }
                    RepositoryWindow(url: url, tabStrip: switcher == .tabs ? AnyView(
                        RepositoryTabStrip(
                            paths: railPaths.contains(url.plainPath) ? railPaths : railPaths + [url.plainPath],
                            current: url.plainPath,
                            onSelect: { switchRail(to: $0) },
                            onClose: { closeTab($0) },
                            onAdd: { isChoosingTab = true }
                        )
                    ) : nil) { newURL in
                        if switcher.sharesWindow { switchRail(to: newURL) } else { switchWindow(to: newURL) }
                    }
                    .id(url)
                }
                .onAppear { appModel.windowAppeared(for: url) }
                .onDisappear { appModel.windowDisappeared(for: url) }
                .onChange(of: url) { old, new in
                    // A rail switch keeps the window: move its bookkeeping to the new repository.
                    appModel.windowDisappeared(for: old)
                    appModel.windowAppeared(for: new)
                }
                .onAppear { addToRail(url) }
            } else {
                // A new tab (the + in the tab bar) starts with the repository list.
                VStack(spacing: 14) {
                    Text("Open a Repository")
                        .font(.system(size: 15, weight: .semibold))
                    RepositoryPopover(currentURL: URL(filePath: "/")) { chosen, _ in
                        if appModel.isOpen(chosen) {
                            // Already in a tab: go there instead of opening it twice.
                            openWindow(id: SceneID.repository, value: chosen)
                            dismissWindow()
                        } else {
                            appModel.noteOpened(chosen)
                            url = chosen
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
                    Text("Repositories that are already open jump to their tab.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 800, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
                .navigationTitle("New Tab")
            }
        }
        .onAppear {
            appModel.register(openWindow: openWindow, dismissWindow: dismissWindow)
        }
        .onChange(of: appModel.railOpenRequest) { _, request in
            // The front window takes repositories opened from File › Open, Welcome and so on.
            guard let request, appearsActive || !NSApp.isActive else { return }
            appModel.railOpenRequest = nil
            switchRail(to: request)
        }
        .onChange(of: appModel.tabChooserRequest) {
            if appearsActive { isChoosingTab = true }
        }
        .sheet(isPresented: $isChoosingTab) {
            VStack(spacing: 0) {
                RepositoryPopover(currentURL: url ?? URL(filePath: "/")) { chosen, inNewWindow in
                    isChoosingTab = false
                    if inNewWindow { appModel.openInNewWindow(chosen) } else { switchRail(to: chosen) }
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { isChoosingTab = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding([.horizontal, .bottom], 12)
            }
        }
    }

    /// Return in the repository pop-up: show another repository in this window, unless it's
    /// already open somewhere else — then that window comes forward instead.
    private func switchWindow(to newURL: URL) {
        if appModel.isOpen(newURL) {
            openWindow(id: SceneID.repository, value: newURL)
        } else {
            appModel.noteOpened(newURL)
            url = newURL
        }
    }

    /// Icon Rail / Named List: show `newURL` here and keep it in the list.
    private func switchRail(to newURL: URL) {
        guard newURL != url else { return }
        if appModel.isOpen(newURL) {
            // It has a window of its own (from Toolbar or Tabs mode, or Open in New Window).
            openWindow(id: SceneID.repository, value: newURL)
            return
        }
        if let url { addToRail(url) }
        addToRail(newURL)
        appModel.noteOpened(newURL)
        url = newURL
    }

    private func addToRail(_ newURL: URL) {
        let path = newURL.plainPath
        var paths = railPaths
        if !paths.contains(path) {
            paths.append(path)
            setRail(paths)
        }
    }

    /// Closes a tab; closing the one on screen shows its neighbor (the window closes with the last).
    private func closeTab(_ path: String) {
        var paths = railPaths.contains(url?.plainPath ?? "") ? railPaths : railPaths + [url?.plainPath ?? ""]
        guard let index = paths.firstIndex(of: path) else { return }
        paths.remove(at: index)
        setRail(paths)
        guard path == url?.plainPath else { return }
        if paths.isEmpty {
            NSApp.keyWindow?.performClose(nil)
        } else {
            url = URL(filePath: paths[min(index, paths.count - 1)], directoryHint: .isDirectory)
        }
    }

    private func setRail(_ paths: [String]) {
        railStorage = paths.joined(separator: "\n")
    }
}
