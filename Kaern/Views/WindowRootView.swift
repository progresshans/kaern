import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Everything inside a Kaern window. With Tabs (the default) the tab row sits in the title bar
/// and each repository has its toolbar under it; with Sidebar or Toolbar switching the toolbar
/// itself is the title bar, and Sidebar adds the repository list down the left.
struct WindowRootView: View {
    let window: WindowModel
    @Environment(AppModel.self) private var app
    @State private var isDropTarget = false
    @State private var width: CGFloat = 0
    @AppStorage(SettingsKey.toolbarStyle, store: .kaern) private var toolbarStyle = ToolbarStyle.iconOnly
    @AppStorage(SettingsKey.repositorySwitching, store: .kaern) private var switching = RepositorySwitching.tabs
    @AppStorage(SettingsKey.listFoldsNarrow, store: .kaern) private var listFoldsNarrow = true
    @AppStorage(PaneSizes.listKey, store: .kaern) private var storedList: Double = 0

    var body: some View {
        Group {
            if switching == .tabs {
                tabsLayout
            } else {
                titleBarLayout
            }
        }
        // What the screens fold at, not the width itself: a window being resized then redraws
        // them when it crosses one of those widths, not at every step.
        .environment(\.windowTier, NarrowTier(width: width))
        .environment(\.toolbarFoldsMake, width > 0 && width < 1000)
        .environment(\.repositorySwitching, switching)
        .frame(minWidth: 760, minHeight: 520)
        .background(K.win)
        .ignoresSafeArea()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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

    /// The tab row, then the repository (its toolbar first). A window has no tab only while it
    /// closes after its last one: the start window (WelcomeWindowController) stands for no repository.
    private var tabsLayout: some View {
        VStack(spacing: 0) {
            TabBar(window: window)
                .zIndex(3)
            ZStack(alignment: .top) {
                if let tab = window.activeTab {
                    RepositoryScreen(window: window, repository: app.repository(for: tab.path))
                        .id(tab.path)
                } else {
                    K.win
                }
                // Clone, Create New Repository, Publish: under the toolbar when a tab shows one.
                WindowSheetHost(window: window, topInset: window.activeTab == nil ? 0 : toolbarStyle.height)
            }
            .animation(.easeOut(duration: 0.15), value: window.sheet?.id)
        }
    }

    /// Sidebar and Toolbar switching: the toolbar in the title bar, the list (Sidebar), then the
    /// repository without a toolbar of its own.
    private var titleBarLayout: some View {
        let repository = window.activeTab.map { app.repository(for: $0.path) }
        let railByWidth = listFoldsNarrow && width > 0 && width < 1100
        // The repository beside the list keeps room for its sidebar, panel and middle at their least.
        let listRange = PaneSizes.range(PaneSizes.listMin, width > 0 ? width - PaneSizes.screenLeast : .infinity)
        let listWidth = PaneSizes.size(storedList, board: RepositoryListView.width, in: listRange)
        return VStack(spacing: 0) {
            Group {
                if let repository {
                    MainToolbar(window: window, repository: repository, inTitleBar: true)
                        .id(repository.path)
                } else {
                    EmptyTitleBar(window: window)
                }
            }
            .zIndex(3)
            ZStack(alignment: .top) {
                HStack(spacing: 0) {
                    if switching == .sidebar {
                        if window.listFolded || railByWidth {
                            RepositoryRailView(window: window, isAutomatic: railByWidth && !window.listFolded)
                                .transition(.move(edge: .leading))
                        } else {
                            RepositoryListView(window: window)
                                .frame(width: listWidth)
                                .overlay(alignment: .trailing) {
                                    PaneResizeHandle(side: .trailing, size: listWidth, range: listRange, label: "Repository list width") {
                                        storedList = Double($0)
                                    } reset: { storedList = 0 }
                                }
                                .debugPaneFrame("list", window: window.id)
                                .zIndex(1)
                                .transition(.move(edge: .leading))
                        }
                    }
                    Group {
                        if let tab = window.activeTab {
                            RepositoryScreen(window: window, repository: app.repository(for: tab.path), showsToolbar: false, showsStatusBar: false)
                                .id(tab.path)
                        } else {
                            K.win
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .animation(.easeOut(duration: 0.18), value: window.listFolded || railByWidth)
                WindowSheetHost(window: window, topInset: 0)
            }
            .animation(.easeOut(duration: 0.15), value: window.sheet?.id)
            // The status bar runs under the list too (WindowRepoSidebar).
            if let repository {
                StatusBarView(repository: repository)
                    .id(repository.path)
            }
        }
    }
}

/// The title bar when no repository is open in Sidebar or Toolbar mode: room for the traffic
/// lights, and the window moves by it.
private struct EmptyTitleBar: View {
    let window: WindowModel
    @AppStorage(SettingsKey.toolbarStyle, store: .kaern) private var style = ToolbarStyle.iconOnly

    var body: some View {
        HStack {
            Spacer()
        }
        .frame(height: style.titleBarHeight)
        .frame(maxWidth: .infinity)
        .background {
            ZStack(alignment: .bottom) {
                K.win
                K.sep.frame(height: 1)
            }
            .windowDragArea()
        }
    }
}

/// How far a narrow window folds (ScreenNarrow). Each step applies below its width.
enum NarrowTier: Int, Comparable {
    case wide
    /// < 1,280: the Commit column hides.
    case noHash
    /// < 1,180: short dates ("2h", "1d").
    case shortDates
    /// < 1,100: the sidebar folds into its section icons; a section opens over the graph.
    case sidebarRail
    /// < 960: the details panel opens over the graph instead of beside it.
    case panelOverlay
    /// < 860: no dates or descriptions.
    case compact

    init(width: CGFloat) {
        switch width {
        case ..<1: self = .wide
        case ..<860: self = .compact
        case ..<960: self = .panelOverlay
        case ..<1100: self = .sidebarRail
        case ..<1180: self = .shortDates
        case ..<1280: self = .noHash
        default: self = .wide
        }
    }

    static func < (lhs: NarrowTier, rhs: NarrowTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension EnvironmentValues {
    /// The window's width, for the narrow-window folding.
    /// How far the window has folded (`NarrowTier`).
    @Entry var windowTier = NarrowTier.wide
    /// Under 1,000 pt: a toolbar with names puts New Branch, Stash and Pop into » (ScreenNarrow).
    @Entry var toolbarFoldsMake = false
    @Entry var repositorySwitching: RepositorySwitching = .tabs
}

/// One repository: toolbar (unless the title bar has it), sidebar | history | panel, status bar.
struct RepositoryScreen: View {
    let window: WindowModel
    @Bindable var repository: RepositoryModel
    var showsToolbar = true
    /// Sidebar and Toolbar switching put the status bar under the whole window instead.
    var showsStatusBar = true
    @AppStorage(SettingsKey.toolbarStyle, store: .kaern) private var toolbarStyle = ToolbarStyle.iconOnly
    @AppStorage(PaneSizes.sidebarKey, store: .kaern) private var storedSidebar: Double = 0
    @AppStorage(PaneSizes.panelKey, store: .kaern) private var storedPanel: Double = 0
    @AppStorage(PaneSizes.drawerKey, store: .kaern) private var storedDrawer: Double = 0
    /// The row of sidebar, middle and panel, and the middle's height: what the panes may take.
    @State private var rowWidth: CGFloat = 0
    @State private var middleHeight: CGFloat = 0
    @Environment(\.windowTier) private var tier
    @Environment(\.repositorySwitching) private var switching

    /// Where cards and sheets start: under this screen's own toolbar, if it has one.
    private var chromeTop: CGFloat { showsToolbar ? toolbarStyle.height : 0 }

    var body: some View {
        // Focus hides both side panels without changing what Sidebar and Details are set to.
        let showsSidebar = window.showsSidebar && !window.isFocused && repository.hasContent
        let sidebarRail = showsSidebar && tier >= .sidebarRail
        let panelOverlay = tier >= .panelOverlay
        let showsDetails = (panelOverlay ? window.overlayPanelOpen : window.showsDetails) && !window.isFocused && repository.isReady
        // The sizes they were dragged to, fitted to the window.
        let sidebarSize = PaneSizes.size(storedSidebar, board: KMetric.sidebarWidth, in: PaneSizes.range(PaneSizes.sidebarMin, .infinity))
        let panelSize = PaneSizes.size(storedPanel, board: repository.screen == .conflicts ? ResolveConflictsPanel.width : KMetric.panelWidth,
                                       in: PaneSizes.range(PaneSizes.panelMin, .infinity))
        let columns = SideColumns(width: rowWidth, sidebar: showsSidebar && !sidebarRail ? sidebarSize : nil,
                                  panel: showsDetails && !panelOverlay ? panelSize : nil, fixed: sidebarRail ? SidebarRail.width : 0)
        // Over the graph (a narrow window), the sidebar from its rail or the panel leaves some of it.
        let overlayRoom = rowWidth > 0 ? rowWidth - (sidebarRail ? SidebarRail.width : 0) - PaneSizes.overlayGap : .infinity
        let flyoutRange = PaneSizes.range(PaneSizes.sidebarMin, overlayRoom)
        let overlayPanelRange = PaneSizes.range(PaneSizes.panelMin, overlayRoom)
        let drawerRange = PaneSizes.range(PaneSizes.drawerMin, middleHeight > 0 ? middleHeight - PaneSizes.graphMin : .infinity)
        let drawerHeight = PaneSizes.size(storedDrawer, board: FocusDrawer.height, in: drawerRange)
        VStack(spacing: 0) {
            if showsToolbar {
                MainToolbar(window: window, repository: repository)
                    .zIndex(2)
            }
            if repository.isReady, repository.isMidOperation || repository.operationFinish != nil {
                OperationBar(repository: repository)
                    .zIndex(1)
            }
            if repository.search.isOpen, repository.isReady, repository.screen == nil {
                FindBar(repository: repository)
                    .zIndex(1)
            }
            HStack(spacing: 0) {
                if sidebarRail {
                    SidebarRail(repository: repository, window: window)
                        .transition(.move(edge: .leading))
                } else if showsSidebar {
                    SidebarView(repository: repository, showsHeader: switching != .tabs)
                        .frame(width: columns.sidebar)
                        .overlay(alignment: .trailing) {
                            PaneResizeHandle(side: .trailing, size: columns.sidebar, range: columns.sidebarRange, label: "Sidebar width") {
                                keepShownWidths(columns, sidebar: sidebarSize, panel: panelSize)
                                storedSidebar = Double($0)
                            } reset: { storedSidebar = 0 }
                        }
                        .debugPaneFrame("sidebar", window: window.id)
                        .zIndex(1)
                        .transition(.move(edge: .leading))
                }
                VStack(spacing: 0) {
                    center
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                    if window.isFocused, window.showsDrawer, repository.isReady, repository.review == nil {
                        FocusDrawer(repository: repository, height: drawerHeight) { window.showsDrawer = false }
                            .overlay(alignment: .top) {
                                PaneResizeHandle(side: .top, size: drawerHeight, range: drawerRange, label: "Drawer height") {
                                    storedDrawer = Double($0)
                                } reset: { storedDrawer = 0 }
                            }
                            .debugPaneFrame("drawer", window: window.id)
                            .transition(.move(edge: .bottom))
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { middleHeight = $0 }
                .layoutPriority(-1)
                if showsDetails, !panelOverlay {
                    detailsPanel
                        .frame(width: columns.panel)
                        .overlay(alignment: .leading) {
                            PaneResizeHandle(side: .leading, size: columns.panel, range: columns.panelRange, label: "Panel width") {
                                keepShownWidths(columns, sidebar: sidebarSize, panel: panelSize)
                                storedPanel = Double($0)
                            } reset: { storedPanel = 0 }
                        }
                        .debugPaneFrame("panel", window: window.id)
                        .zIndex(1)
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(maxHeight: .infinity)
            .background(K.content)
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            .overlay(alignment: .leading) {
                // < 1,100 pt: a section picked in the rail opens the whole sidebar over the graph.
                if sidebarRail, let section = window.sidebarFlyout {
                    let width = min(sidebarSize, flyoutRange.upperBound)
                    ZStack(alignment: .leading) {
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .onTapGesture { window.sidebarFlyout = nil }
                        SidebarView(repository: repository, showsHeader: switching != .tabs, focus: section)
                            .frame(width: width)
                            .shadow(color: .black.opacity(0.18), radius: 17, x: 14)
                            .overlay(alignment: .trailing) {
                                PaneResizeHandle(side: .trailing, size: width, range: flyoutRange, label: "Sidebar width") {
                                    storedSidebar = Double($0)
                                } reset: { storedSidebar = 0 }
                            }
                            .debugPaneFrame("sidebar", window: window.id)
                            .padding(.leading, SidebarRail.width)
                    }
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .trailing) {
                // < 960 pt: the panel opens over the graph, with × to put it away.
                if panelOverlay, showsDetails {
                    let width = min(panelSize, overlayPanelRange.upperBound)
                    detailsPanel
                        .frame(width: width)
                        .shadow(color: .black.opacity(0.16), radius: 17, x: -14)
                        .overlay(alignment: .leading) {
                            PaneResizeHandle(side: .leading, size: width, range: overlayPanelRange, label: "Panel width") {
                                storedPanel = Double($0)
                            } reset: { storedPanel = 0 }
                        }
                        .debugPaneFrame("panel", window: window.id)
                        .overlay(alignment: .topLeading) {
                            Button { window.overlayPanelOpen = false } label: {
                                Icon(Icons.closeLarge, size: 10)
                                    .foregroundStyle(K.label2)
                                    .frame(width: 26, height: 26)
                                    .popSurface(radius: 13)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .offset(x: -13, y: 12)
                            .accessibilityLabel("Hide the details panel")
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let run = repository.hookRun {
                    // `.hookhud`: over the composer, 16 pt from the right edge.
                    HookHUD(repository: repository, run: run)
                        .padding(.trailing, 16)
                        .padding(.bottom, 118)
                        .transition(.opacity)
                }
            }
            if showsStatusBar {
                StatusBarView(repository: repository)
            }
        }
        .overlay(alignment: .bottom) {
            ToastView(repository: repository)
                .padding(.bottom, showsStatusBar ? 44 : 18)
                .animation(.easeOut(duration: 0.2), value: repository.toast?.id)
        }
        // Space and File › Quick Look (ScreenMarks).
        .quickLookPreview($repository.quickLookURL)
        .overlay {
            if window.showsQuickOpen, repository.isReady {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { window.showsQuickOpen = false }
                    QuickOpenPanel(repository: repository, window: window)
                        .padding(.top, chromeTop + 50)
                }
                .transition(.opacity)
            }
        }
        .overlay {
            RepositorySheetHost(repository: repository, toolbarHeight: chromeTop)
        }
        .animation(.easeOut(duration: 0.15), value: repository.sheet?.id)
        .overlay {
            if repository.confirmation != nil || repository.hookFailure != nil {
                // The shade covers the window below the tab row; the card sits near the top.
                ZStack(alignment: .top) {
                    AlertShade()
                    if let confirmation = repository.confirmation {
                        ConfirmationCard(confirmation: confirmation) { repository.confirmation = nil }
                            .padding(.top, chromeTop + 14)
                    } else if let failure = repository.hookFailure {
                        HookFailureCard(repository: repository, failure: failure)
                            .padding(.top, chromeTop + 14)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: showsSidebar)
        .animation(.easeOut(duration: 0.18), value: sidebarRail)
        .animation(.easeOut(duration: 0.18), value: showsDetails)
        .animation(.easeOut(duration: 0.15), value: window.sidebarFlyout)
        .animation(.easeOut(duration: 0.18), value: window.isFocused && window.showsDrawer)
        .animation(.easeOut(duration: 0.15), value: repository.hookRun != nil)
        .onChange(of: tier >= .sidebarRail) { _, folded in if !folded { window.sidebarFlyout = nil } }
        .onChange(of: panelOverlay) { _, overlay in if !overlay { window.overlayPanelOpen = false } }
        .alert(item: $repository.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
    }

    /// A drag keeps what the columns show: one the window has narrowed stays that wide instead of
    /// growing back under the pointer while the other one moves.
    private func keepShownWidths(_ columns: SideColumns, sidebar: CGFloat, panel: CGFloat) {
        if columns.sidebar > 0, columns.sidebar < sidebar { storedSidebar = Double(columns.sidebar) }
        if columns.panel > 0, columns.panel < panel { storedPanel = Double(columns.panel) }
    }

    @ViewBuilder
    private var detailsPanel: some View {
        switch repository.screen {
        case .conflicts: ResolveConflictsPanel(repository: repository)
        case .stash: StashPanel(repository: repository)
        case .explore: ExplorePanel(repository: repository)
        case nil: DetailsPanel(repository: repository)
        }
    }

    @ViewBuilder
    private var center: some View {
        switch repository.phase {
        case .ready:
            if repository.screen == .conflicts {
                ConflictEditor(repository: repository)
            } else if case .stash = repository.screen {
                StashView(repository: repository)
            } else if repository.screen == .explore {
                ExploreView(repository: repository)
            } else if repository.review != nil {
                ReviewView(repository: repository)
            } else {
                VStack(spacing: 0) {
                    if repository.showsPublishBanner, repository.remotes.isEmpty {
                        PublishBanner(repository: repository, window: window)
                            .transition(.opacity)
                    }
                    HistoryView(repository: repository, isFocused: window.isFocused) {
                        if window.isFocused { window.showsDrawer = true }
                        // A narrow window opens the panel over the graph when a row is picked.
                        if tier >= .panelOverlay, !window.isFocused { window.overlayPanelOpen = true }
                    }
                }
            }
        case .waiting, .opening, .light, .loading:
            VStack(spacing: 10) {
                ProgressView().controlSize(.regular)
                Text("Loading \(repository.name)…")
                    .font(.system(size: 13))
                    .foregroundStyle(K.label2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(K.content)
        case .notRepository:
            NotRepositoryView(repository: repository, window: window)
        case .missing:
            // WindowRepoSidebar's 폴더 없음: Locate… points the tab at the folder's new place.
            MissingFolderView(repository: repository, removeTitle: switching == .tabs ? "Close Tab" : "Remove from Sidebar") {
                closeTab()
            }
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
/// `.mstate`: a repository whose folder isn't where it was — Locate… / Remove (or Try Again when
/// the disk comes back).
private struct MissingFolderView: View {
    let repository: RepositoryModel
    let removeTitle: String
    let remove: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Icon(Icons.folderQuestion, size: 30)
                .foregroundStyle(K.label2)
                .frame(width: 68, height: 68)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(K.chip2))
            Text("\(repository.name) isn’t where it used to be")
                .font(.system(size: 17, weight: .bold))
                .padding(.top, 8)
            Text("Kaern can’t find \(Formatters.abbreviatedPath(repository.path)). It may have been moved, renamed or deleted. Your other repositories are fine.")
                .font(.system(size: 13))
                .lineSpacing(2)
                .foregroundStyle(K.label2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 8) {
                PrimaryButton(title: "Locate…", height: 26, fontSize: 12.5) { locate() }
                SheetActionButton(title: removeTitle, action: remove)
                SheetActionButton(title: "Try Again") { AppModel.shared.retry(repository) }
            }
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(K.content)
    }

    private func locate() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use This Folder"
        panel.message = "Where is \(repository.name) now? Choose its folder."
        panel.directoryURL = URL(filePath: (repository.path as NSString).deletingLastPathComponent, directoryHint: .isDirectory)
        let path = repository.path
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                guard await AppModel.shared.relocate(path, to: url) == nil else { return }
                let alert = NSAlert()
                alert.messageText = "\(url.lastPathComponent) isn’t a repository’s own folder"
                alert.informativeText = "Choose the folder that has .git in it. A folder inside another repository would open that repository instead."
                if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) { _ in } } else { alert.runModal() }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }
}

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
