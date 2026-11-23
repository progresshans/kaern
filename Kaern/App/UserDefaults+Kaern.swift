import Foundation

extension UserDefaults {
    /// Where Kaern keeps its settings: column widths, diff layout, file tree, pull strategy, git path.
    /// Every setting Kaern saves goes through this store, `@AppStorage(key, store: .kaern)` included.
    ///
    /// A Debug test session has its own settings. The flow launcher archives its private preferences
    /// domain beside the session as `<session>.settings.plist`. A manually launched test session
    /// uses that plist directly. Launch arguments such as `-KaernColumnRef 176` take precedence.
    static let kaern: UserDefaults = {
        #if DEBUG
        if let stem = TestSession.stem {
            // Flow checks use a native preferences domain per session. Their launcher imports
            // and exports the session plist. Accept only IDs in the test namespace.
            if let id = UserDefaults.standard.string(forKey: "KaernCheckPreferencesID").flatMap(UUID.init(uuidString:)) {
                return UserDefaults(suiteName: "com.progresshans.kaern.check." + id.uuidString.lowercased())!
            }
            // A suite named by an absolute path is that plist file (CFPreferences adds `.plist`).
            // Only the app's own bundle identifier and the global domain are refused as names.
            return UserDefaults(suiteName: stem + ".settings")!
        }
        #endif
        return .standard
    }()
}
