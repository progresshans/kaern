import AppKit
import Foundation
import KaernKit

/// UserDefaults keys for Settings. Views read them with `@AppStorage`, models with `Preferences`.
enum PreferenceKey {
    static let repositorySwitcher = "repositorySwitcher"
    static let fetchAutomatically = "fetchAutomatically"
    static let fetchInterval = "fetchIntervalMinutes"
    static let pull = "pullPreference"
    static let branchSwitch = "branchSwitchPreference"
    static let defaultBranch = "defaultBranchName"
    static let editor = "openFilesIn"
    static let mergeTool = "mergeTool"
    static let showAuthor = "showAuthorColumn"
    static let gitPath = "gitExecutablePath"
    static let historyPageSize = "historyPageSize"
    static let recordCommandLog = "recordCommandLog"
    /// The last width the sidebar and inspector were dragged to; new windows start with it.
    static let sidebarWidth = "sidebarWidth"
    static let inspectorWidth = "inspectorWidth"
    /// Blame's Ignore Whitespace (`-w`) and Detect Moved Lines (`-M -C`) checkboxes.
    static let blameIgnoreWhitespace = "blameIgnoreWhitespace"
    static let blameDetectMoves = "blameDetectMoves"
    /// Settings › Advanced › SSH: let git's ssh use the agent (ssh-agent, 1Password).
    static let useSSHAgent = "useSSHAgent"
    /// Settings › Advanced › File changes: refresh as soon as files change on disk.
    static let watchFileChanges = "watchFileChanges"
    /// The diff's Ignore Whitespace toggle (`git diff -w`).
    static let diffIgnoreWhitespace = "diffIgnoreWhitespace"
    /// Settings › General › Show GitHub avatars.
    static let showAvatars = "showGitHubAvatars"
    /// Branches hidden in each repository's graph, and the one shown alone (by repository path).
    static let graphFilters = "graphFilters"
}

/// Settings › General › "Switch repositories with". Toolbar and Tabs give each repository its
/// own window (or tab); Icon Rail and Named List switch repositories inside one window.
enum RepositorySwitcher: String, CaseIterable, Identifiable {
    case toolbar
    case tabs
    case iconRail
    case namedList

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toolbar: "Toolbar"
        case .tabs: "Tabs"
        case .iconRail: "Icon Rail"
        case .namedList: "Named List"
        }
    }

    var summary: String {
        switch self {
        case .toolbar: "Opens the repository list from the toolbar. Each repository gets its own window."
        case .tabs: "Shows a tab for each repository, with a + button that opens the repository list."
        case .iconRail: "Shows a narrow rail with each repository's initials and change dot."
        case .namedList: "Shows repository names and current branches next to the sidebar."
        }
    }

    var isAvailable: Bool { true }

    /// One window holds several repositories (C and D).
    var usesRail: Bool { self == .iconRail || self == .namedList }

    /// Tabs, Icon Rail and Named List: a window switches between several repositories.
    var sharesWindow: Bool { self != .toolbar }

    static var current: RepositorySwitcher {
        RepositorySwitcher(rawValue: UserDefaults.standard.string(forKey: PreferenceKey.repositorySwitcher) ?? "") ?? .toolbar
    }
}

enum FetchInterval: Int, CaseIterable, Identifiable {
    case oneMinute = 1
    case fiveMinutes = 5
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case hour = 60

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .oneMinute: "Every Minute"
        case .fiveMinutes: "Every 5 Minutes"
        case .fifteenMinutes: "Every 15 Minutes"
        case .thirtyMinutes: "Every 30 Minutes"
        case .hour: "Every Hour"
        }
    }
}

enum PullPreference: String, CaseIterable, Identifiable {
    case gitConfig
    case merge
    case rebase
    case fastForwardOnly

    var id: String { rawValue }

    var strategy: GitRepository.PullStrategy {
        switch self {
        case .gitConfig: .gitConfig
        case .merge: .merge
        case .rebase: .rebase
        case .fastForwardOnly: .fastForwardOnly
        }
    }

    var title: String {
        switch self {
        case .gitConfig: "Use Git Configuration"
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .fastForwardOnly: "Fast-Forward Only"
        }
    }
}

enum BranchSwitchPreference: String, CaseIterable, Identifiable {
    case ask
    case stash
    case bring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Ask What to Do with Changes"
        case .stash: "Stash Changes"
        case .bring: "Bring Changes Along"
        }
    }
}

