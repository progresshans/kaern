import AppKit
import KaernKit
import SwiftUI

/// Full-width toolbar · sidebar | history (or diff) | inspector · status bar.
struct RepositoryWindow: View {
    @State private var model: RepositoryModel
    let onSwitchRepository: (URL) -> Void

    @AppStorage(PreferenceKey.showAuthor) private var showAuthor = true
    @AppStorage(PreferenceKey.watchFileChanges) private var watchFileChanges = true
    @Environment(\.undoManager) private var undoManager
    /// Each window keeps its own pane widths; a new window starts from the last ones dragged.
    @SceneStorage("sidebarWidth") private var windowSidebarWidth: Double?
    @SceneStorage("inspectorWidth") private var windowInspectorWidth: Double?
    @AppStorage(PreferenceKey.sidebarWidth) private var lastSidebarWidth = LayoutMetrics.defaultSidebarWidth
    @AppStorage(PreferenceKey.inspectorWidth) private var lastInspectorWidth = LayoutMetrics.defaultInspectorWidth

    private var sidebarWidth: Binding<Double> {
        Binding(
            get: { windowSidebarWidth ?? lastSidebarWidth },
            set: { windowSidebarWidth = $0; lastSidebarWidth = $0 }
        )
    }

    private var inspectorWidth: Binding<Double> {
        Binding(
            get: { windowInspectorWidth ?? lastInspectorWidth },
            set: { windowInspectorWidth = $0; lastInspectorWidth = $0 }
        )
    }

    /// Settings › General › Tabs: the strip of repository tabs under the bar.
    let tabStrip: AnyView?

    init(url: URL, tabStrip: AnyView? = nil, onSwitchRepository: @escaping (URL) -> Void) {
        _model = State(initialValue: RepositoryModel(url: url))
        self.tabStrip = tabStrip
        self.onSwitchRepository = onSwitchRepository
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: RepositoryTitleBar.height)
            if let tabStrip { tabStrip }
            content
        }
        // On top of everything: the sidebar's and inspector's lists reach up under the title
        // bar, and the bar has to cover them to be a band of its own.
        .overlay(alignment: .top) {
            RepositoryTitleBar(model: model, onSwitchRepository: onSwitchRepository)
        }
        .ignoresSafeArea(edges: .top)
        .background(TitleBarConfigurator())
            .overlay(alignment: .top) {
                if model.quickSwitcherQuery != nil {
                    ZStack(alignment: .top) {
                        // A click outside closes it.
                        Color.black.opacity(0.001)
                            .onTapGesture { model.quickSwitcherQuery = nil }
                        QuickSwitcher(model: model, onSwitchRepository: onSwitchRepository)
                            .padding(.top, RepositoryTitleBar.height + 12)
                    }
                }
            }
            .frame(minWidth: 800, minHeight: 500)
            .navigationTitle(model.displayName)

            .focusedSceneValue(\.repositoryModel, model)
            .onAppear {
                model.undoManager = undoManager
                // Take the remembered widths now, so dragging in another window doesn't move these panes.
                if windowSidebarWidth == nil { windowSidebarWidth = lastSidebarWidth }
                if windowInspectorWidth == nil { windowInspectorWidth = lastInspectorWidth }
            }
            .task {
                model.undoManager = undoManager
                #if DEBUG
                DebugDriver.shared.register(model)
                #endif
                await model.load()
            }
            .onDisappear { model.close() }
            .onChange(of: watchFileChanges) { _, enabled in model.setWatching(enabled) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                // Without the file watcher, catch up on what changed while Kaern was in the background.
                if !watchFileChanges { model.scheduleRefresh(.refs) }
            }
            .alert(
                model.alert?.title ?? "",
                isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
                presenting: model.alert
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
            .confirmationDialog(
                model.confirmation.map { model.text(for: $0).title } ?? "",
                isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } }),
                presenting: model.confirmation
            ) { confirmation in
                let text = model.text(for: confirmation)
                Button(text.action, role: text.isDestructive ? .destructive : nil) {
                    Task { await model.performConfirmed(confirmation) }
                }
                Button("Cancel", role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
            } message: { confirmation in
                Text(model.text(for: confirmation).message)
            }
            .sheet(item: $model.sheet) { sheet in
                RepositorySheetView(sheet: sheet, model: model)
            }
            .alert(
                model.remoteProblem.map(RemoteProblemText.title) ?? "",
                isPresented: Binding(get: { model.remoteProblem != nil }, set: { if !$0 { model.remoteProblem = nil } }),
                presenting: model.remoteProblem
            ) { problem in
                RemoteProblemButtons(problem: problem, model: model)
            } message: { problem in
                Text(RemoteProblemText.message(problem))
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Open Repository", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case .ready:
            mainLayout
        }
    }

    private var mainLayout: some View {
        VStack(spacing: 0) {
            OperationBar(model: model)
            RepositoryNoticeBar(model: model)
            GraphFilterBar(model: model)
            GeometryReader { proxy in
                let metrics = LayoutMetrics(
                    width: Double(proxy.size.width),
                    showSidebar: model.showSidebar,
                    showInspector: model.showInspector,
                    sidebarWidth: sidebarWidth.wrappedValue,
                    inspectorWidth: inspectorWidth.wrappedValue
                )
                HStack(spacing: 0) {
                    if model.showSidebar {
                        SidebarView(model: model)
                            .frame(width: CGFloat(metrics.sidebarWidth))
                        PaneDivider(
                            width: sidebarWidth,
                            range: metrics.sidebarRange,
                            growsTowardTrailing: true,
                            onCollapse: { withAnimation(.snappy(duration: 0.2)) { model.showSidebar = false } },
                            onDoubleClick: {
                                let fitting = SidebarView.fittingWidth(for: model)
                                withAnimation(.snappy(duration: 0.2)) {
                                    sidebarWidth.wrappedValue = LayoutMetrics.clamp(fitting, to: metrics.sidebarRange)
                                }
                            }
                        )
                    }
                    CenterPane(model: model, showsAuthor: showAuthor, showsCommitColumn: metrics.showsCommitColumn)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.showInspector && metrics.fitsInspector {
                        PaneDivider(
                            width: inspectorWidth,
                            range: metrics.inspectorRange,
                            growsTowardTrailing: false,
                            onCollapse: { withAnimation(.snappy(duration: 0.2)) { model.showInspector = false } },
                            onDoubleClick: {
                                withAnimation(.snappy(duration: 0.2)) { inspectorWidth.wrappedValue = LayoutMetrics.defaultInspectorWidth }
                            }
                        )
                        InspectorView(model: model)
                            .frame(width: CGFloat(metrics.inspectorWidth))
                    }
                }
                .overlay(alignment: .trailing) {
                    if !metrics.fitsInspector && model.showInspectorOverlay {
                        InspectorView(model: model)
                            .frame(width: 320)
                            .background(Color(Palette.inspectorBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.18), radius: 16, y: 4)
                            .padding(8)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                            .onExitCommand { model.showInspectorOverlay = false }
                    }
                }
                .onChange(of: metrics.fitsInspector, initial: true) { _, fits in
                    model.isInspectorCompact = !fits
                    if fits { model.showInspectorOverlay = false }
                }
                .onChange(of: Double(proxy.size.width) < LayoutMetrics.compactSearchWidth, initial: true) { _, compact in
                    model.isSearchCompact = compact
                }
                .onChange(of: Double(proxy.size.width) < LayoutMetrics.compactToolbarWidth, initial: true) { _, compact in
                    model.isToolbarCompact = compact
                }
            }
            StatusBar(model: model)
        }
    }
}

