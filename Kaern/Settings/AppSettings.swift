import AppKit
import KaernKit

/// The keys of Kaern's settings (Settings window), all kept in `UserDefaults.kaern`.
///
/// Older keys live next to the code that uses them: `KaernGitPath` (`GitLocator.userPathKey`),
/// `KaernDiffLayout` / `KaernIgnoreWhitespace` / `KaernFileTree` (`DiffPreferences`),
/// `KaernPullStrategy`, `KaernColumn…`.
enum SettingsKey {
    // General
    static let onLaunch = "KaernOnLaunch"
    static let repositorySwitching = "KaernRepositorySwitching"
    static let groupFolders = "KaernGroupFolders"
    static let tabCharacters = "KaernTabCharacters"
    static let autoFetch = "KaernAutoFetch"
    static let autoFetchMinutes = "KaernAutoFetchMinutes"
    static let theme = "KaernTheme"
    // Accounts
    static let accounts = "KaernAccounts"
    // Diff
    static let diffContext = "KaernDiffContext"
    static let diffWords = "KaernDiffWords"
    static let diffWrap = "KaernDiffWrap"
    static let diffFontName = "KaernDiffFontName"
    static let diffFontSize = "KaernDiffFontSize"
    // Advanced
    static let sshAgent = "KaernSSHAgent"
    static let watchFiles = "KaernWatchFiles"
    static let historyLoading = "KaernHistoryLoading"
}

/// What a launch opens (General › On launch).
enum LaunchBehavior: String, CaseIterable {
    /// The windows and tabs from last time (the default).
    case reopen
    /// One empty window; last time's tabs wait behind its Reopen button.
    case welcome
    /// No window until the Dock icon is clicked or a repository is opened.
    case nothing
}

/// How a window switches repositories (General › Switch repositories).
enum RepositorySwitching: String, CaseIterable {
    case tabs, sidebar, toolbar
}

/// System, Light or Dark (General › Appearance).
enum AppTheme: String, CaseIterable {
    case system, light, dark

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// How history loads (Advanced › Large repositories).
enum HistoryLoading: String, CaseIterable {
    /// One page first, the next ones as you scroll (the default).
    case pages
    /// Everything up front.
    case all
}

/// Reads settings with their defaults. Views bind with `@AppStorage(key, store: .kaern)`.
@MainActor
enum AppSettings {
    private static var store: UserDefaults { .kaern }

    static var onLaunch: LaunchBehavior {
        LaunchBehavior(rawValue: store.string(forKey: SettingsKey.onLaunch) ?? "") ?? .reopen
    }

    static var groupsFolders: Bool { store.object(forKey: SettingsKey.groupFolders) as? Bool ?? true }

    /// Tabs shrink until about this many characters show (8, 12 or 16).
    static var tabCharacters: Int {
        let value = store.integer(forKey: SettingsKey.tabCharacters)
        return [8, 12, 16].contains(value) ? value : 12
    }

    static var autoFetch: Bool { store.object(forKey: SettingsKey.autoFetch) as? Bool ?? true }

    /// 1, 5 or 15 minutes.
    static var autoFetchMinutes: Int {
        let value = store.integer(forKey: SettingsKey.autoFetchMinutes)
        return [1, 5, 15].contains(value) ? value : 5
    }

    static var theme: AppTheme { AppTheme(rawValue: store.string(forKey: SettingsKey.theme) ?? "") ?? .system }

    /// Unchanged lines around each change (3, 5 or 10).
    static var diffContext: Int {
        let value = store.integer(forKey: SettingsKey.diffContext)
        return [3, 5, 10].contains(value) ? value : 3
    }

    static var diffWords: Bool { store.object(forKey: SettingsKey.diffWords) as? Bool ?? true }
    static var diffWraps: Bool { store.object(forKey: SettingsKey.diffWrap) as? Bool ?? true }

    static var usesSSHAgent: Bool { store.object(forKey: SettingsKey.sshAgent) as? Bool ?? true }
    static var watchesFiles: Bool { store.object(forKey: SettingsKey.watchFiles) as? Bool ?? true }
    static var historyLoading: HistoryLoading {
        HistoryLoading(rawValue: store.string(forKey: SettingsKey.historyLoading) ?? "") ?? .pages
    }

    // MARK: Appearance

    /// Applies General › Appearance. A Debug run's `-KaernAppearance light|dark` wins, so tests
    /// can check both looks without changing the setting.
    static func applyTheme() {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "KaernAppearance") {
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
            return
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
            return
        default:
            break
        }
        #endif
        NSApp.appearance = theme.appearance
    }

    // MARK: Diff font

    /// The diff font (Diff › Font): SF Mono 12 pt unless chosen otherwise.
    static var diffFont: NSFont {
        let size = store.double(forKey: SettingsKey.diffFontSize)
        let pointSize = size >= 8 && size <= 24 ? size : 12
        if let name = store.string(forKey: SettingsKey.diffFontName), !name.isEmpty, let font = NSFont(name: name, size: pointSize) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
    }

    /// "SF Mono, 12 pt".
    static var diffFontDescription: String {
        let font = diffFont
        let name = store.string(forKey: SettingsKey.diffFontName).flatMap { $0.isEmpty ? nil : font.displayName } ?? "SF Mono"
        let size = font.pointSize
        return "\(name), \(size == size.rounded() ? String(Int(size)) : String(format: "%.1f", size)) pt"
    }
}

extension Notification.Name {
    /// A setting that running parts of Kaern apply right away changed (theme, auto-fetch…).
    static let kaernSettingsChanged = Notification.Name("KaernSettingsChanged")
}
