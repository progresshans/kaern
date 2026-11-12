// Renders the background of the DMG's window into Packaging/DMG (background.png and background@2x.png): the stones
// of Kaern's icon (script/make_icon.swift) laid as stepping stones from the app to the Applications folder, the last
// one blue, and a line saying what to do. script/release.sh lays the window out to match (DMG_* there).
//
// Usage: swift script/make_dmg_background.swift
import AppKit

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appending(path: "Packaging/DMG")

/// The window's content area, in points; release.sh's DMG_WINDOW has the same size.
let size = NSSize(width: 640, height: 400)
/// The icons' centers (release.sh's DMG_APP and DMG_APPLICATIONS), from the top left; they're 128 pt.
let appCenter = NSPoint(x: 180, y: 170)
let applicationsCenter = NSPoint(x: 460, y: 170)

/// Light and opaque, in either appearance: over a background picture Finder draws the icons' labels in black even in
/// Dark Mode, and the picture's clear parts in white. The fill is the icon tile's (script/make_icon.swift).
let fill = NSGradient(colors: [
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
    NSColor(srgbRed: 0.957, green: 0.961, blue: 0.973, alpha: 1),
])!
let stoneGray = [
    NSColor(srgbRed: 0.78, green: 0.79, blue: 0.81, alpha: 1),
    NSColor(srgbRed: 0.66, green: 0.67, blue: 0.70, alpha: 1),
    NSColor(srgbRed: 0.55, green: 0.56, blue: 0.59, alpha: 1),
]
let blue = NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)
let captionColor = NSColor(srgbRed: 0.53, green: 0.53, blue: 0.56, alpha: 1)

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    // Points, not pixels: the context draws in points (so the 2x picture at twice the scale), and the 2x picture says
    // 144 dpi, which tiffutil -cathidpicheck pairs with the 1x one.
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    fill.draw(in: NSRect(origin: .zero, size: size), angle: -90)

    /// A rectangle given from the top left, as the layout is.
    func rect(centerX: CGFloat, centerY: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: centerX - width / 2, y: size.height - centerY - height / 2, width: width, height: height)
    }
    func stone(_ frame: NSRect, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: frame, xRadius: frame.height * 0.32, yRadius: frame.height * 0.32).fill()
    }

    // Stepping stones between the icons, rising toward Applications, each a little bigger; the last is the blue one
    // from the top of the cairn.
    let start = appCenter.x + 64 + 22, end = applicationsCenter.x - 64 - 26
    let stones: [(CGFloat, CGFloat, CGFloat, NSColor)] = [  // (along 0…1, width, height, color)
        (0.00, 15, 9, stoneGray[0]),
        (0.32, 18, 10.5, stoneGray[1]),
        (0.65, 21, 12, stoneGray[2]),
        (1.00, 24, 14, blue),
    ]
    for (along, width, height, color) in stones {
        let x = start + (end - start) * along
        let y = appCenter.y + 14 - 22 * along
        stone(rect(centerX: x, centerY: y, width: width, height: height), color)
    }

    // What to do, under the labels Finder draws below the icons.
    let caption = NSAttributedString(string: "Drag Kaern to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: captionColor,
    ])
    let captionSize = caption.size()
    caption.draw(at: NSPoint(x: (size.width - captionSize.width) / 2, y: size.height - 304 - captionSize.height / 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (scale, name) in [(CGFloat(1), "background.png"), (2, "background@2x.png")] {
    let url = output.appending(path: name)
    try render(scale: scale).write(to: url)
    print("wrote Packaging/DMG/\(name)")
}
