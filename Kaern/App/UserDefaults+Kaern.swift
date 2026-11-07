import Foundation

extension UserDefaults {
    /// Where Kaern keeps its settings: column widths, diff layout, file tree, pull strategy, git path.
    /// Every setting Kaern saves goes through this store, `@AppStorage(key, store: .kaern)` included.
    ///
    /// An instance on a test session (Debug, `-KaernSessionFile <path>`) keeps its settings next to
    /// that session file instead, as `<session>.settings.plist`. A test run then never changes your
    /// settings, and a new test session starts from the defaults. Launch arguments
    /// (`-KaernColumnRef 176`) still override what either store holds.
    static let kaern: UserDefaults = {
        #if DEBUG
        if let session = SessionStore.testSessionPath {
            let file = ((session as NSString).expandingTildeInPath as NSString).deletingPathExtension
            // A suite named by an absolute path is that plist file (CFPreferences adds `.plist`).
            // Only the app's own bundle identifier and the global domain are refused as names.
            return UserDefaults(suiteName: file + ".settings")!
        }
        #endif
        return .standard
    }()
}
