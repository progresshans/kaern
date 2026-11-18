import SwiftUI

/// The start window's content (the Welcome board, WelcomeWindowController): the app, the last
/// session to reopen, actions, and recent repositories grouped by the folder group they were last
/// in. What opens here goes into `window`, the model the start window holds until it becomes a
/// main window.
struct WelcomeView: View {
    let window: WindowModel
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.onLaunch, store: .kaern) private var onLaunch = LaunchBehavior.reopen
    @State private var filter = ""

    var body: some View {
        HStack(spacing: 0) {
            leftColumn
                .frame(width: z(352))
            recentColumn
        }
        .background(K.content)
    }

    // MARK: Left

    private var leftColumn: some View {
        VStack(spacing: 0) {
            // Under the traffic lights, as on the board (their 12 pt row, then 26 pt).
            AppMark()
                .padding(.top, z(38))
            Text("Kaern")
                .font(.system(size: z(26), weight: .bold))
                .padding(.top, z(16))
            Text(versionText)
                .font(.system(size: z(12)))
                .foregroundStyle(K.label2)
                .padding(.top, z(2))
            if let closed = app.lastClosed {
                lastSession(closed)
                    .padding(.top, z(20))
            }
            VStack(spacing: z(7)) {
                WelcomeAction(title: "Open Repository…", shortcut: "⌘O", symbol: "folder") {
                    app.showOpenPanel(for: window)
                }
                WelcomeAction(title: "Clone Repository…", shortcut: "⇧⌘C", symbol: "arrow.down.circle") {
                    app.showClone(in: window)
                }
                WelcomeAction(title: "Create New Repository…", shortcut: "⌥⌘N", symbol: "plus.square") {
                    app.showCreate(in: window)
                }
            }
            .padding(.top, z(14))
            Spacer(minLength: 0)
            // The board's checkbox, as Settings › General › On launch: on, last time's repositories
            // open by themselves; off, they wait here behind Reopen.
            Toggle(isOn: reopensAtLaunch) {
                Text(AppSettings.repositorySwitching == .tabs ? "Reopen last time’s tabs at launch" : "Reopen last time’s repositories at launch")
                    .font(.system(size: z(12)))
                    .foregroundStyle(K.label2)
            }
            .toggleStyle(.checkbox)
        }
        .padding(EdgeInsets(top: z(16), leading: z(26), bottom: z(18), trailing: z(26)))
    }

    private func lastSession(_ closed: Session.ClosedWindow) -> some View {
        let tabs = closed.window.tabs
        let groups = closed.window.groups
        let loose = tabs.filter { $0.group == nil }.count
        return VStack(alignment: .leading, spacing: z(9)) {
            HStack(alignment: .firstTextBaseline, spacing: z(8)) {
                Text("Last session").font(KFont.body650)
                Spacer()
                Text("Closed \(Formatters.closedAt(closed.date))")
                    .font(.system(size: z(11.5)))
                    .foregroundStyle(K.label2)
            }
            FlowChips(items: groups.map { group in
                (group.color.color, "\(group.name) \(tabs.filter { $0.group == group.id }.count)")
            } + (loose > 0 ? [(nil, groups.isEmpty ? Formatters.count(loose, "tab", "tabs") : "+\(loose) more")] : []))
            Button {
                app.reopenLastSession(in: window)
            } label: {
                Text(AppSettings.repositorySwitching == .tabs ? (tabs.count == 1 ? "Reopen 1 Tab" : "Reopen \(tabs.count) Tabs")
                     : (tabs.count == 1 ? "Reopen 1 Repository" : "Reopen \(tabs.count) Repositories"))
                    .font(.system(size: z(13), weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: z(30))
                    .background(RoundedRectangle(cornerRadius: z(8), style: .continuous).fill(K.accent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(EdgeInsets(top: z(12), leading: z(14), bottom: z(12), trailing: z(12)))
        .background(RoundedRectangle(cornerRadius: z(12), style: .continuous).fill(K.accentSoft))
    }

    /// "Version 1.1.0", or "Version 1.1.0-beta.2". The build number is made from the version (script/release.sh), so it
    /// would add only a long number here; Kaern › About Kaern still shows it.
    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Version \(version)"
    }

    private var reopensAtLaunch: Binding<Bool> {
        Binding(get: { onLaunch == .reopen }, set: { onLaunch = $0 ? .reopen : .welcome })
    }

    // MARK: Recent

    private var recentColumn: some View {
        let items = app.recent.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.path.localizedCaseInsensitiveContains(filter) }
        let grouped = Dictionary(grouping: items) { $0.groupName ?? "" }
        let order = items.reduce(into: [String]()) { names, item in
            let key = item.groupName ?? ""
            if !names.contains(key) { names.append(key) }
        }.sorted { a, b in a.isEmpty ? false : (b.isEmpty ? true : false) }
        return VStack(spacing: 0) {
            HStack(spacing: z(10)) {
                Text("Recent Repositories").font(KFont.body650)
                Spacer()
                HStack(spacing: z(6)) {
                    Icon(Icons.search(1.4), size: 12).foregroundStyle(K.label2)
                    TextField("Filter", text: $filter)
                        .textFieldStyle(.plain)
                        .font(.system(size: z(12)))
                }
                .padding(.horizontal, z(8))
                .frame(width: z(170), height: z(26))
                .background(RoundedRectangle(cornerRadius: z(7), style: .continuous).fill(K.hover))
            }
            .padding(EdgeInsets(top: z(16), leading: z(18), bottom: z(8), trailing: z(16)))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(order, id: \.self) { key in
                        let members = grouped[key] ?? []
                        HStack(spacing: z(7)) {
                            if let color = members.first?.groupColor {
                                Circle().fill(color.color).frame(width: z(8), height: z(8))
                            }
                            Text(key.isEmpty ? "Other" : key)
                            Spacer()
                            Text("\(members.count)").fontWeight(.medium)
                        }
                        .font(KFont.weighted(11.5, 0.35))
                        .foregroundStyle(K.label2)
                        .padding(.horizontal, z(8))
                        .frame(height: z(28))
                        .padding(.top, z(6))
                        ForEach(members) { item in
                            RecentRow(item: item) {
                                app.open([URL(filePath: item.path, directoryHint: .isDirectory)], in: window)
                            }
                        }
                    }
                    if app.recent.isEmpty {
                        Text("Repositories you open show up here.")
                            .font(.system(size: z(12)))
                            .foregroundStyle(K.label2)
                            .frame(maxWidth: .infinity)
                            .padding(.top, z(60))
                    } else if items.isEmpty {
                        Text("No recent repository matches “\(filter)”.")
                            .font(.system(size: z(12)))
                            .foregroundStyle(K.label2)
                            .frame(maxWidth: .infinity)
                            .padding(.top, z(40))
                    }
                }
                .padding(EdgeInsets(top: 0, leading: z(10), bottom: z(8), trailing: z(10)))
            }
            Text("Drop a folder here to open it")
                .font(.system(size: z(12)))
                .foregroundStyle(K.label2)
                .frame(maxWidth: .infinity)
                .padding(z(10))
                .overlay(
                    RoundedRectangle(cornerRadius: z(10), style: .continuous)
                        .strokeBorder(K.sepStrong, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                )
                .padding(EdgeInsets(top: z(6), leading: z(12), bottom: z(12), trailing: z(12)))
        }
        .background(K.sidebar)
        .overlay(alignment: .leading) { K.sep.frame(width: 1) }
    }
}

/// The app mark from the Welcome board (three bars).
private struct AppMark: View {
    var body: some View {
        VStack(spacing: z(5)) {
            RoundedRectangle(cornerRadius: z(6)).fill(Color(nsColor: K.hex(0x0a7cff))).frame(width: z(26), height: z(13))
            RoundedRectangle(cornerRadius: z(6)).fill(AppMark.middle).frame(width: z(46), height: z(15))
            RoundedRectangle(cornerRadius: z(6)).fill(AppMark.bottom).frame(width: z(64), height: z(17))
        }
        .accessibilityHidden(true)
    }

    static let middle = Color(nsColor: NSColor(name: nil) { $0.isDark ? K.hex(0x8e8e93) : K.hex(0x5b5b61) })
    static let bottom = Color(nsColor: NSColor(name: nil) { $0.isDark ? K.hex(0xaeaeb2) : K.hex(0x46464b) })
}

private struct WelcomeAction: View {
    let title: String
    let shortcut: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: z(10)) {
                Image(systemName: symbol).foregroundStyle(K.accent).frame(width: z(18))
                Text(title).font(.system(size: z(13), weight: .semibold)).foregroundStyle(K.label)
                Spacer()
                Text(shortcut).font(.system(size: z(12), weight: .medium)).foregroundStyle(K.label2)
            }
            .padding(.horizontal, z(12))
            .frame(height: z(36))
            .background(RoundedRectangle(cornerRadius: z(9), style: .continuous).fill(hovering && isEnabled ? K.chip2 : K.hover))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { hovering = $0 }
    }
}