/// The column rules live in KaernKit (`PaneLayout`), where they're tested.
typealias LayoutMetrics = PaneLayout

extension PaneLayout {
    /// Below this window width Stash moves into the toolbar's » menu (the second collapse step).
    static let compactToolbarWidth: Double = 1000
}

/// History table, or the diff of the selected file with a way back.
struct CenterPane: View {
    let model: RepositoryModel
    let showsAuthor: Bool
    let showsCommitColumn: Bool

    var body: some View {
        ZStack {
            HistoryTable(
                model: model,
                input: HistoryTable.Input(
                    historyVersion: model.historyVersion,
                    searchVersion: model.searchVersion,
                    selection: model.selection,
                    status: model.status,
                    operation: model.operation,
                    showsAuthor: showsAuthor,
                    showsCommitColumn: showsCommitColumn,
                    isVisible: model.selectedFile == nil && model.fileHistory == nil && model.stashView == nil && model.pullRequests == nil,
                    focusRequest: model.historyFocusRequest,
                    signatureVersion: model.signatureVersion,
                    comparisonBase: model.comparisonBase,
                    avatarVersion: AvatarStore.shared.version
                )
            )
            if let pullRequests = model.pullRequests {
                PullRequestsView(model: model, state: pullRequests)
            } else if let stashView = model.stashView {
                StashView(model: model, state: stashView)
            } else if let fileHistory = model.fileHistory {
                FileHistoryView(model: model, state: fileHistory)
            } else if case .working(let path) = model.selectedFile,
               model.status.entries.first(where: { $0.path == path })?.isConflicted == true {
                ConflictEditorView(model: model, path: path)
                    .id(path)
            } else if model.selectedFile != nil {
                DiffView(model: model)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }
}

/// A 1pt separator with a wider invisible handle: drag to resize the pane next to it, drag
/// past its minimum to hide it (like Finder's sidebar), double-click for its natural width.
struct PaneDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// `true` when dragging toward the trailing edge makes the pane wider (the sidebar).
    let growsTowardTrailing: Bool
    var onCollapse: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    @State private var startWidth: Double?
    @State private var didCollapse = false

    /// At a limit the pointer only shows the direction that still works.
    private var directions: HorizontalDirection.Set {
        let atMinimum = width <= range.lowerBound + 0.5
        let atMaximum = width >= range.upperBound - 0.5
        if atMinimum && atMaximum { return .all }
        if atMinimum { return growsTowardTrailing ? .trailing : .leading }
        if atMaximum { return growsTowardTrailing ? .leading : .trailing }
        return .all
    }

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize(directions: directions))
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                guard !didCollapse else { return }
                                let start = startWidth ?? width
                                startWidth = start
                                let delta = growsTowardTrailing ? value.translation.width : -value.translation.width
                                switch PaneLayout.drag(from: start, by: delta, in: range) {
                                case .width(let newWidth):
                                    width = newWidth
                                case .collapse:
                                    didCollapse = true
                                    // Showing the pane again brings back the width it had before this drag.
                                    width = start
                                    onCollapse()
                                }
                            }
                            .onEnded { _ in
                                startWidth = nil
                                didCollapse = false
                            }
                    )
                    .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleClick() })
                    .accessibilityElement()
                    .accessibilityLabel(growsTowardTrailing ? "Sidebar Width" : "Inspector Width")
                    .accessibilityValue("\(Int(width)) points")
                    .accessibilityAdjustableAction { direction in
                        width = PaneLayout.clamp(width + (direction == .increment ? 20 : -20), to: range)
                    }
            }
            .zIndex(1)
    }
}
