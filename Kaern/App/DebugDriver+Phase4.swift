#if DEBUG
import AppKit
import KaernKit

/// Phase-4 debug commands: Settings, conflicts, stashes, sheets, interactive rebase, file
/// history and blame, the Activity popover and auto-fetch.
extension DebugDriver {
    static let phase4Commands: Set<String> = [
        "settings", "setting", "fakeAccount",
    ]

    func phase4(_ command: String, _ args: [String]) {
        switch command {
        case "settings":
            // settings <General|Accounts|Git|Diff|Advanced> | settings close
            if args.first == "close" {
                SettingsWindowController.shared.window?.close()
            } else {
                let pane = SettingsWindowController.Pane(rawValue: args.first ?? "General") ?? .general
                SettingsWindowController.shared.show(pane)
            }
            return
        case "setting":
            // setting <key> <value> — in this test instance's own settings file.
            guard args.count >= 2 else { return }
            let value = args.dropFirst().joined(separator: " ")
            if let number = Int(value) {
                UserDefaults.kaern.set(number, forKey: args[0])
            } else if value == "YES" || value == "NO" {
                UserDefaults.kaern.set(value == "YES", forKey: args[0])
            } else if value == "-" {
                UserDefaults.kaern.removeObject(forKey: args[0])
            } else {
                UserDefaults.kaern.set(value, forKey: args[0])
            }
            NotificationCenter.default.post(name: .kaernSettingsChanged, object: args[0])
            if args[0] == SettingsKey.theme { AppSettings.applyTheme() }
            return
        case "fakeAccount":
            // fakeAccount <login> <host> [Full Name] — shows an account without a token (Accounts pane).
            guard args.count >= 2 else { return }
            var list = HostingAccount.all
            list.append(HostingAccount(kind: args[1].contains("gitlab") ? .gitlab : .github, host: args[1], login: args[0],
                                       name: args.count > 2 ? args.dropFirst(2).joined(separator: " ") : nil, userID: 4_120_731,
                                       email: nil))
            HostingAccount.all = list
            return
        default:
            break
        }
    }
}
#endif