private struct RecentRow: View {
    let item: Session.RecentRepository
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: z(10)) {
                Text(String(item.name.prefix(1)).uppercased())
                    .font(.system(size: z(13), weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: z(30), height: z(30))
                    .background(RoundedRectangle(cornerRadius: z(8), style: .continuous).fill(item.groupColor?.color ?? AvatarPalette.color(for: item.path)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.system(size: z(13), weight: .semibold)).foregroundStyle(K.label)
                    Text(Formatters.abbreviatedPath(item.path)).font(.system(size: z(11.5))).foregroundStyle(K.label2)
                        .truncationMode(.middle)
                }
                .lineLimit(1)
                Spacer()
                Text(Formatters.historyDate(item.lastOpened))
                    .font(.system(size: z(11.5)))
                    .foregroundStyle(K.label2)
            }
            .padding(.horizontal, z(10))
            .frame(height: z(46))
            .background(RoundedRectangle(cornerRadius: z(9), style: .continuous).fill(hovering ? K.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.path)
    }
}

/// Group chips of the last session (wrap onto more lines when needed).
private struct FlowChips: View {
    let items: [(Color?, String)]

    var body: some View {
        FlowLayout(spacing: z(5)) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: z(5)) {
                    if let color = item.0 { Circle().fill(color).frame(width: z(8), height: z(8)) }
                    Text(item.1).font(.system(size: z(11.5), weight: .semibold))
                }
                .padding(.horizontal, z(8))
                .frame(height: z(20))
                .background(Capsule().fill(K.content))
            }
        }
    }
}

