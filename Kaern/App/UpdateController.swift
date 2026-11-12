import AppKit
import OSLog
import Sparkle

/// Kaern's updates (Sparkle). A release build reads the appcast in `SUFeedURL` once a day and asks
/// before installing what it finds; Kaern › Check for Updates… and Settings › General › Updates
/// check at once. Updates are signed with the EdDSA key whose public half is `SUPublicEDKey`
/// (Packaging/Info.plist, Packaging/README.md). Releases are offered to every copy, betas only with
/// Settings › General › Updates › Get beta versions.
///
/// Debug builds (`./script/build_and_run.sh`, the flow checks) never start it: they are built from
/// the source, and a test instance mustn't reach the network or show an update window.
final class UpdateController: NSObject, SPUUpdaterDelegate {
    static let shared = UpdateController()
    private static let log = Logger(subsystem: "com.progresshans.kaern", category: "updates")

    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private(set) var isRunning = false

    /// The feed and the public key are both in Info.plist.
    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return !feed.isEmpty && !key.isEmpty
    }

    /// Updates are offered in this build: a release build (test sessions are Debug only) that knows
    /// where to look.
    static var isAvailable: Bool {
        #if DEBUG
        return false
        #else
        return isConfigured
        #endif
    }

    /// At launch: starts the updater (its first scheduled check comes later, never during launch).
    func start() {
        guard Self.isAvailable, !isRunning else { return }
        // A beta keeps getting betas until they're turned off.
        UserDefaults.kaern.register(defaults: [SettingsKey.betaUpdates: Self.isBeta])
        do {
            try controller.updater.start()
            isRunning = true
        } catch {
            Self.log.error("The updater didn’t start: \(error.localizedDescription, privacy: .public)")
        }
    }

    var canCheckForUpdates: Bool { isRunning && controller.updater.canCheckForUpdates }

    /// Check for Updates…: Sparkle's own window says what it found.
    func checkForUpdates() {
        guard isRunning else { return }
        controller.checkForUpdates(nil)
    }

    /// Settings › General › Updates (Sparkle keeps the choice).
    var automaticallyChecksForUpdates: Bool {
        get { isRunning && controller.updater.automaticallyChecksForUpdates }
        set { if isRunning { controller.updater.automaticallyChecksForUpdates = newValue } }
    }

    /// This copy is a beta: its version is like 1.1.0-beta.2 (script/release.sh).
    static var isBeta: Bool {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?.contains("-beta.") == true
    }

    /// Settings › General › Updates › Get beta versions: the appcast's beta channel too. Turned on, it
    /// looks for one at once. Turned off, a beta stays until a newer release comes: Sparkle never
    /// installs an older version.
    var getsBetaVersions: Bool {
        get { UserDefaults.kaern.bool(forKey: SettingsKey.betaUpdates) }
        set {
            UserDefaults.kaern.set(newValue, forKey: SettingsKey.betaUpdates)
            if newValue, canCheckForUpdates { controller.updater.checkForUpdatesInBackground() }
        }
    }

    // MARK: SPUUpdaterDelegate

    /// Releases have no channel, so every copy sees them; betas are in "beta".
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        getsBetaVersions ? ["beta"] : []
    }

    /// Where the source is, for the About panel (Packaging/Info.plist's `KaernSourceURL`).
    static var sourceURL: URL? {
        (Bundle.main.infoDictionary?["KaernSourceURL"] as? String).flatMap(URL.init(string:))
    }
}

/// Kaern › About Kaern: the standard panel, with the license, where the source is, and Sparkle's notice.
enum AboutPanel {
    static func show() {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 4
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: center,
        ]
        let credits = NSMutableAttributedString(
            string: "Kaern is free software under the GNU Affero General Public License, version 3 or later.\n", attributes: base)
        if let source = UpdateController.sourceURL {
            credits.append(NSAttributedString(string: "Source: ", attributes: base))
            var link = base
            link[.link] = source
            let shown = source.absoluteString.replacingOccurrences(of: "https://", with: "")
            credits.append(NSAttributedString(string: shown + "\n", attributes: link))
        }
        credits.append(NSAttributedString(string: "Updates by Sparkle, under the MIT license (Sparkle-LICENSE.txt in the app).", attributes: base))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}
