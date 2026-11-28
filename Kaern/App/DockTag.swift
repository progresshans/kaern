#if DEBUG
import AppKit

/// A tag on a Debug build's Dock icon, so it isn't taken for the installed Kaern beside it: DEV on a build you run
/// yourself (build_and_run.sh, Xcode), TEST on an instance of a test session (`-KaernSessionFile`: the flow checks,
/// checks/launch.sh). Release builds have none of it.
///
/// Only the Dock tile changes (`NSDockTile.contentView`): the app's icon (`NSApp.applicationIconImage`) stays as it
/// is, so the alerts drawn in the window, and the checks' pictures of them, keep the plain one.
enum DockTag: String {
    case dev = "DEV"
    case test = "TEST"

    /// This instance's: a test session's, or a build of your own.
    static var current: DockTag { SessionStore.testSessionPath != nil ? .test : .dev }

    /// The tag on this instance's Dock tile, once `install()` has run.
    private(set) static var shown: DockTag?

    var color: NSColor {
        switch self {
        case .dev: NSColor(srgbRed: 0.96, green: 0.45, blue: 0.05, alpha: 1)
        case .test: NSColor(srgbRed: 0.53, green: 0.32, blue: 0.92, alpha: 1)
        }
    }

    static func install() {
        let tile = NSApp.dockTile
        tile.contentView = DockTagView(current, size: tile.size)
        tile.display()
        shown = current
    }
}

/// The app's icon with a tag on its top right corner. Drawn in the icon's own grid (an 824-unit tile in a 1024-unit
/// canvas, `script/make_icon.swift`), the tag and its shadow inside the canvas: the Dock shows nothing past it.
final class DockTagView: NSView {
    let kind: DockTag

    init(_ kind: DockTag, size: NSSize) {
        self.kind = kind
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        context.imageInterpolation = .high
        NSApp.applicationIconImage?.draw(in: bounds)

        NSGraphicsContext.saveGraphicsState()
        let grid = NSAffineTransform()
        grid.scale(by: bounds.width / 1024)
        grid.concat()
        let kern: CGFloat = 6
        let font = NSFont.systemFont(ofSize: 162, weight: .heavy)
        let text = NSAttributedString(string: kind.rawValue, attributes: [.font: font, .foregroundColor: NSColor.white, .kern: kern])
        let textWidth = text.size().width - kern  // no kern after the last letter
        let height: CGFloat = 270
        let tag = NSRect(x: 990 - (textWidth + 120), y: 990 - height, width: textWidth + 120, height: height)
        let path = NSBezierPath(roundedRect: tag, xRadius: 68, yRadius: 68)

        // A shadow's blur and offset are in device pixels whatever the drawing's scale: scaled to the grid here, or a
        // small tile's shadow would spread past the canvas and be cut off at its edge.
        NSGraphicsContext.saveGraphicsState()
        let scale = hypot(context.cgContext.ctm.a, context.cgContext.ctm.b)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
        shadow.shadowBlurRadius = 12 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -6 * scale)
        shadow.set()
        kind.color.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.setStroke()
        path.lineWidth = 22
        path.stroke()
        // The capitals centred by their cap height.
        text.draw(at: NSPoint(x: tag.midX - textWidth / 2, y: tag.midY - font.capHeight / 2 + font.descender))
        NSGraphicsContext.restoreGraphicsState()
    }
}
#endif