/// Lays children out in rows, wrapping at the proposed width.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// + / ⌘T: recent repositories that aren't open, a filter, and Open Repository….
struct NewTabPopover: View {
    let window: WindowModel
    /// Sidebar mode's Add Repository…: Clone and Create too.
    var showsMore = false
    @Environment(AppModel.self) private var app
    @State private var filter = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    var body: some View {
        let items = app.recentNotOpen(in: window).filter {
            filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.path.localizedCaseInsensitiveContains(filter)
        }
        VStack(alignment: .leading, spacing: z(8)) {
            TextField("Filter recent repositories", text: $filter)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit {
                    if items.indices.contains(highlighted) { open(items[highlighted]) } else { openPanel() }
                }
                .onKeyPress(.downArrow) {
                    highlighted = min(highlighted + 1, max(items.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    highlighted = max(highlighted - 1, 0)
                    return .handled
                }
                .onChange(of: filter) { highlighted = 0 }
            if items.isEmpty {
                Text(app.recent.isEmpty ? "Repositories you open show up here." : "No other recent repositories.")
                    .font(.system(size: z(12)))
                    .foregroundStyle(K.label2)
                    .padding(.vertical, z(6))
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(items.prefix(40).enumerated()), id: \.element.id) { index, item in
                            Button { open(item) } label: {
                                HStack(spacing: z(8)) {
                                    if let color = item.groupColor {
                                        Circle().fill(color.color).frame(width: z(7), height: z(7))
                                    } else {
                                        Color.clear.frame(width: z(7), height: z(7))
                                    }
                                    Text(item.name).font(.system(size: z(13), weight: .semibold))
                                    Text(Formatters.abbreviatedPath(item.path))
                                        .font(.system(size: z(11.5)))
                                        .foregroundStyle(index == highlighted ? .white.opacity(0.85) : K.label2)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .lineLimit(1)
                                .foregroundStyle(index == highlighted ? .white : K.label)
                                .padding(.horizontal, z(8))
                                .frame(height: z(26))
                                .background(RoundedRectangle(cornerRadius: z(5), style: .continuous).fill(index == highlighted ? K.sel : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { if $0 { highlighted = index } }
                        }
                    }
                }
                .frame(maxHeight: z(300))
            }
            Divider()
            footerButton("Open Repository…", "⌘O") { openPanel() }
            if showsMore {
                footerButton("Clone Repository…", "⇧⌘C") {
                    window.showsNewTab = false
                    app.showClone(in: window)
                }
                footerButton("Create New Repository…", "⌥⌘N") {
                    window.showsNewTab = false
                    app.showCreate(in: window)
                }
                footerButton("Repositories Window", "⇧⌘R") {
                    window.showsNewTab = false
                    RepositoriesWindowController.shared.show()
                }
            }
        }
        .padding(z(10))
        .frame(width: z(340))
        .onAppear { focused = true }
    }

    private func footerButton(_ title: String, _ shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut).foregroundStyle(K.label2)
            }
            .font(.system(size: z(13)))
            .padding(.horizontal, z(8))
            .frame(height: z(26))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func open(_ item: Session.RecentRepository) {
        window.showsNewTab = false
        app.open([URL(filePath: item.path, directoryHint: .isDirectory)], in: window)
    }

    private func openPanel() {
        window.showsNewTab = false
        app.showOpenPanel(for: window)
    }
}