/// Apps offered in Settings › General › "Open files in".
enum EditorChoice: String, CaseIterable, Identifiable {
    case xcode = "com.apple.dt.Xcode"
    case visualStudioCode = "com.microsoft.VSCode"
    case cursor = "com.todesktop.230313mzl4w4u92"
    case zed = "dev.zed.Zed"
    case sublimeText = "com.sublimetext.4"
    case bbedit = "com.barebones.bbedit"
    case nova = "com.panic.Nova"
    case textEdit = "com.apple.TextEdit"
    case defaultApp = "default"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xcode: "Xcode"
        case .visualStudioCode: "Visual Studio Code"
        case .cursor: "Cursor"
        case .zed: "Zed"
        case .sublimeText: "Sublime Text"
        case .bbedit: "BBEdit"
        case .nova: "Nova"
        case .textEdit: "TextEdit"
        case .defaultApp: "Default App"
        }
    }

    var applicationURL: URL? {
        guard self != .defaultApp else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue)
    }

    var isInstalled: Bool { self == .defaultApp || applicationURL != nil }
}

enum MergeToolChoice: String, CaseIterable, Identifiable {
    case fileMerge = "opendiff"
    case kaleidoscope = "ksdiff"
    case visualStudioCode = "vscode"
    case gitConfig = "gitconfig"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fileMerge: "FileMerge"
        case .kaleidoscope: "Kaleidoscope"
        case .visualStudioCode: "Visual Studio Code"
        case .gitConfig: "Use Git Configuration"
        }
    }
}

/// Typed access to the defaults for non-view code.
enum Preferences {
    static let defaults: [String: Any] = [
        PreferenceKey.repositorySwitcher: RepositorySwitcher.toolbar.rawValue,
        PreferenceKey.fetchAutomatically: true,
        PreferenceKey.fetchInterval: FetchInterval.fiveMinutes.rawValue,
        PreferenceKey.pull: PullPreference.gitConfig.rawValue,
        PreferenceKey.branchSwitch: BranchSwitchPreference.ask.rawValue,
        PreferenceKey.defaultBranch: "main",
        PreferenceKey.editor: EditorChoice.xcode.rawValue,
        PreferenceKey.mergeTool: MergeToolChoice.fileMerge.rawValue,
        PreferenceKey.showAuthor: true,
        PreferenceKey.gitPath: GitRunner.defaultExecutableURL.path(percentEncoded: false),
        PreferenceKey.historyPageSize: 5000,
        PreferenceKey.recordCommandLog: true,
        PreferenceKey.blameIgnoreWhitespace: true,
        PreferenceKey.blameDetectMoves: false,
        PreferenceKey.useSSHAgent: true,
        PreferenceKey.watchFileChanges: true,
        PreferenceKey.diffIgnoreWhitespace: false,
        PreferenceKey.showAvatars: true,
    ]

    static func register() {
        UserDefaults.standard.register(defaults: defaults)
    }

    private static var store: UserDefaults { .standard }

    static var fetchAutomatically: Bool { store.bool(forKey: PreferenceKey.fetchAutomatically) }

    static var fetchInterval: FetchInterval {
        FetchInterval(rawValue: store.integer(forKey: PreferenceKey.fetchInterval)) ?? .fiveMinutes
    }

    static var pull: PullPreference {
        PullPreference(rawValue: store.string(forKey: PreferenceKey.pull) ?? "") ?? .gitConfig
    }

    static var branchSwitch: BranchSwitchPreference {
        BranchSwitchPreference(rawValue: store.string(forKey: PreferenceKey.branchSwitch) ?? "") ?? .ask
    }

    static var defaultBranch: String {
        let name = store.string(forKey: PreferenceKey.defaultBranch)?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "main" : name
    }

    static var editor: EditorChoice {
        EditorChoice(rawValue: store.string(forKey: PreferenceKey.editor) ?? "") ?? .xcode
    }

    static var gitExecutableURL: URL {
        let path = store.string(forKey: PreferenceKey.gitPath) ?? ""
        return path.isEmpty ? GitRunner.defaultExecutableURL : URL(filePath: path)
    }

    static var historyPageSize: Int {
        max(500, store.integer(forKey: PreferenceKey.historyPageSize))
    }

    static var recordCommandLog: Bool { store.bool(forKey: PreferenceKey.recordCommandLog) }

    static var blameIgnoreWhitespace: Bool { store.bool(forKey: PreferenceKey.blameIgnoreWhitespace) }

    static var diffIgnoreWhitespace: Bool { store.bool(forKey: PreferenceKey.diffIgnoreWhitespace) }

    static var showAvatars: Bool { store.bool(forKey: PreferenceKey.showAvatars) }
    static var blameDetectMoves: Bool { store.bool(forKey: PreferenceKey.blameDetectMoves) }
    static var useSSHAgent: Bool { store.bool(forKey: PreferenceKey.useSSHAgent) }
    static var watchFileChanges: Bool { store.bool(forKey: PreferenceKey.watchFileChanges) }

    /// Settings › Advanced › Reset "Don't Ask Again" Choices.
    static func resetDontAskAgainChoices() {
        store.removeObject(forKey: PreferenceKey.branchSwitch)
    }
}
