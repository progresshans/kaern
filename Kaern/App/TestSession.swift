#if DEBUG
import Foundation

/// An instance on a test session: a Debug build launched with `-KaernSessionFile <path>`.
/// What it would change outside its sample repositories stays next to that session file, so a
/// test run never touches your session, settings, git config or Keychain:
/// - `<session>.settings.plist`: Kaern's settings (`UserDefaults.kaern`)
/// - `<session>.gitconfig`: git's global config, unless the launcher passes `GIT_CONFIG_GLOBAL`
/// - `<session>.credentials`: what a sign-in hands to git's credential helper
enum TestSession {
    /// The session file without its extension: `/tmp/run/session-test` for `session-test.json`.
    static var stem: String? {
        SessionStore.testSessionPath.map { (($0 as NSString).expandingTildeInPath as NSString).deletingPathExtension }
    }

    /// Environment for every git command a test instance runs.
    static func gitEnvironment() -> [String: String] {
        guard let stem else { return [:] }
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        if inherited["GIT_CONFIG_GLOBAL"] == nil {
            let config = stem + ".gitconfig"
            if !FileManager.default.fileExists(atPath: config) {
                // An identity of its own, so commits in sample repositories work.
                try? "[user]\n\tname = Kaern Test\n\temail = test@kaern.invalid\n"
                    .write(toFile: config, atomically: true, encoding: .utf8)
            }
            environment["GIT_CONFIG_GLOBAL"] = config
        }
        // Credentials go to a file, never the Keychain: an empty credential.helper clears the
        // helpers git's other config lists (osxkeychain) before the file-based one.
        let count = Int(inherited["GIT_CONFIG_COUNT"] ?? "") ?? 0
        environment["GIT_CONFIG_KEY_\(count)"] = "credential.helper"
        environment["GIT_CONFIG_VALUE_\(count)"] = ""
        environment["GIT_CONFIG_KEY_\(count + 1)"] = "credential.helper"
        environment["GIT_CONFIG_VALUE_\(count + 1)"] = "store --file=" + shellQuoted(stem + ".credentials")
        environment["GIT_CONFIG_COUNT"] = String(count + 2)
        return environment
    }

    /// This instance's launch arguments, to start it again on the same test session.
    static var launchArguments: [String] { Array(ProcessInfo.processInfo.arguments.dropFirst()) }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif
