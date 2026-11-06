import AppKit

// Kaern runs on the AppKit app lifecycle: it creates its windows itself from its session file,
// and its menus are AppKit menus validated against the current window (see `MainMenu`).
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
