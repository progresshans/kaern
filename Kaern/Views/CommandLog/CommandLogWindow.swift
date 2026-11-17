import AppKit
import KaernKit
import SwiftUI

/// Window › Command Log (⇧⌘L): one window for every repository.
@MainActor
final class CommandLogWindowController: NSWindowController, NSWindowDelegate {
    static let shared = CommandLogWindowController()
    private let state = CommandLogState()
    private var lights: TrafficLights?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Command Log"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 420)
        window.backgroundColor = NSColor(name: nil) { $0.isDark ? K.hex(0x323232) : K.hex(0xececec) }
        let hosting = KaernHostingView(rootView: CommandLogView(log: CommandLog.shared, state: state))
        hosting.sizingOptions = []
        window.contentView = hosting
        super.init(window: window)
        window.delegate = self
        // The traffic lights sit in the 52 pt bar.
        lights = TrafficLights(window: window, centerFromTop: 26)
        hosting.onLayout = { [weak self] in self?.lights?.apply() }
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    #if DEBUG
    var debugState: CommandLogState { state }
    #endif

    /// Shows the window; `repository` is the folder of the tab it was opened from (the second
    /// scope button).
    func show(repository: String?) {
        if let repository { state.repositoryPath = repository }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The window's filters and selection.
@MainActor @Observable
final class CommandLogState {
    enum Filter: String, CaseIterable { case all, failed, changes, network }

    var filter: Filter = .all
    var onlyRepository = false
    var repositoryPath: String?
    var showsBackground = false
    var query = ""
    var selection: UUID?
    var toast: String?

    var repositoryName: String? { repositoryPath.map { ($0 as NSString).lastPathComponent } }
}

/// ScreenCommandLog: the commands (Time · Repository · Command · Took · Result) and the
/// selected one's details: the command as it can be typed, why it ran, its exit code and output.
struct CommandLogView: View {
    let log: CommandLog
    @Bindable var state: CommandLogState

    var body: some View {
        let today = log.entries.filter { Calendar.current.isDateInToday($0.record.started) }
        // The repository's folder or one inside it: "kaern-site" next to "kaern" isn't.
        let root = state.repositoryPath.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        let scoped = today.filter { entry in
            guard state.onlyRepository else { return true }
            guard let root else { return false }
            return entry.record.directory == root || entry.record.directory.hasPrefix(root + "/")
        }
        let shown = Array(scoped.filter(matches).reversed())
        let hiddenBackground = state.showsBackground ? 0 : scoped.filter { Self.isQuiet($0) && matchesIgnoringBackground($0) }.count
        let selected = shown.first { $0.id == state.selection } ?? shown.first
        VStack(spacing: 0) {
            CommandLogBar(state: state)
            HStack(spacing: 0) {
                CommandList(entries: shown, selection: selected?.id, hiddenBackground: hiddenBackground, state: state,
                            emptyText: state.query.isEmpty ? "Nothing here yet" : "No command matches “\(state.query)”")
                    .frame(maxWidth: .infinity)
                K.sep.frame(width: 1)
                CommandDetail(entry: selected, log: log, state: state)
                    .frame(width: 600)
            }
            .background(K.content)
            HStack {
                Text("Showing \(shown.count) of \(state.showsBackground ? scoped.count : scoped.filter { !Self.isQuiet($0) }.count) commands today · Kaern hides tokens and passwords in this log")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(K.label2)
            .padding(.horizontal, 14)
            .frame(height: KMetric.statusBar)
            .background { ZStack(alignment: .top) { K.win; K.sep.frame(height: 1) } }
        }
        .overlay(alignment: .bottom) {
            if let toast = state.toast {
                CommandLogToast(text: toast).padding(.bottom, 44)
            }
        }
        .ignoresSafeArea()
        .frame(minWidth: 860, minHeight: 420)
        .background(K.win)
    }

    /// Background work, and the reads an action makes along the way (rev-parse, ls-files…),
    /// are hidden until Show Background; a read that failed or still runs stays in the list.
    static func isQuiet(_ entry: CommandLog.Entry) -> Bool {
        let record = entry.record
        // A background network command that failed (auto-fetch) stays in the list.
        if entry.isBackground { return !(record.failed && !record.wasStopped && record.kinds.contains(.network)) }
        return record.kinds.isEmpty && !record.failed && !record.isRunning
    }

    private func matchesIgnoringBackground(_ entry: CommandLog.Entry) -> Bool {
        let record = entry.record
        switch state.filter {
        case .all: break
        case .failed: guard record.failed, !record.wasStopped else { return false }
        case .changes: guard record.kinds.contains(.changes) else { return false }
        case .network: guard record.kinds.contains(.network) else { return false }
        }
        let query = state.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        let haystack = record.commandLine + " " + entry.repository + " " + (record.trigger?.action ?? "")
        return haystack.localizedCaseInsensitiveContains(query)
    }

    private func matches(_ entry: CommandLog.Entry) -> Bool {
        if Self.isQuiet(entry), !state.showsBackground { return false }
        return matchesIgnoringBackground(entry)
    }
}

/// `.clbar`: title, repository scope, filters, background toggle, search.
private struct CommandLogBar: View {
    @Bindable var state: CommandLogState

    var body: some View {
        HStack(spacing: 10) {
            Text("Command Log")
                .font(.system(size: 13, weight: .bold))
                .padding(.trailing, 8)
            SegmentedChoice(options: [(false, "All Repositories"), (true, state.repositoryName ?? "This Repository")],
                            selection: $state.onlyRepository, label: "Repositories")
                .disabled(state.repositoryPath == nil)
            SegmentedChoice(options: [(CommandLogState.Filter.all, "All"), (.failed, "Failed"), (.changes, "Changes"), (.network, "Network")],
                            selection: $state.filter, label: "Show")
            Spacer(minLength: 8)
            GhostButton(title: state.showsBackground ? "Hide Background" : "Show Background") { state.showsBackground.toggle() }
            HStack(spacing: 6) {
                Icon(Icons.search(1.4), size: 12).foregroundStyle(K.label2)
                TextField("Search commands, repositories, actions", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !state.query.isEmpty {
                    Button { state.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(K.label3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .frame(width: 300, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(K.field)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5)))
        }
        .padding(.leading, 82)
        .padding(.trailing, 14)
        .frame(height: 52)
        .background {
            ZStack(alignment: .bottom) { K.win; K.sep.frame(height: 1) }
                .windowDragArea()
        }
    }
}

/// `.cllist`: the header and the rows, newest first.
private struct CommandList: View {
    let entries: [CommandLog.Entry]
    let selection: UUID?
    let hiddenBackground: Int
    let state: CommandLogState
    let emptyText: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Time").frame(width: 70, alignment: .leading)
                Text("Repository").frame(width: 150, alignment: .leading)
                Text("Command").frame(maxWidth: .infinity, alignment: .leading)
                Text("Took").frame(width: 64, alignment: .trailing)
                Text("Result").frame(width: 74, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(K.label2)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        CommandRow(entry: entry, isAlternate: index % 2 == 1, isSelected: entry.id == selection)
                            .onTapGesture { state.selection = entry.id }
                    }
                    if entries.isEmpty {
                        Text(emptyText).font(.system(size: 13)).foregroundStyle(K.label2).padding(.vertical, 40)
                    }
                    if hiddenBackground > 0 {
                        HStack(spacing: 8) {
                            Text("\(hiddenBackground) background \(hiddenBackground == 1 ? "command" : "commands") hidden — git status, for-each-ref, rev-parse and other reads run whenever files change")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Show") { state.showsBackground = true }
                                .buttonStyle(.plain)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(K.accentText)
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(K.label2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(K.hover))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }
}

/// `.clrow`: one command.
private struct CommandRow: View {
    let entry: CommandLog.Entry
    let isAlternate: Bool
    let isSelected: Bool

    var body: some View {
        let record = entry.record
        let failed = record.failed && !record.wasStopped
        HStack(spacing: 0) {
            Text(Self.time.string(from: record.started))
                .monospacedDigit()
                .foregroundStyle(isSelected ? .white.opacity(0.8) : K.label2)
                .frame(width: 70, alignment: .leading)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2.5).fill(RepositoryDot.color(entry.repository)).frame(width: 8, height: 8)
                Text(entry.repository).lineLimit(1).truncationMode(.tail)
            }
            .frame(width: 150, alignment: .leading)
            Text(record.commandLine)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(isSelected ? .white : failed ? K.err : (entry.isBackground ? K.label2 : K.label))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Took(record: record, selected: isSelected)
                .frame(width: 64, alignment: .trailing)
            ResultMark(record: record, selected: isSelected)
                .frame(width: 74, alignment: .trailing)
        }
        .font(.system(size: 13))
        .foregroundStyle(isSelected ? .white : (entry.isBackground ? K.label2 : K.label))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(isSelected ? K.sel : isAlternate ? K.alt : K.content)
        .contentShape(Rectangle())
    }

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// How long a command took ("61 ms", "2.1 s"), or how long it has run ("0:42").
private struct Took: View {
    let record: GitCommandRecord
    let selected: Bool

    var body: some View {
        Group {
            if record.isRunning {
                TimelineView(.periodic(from: record.started, by: 0.5)) { context in
                    Text(Self.elapsed(context.date.timeIntervalSince(record.started)))
                }
            } else {
                Text(record.duration.map(Self.format) ?? "—")
            }
        }
        .monospacedDigit()
        .foregroundStyle(selected ? .white.opacity(0.8) : K.label2)
    }

    static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        if seconds < 1 { return "\(max(1, Int((seconds * 1000).rounded()))) ms" }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        return elapsed(seconds)
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}

/// `.cls`: ✓, "exit 128", "stopped" or a spinner.
private struct ResultMark: View {
    let record: GitCommandRecord
    let selected: Bool

    var body: some View {
        if record.isRunning {
            Spinner(size: 12, lineWidth: 1.7)
        } else if record.wasStopped {
            Text("stopped").font(.system(size: 11, weight: .bold)).foregroundStyle(selected ? .white : K.label2)
        } else if record.failed {
            Text("exit \(record.status ?? 0)").font(.system(size: 11, weight: .bold)).foregroundStyle(selected ? .white : K.err)
        } else {
            Icon(Icons.checkSmall, size: 12).foregroundStyle(selected ? .white : K.ok)
        }
    }
}

/// `.cldet`: the selected command.
private struct CommandDetail: View {
    let entry: CommandLog.Entry?
    let log: CommandLog
    let state: CommandLogState

    var body: some View {
        ScrollView {
            if let entry {
                let record = entry.record
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        if record.isRunning {
                            Spinner(size: 12, lineWidth: 1.7)
                        } else if record.failed, !record.wasStopped {
                            Icon(Icons.error, size: 13).foregroundStyle(K.err)
                        } else {
                            Icon(Icons.checkSmall, size: 12).foregroundStyle(record.wasStopped ? K.label2 : K.ok)
                        }
                        title(record).font(.system(size: 13, weight: .bold))
                        Spacer(minLength: 0)
                        if record.isRunning, log.canStop(record.id) {
                            GhostButton(title: "Stop") { log.stop(record.id) }
                        }
                    }
                    CommandText(arguments: record.arguments)
                        .padding(.top, 10)
                    HStack(spacing: 6) {
                        GhostButton(title: "Copy Command") { copy(record.commandLine, "Copied the command") }
                        GhostButton(title: "Open in Terminal") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(record.commandLine, forType: .string)
                            TabBar.openInTerminal(record.directory)
                            flash("Opened Terminal in \(Formatters.abbreviatedPath(record.directory)) · the command is on the clipboard")
                        }
                        .disabled(record.directory.isEmpty)
                    }
                    .padding(.top, 8)
                    if record.failed, !record.wasStopped,
                       let failure = GitFailure.explain(arguments: record.arguments, errorOutput: record.errorOutput, output: record.output, status: record.status) {
                        WhyBox(help: FailureHelp.make(failure, repositoryPath: record.directory, repositoryName: entry.repository,
                                                      auto: record.trigger?.action.hasPrefix("Auto-fetch") == true))
                            .padding(.top, 14)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        meta("Repository", entry.repository + " · " + Formatters.abbreviatedPath(record.directory))
                        meta("Started", "Today at " + CommandRow.time.string(from: record.started))
                        meta("Triggered by", record.trigger.map { $0.action + ($0.isBackground ? " (background)" : "") } ?? "Kaern (background)")
                        meta("Exit code", record.status.map { String($0) + (record.wasStopped ? " · stopped" : "") } ?? "—")
                        meta("Git", AppModel.shared.git.map { ($0.version ?? "?") + " · " + $0.url.path(percentEncoded: false) } ?? "—")
                        meta("Environment", "GIT_TERMINAL_PROMPT=0 · GIT_OPTIONAL_LOCKS=0 · LC_ALL=en_US.UTF-8 · GIT_EDITOR=true")
                        if record.hasInput { meta("Input", "Sent on standard input (a message or a patch), not kept") }
                    }
                    .padding(.top, 14)
                    let progress = entry.progress.suffix(4).joined(separator: "\n")
                    if !record.errorOutput.isEmpty || (record.isRunning && !progress.isEmpty) {
                        heading(record.failed ? "Error output" : record.isRunning ? "Progress" : "Messages")
                        OutputBox(text: record.isRunning ? progress : record.errorOutput, isError: record.failed && !record.wasStopped)
                    }
                    if !record.output.isEmpty {
                        heading("Output")
                        OutputBox(text: record.output + (record.isOutputCut ? "\n…" : ""), isError: false)
                    }
                    if !record.output.isEmpty || !record.errorOutput.isEmpty {
                        Button("Copy Output") { copy(record.output + record.errorOutput, "Copied the output") }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(K.accentText)
                            .padding(.top, 8)
                    }
                }
                .padding(EdgeInsets(top: 16, leading: 18, bottom: 18, trailing: 18))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(K.inspector)
    }

    private func title(_ record: GitCommandRecord) -> some View {
        Group {
            if record.isRunning {
                TimelineView(.periodic(from: record.started, by: 0.5)) { context in
                    Text("Running for " + Took.elapsed(context.date.timeIntervalSince(record.started)))
                }
            } else if record.wasStopped {
                Text("Stopped after " + (record.duration.map(Took.format) ?? "—"))
            } else if record.failed {
                Text("Failed with exit code \(record.status ?? 0)")
            } else {
                Text("Finished in " + (record.duration.map(Took.format) ?? "—"))
            }
        }
    }

    private func meta(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key).foregroundStyle(K.label2).frame(width: 92, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
        .lineSpacing(2)
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(KFont.weighted(11.5, 0.35))
            .foregroundStyle(K.label2)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }

    private func copy(_ text: String, _ message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash(message)
    }

    private func flash(_ message: String) {
        state.toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            if state.toast == message { state.toast = nil }
        }
    }
}

/// `.why`: what went wrong in one sentence, and the button that fixes it.
private struct WhyBox: View {
    let help: FailureHelp

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(help.message)
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .foregroundStyle(K.label)
                .fixedSize(horizontal: false, vertical: true)
            if let title = help.fixTitle, let fix = help.fix {
                PrimaryButton(title: title, height: 24, fontSize: 12, action: fix)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(K.err.opacity(0.09))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(K.err.opacity(0.18), lineWidth: 0.5)))
    }
}

/// `.clcmd`: the command with git in bold, the subcommand in the accent color, options in
/// purple and quoted values in green.
private struct CommandText: View {
    let arguments: [String]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(attributed)
            .font(.system(size: 12, design: .monospaced))
            .lineSpacing(6)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(K.field)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5)))
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        var git = AttributedString("git")
        git.font = .system(size: 12, weight: .bold, design: .monospaced)
        result += git
        let subcommand = GitRunnerArguments.subcommandIndex(arguments)
        for (index, argument) in arguments.enumerated() {
            var part = AttributedString(" " + GitCommandRecord.shellQuoted(argument))
            if index == subcommand || (subcommand.map { index == $0 + 1 && arguments[$0] == "lfs" } ?? false) {
                part.foregroundColor = K.accentText
                part.font = .system(size: 12, weight: .semibold, design: .monospaced)
            } else if argument.hasPrefix("-") {
                part.foregroundColor = Color(nsColor: scheme == .dark ? K.hex(0xc39bff) : K.hex(0x8a4fd6))
            } else if argument.contains(" ") || argument.contains("\"") {
                part.foregroundColor = K.add
            }
            result += part
        }
        return result
    }
}

