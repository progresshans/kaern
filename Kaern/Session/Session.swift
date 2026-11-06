import Foundation
import OSLog

/// What Kaern brings back at launch. Kaern writes this itself (macOS window restoration is
/// off), so tabs, their order, folder groups and the selected tab survive quitting, a crash or
/// a restart. It holds a list of windows, so a later "Move Tab to New Window" needs no change.
struct Session: Codable, Equatable {
    static let currentVersion = 1

    var version = Session.currentVersion
    /// Open windows, front to back.
    var windows: [WindowState] = []
    /// The last window the user closed with tabs in it, so the empty window can offer
    /// "Reopen N Tabs".
    var lastClosed: ClosedWindow?
    /// Recently opened repositories, newest first (the empty window's list).
    var recent: [RecentRepository] = []

    struct WindowState: Codable, Equatable, Identifiable {
        var id: UUID
        /// Window frame in screen coordinates (`nil`: let Kaern place it).
        var frame: CGRect?
        var isFullScreen = false
        /// Strip order. Members of a group are always next to each other.
        var tabs: [TabState] = []
        var groups: [GroupState] = []
        var activeTab: UUID?
        var showsSidebar = true
        var showsDetails = true
    }

    struct TabState: Codable, Equatable, Identifiable {
        var id: UUID
        /// The repository folder (the working tree's top level).
        var path: String
        var group: UUID?
    }

    struct GroupState: Codable, Equatable, Identifiable {
        var id: UUID
        var name: String
        var color: GroupColor
        var collapsed = false
    }

    struct ClosedWindow: Codable, Equatable {
        var window: WindowState
        var date: Date
    }

    struct RecentRepository: Codable, Equatable, Identifiable {
        var path: String
        var name: String
        /// The folder group it was last in, for grouping the recent list.
        var groupName: String?
        var groupColor: GroupColor?
        var lastOpened: Date

        var id: String { path }
    }
}

/// Reads and writes the session file, `~/Library/Application Support/Kaern/Session.json`.
/// Writes are atomic, so a crash mid-write leaves the previous session intact.
struct SessionStore {
    let url: URL
    private static let log = Logger(subsystem: "com.progresshans.kaern", category: "session")

    static var defaultURL: URL {
        #if DEBUG
        // `-KaernSessionFile <path>` keeps test sessions away from the real one.
        if let custom = UserDefaults.standard.string(forKey: "KaernSessionFile"), !custom.isEmpty {
            return URL(filePath: (custom as NSString).expandingTildeInPath)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base.appending(path: "Kaern", directoryHint: .isDirectory).appending(path: "Session.json")
    }

    init(url: URL = SessionStore.defaultURL) {
        self.url = url
    }

    func load() -> Session {
        guard let data = try? Data(contentsOf: url) else { return Session() }
        do {
            let session = try Self.decoder.decode(Session.self, from: data)
            guard session.version <= Session.currentVersion else {
                Self.log.error("Session file is from a newer Kaern (version \(session.version)); starting empty")
                return Session()
            }
            return session
        } catch {
            Self.log.error("Couldn't read the session file: \(error.localizedDescription, privacy: .public)")
            // Keep the unreadable file for inspection instead of overwriting it silently.
            let backup = url.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            return Session()
        }
    }

    func save(_ session: Session) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encoder.encode(session)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.log.error("Couldn't write the session file: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
