import SwiftUI
import UniformTypeIdentifiers

/// Everything inside a Kaern window: the tab row (in the title bar), then the selected
/// repository, or the empty state when no tab is open.
struct WindowRootView: View {
    let window: WindowModel
    @Environment(AppModel.self) private var app
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            TabBar(window: window)
                .zIndex(3)
            if let tab = window.activeTab {
                RepositoryScreen(window: window, repository: app.repository(for: tab.path))
                    .id(tab.path)
            } else {
                EmptyStateView(window: window)
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .background(K.win)
        .ignoresSafeArea()
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(K.accent, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) && isDirectory.boolValue
            }
            guard !folders.isEmpty else { return false }
            app.open(folders, in: window)
            return true
        } isTargeted: { isDropTarget = $0 }
    }
}

/// One repository: toolbar, sidebar | history | panel, status bar.
struct RepositoryScreen: View {
    let window: WindowModel
    @Bindable var repository: RepositoryModel

    var body: some View {
        VStack(spacing: 0) {
            MainToolbar(window: window, repository: repository)
                .zIndex(2)
            HStack(spacing: 0) {
                if window.showsSidebar {
                    SidebarView(repository: repository)
                        .transition(.move(edge: .leading))
                }
                center
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if window.showsDetails, repository.isReady {
                    DetailsPanel(repository: repository)
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(maxHeight: .infinity)
            .background(K.content)
            .clipped()
            StatusBarView(repository: repository)
        }
        .animation(.easeOut(duration: 0.18), value: window.showsSidebar)
        .animation(.easeOut(duration: 0.18), value: window.showsDetails)
        .alert(item: $repository.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
    }

    @ViewBuilder
    private var center: some View {
        switch repository.phase {
        case .ready:
            HistoryView(repository: repository)
        case .waiting, .opening, .light, .loading:
            VStack(spacing: 10) {
                ProgressView().controlSize(.regular)
                Text("Loading \(repository.name)…")
                    .font(.system(size: 13))
                    .foregroundStyle(K.label2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(K.content)
        case .missing:
            MessageView(
                icon: Icons.missingFolder,
                title: "Folder not found",
                message: "\(Formatters.abbreviatedPath(repository.path)) isn’t there anymore. It may have been moved, renamed or deleted, or its disk isn’t connected.",
                primary: ("Try Again", { AppModel.shared.retry(repository) }),
                secondary: ("Close Tab", { closeTab() })
            )
        case .failed(let message):
            MessageView(
                icon: Icons.error,
                title: "Couldn’t open \(repository.name)",
                message: message,
                primary: ("Try Again", { AppModel.shared.retry(repository) }),
                secondary: ("Close Tab", { closeTab() })
            )
        }
    }

    private func closeTab() {
        if let tab = window.tabs.first(where: { $0.path == repository.path }) {
            AppModel.shared.close([tab.id], in: window)
        }
    }
}

/// A centered message with up to two buttons (missing folder, unreadable repository).
private struct MessageView: View {
    let icon: SVGIcon
    let title: String
    let message: String
    let primary: (String, () -> Void)
    let secondary: (String, () -> Void)

    var body: some View {
        VStack(spacing: 10) {
            Icon(icon, size: 34).foregroundStyle(K.label2)
            Text(title).font(.system(size: 15, weight: .bold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(K.label2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 8) {
                Button(secondary.0, action: secondary.1)
                Button(primary.0, action: primary.1)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(K.content)
    }
}