/// Where the subcommand is in a command's arguments (after `-c key=value` options).
enum GitRunnerArguments {
    static func subcommandIndex(_ arguments: [String]) -> Int? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-c" || argument == "-C" { index += 2 } else if argument.hasPrefix("-") { index += 1 } else { return index }
        }
        return nil
    }
}

/// `.clout`: output in a field.
private struct OutputBox: View {
    let text: String
    let isError: Bool

    /// What a terminal would show: of the progress updates git separates with `\r`, the last.
    static func terminalText(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.split(separator: "\r", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        }
        .joined(separator: "\n")
    }

    var body: some View {
        Text(Self.terminalText(text).trimmingCharacters(in: .newlines))
            .font(.system(size: 11.5, design: .monospaced))
            .lineSpacing(5)
            .foregroundStyle(isError ? K.del : K.label)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(K.field)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5)))
    }
}

private struct CommandLogToast: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(scheme == .dark ? Color(nsColor: K.hex(0x1d1d1f)) : .white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(scheme == .dark ? Color(.sRGB, red: 236 / 255, green: 236 / 255, blue: 240 / 255, opacity: 0.95)
                                      : Color(.sRGB, red: 30 / 255, green: 30 / 255, blue: 32 / 255, opacity: 0.92))
                .shadow(color: .black.opacity(0.25), radius: 15, y: 10))
            .fixedSize()
    }
}

/// A repository's color dot in the log (stable per name).
enum RepositoryDot {
    private static let colors: [UInt32] = [0x0a84ff, 0xff453a, 0x30b45a, 0xa35bd6, 0xff9f0a, 0x30b0c7, 0xd6336c, 0x8e8e93]

    static func color(_ name: String) -> Color {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Color(nsColor: K.hex(colors[Int(hash % UInt32(colors.count))]))
    }
}
