// Renders the Kaern app icon (a small cairn: three stacked stones, the top one in accent blue)
// into Kaern/Resources/Assets.xcassets/AppIcon.appiconset.
//
// Usage: swift script/make_icon.swift
import AppKit

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appending(path: "Kaern/Resources/Assets.xcassets/AppIcon.appiconset")

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    // macOS icon grid: 824pt rounded square centered in the 1024pt canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGradient(colors: [
        NSColor(srgbRed: 0.965, green: 0.969, blue: 0.980, alpha: 1),
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
    ])!.draw(in: tilePath, angle: 90)
    NSColor(white: 0, alpha: 0.08).setStroke()
    tilePath.lineWidth = 4
    tilePath.stroke()

    func stone(_ rect: NSRect, _ color: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 34, yRadius: 34)
        color.setFill()
        path.fill()
    }
    let gray = NSColor(srgbRed: 0.33, green: 0.34, blue: 0.37, alpha: 1)
    stone(NSRect(x: 292, y: 262, width: 440, height: 120), gray)
    stone(NSRect(x: 352, y: 410, width: 320, height: 120), gray)
    stone(NSRect(x: 427, y: 558, width: 170, height: 118), NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let url = output.appending(path: "icon_\(size).png")
    try render(size: size).write(to: url)
    print("wrote \(url.lastPathComponent)")
}
